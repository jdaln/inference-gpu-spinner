# Validation matrix — system of record

This is the exact record of what has been **live-validated** on real UpCloud GPUs, what 
has not yet been tested, and what is **known broken**. Every model × quant × tier the spinner
targets has a row. Update this file on every live run — do not rely on memory.

**Capture results consistently with `bin/spin validate`** (run it against a deployed model): it reports
the served model id + `max_model_len` (`/v1/models`), the vLLM-reported **GPU KV cache size** and
**max concurrency at full context**, **VRAM used**, and a **test generation** — exactly the fields below.

Status legend: ✅ validated live · ⬜ not yet run on this tier (paper-sized) · ❌ known broken ·
🚫 not servable on this tier (needs a bigger/multi-GPU node).

**What ⬜ means, as of 2026-09-20.** For every row below it means exactly this and nothing more,
and it is a statement about evidence rather than a queue position: *the offline gate confirms the architecture, the
parsers and every flag exist in the image the profile pins; the preflights confirm the hardware
fits on paper; nobody has started the engine.* The `max_model_len` in such a row is the model's
serving recipe, not a measurement — treat it as untested in both directions.

Most ⬜ rows sit behind `requires_review`, so reaching one takes a deliberate
`--allow-unvalidated`. **Three do not**: `qwen38`, `qwen38-nvfp4` and `qwen38-flash-next` deploy
on a bare `bin/spin up --model <name>` with only a debug warning — and `qwen38-flash-next` lands
on a 4-GPU, €6.60/h tier that way. Those are the rows that matter most, because an accidental user
reaches them.

The rest stay ⬜ by budget decision: the campaign that produced the RTX PRO 6000 rows was scoped
to that hardware. Testing the 4×B200 rows is ~€18/h each and the 8×B200 rows
~€36/h; see "Timings & session cost" for what a session buys.

## Models

Numbers are vLLM's own startup report (`kv_cache_utils`), `nvidia-smi`, and `/v1/models`, captured live.

**`Tier (plan)` below is where a run was measured.** Where a profile deploys can differ: `bin/spin`
picks that from the profile's `min_plan`, and for several models the cheapest plan that runs them is
one nobody has measured yet. Rows say so where the two differ, and the main lane per profile is in
the [README table](../README.md#models).

| Profile | Model | Quant | Tier (plan) | `max_model_len` | Status | KV pool | Concurrency @ max | VRAM | Date | Evidence |
|---|---|---|---|---|---|---|---|---|---|---|
| `qwen36` | Qwen3.6-27B | FP8 | L40S (`…1xL40S`) | 262144 (native) | ✅ | 372,123 tok | 1.42× | 41,023/46,068 MiB | 2026-07-04 | commit `11d6177`; gen "Capital of Finland" |
| `gemma4-31b` | Gemma 4 31B (dense) | FP8 | L40S | 65536 | ✅ | 105,859 tok | 1.62× | 41,543/46,068 MiB | 2026-07-04 | `11d6177`; gen "gemma 64k ok" |
| `gemma4-26b` | Gemma 4 26B-A4B (MoE) | FP8 | L40S | 131072 | ✅ | 986,681 tok | 7.53× | 41,597/46,068 MiB | 2026-07-04 | `11d6177`; gen "gemma 26b ok" (headroom for 262144) |
| `qwen36-35b` | Qwen3.6-35B-A3B (MoE) | FP8 | H100 (`…1xH100`) | 262144 | ✅ | 3,416,000 tok | 13.03× | 74,183/81,559 MiB | 2026-07-04 | `bin/spin validate`: gen "validation ok" / "NVIDIA's flagship AI GPU" (thinking model — pass `enable_thinking:false` for direct answers) |
| `qwen36-27b-nvfp4` | Qwen3.6-27B | NVFP4 | B200 (`…1xB200`) | 262144 | ✅ | 4,413,523 tok | 16.84× | 169,304/183,359 MiB | 2026-07-04 | `bin/spin validate`: gen "validation ok" |
| `qwen36-35b-nvfp4` | Qwen3.6-35B-A3B (MoE) | NVFP4 | B200 ✅ 2026-07-04; **also 1×RTX PRO 6000 ✅ 2026-09-20** | 262144 | ✅ | 6,269,102 tok (RTX PRO 6000) | 23.91× | 90,283/97,887 MiB | 2026-09-20 | **cc 12.0 ban removed — same stale gate as `gemma4-26b-nvfp4`.** Ran on the shared cu129 pin; vLLM chose the **MARLIN** NvFp4 MoE kernel (its sibling chose `VLLM_CUTLASS`) and both were correct, so the gate was wrong about the family rather than about one kernel. `soak --rounds 3 --concurrency 20 --context 32768`: factual 6/6, both traps declined, **60/60 needles**, 0 wrong/rejected/timed out, p50 17.3 s. **Default lane moves B200 €4.50/h → RTX PRO 6000 €1.65/h list (€1.24 spot)** |
| `qwen38` | Qwen3.8-27B (dense hybrid) | FP8 | **1×RTX PRO 6000** (spot) — lane is L40S | 131072 | ✅ | 1,743,257 tok | 13.30× | 88,147/97,887 MiB | 2026-09-20 | Validated live on `GPU-SPOT-16xCPU-80GB-1xRTXPRO6000` (€1.24/h), driver 595.58.03, cc 12.0. FLASHINFER attention; model load 27.57 GiB in 72.8 s; init engine 41.5 s. `soak --rounds 3 --concurrency 20 --context 32768`: factual 6/6, both traps declined, **60/60 needles** at all depths, 0 wrong/rejected/timed out; median 32,754 prompt_tokens, p50/p95 41.7 s/69.1 s. **`max_model_len` deliberately NOT raised.** The KV pool here would carry 262144 easily (6.6× concurrency), but 131072 was chosen for this profile's actual default lane, a 46 GiB L40S, and raising it from a 96 GiB measurement would be exactly the carry-a-number-across-tiers error. **The L40S lane remains unmeasured** — ~€1 and ~45 min to close |
| `qwen38-nvfp4` | Qwen3.8-27B (dense hybrid) | NVFP4 | **1×RTX PRO 6000** (spot) | 262144 | ✅ | 1,902,460 tok | 7.26× | 88,087/97,887 MiB | 2026-09-20 | Validated live on `GPU-SPOT-16xCPU-80GB-1xRTXPRO6000` (€1.24/h), driver 595.58.03, cc 12.0. FLASHINFER attention backend; CUDA graphs captured PIECEWISE+FULL in 9 s (1.55 GiB); model load 20.29 GiB in 53.8 s; init engine 123.9 s. `validate` returned coherent text — **not** the single-repeated-token signature of the zeroed NVFP4 activation scale (vllm#54189). `soak --rounds 3 --concurrency 20 --context 32768`: factual 6/6, both fabrication traps declined, **60/60 needles** at head/middle/tail, 0 wrong, 0 rejected, 0 timed out; median 32,754 prompt_tokens, p50/p95 45.4 s/68.5 s. `ceiling` ascended 65,429 → 130,803 → **259,512 prompt_tokens, all passing**, restart count unchanged — so the profile's 262144 is a measured ceiling, not a recipe number. Weights came from `bin/spin prefetch` (no download on the GPU box) |
| `qwen38-flash-next` | Qwen3.8-Flash-Next (125B-A6B MoE + 51B N-gram) | FP8 | **4×RTX PRO 6000** (spot) | 262144 | ✅ | 3,640,845 tok | 13.89× | 85,340–85,466/97,887 MiB ×4 | 2026-09-20 | Validated on `GPU-SPOT-64xCPU-320GB-4xRTXPRO6000` (€4.95/h, list 6.60), driver 595.58.03, cc 12.0. TRITON Fp8 MoE; model load 32.72 GiB/rank in ~29 s; init engine 110.7 s. **TP=4 over PCIe with no NVLink came up first try — `NCCL_P2P_DISABLE` was not needed.** soak 3×20 @32768: factual 6/6, **60/60 needles**, 0 wrong/rejected/timed out, p50 20.8 s. `ceiling`: 65,429 → 130,803 → **259,512 prompt_tokens all passing**, so 262144 is measured. **Required a fix to ship: `cap_add: [SYS_PTRACE]`.** Its mandatory `VLLM_PLE_CPU_OFFLOAD=1` passes CUDA tensors over IPC, which calls `pidfd_getfd(2)`; Docker's default seccomp gates that behind CAP_SYS_PTRACE, so engine init died with `RuntimeError: pidfd_getfd: Operation not permitted` ~8 min in, after the 173 GB checkpoint had loaded. Every offline gate passed it — no static check sees a refused syscall |
| `gemma4-26b-nvfp4` | Gemma 4 26B-A4B (MoE) | NVFP4 | B200 ✅ 2026-07-05; **also 1×RTX PRO 6000 ✅ 2026-09-20** | 262144 | ✅ | 4,822,910 tok (RTX PRO 6000) | 18.40× | 88,921/97,887 MiB | 2026-09-20 | **The cc 12.0 ban was stale — removed.** Ran on `GPU-SPOT-16xCPU-80GB-1xRTXPRO6000` (€1.24/h) on the shared **cu129** pin `v0.23.0-cu129-ubuntu2404`, i.e. the very build the profile said returns invalid output. vLLM selected `VLLM_CUTLASS` NvFp4 MoE — the grouped block-scaled GEMM path in question — and the result was correct throughout: `soak --rounds 3 --concurrency 20 --context 32768` gave factual 6/6, both traps declined, **60/60 needles** at head/middle/tail, 0 wrong/rejected/timed out, p50 14.1 s. A short-prompt check alone was deliberately not trusted (vllm#55757 is the case where short passes and long fails); the graded long-context load is what clears it. The cu130 image was not needed. Root cause of the stale gate: flashinfer#2708 closed 2026-04-20 and vllm#54189 closed 2026-08-30, both before this image was built (2026-06-13), but the profile comment was never re-checked. **Default lane moves B200 €4.50/h → RTX PRO 6000 €1.65/h list (€1.24 spot), a 63–72% cut** |
| `gemma4-31b-nvfp4` | Gemma 4 31B (dense) | NVFP4 | B200 | 262144 | ✅ | 2,415,691 tok | 9.22× | 166,008/183,359 MiB | 2026-07-04 | validate OK |
| `deepseek-v4-flash-vision` | DeepSeek-V4-Flash-Vision-Exp (285B-A13B MoE, multimodal) | FP4+FP8 | **4×B200** (`…4xB200`, TP=4+EP) | 32768 | ⬜ | — | — | — | — | `requires_review`; ~168 GB of weights, ~202 GB VRAM budget before KV. Needs the pinned `vllm/vllm-openai:deepseekv4-flash-vision` image — the stable wheel routes this checkpoint to the text-only class. Published vision runs exist only on GB200 NVL4 (TP4+EP) and MI350X, neither offered here 🚫 |
| `deepseek-v41-flash` | DeepSeek-V4.1-Flash (552B + 196B Engram MoE) | MXFP4+MXFP8 | **4×B200** (`…4xB200`, TP=4) | 1048576 | ⬜ | — | — | — | — | Newly added, `requires_review`. ~511 GB on disk / 476 GiB, recipe floor 614 GB VRAM — one GB200 NVL4 tray at TP4, which 4×B200 matches. Needs a vLLM nightly from 2026-09-10 or later; no release serves `deepseek_v41`. Engram tables alone are 183 GiB 🚫 |
| `deepseek-v4-pro-0813` | DeepSeek-V4-Pro-0813 (1.6T-A49B MoE) | FP4+FP8 | **8×B200** (`…8xB200`, TP=8) | 393216 | ⬜ | — | — | — | — | Newly added, `requires_review`. ~893 GB of weights; the recipe states it does not fit one 768 GB tray and all its recommended deployments are 8-GPU. ~€36/h and a ~1000 GB weights disk. `max_model_len` 393216 is the floor for the "max" reasoning mode 🚫 |
| `k2-horizon-375b` | K2-Horizon-375B-A23B (379B-A27B MoE) | FP8 | **lane: 8×RTX PRO 6000** (`…8xRTXPRO6000`, TP=8) | 131072 (native 524288) | ⬜ | — | — | — | — | Newly added, `requires_review`. ~391 GB of weights. `K2HorizonForCausalLM` is in neither v0.23.0 nor v0.29.0, so it pins the same dated nightly as `deepseek-v41-flash`. The recipe's only verified run is BF16 at TP8 on MI355X; this serves the FP8 build at TP8 on 8× RTX PRO 6000 (13.20 €/h vs 18.00 for 4×B200), which is both cheaper and the same TP as the published run. 4× RTX PRO 6000 cannot hold it: 391 GB of weights against 380 GB 🚫 |
| `glm53-flash` | GLM-5.3-Flash (321B-A18B MoE, multimodal) | FP8 | **4×B200** (`…4xB200`, TP=4) | 1048576 | ⬜ | — | — | — | — | Newly added, `requires_review`. ~306 GiB of weights. `Glm5NextForConditionalGeneration` is in neither v0.23.0 nor v0.29.0 — needs the pinned `vllm/vllm-openai:glm53-flash` image. FP8 KV cache is Blackwell-only for this model; Hopper must run BF16 KV. **Kept deliberately alongside the validated `glm53-flash-nvfp4`, which is not a substitute**: the NVFP4 sibling is capped at a *measured* 98304 while this profile carries the recipe's 1048576, and it needs no third-party kernel overlay. Its 1M is unmeasured, and vllm#54317 reports the same KDA crash frame on 4×B200 — so the ~100k per-request boundary measured on the NVFP4 build probably applies here too. Anyone paying 18.00 €/h for the long-context lane should ceiling-search it first (`bin/spin ceiling`) 🚫 |
| `glm53-flash-nvfp4` | GLM-5.3-Flash (321B-A18B MoE, multimodal) | NVFP4 | **4×RTX PRO 6000** (`…4xRTXPRO6000`, TP=4) | **98304 (capped — native is 1,048,576)** | ✅ | 4,552,849 tok | 4.34× @1M, ~46× at the cap | 85,219/97,887 MiB ×4 | 2026-09-20 | driver 595.58.03, cc 12.0, Server Edition. `Using FLASHINFER_MLA_SPARSE_SM120 attention backend out of potential backends: ['FLASHINFER_MLA_SPARSE_SM120']` — the pinned overlay is the only MLA candidate, so without it the model cannot start. NVFP4 MoE auto-selects **MARLIN**. Engine init 185 s. Graded soak (`bin/spin soak`): **60/60 needles at 3 × 20 × 25,861 tok** (p50 27.4 s), **10/10 at 98,100** (p50 57 s), **10/10 at 65,403** (p50 50 s), **20/20 at 51,670** (p50 27 s). **Context ceiling ~100k per request:** a single 102,400-token request kills the engine (CUDA illegal memory access in KDA linear attention), so `max_model_len` is capped at 98304 and over-long requests get a clean 400. Request length alone decides it: concurrency, prefix caching, KV capacity, memory exhaustion, the overlay and this GPU were each ruled out, and vllm#54317 reports the same frame on 4×B200. Full evidence in `ansible/models/glm53-flash-nvfp4.yml`. 6.60 €/h against 18.00 for the FP8 4×B200 row. | **Re-run 2026-09-20 on a clean disk** (spot, €4.95/h): the pinned overlay rebuilt from source and loaded (`FLASHINFER_MLA_SPARSE_SM120` present), MARLIN MoE, and `init engine` reproduced at **184.94 s vs the 185 s recorded** — the digest+commit pin is deterministic. Three figures came out higher and are NOT overwritten here: KV pool 4,971,913 vs 4,552,849 tok (+9.2%), concurrency 50.58× vs ~46×, VRAM 86,453 vs 85,219 MiB. Same image digest and plugin commit, so most likely a difference in free memory at profiling time; size against the lower figure. The vllm#52225 sustained-load (Xid 13) check is still outstanding — both runs exercised minutes, not hours |
| `glm53` | GLM-5.3 (743B-A39B MoE) | FP8 | **8×B200** (`…8xB200`, TP=8) | 1048576 | ⬜ | — | — | — | — | Newly added, `requires_review`. Same architecture and flags as `glm52`, but the recipe's floor is vLLM 0.28.0, so it pins v0.29.0 rather than the shared v0.23.0. ~756 GB of weights, ~€36/h 🚫 |
| `kimi-k3` | Kimi K3 (93L, 896 experts, multimodal) | compressed-tensors | 8×GB300 — **not available on UpCloud** | 262144 | 🚫 | — | — | — | — | Newly added, `requires_review`. ~1561 GB of weights against ~1538 GB on 8×B200, and the recipe's floor is 8×GB300 (2304 GB). Its image is cu130-only and needs an r580+ driver. Every preflight refuses it here. **🚫 is permanent, not pending**: measured 1454 GB of weights (HF file listing, 2026-09-20) against ~1432 GB of VRAM on the largest node sold here (8×B200 = 8×179), and `min_vram_gb: 280` exceeds any single GPU on offer. There is no run to schedule. It also has no `min_plan`, deliberately — `bin/spin up` now refuses a profile with no usable `min_plan` rather than letting it latch onto whatever box is live |
| `glm52-nvfp4` | GLM-5.2 (753B MoE) | NVFP4 | **4×B200** (`…4xB200`, TP=4+EP) | 786432 | ✅ | 828,160 tok | 1.05× | 170,786/183,359 MiB ×4 | 2026-07-04 | `bin/spin validate` OK; full soak + quality pass — see **“Soak & output-quality checks”** below. ⚠️ 1.05× = single-user at full ctx. 1M ctx does NOT fit (needs 53.9 GiB KV vs 40.8 free; vLLM ceiling 793,216) |
| `glm52` | GLM-5.2 (753B) | FP8 | 8×B200 node | 1048576 | ⬜ | — | — | — | — | `requires_review`; FP8 ~704 GB (measured 2026-09-20) needs 8×B200 (36 €/h) — the NVFP4 row above is the validated path at half the price. **Kept deliberately: not a duplicate.** The NVFP4 build serves 786432 context, this one 1048576, and this is the higher-precision weights. Gated on cost, not doubt. It shipped without `validated: false`, so until 2026-09-20 it silently defaulted to claiming a live run; that key is now set |

Notes:
- All validated L40S rows use `--kv-cache-dtype fp8` (static; **never** `--calculate-kv-scales` on the
  Qwen Gated-DeltaNet+Attention hybrids — vLLM #37554 corrupts FP8 KV).
- `qwen36` is also expected to run on H100/B200 with far more KV headroom, but only the **L40S** run is verified.
- Each `max_model_len` is capped at the model's **native** context; beyond that needs YaRN/rope_scaling.
- **B200 reports 179 GB** usable via nvidia-smi (183,359 MiB) — profile floors use `min_vram_gb: 175`.
- **RTX PRO 6000 (96 GB GDDR7, compute capability 12.0) has its first row: `glm53-flash-nvfp4`,
  2026-09-20.** A 96 GB card reports **95 GB** via nvidia-smi, hence `min_vram_gb: 90` on these
  profiles. The card is the *Blackwell Server Edition* — the variant the overlay kernel lists as
  verified; upstream reports from Max-Q or Workstation parts do not carry over. It is also the default
  lane for `qwen38-flash-next` (4×) and `k2-horizon-375b` (8×), which have no rows yet: they pass
  preflight, print an untested warning and serve. Measure them and add the rows.
- **Driver on the UpCloud GPU template: r595 (595.58.03), measured 2026-09-20** on
  `GPU-64xCPU-320GB-4xRTXPRO6000` in fi-hel2 (card: *RTX PRO 6000 Blackwell Server Edition*,
  97,887 MiB → `gpu_total_vram_gb` 95, cc 12.0, four per node). That clears the r580+ floor, so
  **the official cu130 tags are usable on this account** — `glm53-flash-x86_64-cu130`,
  `qwen38-flash-next-x86_64-cu130` and `deepseekv4-flash-vision-x86_64-cu130` all exist in
  `vllm/vllm-openai`. It also makes the NVFP4 MoE profiles (`gemma4-26b-nvfp4`,
  `qwen36-35b-nvfp4`) worth re-testing on a single card at 1.65 EUR/h against 4.50 on a B200: the
  GEMM fault they cite is reported fixed in cu130's FlashInfer, so dense-or-MoE is the only
  question left to answer.
- **Why the other large profiles still refuse cc 12.0: sparse attention.**
  vllm-project/vllm#55757 reports DeepSeek-style sparse MLA unservable on sm_120, and it fails
  *late* — short prompts pass and realistic lengths break, so a quick check proves little. The NVFP4
  MoE GEMM fault is reported fixed on cu130 (flashinfer-ai/flashinfer#2708), and much of that
  symptom was vllm-project/vllm#54189: an uninitialised `w13_input_scale` silently multiplying every
  expert output by zero. **If a model loads and serves but emits one token repeatedly, suspect that
  before the kernels.**
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
  (availability verified; soak responses were not quality-graded at the time — the quality
  evidence is the battery. `bin/spin soak` grades them now).
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

**Do the download on a different machine.** Every "cold" figure above is dominated by the pull, and
the pull is billed at whatever compute holds the disk — which is not GPU work in any sense. A
`2xCPU-4GB` box costs €0.0446/h against €6.60 for 4×RTX PRO 6000 and €18.00 for 4×B200, so
`bin/spin prefetch <profile>...` collapses that line item by about 150×:

| Pull | On the GPU box | Via `bin/spin prefetch` |
|---|---|---|
| 173 GB (`qwen38-flash-next`, 4×RTX PRO 6000) | ~23 min ≈ €2.53 | ~23–46 min ≈ €0.02 |
| 354 GB (that plus `glm53-flash-nvfp4`) | ~47 min ≈ €5.17 | ~47–94 min ≈ €0.04 |
| 831 GB (`deepseek-v4-pro-0813`, 8×B200) | ~110 min ≈ €66 | ~110–220 min ≈ €0.10 |

It also pulls each profile's container image (9–14 GB, currently pulled at GPU rate) onto the same
disk, because Docker's data-root lives there. An UpCloud disk attaches to one server at a time, so
prefetch and a GPU session are strictly sequential — `bin/spin prefetch` refuses while a GPU server
exists. The small box's slower NIC makes the wall-clock longer and the bill smaller; on the
expensive tiers that is always the right trade.

**Spot plans are 25% off and are plain plan ids** — `--plan GPU-SPOT-64xCPU-320GB-4xRTXPRO6000`
(€4.95/h vs €6.60) works with no code change. A spot box can be reclaimed; with weights already
prefetched onto `/data`, that costs minutes rather than a re-download, which makes validation runs
close to the ideal spot workload. Do not use spot for anything serving traffic.

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

## Multi-model swap presets

| Preset | Plan | Entries | Status | Date | Notes |
|---|---|---|---|---|---|
| `rtxpro6000` | `GPU-16xCPU-80GB-1xRTXPRO6000` | qwen36, gemma4-26b, gemma4-31b, qwen36-27b-nvfp4, gemma4-31b-nvfp4 | ✅ | 2026-09-20 | First run of the preset as a whole. All five registered and answered after a cold swap-in of 159–308 s. Graded soak through the swap path (gemma4-31b-nvfp4, 2×6 @16384): factual 6/6, traps 2/2, 12/12 needles, 0 wrong. Rendered config now carries `--tensor-parallel-size`/`--dtype` and a derived `healthCheckTimeout: 900`. **`bin/spin validate` is blind here** — `/v1/models` reports `max_model_len=null` until a backend loads |
| `l40s` | `GPU-8xCPU-64GB-1xL40S` | qwen36, gemma4-26b, gemma4-31b | ⬜ | — | Renders and resolves in CI; never deployed |
| `b200-nvfp4` | `GPU-24xCPU-240GB-1xB200` | qwen36-27b-nvfp4, qwen36-35b-nvfp4, gemma4-26b-nvfp4, gemma4-31b-nvfp4 | ⬜ | — | Renders and resolves in CI; never deployed. Note all four entries now also run on the far cheaper `rtxpro6000` lane |

## Repo, size and image audit — re-verified 2026-09-20

Every check below is free and was re-run against the live APIs on 2026-09-20, covering all 21
profiles (the previous note predated the eleven added on this branch).

**Gating.** All 21 HF repos return `gated: false`, so no model strictly needs an `HF_TOKEN`. Set
one anyway: anonymous downloads throttle to ~50 KB/s after a few hundred GB in a day, which on a
€18/h box costs far more than the token is worth. Check a repo with
`curl https://huggingface.co/api/models/<repo> | jq .gated` (the model-card prose can mislead).

**Download sizes**, summed from each repo's file listing (`?blobs=true`), not `usedStorage` —
that counts every revision and reads several times too high:

| Profile | Measured | Profile said | Profile | Measured | Profile said |
|---|---|---|---|---|---|
| qwen38 | 29 GB | ~31 | qwen38-nvfp4 | 22 GB | ~22 |
| qwen36 | 29 GB | ~29 | qwen36-35b | 35 GB | ~37.5 |
| gemma4-26b | 27 GB | ~27 | gemma4-31b | 31 GB | ~33 |
| gemma4-26b-nvfp4 | 18 GB | ~14 | gemma4-31b-nvfp4 | 30 GB | ~21 |
| qwen36-27b-nvfp4 | 20 GB | ~17 | qwen36-35b-nvfp4 | 22 GB | ~19 |
| qwen38-flash-next | 173 GB | ~186 | glm53-flash-nvfp4 | 181 GB | ~195 |
| deepseek-v4-flash-vision | 156 GB | ~168 | glm53-flash | 306 GB | ~306 |
| k2-horizon-375b | 364 GB | ~391 | **glm52-nvfp4** | **433 GB** | **~377 (understated)** |
| deepseek-v41-flash | 475 GB | ~511 | glm52 / glm53 | 704 GB | ~756 |
| deepseek-v4-pro-0813 | 831 GB | ~893 | kimi-k3 | 1454 GB | ~1561 |

Most profiles were conservative, which is the safe direction. `glm52-nvfp4` was the exception —
it claimed ~377 GB against a real 433 GB pull, and has been corrected. Every profile now carries a
machine-checked `min_disk_gb` (measured + ~40 GB for the container image and Docker's data-root,
which share the disk), and the vLLM role refuses to deploy when `/data` has less free than that.
Before this, an under-sized disk was discovered as "No space left on device" 20–120 minutes into a
pull on a GPU billed by the hour — the one common failure with no machine check.

**Container images.** All nine pinned tags still resolve on Docker Hub. Four are mutable
(`:qwen38-flash-next`, `:deepseekv4-flash-vision`, `:glm53-flash`, `:kimi-k3`) and should be
pinned by digest as `glm53-flash-nvfp4` already is — that tag moved once already. Note there is
**no cu130 release tag**: vLLM's stable releases (v0.28.0, v0.29.0) are cu129 only, and cu130
exists solely as model-specific builds (`glm53-flash-x86_64-cu130`, `gemma4-unified-x86_64-cu130`,
`glm52-x86_64-cu130`, `qwen38-x86_64-cu130`, …). Any plan to "move to cu130" is per-profile.

**Upstream issues the profiles depend on**, re-read on 2026-09-20 — two are stale:

| Issue | State | Consequence |
|---|---|---|
| flashinfer#2708 (SM120 CUTLASS FP4 GEMM) | **closed 2026-04-20** | The NVFP4-MoE `unsupported_compute_capabilities: [12.0]` gates may be obsolete *with a cu130 image*. Worth a ~€2 retest on 1×RTX PRO 6000 against €4.50/h on B200 |
| vllm#54189 (NVFP4 MoE zeroed activation scale) | **closed 2026-08-30** | Part of what `glm53-flash-nvfp4`'s plugin overlay works around may now be upstream |
| vllm#37554 (`--calculate-kv-scales` corrupts FP8 KV) | closed 2026-03-20 | The "never add this flag" note in `qwen36.yml` is now historical |
| flashinfer#5075 (SM120 NoPE rows) | closed 2026-09-11 | One of the two the overlay waits on has landed |
| vllm#55277 (SM120 NoPE sparse MLA) | open | The other has not — keep the overlay |
| vllm#55757 (sparse MLA unservable on SM120) | open | The cc-12.0 gates on the DeepSeek profiles stand |
| vllm#54317 (GLM-5.3-Flash KDA illegal memory access) | open | Applies to 4×B200 too, so `glm53-flash` FP8 is exposed |
| vllm#52225 (Xid 13, Marlin MoE, RTX PRO 6000) | open | Only a long run surfaces it |
| vllm#41834 (SM12x for DeepSeek V4 Flash) | open | No cheaper lane for `deepseek-v4-flash-vision`; 4×B200 stands |

Re-check before trusting any of it: `curl -s https://api.github.com/repos/vllm-project/vllm/issues/N | jq '{state,updated_at}'`.
