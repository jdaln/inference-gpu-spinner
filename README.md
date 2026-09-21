# inference-gpu-spinner — on-demand cloud GPU inference

Spin up a cloud GPU in the morning, serve an LLM via **vLLM** (OpenAI-compatible) behind **Caddy**
(automatic HTTPS), and tear it down at night — so you pay only for the hours you use. First provider:
**UpCloud**. Built on **OpenTofu + Ansible**.

**New here? Start with [docs/getting-started.md](docs/getting-started.md)** — a step-by-step
walkthrough from a fresh clone to a served model and back down.

## How it works

- **Persistent stack** (`terraform/persistent/`) — a data disk (cached weights + Docker image + TLS
  cert) and a stable floating IP. Created once, never destroyed.
- **Ephemeral stack** (`terraform/providers/upcloud/`) — the GPU server + firewall, created and
  destroyed each session. Each spin-up re-binds the floating IP and re-attaches the disk.
- **Ansible** (`ansible/`) verifies the GPU/Docker (the UpCloud template pre-ships driver, CUDA and
  Docker), then runs vLLM + Caddy as a systemd-managed `docker compose` stack.
- **Stable hostname**: `<floating-ip-dashed>.sslip.io`, so the Let's Encrypt cert (kept on the disk)
  is reused across spin-ups instead of re-issued.

Architecture, security model, and the full cost breakdown: **[docs/gpu-spinner.md](docs/gpu-spinner.md)**.

## Prerequisites

- [OpenTofu](https://opentofu.org) ≥ 1.7, Ansible ≥ 10, `curl`, `jq`, `ssh` (optionally `upctl`).
- An UpCloud account + API token.
- `python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt`
- `ansible-galaxy collection install -r requirements.yml`

## Setup

1. `cp .env.example .env` — fill in `UPCLOUD_TOKEN`, `ACME_EMAIL` (a **real** address; Let's Encrypt
   rejects placeholder domains) and `VLLM_API_KEY`.
2. `cp terraform/providers/upcloud/terraform.tfvars.example terraform/providers/upcloud/terraform.tfvars`
   — set `os_template` and `ssh_public_keys`.

Each variable, and what to set when your egress IP rotates, is covered in
[docs/getting-started.md](docs/getting-started.md).

## Use

```bash
bin/spin persistent-init                                 # once: create the disk + floating IP
bin/spin up                                              # default: qwen36 (Qwen3.6-27B FP8) on an L40S
bin/spin up --model qwen38-flash-next                    # each profile brings its own plan (4x RTX PRO 6000 here)
bin/spin up --model qwen36-35b --plan GPU-16xCPU-80GB-1xRTXPRO6000  # --plan overrides it
bin/spin up --swap-profile b200-nvfp4                    # several models, one endpoint
bin/spin prefetch qwen38 qwen38-nvfp4                     # pull weights + images on a ~EUR 0.045/h CPU box
bin/spin status         # GPU + service status
bin/spin validate       # capture context/KV/VRAM/test-gen evidence
bin/spin soak           # answer-quality + concurrent-load check
bin/spin ceiling        # find the longest single request the model actually survives
bin/spin down           # destroy the GPU (keeps the IP) — stops the compute bill
```

Endpoint: `https://<floating-ip-dashed>.sslip.io/v1` — locked to your IP by the firewall and gated
by the vLLM API key. The `model` field takes the **served name**, not the profile name (`qwen36`
serves `qwen3.6-27b-fp8`); `bin/spin up` prints it, and `/v1/models` is authoritative.

```bash
curl https://<host>.sslip.io/v1/chat/completions \
  -H "Authorization: Bearer $VLLM_API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.6-27b-fp8","messages":[{"role":"user","content":"hello"}]}'
```

## Models

Pick a profile with `--model` (or `-e vllm_model=`); profiles live in `ansible/models/`. FP8 runs
anywhere from an L40S up; **NVFP4** needs Blackwell (~2× smaller + faster), and *which* Blackwell
depends on whether the checkpoint is dense or MoE — see below the table.

**Main lane** is the plan `bin/spin up --model <name>` deploys when you don't pass `--plan`; it
comes from the profile's `min_plan`. **Measured on** is where a dated live run exists in
[docs/validation.md](docs/validation.md). The two differ whenever the cheapest plan that runs a
model is still waiting for someone to measure it.

| Profile | Model | Quant | Main lane (default plan) | Measured on |
|---|---|---|---|---|
| `qwen36` (default) | Qwen3.6-27B | FP8 | L40S | L40S |
| `qwen38` | Qwen3.8-27B | FP8 | L40S | **L40S** and RTX PRO 6000 |
| `qwen38-nvfp4` | Qwen3.8-27B | NVFP4 | RTX PRO 6000 | **RTX PRO 6000** |
| `qwen38-flash-next` | Qwen3.8-Flash-Next (125B-A6B MoE + 51B N-gram) | FP8 | **4×RTX PRO 6000** | **4×RTX PRO 6000** |
| `glm53-flash-nvfp4` | GLM-5.3-Flash (321B-A18B MoE, **multimodal**) | NVFP4 | **4×RTX PRO 6000** | **4×RTX PRO 6000** (context capped at 98304) |
| `gemma4-26b` | Gemma 4 26B-A4B (MoE) | FP8 | L40S | L40S |
| `gemma4-31b` | Gemma 4 31B | FP8 | L40S | L40S |
| `qwen36-35b` | Qwen3.6-35B-A3B (MoE) | FP8 | H100 | **H100** |
| `qwen36-27b-nvfp4`, `gemma4-31b-nvfp4` | (same models, dense) | NVFP4 | B200 | B200; also RTX PRO 6000 via the `rtxpro6000` preset |
| `qwen36-35b-nvfp4`, `gemma4-26b-nvfp4` | (same models, MoE) | NVFP4 | **RTX PRO 6000** (was B200) | B200 **and RTX PRO 6000** |
| `glm52-nvfp4` | GLM-5.2 (753B MoE) | NVFP4 | 4×B200 | 4×B200 |
| `glm53-flash` | GLM-5.3-Flash, FP8 build | FP8 | 4×B200 — `requires_review` | — (new) |
| `glm53` | GLM-5.3 (743B-A39B MoE) | FP8 | 8×B200 — `requires_review` | — (new) |
| `k2-horizon-375b` | K2-Horizon-375B-A23B (379B-A27B MoE) | FP8 | **8×RTX PRO 6000** (TP=8) — `requires_review` | — (new) |
| `kimi-k3` | Kimi K3 (93L, 896 experts, **multimodal**) | compressed-tensors | **no UpCloud plan fits** | — (new) |
| `deepseek-v4-flash-vision` | DeepSeek-V4-Flash-Vision-Exp (285B-A13B MoE, **multimodal**) | FP4+FP8 | 4×B200 — `requires_review` | — (new) |
| `deepseek-v41-flash` | DeepSeek-V4.1-Flash (552B + 196B Engram MoE, **multimodal**) | MXFP4+MXFP8 | 4×B200 — `requires_review` | — (new) |
| `deepseek-v4-pro-0813` | DeepSeek-V4-Pro-0813 (1.6T-A49B MoE) | FP4+FP8 | 8×B200 — `requires_review` | — (new) |
| `glm52` | GLM-5.2 | FP8 | 8×B200 — `requires_review` (kept gated: ~36 €/h to test) | — |

**The RTX PRO 6000 line.** 96 GB, compute capability 12.0 — Blackwell, but a different family from
the B200's 10.0. At €1.65/h for a single card and €6.60 for four, against €4.50 and €18.00 for the
B200 equivalents, it is the default lane wherever it works, and it usually has capacity when H100
and B200 are sold out. Every FP8 profile runs on it, and so does **dense** NVFP4. Multi-GPU plans
have **no NVLink**, so tensor parallelism runs over PCIe. As of 2026-09-20 there are measured runs
for `glm53-flash-nvfp4`, `qwen38-nvfp4`, `qwen38`, `qwen38-flash-next`, `gemma4-26b-nvfp4`,
`qwen36-35b-nvfp4` and the whole `rtxpro6000` preset.

**NVFP4 MoE runs on this card too.** `gemma4-26b-nvfp4` and `qwen36-35b-nvfp4` both pass a full
graded soak on the *existing* cu129 pin — one via `VLLM_CUTLASS`, one via `MARLIN` — so their
default lane moved from a €4.50/h B200 to this €1.65/h card (€1.24 spot). Both had refused cc 12.0
until 2026-09-20, citing a CUTLASS grouped GEMM that returns invalid output; the gate was banning
the whole family over one suspect kernel, and the upstream fixes
([flashinfer#2708](https://github.com/flashinfer-ai/flashinfer/issues/2708),
[vllm#54189](https://github.com/vllm-project/vllm/issues/54189)) had landed months before anyone
re-read the tickets. Check the ticket before trusting a gate.

**Sparse attention is what keeps the rest on B200.** Every remaining large model here is a
DeepSeek-style sparse MLA architecture, and SM120 has no working kernel for it
([vllm#55757](https://github.com/vllm-project/vllm/issues/55757)). The failure hides: short prompts
answer correctly and realistic lengths break. `glm53-flash-nvfp4` gets around it with a pinned
third-party kernel overlay; the DeepSeek profiles keep their cc 12.0 gate until the upstream fixes
land, each recording its own trigger. Quantisation is the settled part: cu130 fixes the CUTLASS
grouped-GEMM fault behind the old reports of NVFP4 MoE misbehaving on this card. Profiles
declare their limits via `min_compute_capability`, `unsupported_compute_capabilities` and
`untested_compute_capabilities`. Detail:
[docs/gpu-spinner.md](docs/gpu-spinner.md#what-runs-on-which-gpu).

**Size the weights disk before the first pull.** The default 150 GB `/data` does not hold the large
profiles — `qwen38-flash-next` is ~186 GB, `deepseek-v41-flash` ~511 GB, `deepseek-v4-pro-0813`
~893 GB. Each profile states its own figure: set `WEIGHTS_SIZE_GB` and re-run
`bin/spin persistent-init`, and remember the disk bills 24/7 until you remove it.

Where a main lane has no measured row, it should still work and warns when you deploy it: treat the
run as a validation, capture `bin/spin validate` **and `bin/spin soak`**, and add the row. Run
`bin/spin prefetch <profile>` first — a weights pull is billed at whatever compute holds the disk,
and doing it on a CPU box instead of a GPU is about 150× cheaper. If the profile's `max_model_len`
is the recipe's number rather than a measurement, `bin/spin ceiling` finds the real boundary.
Two skills in [`.claude/skills/`](.claude/skills/) walk an agent through both jobs:
`adding-a-model-profile` (offline, free) and `testing-a-model-profile` (live, billed). Nine
profiles are gated behind `requires_review` (pass `--allow-unvalidated` to run anyway): `glm52`,
`glm53` and `deepseek-v4-pro-0813` cost ~€36/h on an 8×B200 node; `glm53-flash`,
`deepseek-v41-flash` and `deepseek-v4-flash-vision` need four B200s and a container image outside
the shared pin; `k2-horizon-375b` and `glm53-flash-nvfp4` are large multi-GPU runs; and `kimi-k3`
fits no plan here.

**Why two profiles serve the same model.** `glm53-flash` (FP8, 4×B200, €18/h) and
`glm53-flash-nvfp4` (4×RTX PRO 6000, €6.60/h) are the same checkpoint, and so are `glm52` and
`glm52-nvfp4` — but they are not interchangeable, so both stay. The NVFP4 builds are cheaper and
are the validated path; the FP8 builds carry a longer context (`glm53-flash` 1048576 against a
*measured* 98304 cap on the NVFP4 sibling; `glm52` 1048576 against 786432), higher-precision
weights, and no dependency on a pinned third-party kernel overlay. Use the NVFP4 lane unless you
need one of those. Note the FP8 context figures are the recipes' numbers and unmeasured —
[vllm#54317](https://github.com/vllm-project/vllm/issues/54317) reports the same crash frame on
4×B200 that capped the NVFP4 build, so ceiling-search before relying on 1M.

All 21 model repos are **ungated** on Hugging Face (re-verified 2026-09-20), so no `HF_TOKEN` is
required — but set one in `.env` anyway: anonymous downloads throttle to ~50 KB/s after a few
hundred GB in a day, which costs far more than the token on a billing GPU. **LoRA** adapter serving and **multi-model swap**
are supported — see below and `docs/gpu-spinner.md`.

## Multi-model serving

Serve several models behind one endpoint with **llama-swap** — one model in VRAM at a time, loaded on
demand, chosen by the OpenAI `model` field:

```bash
bin/spin swap-profiles                                 # list presets
bin/spin up --swap-profile l40s                        # each preset names its own plan (swap_plan)
bin/spin up --swap-profile rtxpro6000                  # ...pass --plan only to override
```

Presets live in `ansible/swap-profiles/` (just a list of model names): `l40s`, `rtxpro6000` and
`b200-nvfp4`. Details:
[docs/gpu-spinner.md](docs/gpu-spinner.md#multi-model-serving-llama-swap).

## Cost

Compute bills only while the GPU server exists (L40S ≈ €1.11/h, up to €36/h for an 8×B200 node);
the persistent disk and floating IP bill 24/7 whether or not a GPU exists (≈ €36/mo at the default
150 GB MaxIOPS disk). Rates per tier, disk sizing, and measured per-session costs:
[docs/gpu-spinner.md](docs/gpu-spinner.md#cost) and [docs/validation.md](docs/validation.md).

## Winding down & safety

`bin/spin down` destroys the GPU — the daily cost saver — and **by default also deletes the weights
disk** (any disk ≥ `DECOMMISSION_THRESHOLD_GB`, default 150) to stop its standing cost; keep the
cache with `--keep-disk` or `DECOMMISSION_ON_DOWN=never`. An on-box timer also powers the server off
at a fixed local time (default 21:00 Europe/Zurich; tune with `--shutdown-at` / `--shutdown-tz` /
`--no-shutdown`). `bin/spin persistent-destroy --yes` is the only path to €0 standing cost, and is
irreversible. Full detail: [docs/gpu-spinner.md](docs/gpu-spinner.md#cost).

## Checking a profile before you pay for it

For every profile, `tests/check-vllm-compat.py` reads vLLM's source at the ref its pinned image
corresponds to and verifies that the checkpoint's architecture is in that build's model registry,
that the parsers it names are registered, and that every flag it passes exists. No GPU needed; it
runs in CI:

```bash
make test                                     # every free gate: lint, renders, compat, plans, terraform
python3 tests/check-vllm-compat.py            # all profiles
python3 tests/check-vllm-compat.py qwen38     # just one
tests/check-plans.sh                          # do the plan ids still exist? (needs UPCLOUD_TOKEN)
```

`tests/check-plans.sh` exists because the identifiers move. On 2026-09-20 all three B200 plan ids
in this repo were dead — UpCloud had doubled the vCPU count in the name — and eleven profiles
pointed at plans that no longer existed. CI was green throughout, because it only compared the
profiles to `tests/plans.txt`, which was stale too. That check asks the provider instead.

A registry hit means the code exists, while the recipe says which version actually serves the
model — often a higher floor than the release that first carried the architecture. Read the recipe,
then pin accordingly.

## Other providers

`terraform/providers/{runpod,lambda,vast,generic-openstack}/` are stubs documenting the provider
"contract". Only UpCloud is implemented.
