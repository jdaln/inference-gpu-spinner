#!/usr/bin/env bash
# Unit test for the plan cost gate (bin/lib/plan.sh), which replaced the per-profile
# `requires_review` flag on 2026-09-21. That flag had a regression test; this keeps the coverage.
#
# Pure shell, no network, no cloud: it sources the library and drives plan_price /
# assert_plan_affordable directly.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# assert_plan_affordable calls die/warn/log from common.sh.
# common.sh's die EXITS; a stub that merely returns lets execution fall through the guard and the
# caller sees success. Inside $( ) this exits the subshell, so rc=1 reaches the test.
die()  { printf 'die: %s\n' "$*"; exit 1; }
warn() { printf 'warn: %s\n' "$*"; }
log()  { printf 'log: %s\n' "$*"; }
# shellcheck source=bin/lib/plan.sh
. bin/lib/plan.sh

fail=0
check() {   # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  \033[32mPASS\033[0m  %s\n' "$1"
  else printf '  \033[31mFAIL\033[0m  %s (expected %q, got %q)\n' "$1" "$2" "$3"; fail=1; fi
}

echo "--- plan_price ---"
check "L40S list"            "1.11"  "$(plan_price GPU-8xCPU-64GB-1xL40S)"
check "L40S spot"            "0.83"  "$(plan_price GPU-SPOT-8xCPU-64GB-1xL40S)"
check "4xRTXPRO6000 list"    "6.60"  "$(plan_price GPU-64xCPU-320GB-4xRTXPRO6000)"
check "4xRTXPRO6000 spot"    "4.95"  "$(plan_price GPU-SPOT-64xCPU-320GB-4xRTXPRO6000)"
check "8xB200 list"         "36.00"  "$(plan_price GPU-192xCPU-1920GB-8xB200)"
check "unknown plan"             ""  "$(plan_price GPU-NOT-A-REAL-PLAN)"

echo "--- assert_plan_affordable (default limit 10) ---"
out="$(assert_plan_affordable GPU-8xCPU-64GB-1xL40S qwen38 "" 2>&1)"; rc=$?
check "cheap plan admitted"            "0" "$rc"
out="$(assert_plan_affordable GPU-192xCPU-1920GB-8xB200 glm53 "" 2>&1)"; rc=$?
check "36 EUR/h refused"               "1" "$rc"
case "$out" in *"--allow-expensive"*) r=yes ;; *) r=no ;; esac
check "refusal names the opt-out"    "yes" "$r"
case "$out" in *"GPU-SPOT-192xCPU-1920GB-8xB200"*) r=yes ;; *) r=no ;; esac
check "refusal suggests the spot id" "yes" "$r"
out="$(assert_plan_affordable GPU-192xCPU-1920GB-8xB200 glm53 1 2>&1)"; rc=$?
check "--allow-expensive admits"       "0" "$rc"
out="$(MAX_EUR_PER_HOUR=50 assert_plan_affordable GPU-192xCPU-1920GB-8xB200 glm53 "" 2>&1)"; rc=$?
check "raised limit admits"            "0" "$rc"
out="$(assert_plan_affordable GPU-NOT-A-REAL-PLAN x "" 2>&1)"; rc=$?
check "unpriced plan warns, admits"    "0" "$rc"
case "$out" in warn:*) r=yes ;; *) r=no ;; esac
check "and it warns"                 "yes" "$r"

# The boundary every expensive profile now sits behind.
echo "--- every profile's default plan vs the limit ---"
for f in ansible/models/*.yml; do
  plan="$(profile_plan "$f" min_plan)"; [ -n "$plan" ] || continue
  price="$(plan_price "$plan")"; [ -n "$price" ] || continue
  gated=$(awk -v p="$price" 'BEGIN{print (p>10) ? "gated" : "open"}')
  printf '    %-9s %-6s %s\n' "$gated" "$price" "$(basename "$f" .yml)"
done

[ "$fail" -eq 0 ] && echo "cost gate OK" || echo "COST GATE TESTS FAILED"
exit $fail
