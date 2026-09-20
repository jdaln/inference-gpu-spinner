# shellcheck shell=bash
# Sourced by bin/spin. Lifecycle commands: persistent stack, up/down, start/stop, status/logs/ssh/plan.

cmd_persistent_init() {
  require_token
  # Disk size/tier are the standing-cost knobs — let the operator set them in .env instead of
  # remembering tofu -var syntax. Explicit -var passed after (in "$@") still wins. See .env.example.
  local pv=()
  [ -n "${WEIGHTS_SIZE_GB:-}" ] && pv+=(-var "weights_size_gb=$WEIGHTS_SIZE_GB")
  [ -n "${WEIGHTS_TIER:-}" ]    && pv+=(-var "weights_tier=$WEIGHTS_TIER")

  # Warn before a size change: growing the disk raises the 24/7 bill, and UpCloud CANNOT shrink a
  # disk (only decommission + re-init smaller). Compare the requested size to the live disk.
  local want="${WEIGHTS_SIZE_GB:-500}" diskid cur
  diskid="$(tofu_output "$PERSIST_DIR" weights_storage_id)"
  if [ -n "$diskid" ] && printf '%s' "$want" | grep -qE '^[0-9]+$'; then
    # || true: advisory size comparison. Under `set -e` with pipefail a failed API call here
    # aborted the command substitution and killed bin/spin with a bare exit code (seen: 56).
    cur="$(api GET "/storage/$diskid" 2>/dev/null | jq -r '.storage.size // empty' || true)"
    if printf '%s' "$cur" | grep -qE '^[0-9]+$'; then
      local rate=226; [ "${WEIGHTS_TIER:-maxiops}" = "standard" ] && rate=86
      if [ "$want" -gt "$cur" ]; then
        warn "weights disk will GROW ${cur}→${want} GB (≈ +€$(( (want-cur)*rate/1000 ))/mo at ${WEIGHTS_TIER:-maxiops}). Disks cannot shrink later."
      elif [ "$want" -lt "$cur" ]; then
        warn "requested ${want} GB < current ${cur} GB — UpCloud cannot SHRINK a disk, so apply will fail."
        warn "to reduce: 'bin/spin persistent-destroy' then re-init at the smaller size (re-downloads weights)."
      fi
    fi
  fi

  tofu_init "$PERSIST_DIR"

  # Report the failure rather than letting `set -e` end the script with nothing on screen. A silent
  # return here was indistinguishable from success, and `up` called this internally and ended the
  # same way.
  local rc=0
  "$TOFU" -chdir="$PERSIST_DIR" apply ${pv[@]+"${pv[@]}"} "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    die "tofu apply exited $rc in $PERSIST_DIR. Nothing was created.
    If it printed nothing above, run it directly to see the reason:
      $TOFU -chdir=$PERSIST_DIR apply"
  fi

  # An apply can exit 0 having created nothing. The outputs are what the rest of the CLI reads, so
  # check those rather than the exit status alone.
  local ip
  ip="$(tofu_output "$PERSIST_DIR" floating_ip)"
  if [ -z "$ip" ]; then
    die "apply finished but $PERSIST_DIR has no floating_ip output, so the stack is not up.
    Check what the state holds:  $TOFU -chdir=$PERSIST_DIR state list"
  fi
  log "Persistent stack ready. Floating IP: $ip"
}

# Decommission the persistent stack → €0 standing cost. prevent_destroy (main.tf) blocks a plain
# `tofu destroy` (and must be a literal, so it can't be toggled by a var), so this deletes the disk +
# releases the IP via the API, then drops them from tofu state (the stack stays declarable — a later
# persistent-init recreates both fresh). IRREVERSIBLE: loses cached weights + the stable IP/cert.
cmd_persistent_destroy() {
  require_token
  local yes=""; [ "${1:-}" = "--yes" ] && yes=1
  local srv; srv="$(tofu_out server_uuid 2>/dev/null || true)"
  # tofu prints a "no outputs found" warning (not a UUID) once the server is down — only a real UUID
  # means a server still exists; anything else (warning text / empty) is treated as "no server".
  printf '%s' "$srv" | grep -qE '^[0-9a-fA-F-]{36}$' || srv=""
  [ -z "$srv" ] || die "an ephemeral GPU server still exists ($srv) — run 'bin/spin down' first."
  local diskid ip
  diskid="$(tofu_output "$PERSIST_DIR" weights_storage_id)"
  ip="$(tofu_output "$PERSIST_DIR" floating_ip)"
  [ -n "$diskid$ip" ] || die "no persistent resources in state — nothing to decommission."
  warn "PERSISTENT DECOMMISSION — IRREVERSIBLE. This will:"
  printf '  \033[1;33m•\033[0m DELETE weights disk %s (cached models + Caddy TLS cert)\n' "${diskid:-?}" >&2
  printf '  \033[1;33m•\033[0m RELEASE floating IP %s (the stable <dashed>.sslip.io hostname is lost)\n' "${ip:-?}" >&2
  printf '  Next spin-up re-downloads ALL weights and gets a NEW IP + cert. Standing cost → €0.\n' >&2
  [ -n "$yes" ] || die "refusing without confirmation. Re-run:  bin/spin persistent-destroy --yes"
  if [ -n "$diskid" ]; then
    if api DELETE "/storage/$diskid" >/dev/null 2>&1; then log "deleted weights disk $diskid"
    else warn "could not delete disk $diskid (already gone / still attached?)"; fi
  fi
  if [ -n "$ip" ]; then
    if api DELETE "/ip_address/$ip" >/dev/null 2>&1; then log "released floating IP $ip"
    else warn "could not release IP $ip (already gone?)"; fi
  fi
  "$TOFU" -chdir="$PERSIST_DIR" state rm upcloud_storage.weights upcloud_floating_ip_address.vip >/dev/null 2>&1 || true
  log "Persistent stack decommissioned. Standing cost → €0. Re-create anytime with 'bin/spin persistent-init'."
}

cmd_up() {
  require_token
  local model="${VLLM_MODEL:-qwen36}" plan="" flags_explicit="" swap_profile=""
  local tf_args=() ans_args=()
  local sd_at="${AUTO_SHUTDOWN_AT:-}" sd_tz="${AUTO_SHUTDOWN_TZ:-}" sd_enabled="${AUTO_SHUTDOWN:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)        model="$2"; flags_explicit=1; shift 2 ;;
      --plan)         plan="$2";  flags_explicit=1; shift 2 ;;
      --swap-profile) swap_profile="$2"; flags_explicit=1; shift 2 ;;
      --allow-unvalidated) ans_args+=(-e allow_unvalidated_model=true); shift ;;
      # Pass an Ansible extra-var straight through. Extra vars outrank the profile's own
      # include_vars, so this is how you deploy the same profile at a different setting without
      # editing the file: `-e max_model_len=262144` for a token-ceiling search, or the fallbacks
      # several profiles document in their own comments (`-e tensor_parallel_size=4`,
      # `-e vllm_image_override=...`). Repeatable. The deployed value then differs from the file,
      # so record which one was live, and re-run without -e before you tear down.
      -e|--set)       [ $# -ge 2 ] || die "$1 needs a key=value argument."
                      case "$2" in *=*) ;; *) die "$1 expects key=value, got '$2'." ;; esac
                      ans_args+=(-e "$2"); shift 2 ;;
      --shutdown-at)  sd_at="$2"; shift 2 ;;
      --shutdown-tz)  sd_tz="$2"; shift 2 ;;
      --no-shutdown)  sd_enabled="false"; shift ;;
      --shutdown)     sd_enabled="true";  shift ;;
      *) die "unknown option: $1" ;;
    esac
  done

  # Multi-model swap: turn --swap-profile <name> into the ansible vars that enable llama-swap. The
  # preset (ansible/swap-profiles/<name>.yml) is loaded whole via -e @file (Ansible reads its
  # swap_profiles list). Validate the name here so a typo fails before any tofu/GPU spend.
  local swap_file=""
  if [ -n "$swap_profile" ]; then
    swap_file="ansible/swap-profiles/${swap_profile}.yml"
    [ -f "$swap_file" ] || die "unknown swap profile '$swap_profile'. See: bin/spin swap-profiles"
    ans_args+=(-e multi_model_enabled=true -e "@$swap_file")
  fi

  # Resume an existing STOPPED server (e.g. after the auto-off safety) instead of recreating —
  # the image + model are already on the intact disks, so this is fast. Run `bin/spin down` first
  # if you want a fresh box.
  local existing; existing="$(tofu_out server_uuid 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$(server_state "$existing")" = "stopped" ]; then
    # Resume can't change the model or plan — refuse rather than silently ignore explicit flags.
    [ -z "$flags_explicit" ] || die "a STOPPED server exists; resume can't apply --model/--plan.
    Either 'bin/spin start' (resume as-is), or 'bin/spin down' first for a fresh box with new flags."
    log "Existing server $existing is stopped — resuming (no rebuild)..."
    refresh_firewall
    api POST "/server/$existing/start" >/dev/null
    wait_ssh "$(tofu_out ssh_host)"
    log "Resumed. Endpoint: $(tofu_out endpoint)  (vLLM auto-starts on boot; give it ~a minute)"
    return 0
  fi

  [ -n "${ACME_EMAIL:-}" ]   || die "ACME_EMAIL not set (needed for Let's Encrypt)."
  # The vllm role rejects placeholder domains, but only after the server exists and ~40 tasks
  # have run. Same test here costs nothing and fails before anything is provisioned.
  if printf '%s' "$ACME_EMAIL" | tr '[:upper:]' '[:lower:]' \
     | grep -qE '@(example\.(com|org|net)|[^@]*\.(invalid|local|test))$'; then
    die "ACME_EMAIL is still a placeholder ($ACME_EMAIL).
    Let's Encrypt refuses these domains, so Caddy would never get a certificate and HTTPS would
    fail after an otherwise clean deploy. Set a real, deliverable address in .env."
  fi
  [ -n "${VLLM_API_KEY:-}" ] || die "VLLM_API_KEY not set (vLLM auth)."
  check_tfvars
  # Plan resolution, highest priority first: an explicit --plan, then the plan of a server that
  # already exists, then the one the profile/preset names, then the OpenTofu default.
  local want_plan=""
  if [ -n "$swap_profile" ]; then want_plan="$(profile_plan "$swap_file" swap_plan)"
  else want_plan="$(profile_plan "ansible/models/${model}.yml" min_plan)"; fi

  # A profile with no parseable min_plan produces an empty want_plan, which silently disables both
  # guards below: it inherits whatever box is live (no mismatch check) or falls through to the
  # OpenTofu default, and the mistake only surfaces after Ansible has run. kimi-k3 is the live
  # example — no UpCloud plan satisfies its 280 GB per-GPU floor, so it deliberately has no
  # min_plan, and it is precisely the profile that must not latch onto a running server.
  # Refuse unless the operator names the tier themselves.
  if [ -z "$plan" ] && [ -z "$want_plan" ] && [ -z "$swap_profile" ]; then
    die "profile '${model}' declares no usable min_plan, so bin/spin cannot choose a tier for it.
    Either the profile is missing the field, or no plan fits it (kimi-k3 needs ~280 GB per GPU;
    nothing sold here has that). Pass --plan <id> to name the tier explicitly and accept the cost.
    Plans and prices: tests/plans.txt"
  fi

  # Guard against an unintended resize: with no --plan, a re-run on an EXISTING server would plan
  # the config default against the live box (auto-approve!). Inherit the current plan from state.
  if [ -z "$plan" ] && [ -n "$existing" ]; then
    plan="$(state_plan)"
    # A live box on the wrong tier is worse than an error here: preflight only refuses after the
    # weights download, so an L40S inherited under a 390 GB profile burns the pull first.
    if [ -n "$plan" ] && [ -n "$want_plan" ] && [ "$plan" != "$want_plan" ]; then
      die "the existing server is $plan but '${swap_profile:-$model}' expects $want_plan.
    Pass --plan explicitly to override, or 'bin/spin down' first to rebuild on the right tier."
    fi
    [ -n "$plan" ] && log "No --plan given; keeping the existing server's plan ($plan)."
  fi
  if [ -z "$plan" ] && [ -n "$want_plan" ]; then
    plan="$want_plan"
    log "No --plan given; using $plan from the ${swap_profile:-$model} profile."
  fi
  [ -n "$plan" ] && tf_args+=(-var "plan=$plan")
  build_operator_tf_args
  tf_args+=(${OPERATOR_TF_ARGS[@]+"${OPERATOR_TF_ARGS[@]}"})
  assert_operator_reachable
  [ -n "$sd_enabled" ] && ans_args+=(-e "auto_shutdown_enabled=$sd_enabled")
  [ -n "$sd_at" ]      && ans_args+=(-e "auto_shutdown_time=$sd_at")
  [ -n "$sd_tz" ]      && ans_args+=(-e "auto_shutdown_timezone=$sd_tz")

  # If a previous `down` auto-decommissioned the persistent disk, recreate it first — the server
  # can't attach a disk that no longer exists. The weights_storage_id output goes stale after a
  # decommission (`state rm` doesn't recompute outputs), so verify against the API. And tell "the
  # API says it's gone" from "the API call failed": curl exit 22 is the -f HTTP-error case (404 =
  # really gone), anything else is a transport failure that must not trigger a recreate.
  local wid disk_ok="" api_rc=0; wid="$(tofu_output "$PERSIST_DIR" weights_storage_id)"
  if printf '%s' "$wid" | grep -qE '^[0-9a-fA-F-]{36}$'; then
    api GET "/storage/$wid" >/dev/null 2>&1 || api_rc=$?
    if [ "$api_rc" -eq 0 ]; then
      disk_ok=1
    elif [ "$api_rc" -ne 22 ]; then
      warn "could not confirm the weights disk via the UpCloud API (curl exit $api_rc) — assuming it still exists rather than recreating it. Re-run if the deploy then fails on a missing disk."
      disk_ok=1
    fi
  fi
  if [ -z "$disk_ok" ]; then
    log "Persistent weights disk missing (decommissioned on a previous down?) — recreating it first..."
    # -auto-approve: this runs inside `up`, which is non-interactive throughout. Without it the
    # apply stops at tofu's confirmation prompt, and a cancelled apply exits non-zero, so `set -e`
    # ends the whole spin-up with nothing but the line above on screen.
    cmd_persistent_init -auto-approve
  fi

  log "Provisioning GPU server (model=$model)..."
  tofu_init "$EPHEMERAL_DIR"
  local apply_log; apply_log="$(mktemp)"
  trap 'rm -f "$apply_log"' RETURN
  if ! "$TOFU" -chdir="$EPHEMERAL_DIR" apply -auto-approve ${tf_args[@]+"${tf_args[@]}"} 2>&1 | tee "$apply_log"; then
    if grep -qiE 'SERVER_RESOURCES_UNAVAILABLE|resources?[ _]unavailable|out of stock|no (host|capacity)' "$apply_log"; then
      rm -f "$apply_log"
      die "UpCloud has no '${plan:-the default plan}' capacity in fi-hel2 right now.
    Retry shortly, or override the profile's tier with another that fits the model
    (tiers and prices: tests/plans.txt and docs/gpu-spinner.md):
      bin/spin up --model $model --plan GPU-16xCPU-80GB-1xRTXPRO6000   # 96 GB, usually available
      bin/spin up --model $model --plan GPU-12xCPU-240GB-1xH100        # or ...-1xB200"
    fi
    rm -f "$apply_log"
    die "tofu apply failed (see output above)."
  fi
  rm -f "$apply_log"

  local host sslip endpoint
  host="$(tofu_out ssh_host)"; sslip="$(tofu_out sslip_host)"; endpoint="$(tofu_out endpoint)"
  [ -n "$host" ] || die "could not read ssh_host from tofu outputs."

  log "Writing inventory ($host)..."
  mkdir -p "$(dirname "$INVENTORY")"
  printf '[gpu]\n%s ansible_user=root\n' "$host" > "$INVENTORY"

  wait_ssh "$host"

  # ansible-playbook exits 0 when the host pattern matches nothing, so a broken inventory used to
  # produce a "successful" spin-up that configured nothing at all — the endpoint and test commands
  # below would print for a box Ansible never touched. Resolve the inventory first and stop here if
  # our host is not in it. -i names the file rather than the directory, so this works even where
  # ansible.cfg is not picked up.
  if ! ansible-inventory -i "$INVENTORY" --list 2>/dev/null \
       | jq -e --arg h "$host" '.gpu.hosts | index($h)' >/dev/null 2>&1; then
    die "the 'gpu' group in $INVENTORY does not resolve to $host, so Ansible would configure nothing.
    Check what Ansible sees:  ansible-inventory -i $INVENTORY --list"
  fi

  log "Configuring with Ansible (vLLM + Caddy)..."
  ansible-playbook -i "$INVENTORY" ansible/site.yml -e "vllm_model=$model" -e "sslip_host=$sslip" ${ans_args[@]+"${ans_args[@]}"}

  log "Up. Endpoint: $endpoint"
  # The API expects the served model name (what /v1/models lists). In swap mode that's a preset
  # entry name (first one listed); in single-model mode it's the profile's served_name.
  local served
  if [ -n "$swap_file" ]; then
    served="$(awk '/^swap_profiles:/{f=1;next} f&&/^[[:space:]]*-[[:space:]]/{sub(/^[[:space:]]*-[[:space:]]*/,"");sub(/[[:space:]]*#.*/,"");print;exit} f&&/^[^[:space:]#-]/{exit}' "$swap_file" 2>/dev/null)"
    log "Multi-model swap active (preset '$swap_profile'). Models load on demand; run 'bin/spin swap-profiles' to see the menu."
  else
    served="$(awk -F'"' '/^served_name:/{print $2; exit}' "ansible/models/${model}.yml" 2>/dev/null)"
  fi
  cat <<EOF

Test it:
  curl $endpoint/v1/models -H "Authorization: Bearer \$VLLM_API_KEY"
  curl $endpoint/v1/chat/completions -H "Authorization: Bearer \$VLLM_API_KEY" \\
    -H 'Content-Type: application/json' \\
    -d '{"model":"${served:-$model}","messages":[{"role":"user","content":"hello"}]}'

Wind down when done:  bin/spin down
EOF
}

# After a teardown, delete a large persistent disk to stop its 24/7 cost — but KEEP the floating IP so
# the hostname stays stable (the TLS cert lives on the disk, so it re-issues cheaply next spin for the
# same name). Deletes the disk via API + drops it from state; `bin/spin up` recreates it on demand.
# Config (env or flag):
#   DECOMMISSION_ON_DOWN=auto|never   (default auto)      · or `bin/spin down --keep-disk`
#   DECOMMISSION_THRESHOLD_GB=NNN     (default 150)       · only disks this size or larger are removed
down_decommission_disk() {
  local keep_disk="$1"
  local mode="${DECOMMISSION_ON_DOWN:-auto}" thr="${DECOMMISSION_THRESHOLD_GB:-150}"
  if [ -n "$keep_disk" ] || [ "$mode" = "never" ]; then
    log "Persistent disk kept warm — standing cost continues. [${keep_disk:+--keep-disk }DECOMMISSION_ON_DOWN=$mode]"
    return 0
  fi
  local diskid size
  diskid="$(tofu_output "$PERSIST_DIR" weights_storage_id)"
  printf '%s' "$diskid" | grep -qE '^[0-9a-fA-F-]{36}$' || return 0   # no disk in state — nothing to do
  size="$(api GET "/storage/$diskid" 2>/dev/null | jq -r '.storage.size // empty')"
  printf '%s' "$size" | grep -qE '^[0-9]+$' || { warn "could not read disk size — leaving the persistent disk in place."; return 0; }
  if [ "$size" -lt "$thr" ]; then
    log "Persistent disk ${size} GB (< ${thr} GB threshold) kept — minor standing cost. (DECOMMISSION_THRESHOLD_GB=$thr)"
    return 0
  fi
  local rate=226; [ "${WEIGHTS_TIER:-maxiops}" = "standard" ] && rate=86
  warn "AUTO-DECOMMISSION: weights disk is ${size} GB (>= ${thr} GB) — deleting it to stop ~EUR $(( size*rate/1000 ))/mo standing cost."
  warn "  Floating IP is KEPT (stable hostname). Next 'bin/spin up' recreates the disk, re-downloads weights + re-issues the TLS cert (~1 min)."
  warn "  Keep it warm instead: 'bin/spin down --keep-disk', or set DECOMMISSION_ON_DOWN=never / raise DECOMMISSION_THRESHOLD_GB."
  if api DELETE "/storage/$diskid" >/dev/null 2>&1; then
    "$TOFU" -chdir="$PERSIST_DIR" state rm upcloud_storage.weights >/dev/null 2>&1 || true
    log "Weights disk deleted. Standing cost now ~EUR 3.5/mo (floating IP only)."
  else
    warn "could not delete weights disk $diskid (still attached? already gone?) — check manually."
  fi
}

cmd_down() {
  require_token
  local keep_disk="" dargs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-disk) keep_disk=1; shift ;;
      *) dargs+=("$1"); shift ;;
    esac
  done
  log "Destroying GPU server..."
  build_operator_tf_args   # so destroy doesn't trip on the ipify autodetect data source
  "$TOFU" -chdir="$EPHEMERAL_DIR" destroy -auto-approve ${OPERATOR_TF_ARGS[@]+"${OPERATOR_TF_ARGS[@]}"} ${dargs[@]+"${dargs[@]}"}
  rm -f "$INVENTORY"   # stale inventory would point later ansible runs at a recycled IP
  log "Down. The GPU is no longer billing."
  down_decommission_disk "$keep_disk"
}

cmd_start() {
  require_token
  local uuid; uuid="$(tofu_out server_uuid)"
  [ -n "$uuid" ] || die "no server in state — use 'bin/spin up' to create one."
  local st; st="$(server_state "$uuid")"
  case "$st" in
    started) log "Server $uuid is already running." ;;
    stopped) log "Starting server $uuid..."; refresh_firewall; api POST "/server/$uuid/start" >/dev/null ;;
    "")      die "could not read server state (API/token reachable?)." ;;
    *)       die "server state is '$st' — not startable." ;;
  esac
  wait_ssh "$(tofu_out ssh_host)"
  log "Up. Endpoint: $(tofu_out endpoint)  (vLLM auto-starts on boot)"
}

cmd_stop() {
  require_token
  local uuid; uuid="$(tofu_out server_uuid)"
  [ -n "$uuid" ] || die "no server in state."
  log "Powering off $uuid (GPU billing stops; disk + IP + on-box config are kept)..."
  api POST "/server/$uuid/stop" '{"stop_server":{"stop_type":"soft"}}' >/dev/null
  log "Stop requested. Resume with 'bin/spin start'; tear down with 'bin/spin down'."
}

cmd_status() {
  "$TOFU" -chdir="$EPHEMERAL_DIR" output 2>/dev/null || warn "no ephemeral state (server is down?)"
  local host; host="$(tofu_out ssh_host || true)"
  if [ -n "${host:-}" ]; then
    # Report both possible model units: gpu-spinner (single-model compose) and gpu-swap
    # (llama-swap multi-model). Either may be the active one depending on how it was deployed.
    ssh "${SSH_OPTS[@]}" "root@$host" \
      'nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total --format=csv 2>/dev/null || echo "nvidia-smi unavailable"
       for u in gpu-spinner gpu-swap; do printf "%-12s %s\n" "$u:" "$(systemctl is-active "$u" 2>/dev/null || true)"; done' 2>/dev/null || true
  fi
}

cmd_logs() {
  local host; host="$(tofu_out ssh_host)" || die "server is down."
  # Follow whichever model layer is running: llama-swap (gpu-swap) in multi-model mode, else the
  # single-model docker compose stack.
  ssh "${SSH_OPTS[@]}" "root@$host" '
    if systemctl is-active --quiet gpu-swap; then
      echo "== llama-swap (multi-model) journal — backends start/stop on demand ==" >&2
      journalctl -u gpu-swap -n 100 -f
    else
      cd '"$COMPOSE_DIR"' && docker compose logs -f --tail=100
    fi'
}

cmd_ssh() {
  local host; host="$(tofu_out ssh_host)" || die "server is down."
  exec ssh "${SSH_OPTS[@]}" "root@$host" "$@"
}

cmd_plan() { "$TOFU" -chdir="$EPHEMERAL_DIR" plan "$@"; }

# List the multi-model swap presets and the profiles each serves, so a user can pick one for
# `bin/spin up --swap-profile <name>`. Reads the `- name` lines under swap_profiles: in each preset.
cmd_swap_profiles() {
  local dir="ansible/swap-profiles"
  [ -d "$dir" ] || die "no swap-profiles directory ($dir)."
  local found=""
  log "Multi-model swap presets ($dir) — deploy with: bin/spin up --swap-profile <name> --plan <tier>"
  for f in "$dir"/*.yml; do
    [ -e "$f" ] || break
    found=1
    printf '\n  \033[1m%s\033[0m\n' "$(basename "$f" .yml)"
    # models are the '- ' list items; comment lines describe the tier
    grep -E '^\s*-\s' "$f" | sed -E 's/^\s*-\s*/      - /'
  done
  [ -n "$found" ] || warn "no presets found in $dir."
}

# Fill the persistent weights disk from a cheap CPU box, before any GPU exists.
#
# The arithmetic: a download is billed at whatever compute holds the disk, and nothing about it is
# GPU work. 354 GB at ~126 MB/s is ~47 min: 5.17 EUR on 4x RTX PRO 6000 (6.60/h) against 0.035 EUR
# on 2xCPU-4GB (0.0446/h) — about 150x. The GPU box then starts warm and spends its expensive
# minutes on inference. This also pulls each profile's container image (9-14 GB) onto the same
# disk, because Docker's data-root lives there too.
#
# An UpCloud storage device attaches to one server at a time, so this is mutually exclusive with a
# GPU server by construction. Refuse up front rather than letting tofu fail halfway.
cmd_prefetch() {
  require_token
  local models=() keep=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep) keep=1; shift ;;            # leave the box up (debugging); it still costs ~0.045/h
      -*) die "prefetch: unknown option '$1'" ;;
      *) models+=("$1"); shift ;;
    esac
  done
  [ "${#models[@]}" -gt 0 ] || die "prefetch: name at least one profile, e.g.
    bin/spin prefetch qwen38-nvfp4 qwen38-flash-next
  Profiles: ls ansible/models/"

  local m
  for m in "${models[@]}"; do
    [ -f "ansible/models/${m}.yml" ] || die "unknown model profile '$m' (see ansible/models/)."
  done

  # The weights disk cannot be attached to two servers. Fail with the reason, not a tofu error.
  local gpu_srv; gpu_srv="$(tofu_out server_uuid 2>/dev/null || true)"
  if printf '%s' "$gpu_srv" | grep -qE '^[0-9a-fA-F-]{36}$'; then
    die "a GPU server still exists ($gpu_srv) and holds the weights disk.
    An UpCloud disk attaches to one server at a time. Run 'bin/spin down --keep-disk' first
    (keeps the cache), then prefetch, then bring the GPU box back up."
  fi

  check_tfvars
  local wid; wid="$(tofu_output "$PERSIST_DIR" weights_storage_id)"
  printf '%s' "$wid" | grep -qE '^[0-9a-fA-F-]{36}$' \
    || die "no persistent weights disk in state — run 'bin/spin persistent-init' first."

  build_operator_tf_args
  assert_operator_reachable

  local tf_args=(${OPERATOR_TF_ARGS[@]+"${OPERATOR_TF_ARGS[@]}"})
  # Reuse the ephemeral stack's SSH keys. `ssh_public_keys` is a multi-line HCL list, so
  # a line-oriented extraction returns a bare "[" and tofu dies with "Missing expression". Collapse
  # the whole bracketed block onto one line instead. Written to a tfvars file rather than passed as
  # -var because the value contains spaces and quotes.
  local keys
  keys="$(awk '/^ssh_public_keys[[:space:]]*=/{f=1} f{printf "%s ", $0} f&&/\]/{exit}' \
          "$EPHEMERAL_DIR/terraform.tfvars" 2>/dev/null | sed 's/  */ /g')"
  if [ -n "$keys" ]; then
    printf '%s\n' "$keys" > "$PREFETCH_DIR/terraform.tfvars"
  else
    warn "no ssh_public_keys found in $EPHEMERAL_DIR/terraform.tfvars — the prefetch box will be unreachable."
  fi

  log "Provisioning the prefetch box (${#models[@]} profile(s): ${models[*]})..."
  tofu_init "$PREFETCH_DIR"
  "$TOFU" -chdir="$PREFETCH_DIR" apply -auto-approve ${tf_args[@]+"${tf_args[@]}"} \
    || die "tofu apply failed in $PREFETCH_DIR — nothing was fetched."

  local host; host="$(tofu_output "$PREFETCH_DIR" ssh_host)"
  [ -n "$host" ] || die "prefetch stack has no ssh_host output; check: $TOFU -chdir=$PREFETCH_DIR state list"
  wait_ssh "$host"

  printf '[prefetch]\n%s ansible_user=root\n' "$host" > "$INVENTORY"
  local json; json="$(printf '%s\n' "${models[@]}" | jq -R . | jq -sc '{prefetch_models: .}')"
  local rc=0
  ansible-playbook -i "$INVENTORY" ansible/prefetch.yml -e "$json" || rc=$?
  rm -f "$INVENTORY"

  if [ -n "$keep" ]; then
    warn "--keep: the prefetch box is still running at ~EUR 0.045/h. Destroy it with:
    $TOFU -chdir=$PREFETCH_DIR destroy -auto-approve"
  else
    log "Destroying the prefetch box..."
    "$TOFU" -chdir="$PREFETCH_DIR" destroy -auto-approve ${tf_args[@]+"${tf_args[@]}"} \
      || warn "prefetch teardown FAILED — the box is still billing. Destroy it by hand:
    $TOFU -chdir=$PREFETCH_DIR destroy"
  fi

  [ "$rc" -eq 0 ] || die "the prefetch play failed (exit $rc) — see the output above. The disk keeps whatever did download."
  log "Prefetch done. The weights disk is warm; 'bin/spin up --model <one of them>' now skips the pull."
}
