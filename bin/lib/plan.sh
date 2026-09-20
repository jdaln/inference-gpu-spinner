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
