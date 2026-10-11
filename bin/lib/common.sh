# shellcheck shell=bash
# Sourced by bin/spin. Logging, the tofu output/init wrappers, and the UpCloud API caller.

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_token() { [ -n "${UPCLOUD_TOKEN:-}" ] || die "UPCLOUD_TOKEN not set (export it or put it in .env)."; }
# `tofu output -raw NAME` prints a "No outputs found" warning to STDOUT and exits 0 when the state
# has no outputs, so a plain capture returns that 548-byte banner instead of an empty string —
# `[ -n "$x" ]` then passes and the banner lands in a URL or a -var. `output -json NAME` exits
# non-zero with empty stdout instead, which is what every call site here wants.
tofu_output() {
  local dir="$1" name="$2"
  "$TOFU" -chdir="$dir" output -json "$name" 2>/dev/null \
    | jq -r 'if type == "string" then . else tojson end' 2>/dev/null || true
}
tofu_out() { tofu_output "$EPHEMERAL_DIR" "$1"; }

# Init a stack, skipping when already initialized (avoids the flaky public registry on every run)
# and retrying when it must hit the network. Force a re-init with TOFU_REINIT=1.
tofu_init() {
  local dir="$1" i
  if [ -z "${TOFU_REINIT:-}" ] && [ -d "$dir/.terraform" ] && [ -f "$dir/.terraform.lock.hcl" ]; then
    return 0
  fi
  for i in 1 2 3; do
    "$TOFU" -chdir="$dir" init -input=false && return 0
    warn "tofu init failed (attempt $i/3) — registry.opentofu.org flaky? retrying in 10s..."
    sleep 10
  done
  die "tofu init failed for $dir after 3 attempts (provider registry unreachable?)."
}

# --- UpCloud API helpers (for stop/start/resume) ---
api() { # api METHOD /path [json-body]  (bounded: a hung API call must not hang the CLI)
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -fsS --max-time 30 --retry 2 -X "$method" -H "Authorization: Bearer ${UPCLOUD_TOKEN:-}" -H "Content-Type: application/json" \
      --data-binary "$body" "https://api.upcloud.com/1.3${path}"
  else
    curl -fsS --max-time 30 --retry 2 -X "$method" -H "Authorization: Bearer ${UPCLOUD_TOKEN:-}" "https://api.upcloud.com/1.3${path}"
  fi
}
server_state() { api GET "/server/$1" 2>/dev/null | jq -r '.server.state // empty'; }
