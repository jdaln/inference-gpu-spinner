# shellcheck shell=bash
# Sourced by bin/spin. Where the GPU plan comes from, and the provider tfvars sanity check.

# The plan of the server currently in tofu state ("" if none) — used to avoid unintended resizes.
state_plan() {
  "$TOFU" -chdir="$EPHEMERAL_DIR" show -json 2>/dev/null \
    | jq -r '.values.root_module.resources[]? | select(.address=="upcloud_server.gpu") | .values.plan // empty' 2>/dev/null | head -1
}

# Each profile / preset names the plan it runs on (min_plan / swap_plan), which `up` deploys when
# no --plan is given, so the tier need not be remembered per model. Read with sed, not a YAML
# parser: the dependency list is curl/jq/tofu/ansible-playbook/ssh and must not gain python3.
# Anything that is not a well-formed plan identifier is ignored, so a profile may omit the field
# (kimi-k3 does) and callers fall through to the next source.
profile_plan() {
  local file="$1" key="$2" value
  [ -f "$file" ] || return 0
  value="$(sed -n "s/^${key}: *\"\{0,1\}\([A-Za-z0-9-]*\)\"\{0,1\}.*/\1/p" "$file" | head -1)"
  case "$value" in
    GPU-[0-9]*xCPU-[0-9]*GB-[0-9]*x*) printf '%s' "$value" ;;
    *) return 0 ;;
  esac
}

# The provider tfvars are copied from an example with placeholders. Nothing in the persistent stack
# reads them, so a half-finished copy only surfaces much later as an opaque UpCloud API error during
# the ephemeral apply — after a server has been requested. Check them before anything is created.
check_tfvars() {
  local f="$EPHEMERAL_DIR/terraform.tfvars"
  [ -f "$f" ] || die "$f not found. Copy it from ${f}.example, then set os_template and ssh_public_keys."
  if grep -qE '^[[:space:]]*os_template[[:space:]]*=[[:space:]]*"REPLACE_ME"' "$f"; then
    die "$f still has os_template = \"REPLACE_ME\".
    List the GPU templates and paste the UUID or exact title:
      set -a; . ./.env; set +a
      curl -fsS -H \"Authorization: Bearer \$UPCLOUD_TOKEN\" https://api.upcloud.com/1.3/storage/template \\
        | jq -r '.storages.storage[] | select(.title|test(\"GPU|NVIDIA|CUDA\";\"i\")) | \"\\(.uuid)  \\(.title)\"'"
  fi
  # A key inside the ssh_public_keys list, ignoring comment lines.
  if ! grep -vE '^[[:space:]]*#' "$f" | grep -qE '(ssh-(rsa|ed25519|dss)|ecdsa-sha2-)'; then
    die "$f has no SSH public key in ssh_public_keys.
    Without one you cannot reach the server you are about to pay for. Add yours, e.g.
      ssh_public_keys = [\"\$(cat ~/.ssh/id_ed25519.pub)\"]"
  fi
}

# Price of a plan in EUR/hour, from tests/plans.txt. Prints nothing if the plan is not listed.
# Spot ids are not separate rows: GPU-SPOT-<suffix> reads the spot column of the GPU-<suffix> row.
# awk, not python — bin/spin's dependency list deliberately has no python3 (see check_tfvars).
plan_price() {
  local p="$1" row col
  case "$p" in
    GPU-SPOT-*) row="GPU-${p#GPU-SPOT-}"; col=3 ;;
    *)          row="$p";                 col=2 ;;
  esac
  awk -v r="$row" -v c="$col" '$1 == r { print $c; exit }' tests/plans.txt 2>/dev/null
}

# Refuse a plan above MAX_EUR_PER_HOUR unless the operator opts in.
#
# This replaces the old per-profile `requires_review` flag, retired 2026-09-21. That flag meant
# "this needs an expensive plan, confirm" but read as "this is unvalidated", and its override
# (`allow_unvalidated_model`) also switched off the VRAM floor, the compute-capability checks, the
# driver floor and the disk check — six gates behind one badly-named flag. Its original premise was
# also gone: it guarded against deploying a huge model onto the default L40S, which cannot happen
# now that bin/spin derives the plan from min_plan.
#
# Price is the thing worth confirming, so confirm price. Reading it from tests/plans.txt means
# every plan is covered automatically, including ones added later, with no per-profile flag to
# forget — and tests/check-plans.sh keeps those prices honest against the provider.
assert_plan_affordable() {   # assert_plan_affordable <plan-id> <what> <allow_expensive>
  local plan="$1" what="$2" allow="$3" price max
  [ -n "$plan" ] || return 0
  [ -z "$allow" ] || return 0
  max="${MAX_EUR_PER_HOUR:-10}"
  price="$(plan_price "$plan")"
  if [ -z "$price" ] || [ "$price" = "?" ]; then
    warn "no recorded price for $plan — cannot check it against MAX_EUR_PER_HOUR=$max. Add it to tests/plans.txt."
    return 0
  fi
  if awk -v p="$price" -v m="$max" 'BEGIN { exit !(p > m) }'; then
    local hint="see tests/plans.txt for every plan and both prices"
    case "$plan" in
      GPU-SPOT-*) : ;;   # already the cheap id; suggesting one again would read as GPU-SPOT-SPOT-
      *) hint="cheaper spot id: GPU-SPOT-${plan#GPU-} — $hint" ;;
    esac
    die "'$what' deploys on $plan at EUR $price/hour, above the MAX_EUR_PER_HOUR limit of $max.
    That is about EUR $(awk -v p="$price" 'BEGIN{printf "%.0f", p*24}')/day if you leave it up.
    If you mean it:  add --allow-expensive   (or raise MAX_EUR_PER_HOUR)
    $hint."
  fi
  log "Plan $plan costs EUR $price/hour (limit $max)."
}
