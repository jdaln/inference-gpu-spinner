---
name: adding-a-model-profile
description: "Add or change a vLLM model profile (ansible/models/<name>.yml) in inference-gpu-spinner. Use when asked to add, port or define a model, checkpoint or quantization for bin/spin — \"add Qwen3.9 to the spinner\", \"make a profile for this HF repo\", \"support the NVFP4 build\", \"why is this model on B200?\", \"can this run on the RTX card?\" — or to change an existing profile's plan, context, image or gates. Offline and free: this skill never provisions anything. Testing the result is a separate skill, testing-a-model-profile."
---

# Adding a model profile

A profile is one YAML file in `ansible/models/`. It is the *only* thing that decides which GPU
plan a model lands on, what vLLM is told to do, and whether the deploy is allowed at all. Getting
it wrong costs real money, because most mistakes surface only after a paid server has downloaded
several hundred gigabytes.

**This skill is offline. You must not run `bin/spin up`, `bin/spin prefetch`, `tofu apply` or any
Ansible play against a host.** Finish the profile, run the free gates, and hand off.

## Rule one

**Write down only what you measured. Everything else is `false`, absent, or the recipe's number
clearly labelled as such.** `validated:` defaults to **true** in the role
(`ansible/roles/vllm/tasks/main.yml`), so a new profile that omits it silently claims a live run it
never had. `glm52.yml` shipped that way and nobody noticed for months.

## 1. Research before you write anything

```bash
REPO=owner/name
curl -s "https://huggingface.co/api/models/$REPO" | jq '{gated, pipeline_tag}'
curl -s "https://huggingface.co/$REPO/resolve/main/config.json" | jq '{architectures, num_hidden_layers, max_position_embeddings, quantization_config}'
# Real download size — sum the file listing. Avoid `usedStorage`: it counts every revision.
curl -s "https://huggingface.co/api/models/$REPO?blobs=true" \
  | jq '[.siblings[].size] | add / 1073741824 | floor | tostring + " GB"'
```

- `architectures[0]` is what `tests/check-vllm-compat.py` checks against the pinned image.
- `max_position_embeddings` is the checkpoint's **native** context. It is a starting point, not a
  measured ceiling.
- `gated: true` means you must also set `gated: true` in the profile, or the download 401s
  mid-deploy on a billing GPU.
- Then read the model's own serving recipe (model card / vLLM release notes). The recipe usually
  names a **higher** minimum vLLM version than the release that first carried the architecture.

## 2. Pick the quantization and the GPU family

| Checkpoint | Runs on | Notes |
|---|---|---|
| FP8 | L40S (8.9) and newer — everything here | The safe default |
| NVFP4, **dense** | Blackwell: B200 (cc 10.0) and RTX PRO 6000 (cc 12.0) | `min_compute_capability: 10.0` |
| NVFP4, **MoE** | Blackwell, both families | Measured 2026-09-20 on RTX PRO 6000 (cc 12.0) on the shared cu129 pin: `gemma4-26b-nvfp4` via `VLLM_CUTLASS` and `qwen36-35b-nvfp4` via `MARLIN`, both correct under a graded soak. The old "grouped block-scaled GEMM returns garbage on cc 12.0" gate was stale — flashinfer#2708 and vllm#54189 had closed months earlier. Gate a new profile only on evidence you have. |
| MXFP4 / compressed-tensors | check the recipe | |
| DeepSeek-style **sparse MLA** | B200 only | SM120 has no working kernel (vllm#55757). The failure hides: short prompts pass, realistic lengths fail. |

Compute capabilities here: L40S 8.9, H100 9.0, B200 10.0, RTX PRO 6000 12.0. Note 12.0 > 10.0 but
is a *different* family — a `min_compute_capability` alone never keeps a model off the RTX card.

## 3. Size it, then choose the plan

```
per-GPU budget = (GPU VRAM GB) x gpu_memory_utilization (0.90)
tensor_parallel_size = smallest N where (weights GB / N) leaves room for a useful KV pool
```

Per-GPU VRAM as the role sees it (MiB floor-divided by 1024): L40S 44, H100 79, RTX PRO 6000 95,
B200 179. Pick `min_plan` from `tests/plans.txt` — **and nothing else**; CI checks it, and
`tests/check-plans.sh` checks `tests/plans.txt` against UpCloud's live listing. The identifiers
move: on 2026-09-20 all three B200 ids in this repo were dead.

Multi-GPU RTX PRO 6000 plans have **no NVLink** — TP runs over PCIe. Mention it in the comment and
point at `NCCL_P2P_DISABLE: 1` as the fallback if init hangs; do not set it pre-emptively.

## 4. Write the file

Required (the compose template interpolates these bare; a missing one is an undefined-variable
failure): `model_repo`, `served_name`, `max_model_len`, `tensor_parallel_size`, `dtype`.
`gpu_memory_utilization` falls back to 0.90 from `group_vars/all.yml`.

Required by this repo's own gates:

| Key | How to choose it |
|---|---|
| `min_vram_gb` | Per-GPU floor. Set it high enough to keep out a plan that would OOM *after* the download. |
| `weights_gb` | The real download size: sum `.siblings[].size` from the HF API. The deploy-time disk preflight reads this key. |
| `min_disk_gb` | Measured weights + ~40 GB (container image and Docker's data-root share the disk). Sizing advice for `bin/spin persistent-init`. |
| `validated: false` | Always, on a new profile. Remove it only when a dated `docs/validation.md` row exists. |
| `health_wait_retries` | `(weights_GB / 7.56 + engine_init_minutes) x 1.5 x 6`. 7.56 GB/min is the measured authenticated download rate. Default 90 = 15 min, which is too short for anything over ~100 GB. |

Optional gates: `min_compute_capability`, `unsupported_compute_capabilities` +
`unsupported_reason`, `untested_compute_capabilities`, `min_driver_major`, `gated`,
`vllm_image_override`, `extra_env`, `vllm_plugins`, `enable_lora`.

Cost needs no key. `bin/spin` prices the resolved `min_plan` from `tests/plans.txt` and refuses
anything above `MAX_EUR_PER_HOUR` (default 10) until the operator passes `--allow-expensive`, so an
expensive profile is gated the moment its plan is. (`requires_review`, which used to do this per
profile, was retired 2026-09-21.) `--allow-unvalidated` is unrelated: it turns off **every**
hardware preflight.

Pin `vllm_image_override` **by digest** when the tag is mutable — several of these tags have
already moved:
```bash
curl -s "https://hub.docker.com/v2/repositories/vllm/vllm-openai/tags/<tag>" | jq -r .digest
```

## 5. max_model_len: start at the recipe, never at a guess

Set it to the value the model's serving recipe gives, or to native if the recipe is silent. **Do
not cap it lower without a measurement, and do not claim native without one either.** Add a comment
saying which it is. A measured cap comes from `bin/spin ceiling` and belongs to the other skill.

## 6. Comment the way this repo comments

Read `ansible/models/glm53-flash-nvfp4.yml`, the house style, and copy its shape:

- what was measured, on what hardware, **on what date**;
- `FLAGS THAT ARE NOT PREFERENCES` — every non-obvious flag with the failure it prevents;
- upstream issue numbers for every claim;
- a `ruled out, so nobody re-chases them` list;
- the disk figure, and what happens if the disk is too small.

**Check the upstream issues you cite are still open.** Several in this repo were fixed months
before anyone re-read them (vllm#54189 and flashinfer#2708 both closed while the profiles still
described them as blockers):
```bash
curl -s https://api.github.com/repos/vllm-project/vllm/issues/54189 | jq '{state, updated_at}'
```

## 7. Swap presets: only if the profile fits

`ansible/swap-profiles/*.yml` presets are served by a bare `docker run` that carries image, repo,
context, memory fraction, TP, dtype and `extra_vllm_args` — **and nothing else**. A profile with
`extra_env` or `vllm_plugins` is now refused outright (`roles/llama_swap/tasks/refusals.yml`),
because it would otherwise start and serve silently-wrong output. Do not try to work around that.

Also note: in swap mode the client-facing name is the **profile filename**, not `served_name`.

## 8. The free gates — run all of them before asking for money

```bash
make test               # everything below, plus lint, renders and terraform
# or individually:
python3 tests/check-vllm-compat.py <name>
ansible-playbook tests/render-profile.yml -e profile=<name>
tests/check-plans.sh
```

A registry hit in `check-vllm-compat.py` means the architecture *exists* in that build. Whether the
build serves the model correctly is what a live run answers — the other skill.

## 9. Also update

- `README.md` — the model table: "Main lane" is `min_plan`, "Measured on" is a dated
  `docs/validation.md` row. A new profile has **no** "Measured on" entry.
- `docs/validation.md` — add the row now, marked not-yet-run.
- `tests/plans.txt` — only if you reference a plan it does not list.

## Finish with this check

```bash
for k in model_repo served_name max_model_len tensor_parallel_size dtype min_vram_gb min_disk_gb; do
  grep -q "^$k:" ansible/models/<name>.yml || echo "MISSING: $k"
done
grep -q '^validated:' ansible/models/<name>.yml || echo "MISSING: validated (defaults to TRUE — it would claim a live run)"
```

Then hand off: *"the profile passes every offline gate; it has never been run. Testing it costs
about €X on <plan> — see the testing-a-model-profile skill."*
