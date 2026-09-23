#!/usr/bin/env bash
# On a hybrid / linear-attention checkpoint, prefix caching is a correctness setting rather than a
# tuning knob: a cache hit resumes recurrent layers from a recycled block and the model answers fast
# and wrong, with no crash and nothing in the log (vllm#56960). Deleting the flag would otherwise
# pass CI in silence, which is why this gate exists. Mechanism and measurement: see docs/gpu-spinner.md, "Hybrid checkpoints and prefix caching".
#
# Keyed on `hybrid_recurrent_state: true`, which a profile declares whenever config.json shows
# linear_attn_config, or layer_types carrying linear_attention / a mamba state cache / Gated
# DeltaNet. From then on --no-enable-prefix-caching is mandatory.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

rc=0
checked=0
for f in ansible/models/*.yml; do
  grep -qE '^hybrid_recurrent_state:[[:space:]]*(true|yes)[[:space:]]*(#.*)?$' "$f" || continue
  checked=$(( checked + 1 ))
  name="$(basename "$f" .yml)"

  if grep -qE '^[[:space:]]*-[[:space:]]*"--enable-prefix-caching"' "$f"; then
    echo "  $name: declares hybrid_recurrent_state but turns prefix caching ON."
    echo "    A cache hit resumes its recurrent layers from a recycled block's state and the model"
    echo "    answers confidently wrong on long prompts (vllm#56960, vllm#51483). Use"
    echo "    --no-enable-prefix-caching until #56960 is in the pinned image."
    rc=1
  fi

  if ! grep -qE '^[[:space:]]*-[[:space:]]*"--no-enable-prefix-caching"' "$f"; then
    echo "  $name: declares hybrid_recurrent_state but does not set --no-enable-prefix-caching."
    echo "    vLLM defaults enable_prefix_caching=True, so leaving it out is the same as opting in."
    rc=1
  fi
done

if [ "$checked" -eq 0 ]; then
  echo "  no profile declares hybrid_recurrent_state — nothing to check, which is itself suspicious"
  echo "  if this repo still serves KDA / Gated DeltaNet / mamba checkpoints."
  exit 1
fi

[ "$rc" -eq 0 ] && echo "  $checked hybrid profile(s) all pin prefix caching off"
exit "$rc"
