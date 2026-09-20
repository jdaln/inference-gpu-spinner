#!/usr/bin/env bash
# Every check that costs nothing. Run this before asking anyone to spend GPU money.
#
# Mirrors .github/workflows/lint.yml so a green local run means a green CI run. The one extra is
# tests/check-plans.sh, which asks UpCloud whether the plan ids still exist (it skips without a
# token). Nothing here provisions anything or needs a GPU.
#
#   tests/run-offline-gates.sh            # all gates
#   tests/run-offline-gates.sh --quick    # skip the slow per-profile renders
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

QUICK=""; [ "${1:-}" = "--quick" ] && QUICK=1
fail=0
run() {   # run <label> <cmd...>
  local label="$1"; shift
  local out; out="$("$@" 2>&1)"; local rc=$?
  # ansible-playbook exits 0 on some soft failures; treat a non-zero `failed=` recap as a failure.
  printf '%s' "$out" | grep -qE 'failed=[1-9]|fatal:' && rc=1
  if [ "$rc" -eq 0 ]; then printf '  \033[32mPASS\033[0m  %s\n' "$label"
  else printf '  \033[31mFAIL\033[0m  %s\n' "$label"; printf '%s\n' "$out" | tail -25 | sed 's/^/        /'; fail=1; fi
}

echo "--- static ---"
run "shell syntax (bash -n)"        bash -c 'bash -n bin/spin bin/lib/*.sh'
command -v shellcheck >/dev/null && run "shellcheck bin/spin" shellcheck -x bin/spin \
  || echo "  SKIP  shellcheck (not installed)"
run "ansible-lint"                  ansible-lint -q
run "site.yml syntax (single)"      ansible-playbook ansible/site.yml --syntax-check -e vllm_model=qwen36 -e sslip_host=example
run "site.yml syntax (multi)"       ansible-playbook ansible/site.yml --syntax-check -e vllm_model=qwen36 -e sslip_host=example -e multi_model_enabled=true
run "prefetch.yml syntax"           ansible-playbook ansible/prefetch.yml --syntax-check -i ansible/inventory/placeholder.ini

echo "--- profiles ---"
run "vLLM compat (arch/parsers/flags)" python3 tests/check-vllm-compat.py
if [ -z "$QUICK" ]; then
  for f in ansible/models/*.yml; do
    run "renders: $(basename "$f" .yml)" ansible-playbook tests/render-profile.yml -e "profile=$(basename "$f" .yml)"
  done
fi

run "every profile declares the keys that prevent a wasted run" bash -c '
  rc=0
  for f in ansible/models/*.yml; do
    grep -q "^min_disk_gb:" "$f" || { echo "$f: no min_disk_gb (an ENOSPC mid-pull is billed)"; rc=1; }
    grep -q "^weights_gb:" "$f" || { echo "$f: no weights_gb (prefetch cannot size a multi-model pull)"; rc=1; }
    grep -q "^min_vram_gb:" "$f" || { echo "$f: no min_vram_gb"; rc=1; }
    # `validated` defaults to true in the role, so an unvalidated profile that omits it silently
    # claims a live run. glm52 shipped that way. Require it unless a validation.md row exists.
    if ! grep -q "^validated:" "$f"; then
      n=$(basename "$f" .yml)
      grep -qE "^\| .?\`?$n\`?" docs/validation.md || { echo "$f: no validated: key and no docs/validation.md row"; rc=1; }
    fi
  done
  exit $rc'

echo "--- plans ---"
run "every min_plan/swap_plan is in plans.txt" bash -c '
  rc=0
  check() {
    plan=$(sed -n "s/^$2: *\"\{0,1\}\([A-Za-z0-9-]*\)\"\{0,1\}.*/\1/p" "$1" | head -1)
    [ -n "$plan" ] || return 0
    grep -qE "^${plan}[[:space:]]" tests/plans.txt || { echo "$1: $2 $plan not in plans.txt"; rc=1; }
  }
  for f in ansible/models/*.yml; do check "$f" min_plan; done
  for f in ansible/swap-profiles/*.yml; do check "$f" swap_plan; done
  exit $rc'
run "plans.txt matches the live UpCloud listing" tests/check-plans.sh

echo "--- swap presets ---"
for f in ansible/swap-profiles/*.yml; do
  run "renders: swap/$(basename "$f" .yml)" ansible-playbook tests/render-swap-profile.yml -e "preset=$(basename "$f" .yml)"
done
run "llama-swap refuses what it cannot serve" ansible-playbook tests/swap-refusals.yml

echo "--- terraform ---"
for d in terraform/persistent terraform/providers/upcloud terraform/prefetch; do
  [ -d "$d/.terraform" ] && run "tofu validate: $d" "${TOFU:-tofu}" -chdir="$d" validate \
    || echo "  SKIP  tofu validate: $d (run tofu init first)"
done
# CI runs this on a fresh checkout, which has no local terraform.tfvars. Here it does, it is
# gitignored, and it is the operator's own file — so report only files git actually tracks.
run "tofu fmt -check (tracked files)" bash -c '
  rc=0
  for d in terraform/persistent terraform/providers/upcloud terraform/prefetch; do
    while read -r f; do
      [ -n "$f" ] || continue
      git check-ignore -q "$d/$f" && continue      # local, untracked: not ours to format
      echo "unformatted: $d/$f"; rc=1
    done < <(${TOFU:-tofu} -chdir="$d" fmt -check -recursive 2>/dev/null)
  done
  exit $rc'

echo
[ "$fail" -eq 0 ] && echo "All offline gates passed." || echo "OFFLINE GATES FAILED — fix these before spending anything."
exit $fail
