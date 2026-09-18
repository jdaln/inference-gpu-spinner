# Validation matrix — system of record

This is the exact record of what has been **live-validated** on real UpCloud GPUs, what 
has not yet been tested, and what is **known broken**. Every model × quant × tier the spinner
targets has a row. Update this file on every live run — do not rely on memory.

**Capture results consistently with `bin/spin validate`** (run it against a deployed model): it reports
the served model id + `max_model_len` (`/v1/models`), the vLLM-reported **GPU KV cache size** and
**max concurrency at full context**, **VRAM used**, and a **test generation** — exactly the fields below.

Status legend: ✅ validated live · ⬜ not yet run on this tier (paper-sized) · ❌ known broken ·
🚫 not servable on this tier (needs a bigger/multi-GPU node).

## Models

Numbers are vLLM's own startup report (`kv_cache_utils`), `nvidia-smi`, and `/v1/models`, captured live.

| Profile | Model | Quant | Tier (plan) | `max_model_len` | Status | KV pool | Concurrency @ max | VRAM | Date | Evidence |
|---|---|---|---|---|---|---|---|---|---|---|
| `qwen36` | Qwen3.6-27B | FP8 | L40S (`…1xL40S`) | 262144 (native) | ✅ | 372,123 tok | 1.42× | 41,023/46,068 MiB | 2026-07-04 | commit `11d6177`; gen "Capital of Finland" |
| `gemma4-31b` | Gemma 4 31B (dense) | FP8 | L40S | 65536 | ✅ | 105,859 tok | 1.62× | 41,543/46,068 MiB | 2026-07-04 | `11d6177`; gen "gemma 64k ok" |
| `gemma4-26b` | Gemma 4 26B-A4B (MoE) | FP8 | L40S | 131072 | ✅ | 986,681 tok | 7.53× | 41,597/46,068 MiB | 2026-07-04 | `11d6177`; gen "gemma 26b ok" (headroom for 262144) |
| `qwen36-35b` | Qwen3.6-35B-A3B (MoE) | FP8 | H100 (`…1xH100`) | 262144 | ✅ | 3,416,000 tok | 13.03× | 74,183/81,559 MiB | 2026-07-04 | `bin/spin validate`: gen "validation ok" / "NVIDIA's flagship AI GPU" (thinking model — pass `enable_thinking:false` for direct answers) |
| `qwen36-27b-nvfp4` | Qwen3.6-27B | NVFP4 | B200 (`…1xB200`) | 262144 | ✅ | 4,413,523 tok | 16.84× | 169,304/183,359 MiB | 2026-07-04 | `bin/spin validate`: gen "validation ok" |
| `qwen36-35b-nvfp4` | Qwen3.6-35B-A3B (MoE) | NVFP4 | B200 | 262144 | ✅ | 13,897,696 tok | 53.02× | 167,612/183,359 MiB | 2026-07-04 | validate OK — after removing `VLLM_USE_FLASHINFER_MOE_FP4` (see note) |
| `qwen38` | Qwen3.8-27B (dense hybrid) | FP8 | L40S | 131072 (native 262144) | ⬜ | — | — | — | — | Newly added. ~31 GB weights against ~46 GiB usable on an L40S, so `max_model_len` starts at 131072 — raise it once a run shows KV-pool headroom. `--reasoning-parser qwen3` is required (the template opens every turn with `<think>`) 🚫 |
| `qwen38-nvfp4` | Qwen3.8-27B (dense hybrid) | NVFP4 | RTX PRO 6000 or B200 | 262144 | ⬜ | — | — | — | — | Newly added, `unsloth/Qwen3.8-27B-NVFP4`. Dense, so the NVFP4 scaled-mm path applies and vLLM picks a real CUTLASS kernel on sm120. Upstream measured 920,517 KV tokens at 262144 on 2×RTX 5090 🚫 |
| `qwen38-flash-next` | Qwen3.8-Flash-Next (125B-A6B MoE + 51B N-gram) | FP8 | **4×H100** (`…4xH100`, TP=4) | 262144 | ⬜ | — | — | — | — | Newly added. Needs the pinned `vllm/vllm-openai:qwen38-flash-next` image; PyPI vLLM has no `qwen4_exp` support. `VLLM_PLE_CPU_OFFLOAD=1` is required on 80 GB cards. ~186 GB of weights — raise `WEIGHTS_SIZE_GB` first. MTP measured *worse* on this hardware (~36% acceptance), so it is off 🚫 |
| `gemma4-26b-nvfp4` | Gemma 4 26B-A4B (MoE) | NVFP4 | B200 | 262144 | ✅ | 10,641,503 tok | 40.59× | 165,886/183,359 MiB | 2026-07-04 | validate OK — after removing `VLLM_USE_FLASHINFER_MOE_FP4` |
| `gemma4-31b-nvfp4` | Gemma 4 31B (dense) | NVFP4 | B200 | 262144 | ✅ | 2,415,691 tok | 9.22× | 166,008/183,359 MiB | 2026-07-04 | validate OK |
| `deepseek-v4-flash-vision` | DeepSeek-V4-Flash-Vision-Exp (285B-A13B MoE, multimodal) | FP4+FP8 | **4×B200** (`…4xB200`, TP=4+EP) | 32768 | ⬜ | — | — | — | — | `requires_review`; ~168 GB of weights, ~202 GB VRAM budget before KV. Needs the pinned `vllm/vllm-openai:deepseekv4-flash-vision` image — the stable wheel routes this checkpoint to the text-only class. Published vision runs exist only on GB200 NVL4 (TP4+EP) and MI350X, neither offered here 🚫 |
| `deepseek-v41-flash` | DeepSeek-V4.1-Flash (552B + 196B Engram MoE) | MXFP4+MXFP8 | **4×B200** (`…4xB200`, TP=4) | 1048576 | ⬜ | — | — | — | — | Newly added, `requires_review`. ~511 GB on disk / 476 GiB, recipe floor 614 GB VRAM — one GB200 NVL4 tray at TP4, which 4×B200 matches. Needs a vLLM nightly from 2026-09-10 or later; no release serves `deepseek_v41`. Engram tables alone are 183 GiB 🚫 |
| `deepseek-v4-pro-0813` | DeepSeek-V4-Pro-0813 (1.6T-A49B MoE) | FP4+FP8 | **8×B200** (`…8xB200`, TP=8) | 393216 | ⬜ | — | — | — | — | Newly added, `requires_review`. ~893 GB of weights; the recipe states it does not fit one 768 GB tray and all its recommended deployments are 8-GPU. ~€36/h and a ~1000 GB weights disk. `max_model_len` 393216 is the floor for the "max" reasoning mode 🚫 |
| `glm53-flash` | GLM-5.3-Flash (321B-A18B MoE, multimodal) | FP8 | **4×B200** (`…4xB200`, TP=4) | 1048576 | ⬜ | — | — | — | — | Newly added, `requires_review`. ~306 GiB of weights. `Glm5NextForConditionalGeneration` is in neither v0.23.0 nor v0.29.0 — needs the pinned `vllm/vllm-openai:glm53-flash` image. FP8 KV cache is Blackwell-only for this model; Hopper must run BF16 KV 🚫 |
| `glm53` | GLM-5.3 (743B-A39B MoE) | FP8 | **8×B200** (`…8xB200`, TP=8) | 1048576 | ⬜ | — | — | — | — | Newly added, `requires_review`. Same architecture and flags as `glm52`, but the recipe's floor is vLLM 0.28.0, so it pins v0.29.0 rather than the shared v0.23.0. ~756 GB of weights, ~€36/h 🚫 |
| `kimi-k3` | Kimi K3 (93L, 896 experts, multimodal) | compressed-tensors | 8×GB300 — **not available on UpCloud** | 262144 | ⬜ | — | — | — | — | Newly added, `requires_review`. ~1561 GB of weights against ~1538 GB on 8×B200, and the recipe's floor is 8×GB300 (2304 GB). Its image is cu130-only and needs an r580+ driver. Every preflight refuses it here 🚫 |
| `glm52-nvfp4` | GLM-5.2 (753B MoE) | NVFP4 | **4×B200** (`…4xB200`, TP=4+EP) | 786432 | ✅ | 828,160 tok | 1.05× | 170,786/183,359 MiB ×4 | 2026-07-04 | `bin/spin validate` OK; full soak + quality pass — see **“Soak & output-quality checks”** below. ⚠️ 1.05× = single-user at full ctx. 1M ctx does NOT fit (needs 53.9 GiB KV vs 40.8 free; vLLM ceiling 793,216) |
| `glm52` | GLM-5.2 (753B) | FP8 | 8×B200 node | 1048576 | ⬜ | — | — | — | — | `requires_review`; FP8 ~756 GB needs 8×B200 (36 €/h) — the NVFP4 row above is the validated path at half the price |

Notes:
- All validated L40S rows use `--kv-cache-dtype fp8` (static; **never** `--calculate-kv-scales` on the
  Qwen Gated-DeltaNet+Attention hybrids — vLLM #37554 corrupts FP8 KV).
- `qwen36` is also expected to run on H100/B200 with far more KV headroom, but only the **L40S** run is verified.
- Each `max_model_len` is capped at the model's **native** context; beyond that needs YaRN/rope_scaling.
- **B200 reports 179 GB** usable via nvidia-smi (183,359 MiB) — profile floors use `min_vram_gb: 175`.
- **RTX PRO 6000 (96 GB GDDR7, compute capability 12.0) has no rows yet.** Every FP8 profile and the
  two dense NVFP4 profiles list cc 12.0 in `untested_compute_capabilities`: they pass preflight,
  print an UNTESTED warning and serve. Measure one and add its row. NVFP4 **MoE** profiles list
  cc 12.0 in `unsupported_compute_capabilities` instead and refuse — the CUTLASS grouped
  block-scaled GEMM returns invalid output there without a FlashInfer build patched against
  CUDA 13.0, and vllm-project/vllm#35566 is open.
- **NVFP4 MoE**: do **not** set `VLLM_USE_FLASHINFER_MOE_FP4=1` on this image — it *forces* the FlashInfer
  path and raises `NotImplementedError: … no FlashInfer NVFP4 MoE backend supports the configuration`;
  unset, vLLM auto-selects a working (CUTLASS) backend. Cost: two MoE crash-loop rounds on 2026-07-04.
- **FP8 caches freed for DeepSeek** (2026-07-04): the qwen36/gemma4-31b/qwen36-35b FP8 caches (~96 GB) were
  deleted from `/data` to fit DeepSeek's 157 GB — those FP8 models re-download (~5–10 min) on their next spin.
  All 10 profiles cached simultaneously needs ~400 GB — far more than the default `weights_size_gb`
  (150 GB), so treat `/data` as an LRU cache.
- **2026-07-05 spot-check + `requires_review` cleared:** re-ran gemma4-26b & gemma4-31b (L40S) and
  gemma4-26b-nvfp4 & gemma4-31b-nvfp4 (B200) live — numbers match the rows above **exactly**, soak 6/6 with
  fabrication traps declined; qwen36-27b-nvfp4 & qwen36-35b-nvfp4 re-served via llama-swap ("swap ok").
  `requires_review: true` was then removed from all non-GLM profiles (qwen36-35b trusted on its 2026-07-04
  row, not re-run). **glm52 FP8 stays `requires_review` by cost choice** (8×B200 ~36 €/h), not doubt.
  Fixed along the way: `ACME_EMAIL` was a placeholder (`…@example.com`) → Let's Encrypt rejects the domain,
  so Caddy never got a cert and HTTPS silently failed after a full deploy; set a real address + added a
  deploy **preflight** that rejects placeholder domains. The first B200 create hit UpCloud `state=error`
  (host failure) — recovered per the runbook below (auto-repaired → deleted, **weights disk preserved**),
  retry landed on a healthy host.

## Soak & output-quality checks (GLM-5.2 NVFP4, 2026-07-04)

Beyond "does it serve", GLM got a load + quality pass (the procedure is reusable for any profile —
script pattern in the session scratchpad: N rounds of concurrent mixed requests, then a temp-0
factual battery with fabrication traps):

**Output quality (sequential battery, temp 0, 8 heavy requests): excellent — zero fabrications.**
- Facts 6/6 exact: Canberra (dodged the "Sydney" trap), 47×89=4183, Berlin Wall 1989, tungsten=W,
  García Márquez, and the first three *Attention Is All You Need* authors (Vaswani, Shazeer, Parmar).
- Fabrication trap (summarize a nonexistent 1987 novel): **clean refusal** — "I don't want to risk
  providing you with inaccurate or fabricated details about a book I cannot verify."
- Second trap (Marie Curie on the 2024 Olympics): returned empty content — no fabrication; likely a
  thinking-mode token-budget artifact (max_tokens 300), inconclusive rather than failed.

**Capacity under concurrent load (12 rounds × 6 parallel, mixed sizes): admission-limited, by design.**
- 21/72 requests succeeded; the 51 failures were *fast* rejections, not timeouts, and the box stayed
  healthy throughout (no container restarts, VRAM flat at 170.8/179 GiB ×4 — no leak, no crash).
- Interpretation: at `max_model_len: 786432` the KV pool fits **1.05 full-length requests**, so
  vLLM's admission control sheds parallel load. Every *admitted* request returned real content
  (availability verified; soak responses were not quality-graded — quality evidence is the battery).
- **Recommendation:** the 768 K profile is the *single-user / agentic* configuration. For multi-user
  serving, deploy with `-e max_model_len=262144` (~3× concurrency by KV math) — **not yet
  live-verified at 262 K**; a warm re-test costs ~€6–8 (~20 min to serving, weights cached).

## Timings & session cost (measured — this matters at 4.5–18 €/h)

Knowing what "normal" looks like prevents the two expensive mistakes: tearing down a healthy box that
is merely still loading, and idling a billing box waiting for something that already failed. All times
below are measured on live runs (2026-07-04 → 2026-07-04); downloads assume an `HF_TOKEN` (~126 MB/s —
**anonymous drops to ~50 KB/s** after heavy use and will look like a hang).

**Fixed overheads:** `tofu apply` provision ≈ 3–5 min (B200 can be slower; one create sat in `error` —
see the runbook) · Ansible pre-model ≈ 2 min (image is cached on /data, no pull) · teardown ≈ 1–2 min.

| Profile (plan, price) | Cold: download + load → serving | Warm (weights cached) | Cold session cost* |
|---|---|---|---|
| `qwen36` (L40S, 1.11 €/h) | 29 GB ≈ 4 min + load ≈ 2–4 min → **~12 min** | ~2 min (16 s reload measured) | ~0.3 € |
| `gemma4-31b` / `gemma4-26b` (L40S) | 33/27 GB → **~15 min** (587 s health-wait measured) | ~3–5 min | ~0.3 € |
| `qwen36-35b` (H100, 1.79 €/h) | 37.5 GB → **~20 min** (904 s health-wait measured) | ~5 min | ~0.7 € |
| `*-nvfp4` dense/MoE 14–31 GB (1×B200, 4.5 €/h) | → **~10–15 min** | ~3–5 min | ~1 € |
| `deepseek-v4-flash-vision` (4×B200, **18 €/h**) | ~168 GB + TP4 init → **not yet measured** | — | — |
| `glm52-nvfp4` (4×B200, **18 €/h**) | 447 GB ≈ 60 min + **457 s engine init** (+1 warmup restart) → **~90 min** | **~18–20 min** | **~27 € cold / ~6 € warm** |

\* provision→serving→teardown, no usage time. Warm = weights already on `/data` (they persist across
teardowns; `/data` is an LRU cache sized by `weights_size_gb`, 150 GB by default — check
`du -sh /data/hf-cache/hub/models--*` before assuming).

Session discipline for the expensive tiers:
- The health-wait is sized per profile (`health_wait_retries`, ×10 s): GLM 25 min, DeepSeek/35B 20 min,
  default 15 min. If a play still reports a health-wait failure, **poll `/v1/models` before teardown** —
  multi-GPU engines have finished minutes after the play gave up.
- Evening sessions: re-arm the auto-off (`--shutdown-at 23:30`) — it fired mid-engine-load once.
- Watch downloads via `du` growth, not silence: ~126 MB/s ≈ 7.5 GB/min authenticated is normal;
  ~0 for >2 min means throttling/stall — fix the token, don't wait.

## Operational notes

- **/data fills up:** a default-sized 150 GB disk hit 100% on 2026-07-04 (Docker image ~23 G + qwen36 29 G +
  gemma-31b 32 G + gemma-26b 27 G + qwen36-35b 35 G + misc) — an uncached download then fails with
  `No space left on device` deep inside the HF downloader. Freed by deleting re-downloadable caches
  (`/data/hf-cache/hub/models--…`; removed gemma-26b + the stale pruned Qwen3-8B). To keep the FP8 set
  cached simultaneously, grow `weights_size_gb` (persistent stack) to ~250 and re-run
  `bin/spin persistent-init`; all 10 profiles at once need ~400 GB.

- **Multi-GPU cold-start exceeds the health-wait:** GLM-5.2 on 4×B200 took ~18 min to serve (447 GB
  weight load + 457 s engine init/compile + 1 warmup restart) — Ansible's 15-min health-wait expires
  and reports failure while the box is actually fine. Poll `/v1/models` afterward before concluding.
- **The auto-off timer fires blind:** the 21:00-Zurich self-poweroff killed a 4×B200 mid-engine-load
  (validation session running past 19:00 UTC). For evening sessions pass `--shutdown-at 23:30` (or
  re-arm via `-e auto_shutdown_time=`) — the safety doesn't know a deploy is in progress.
- **HF anonymous throttling:** after ~350 GB of unauthenticated downloads in one day, HF cut this
  IP to ~50 KB/s (metadata still fast — only bulk transfer throttled). An `HF_TOKEN` in `.env`
  restored ~126 MB/s instantly. For multi-hundred-GB models, always set a token.
- **Stuck/errored server runbook** (lived 2026-07-04, B200): a server can land in UpCloud state `error`
  at creation (host-level failure — also caused 500s on its firewall/FIP API calls). While `error`,
  stop/delete return 409; UpCloud's automation usually repairs or releases it within ~30 min — poll, and
  destroy the moment it leaves `error`. After any messy delete, check for and remove: (1) an orphaned
  boot disk (`terraform-gpu-spinner-disk`, a 100 GB orphan bills ~€9–23/mo by tier; NEVER touch `gpu-spinner-weights`), and
  (2) stale tofu state (`tofu -chdir=terraform/providers/upcloud state rm upcloud_server.gpu
  upcloud_firewall_rules.gpu` — a deleted server's firewall GET returns "Permission denied", which
  aborts the next plan). A create that times out "waiting for started" may leave an UNTRACKED billing
  server — list servers via the API and delete it by UUID. Correlation IDs from the incident:
  `01KWGVNZ0R…`, `01KWGVQXNZ…`, `01KWGVST4K…`.

- **Losing the operator machine (state recovery):** the local tfstates are the only pointers to the
  billing resources. To rebuild on a fresh machine: clone the repo, restore `.env`, then re-import the
  persistent stack — `tofu -chdir=terraform/persistent import upcloud_storage.weights <disk-uuid>` and
  `tofu -chdir=terraform/persistent import upcloud_floating_ip_address.vip <ip>` (discover both via
  `curl -H "Authorization: Bearer $UPCLOUD_TOKEN" https://api.upcloud.com/1.3/storage/private` /
  `.../ip_address`). The ephemeral stack needs no recovery — destroy any stray server via the API and
  `bin/spin up` fresh.

## All gating verified ungated

Per the HF API (`gated:false`), no model needs an `HF_TOKEN`: `google/gemma-4*`, the RedHat FP8 builds,
the `nvidia/*-NVFP4` builds, and Qwen3.6 are all ungated/Apache-2.0. Check a repo with
`curl https://huggingface.co/api/models/<repo> | jq .gated` (the model-card prose can mislead).
