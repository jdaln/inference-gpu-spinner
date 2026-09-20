#!/usr/bin/env bash
# Verify tests/plans.txt against UpCloud's live plan + price listing.
#
# Why this exists: the CI job "every profile's plan is a real UpCloud plan" compares each profile's
# min_plan to tests/plans.txt, which only proves the repo agrees with itself. On 2026-09-20 all
# three B200 identifiers in plans.txt were dead (UpCloud had doubled the vCPU count in the name) and
# eleven profiles pointed at plans that no longer existed, with CI green the whole time. That would
# have surfaced at `tofu apply`, after bin/spin had started provisioning.
#
# Needs UPCLOUD_TOKEN. Without one it skips (exit 0) rather than failing, so CI without the secret
# still passes and a developer with a token gets the check.
#
# Usage:  tests/check-plans.sh            # from the repo root, or with .env sourced
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
[ -f .env ] && { set -a; . ./.env; set +a; }

if [ -z "${UPCLOUD_TOKEN:-}" ]; then
  echo "check-plans: UPCLOUD_TOKEN not set — skipping the live comparison."
  echo "check-plans: set it (see .env.example) to verify tests/plans.txt against the API."
  exit 0
fi

api() { curl -fsS --max-time 30 -H "Authorization: Bearer $UPCLOUD_TOKEN" "https://api.upcloud.com/1.3$1"; }
ZONE="${UPCLOUD_ZONE:-fi-hel2}"

live_plans="$(api /plan | jq -r '.plans.plan[].name' | sort)"
# /price returns cents per hour, keyed server_plan_<id>.
prices="$(api /price | jq -r --arg z "$ZONE" '
  .prices.zone[] | select(.name==$z) | to_entries[]
  | select(.key | startswith("server_plan_"))
  | "\(.key | sub("^server_plan_";""))\t\(.value.price)"')"

rc=0
while read -r plan list spot _rest; do
  case "$plan" in ''|\#*) continue ;; esac

  if ! printf '%s\n' "$live_plans" | grep -qx "$plan"; then
    echo "::error file=tests/plans.txt::plan '$plan' no longer exists in UpCloud $ZONE"
    rc=1
    continue
  fi

  want_c="$(printf '%s\n' "$prices" | awk -v p="$plan" -F'\t' '$1==p {print $2}')"
  if [ -n "$want_c" ]; then
    want="$(awk -v c="$want_c" 'BEGIN{printf "%.2f", c/100}')"
    [ "$want" = "$list" ] || { echo "::error file=tests/plans.txt::$plan list price is $want EUR/h, file says $list"; rc=1; }
  fi

  if [ "$spot" != "-" ] && [ -n "$spot" ]; then
    sp="${plan/GPU-/GPU-SPOT-}"
    spot_c="$(printf '%s\n' "$prices" | awk -v p="$sp" -F'\t' '$1==p {print $2}')"
    if [ -z "$spot_c" ]; then
      echo "::error file=tests/plans.txt::$plan lists a spot price but $sp does not exist"; rc=1
    else
      want_s="$(awk -v c="$spot_c" 'BEGIN{printf "%.2f", c/100}')"
      [ "$want_s" = "$spot" ] || { echo "::error file=tests/plans.txt::$sp is $want_s EUR/h, file says $spot"; rc=1; }
    fi
  fi

  [ "$rc" -eq 0 ] && echo "  ok  $plan  ${list} / ${spot} EUR/h"
done < tests/plans.txt

[ "$rc" -eq 0 ] && echo "check-plans: tests/plans.txt matches UpCloud $ZONE."
exit $rc
