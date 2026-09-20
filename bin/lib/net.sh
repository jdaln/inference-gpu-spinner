# shellcheck shell=bash
# Sourced by bin/spin. Operator allowlist: reachability check, -var plumbing, firewall refresh, SSH wait.

# Build operator-allowlist -var args from the environment, used by BOTH up and down so neither
# depends on the api.ipify.org autodetect when OPERATOR_IP/OPERATOR_CIDRS is set.
OPERATOR_TF_ARGS=()
# --- Operator reachability -------------------------------------------------------------------
# The firewall allowlists SSH(22) and HTTPS(443) to the operator CIDRs only. Deploying from an
# address outside them creates the server, starts billing it, and then times out waiting for SSH —
# the box is unreachable for the whole run and nothing tells you why until 10 minutes later.
# Check before anything is provisioned. Pure bash so this adds no dependency beyond curl.
ip_to_int() { local IFS=. a b c d; read -r a b c d <<EOF
$1
EOF
printf '%s' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"; }

cidr_covers() {   # $1=cidr (bare IP means /32), $2=dotted IP -> 0 when covered
  local net bits ipi neti mask
  net="${1%%/*}"; bits="${1##*/}"
  [ "$bits" = "$1" ] && bits=32
  case "$net" in *[!0-9.]*|"") return 1 ;; esac
  case "$bits" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bits" -ge 0 ] && [ "$bits" -le 32 ] || return 1
  [ "$bits" -eq 0 ] && return 0
  ipi="$(ip_to_int "$2")"; neti="$(ip_to_int "$net")"
  mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  [ $(( ipi & mask )) -eq $(( neti & mask )) ]
}

# Refuse to provision a box this machine cannot reach. Only meaningful when OPERATOR_CIDRS or
# OPERATOR_IP pins the allowlist — with neither set the stack auto-detects this machine's address,
# so it is reachable by construction.
assert_operator_reachable() {
  [ -n "${SKIP_REACHABILITY_CHECK:-}" ] && return 0
  local allow="${OPERATOR_CIDRS:-${OPERATOR_IP:-}}"
  [ -n "$allow" ] || return 0
  local me; me="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  case "$me" in ''|*[!0-9.]*) warn "could not determine this machine's public IP; skipping the reachability check."; return 0 ;; esac
  local c ok=""
  local IFS=,
  for c in $allow; do
    c="$(printf '%s' "$c" | tr -d '[:space:]')"
    [ -n "$c" ] || continue
    if cidr_covers "$c" "$me"; then ok=1; break; fi
  done
  unset IFS
  [ -n "$ok" ] && { log "Reachability OK — this machine ($me) is inside the operator allowlist."; return 0; }
  die "this machine's public IP ($me) is not in the operator allowlist ($allow).
    The firewall would drop SSH/HTTPS from here, so the server would bill while every connection
    timed out. Add it to OPERATOR_CIDRS in .env, e.g.
      OPERATOR_CIDRS=$allow,$me/32
    as a SINGLE assignment (a later duplicate line silently wins). Editing the rule in the provider
    console does not work: tofu owns the firewall and reverts it on the next apply.
    To deploy anyway (e.g. from a jump host you reach another way): SKIP_REACHABILITY_CHECK=1."
}

build_operator_tf_args() {
  OPERATOR_TF_ARGS=()
  if [ -n "${OPERATOR_CIDRS:-}" ]; then
    local cidr_json
    cidr_json="$(printf '%s' "$OPERATOR_CIDRS" | awk -F, '{printf "["; for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i); printf "%s\"%s\"",(i>1?",":""),$i}; printf "]"}')"
    OPERATOR_TF_ARGS+=(-var "operator_cidrs=$cidr_json")
  elif [ -n "${OPERATOR_IP:-}" ]; then
    OPERATOR_TF_ARGS+=(-var "operator_ip=$OPERATOR_IP")
  fi
}

# Refresh only the firewall allowlist for the current operator IP. A server can sit stopped for a
# while; if your egress IP rotated meanwhile, a plain start would resume behind a stale allowlist
# and lock you out (SSH/443 dropped). We -target the firewall resource, but it references the server
# (server_id), so a -target apply pulls the server into the plan too. To avoid an UNINTENDED RESIZE
# back to the default plan, we read the server's CURRENT plan from state and pass it as -var plan=.
refresh_firewall() {
  tofu_init "$EPHEMERAL_DIR"
  build_operator_tf_args
  local fw_args=()
  fw_args+=(${OPERATOR_TF_ARGS[@]+"${OPERATOR_TF_ARGS[@]}"})
  local cur_plan; cur_plan="$(state_plan)"
  if [ -z "$cur_plan" ] || [ "$cur_plan" = "null" ]; then
    warn "could not read the server's current plan from state — skipping firewall refresh to avoid an unintended resize."
    warn "if your IP changed, run a full 'bin/spin up' (or set OPERATOR_CIDRS) to refresh the allowlist."
    return 0
  fi
  fw_args+=(-var "plan=$cur_plan")
  log "Refreshing firewall allowlist for your current IP (plan=$cur_plan, no resize)..."
  "$TOFU" -chdir="$EPHEMERAL_DIR" apply -auto-approve ${fw_args[@]+"${fw_args[@]}"} -target=upcloud_firewall_rules.gpu
}

# Two failure modes hide behind "waiting for SSH", and both otherwise cost the full timeout on a
# billing GPU:
#   * key not installed -> the box answers and refuses (Permission denied). The wait can never
#     succeed, so fail immediately and name the missing key.
#   * still booting     -> no answer at all. Worth waiting for: a 4-GPU tier with a large attached
#     disk has been measured over 10 minutes, hence the ~20 min default (SSH_WAIT_TRIES).
wait_ssh() {
  local host="$1" i out tries="${SSH_WAIT_TRIES:-240}"
  [ -n "$host" ] || die "no ssh_host available."
  log "Waiting for SSH on $host (up to ~$(( tries * 5 / 60 )) min) ..."
  # stderr is captured into a variable rather than a temp file: a `trap ... RETURN` that removes a
  # `local` temp path fires after the variable has left scope, which under `set -u` kills the
  # script after a successful deploy.
  for i in $(seq 1 "$tries"); do
    if out="$(ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=5 "root@$host" true 2>&1)"; then
      return 0
    fi
    case "$out" in *"Permission denied"*)
      die "SSH reached $host but AUTHENTICATION failed (Permission denied (publickey)).
    The box is up and the firewall is letting you through — it just does not trust this machine's
    key. ssh_public_keys is create-time metadata, so editing terraform.tfvars will not fix a server
    that already exists. To fix the running box, append this machine's public key to
    /root/.ssh/authorized_keys there from a machine that can already log in; add it to
    terraform.tfvars as well so the next build keeps it. This machine offers:
      $(ssh-keygen -lf ~/.ssh/id_ed25519.pub 2>/dev/null | awk '{print $2}')" ;;
    esac
    sleep 5
  done
  die "timed out waiting for SSH after ~$(( tries * 5 / 60 )) min.
    If this tier is simply slow to boot, raise it: SSH_WAIT_TRIES=360 bin/spin up ..."
}
