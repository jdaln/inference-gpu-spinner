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
bin/spin up --model qwen36-35b --plan GPU-16xCPU-80GB-1xRTXPRO6000  # 96 GB card, all FP8 profiles
bin/spin up --swap-profile b200-nvfp4 --plan GPU-12xCPU-240GB-1xB200   # several models, one endpoint
bin/spin status         # GPU + service status
bin/spin validate       # capture context/KV/VRAM/test-gen evidence
bin/spin soak           # answer-quality + concurrent-load check
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

| Profile | Model | Quant | Validated tier | Also runs on (untested) |
|---|---|---|---|---|
| `qwen36` (default) | Qwen3.6-27B | FP8 | L40S | RTX PRO 6000, H100 |
| `qwen38` | Qwen3.8-27B | FP8 | — (new) | L40S, RTX PRO 6000, H100 |
| `qwen38-nvfp4` | Qwen3.8-27B | NVFP4 | — (new) | RTX PRO 6000, B200 |
| `qwen38-flash-next` | Qwen3.8-Flash-Next (125B-A6B MoE + 51B N-gram) | FP8 | — (new) | 4×H100, 4×B200 |
| `gemma4-26b` | Gemma 4 26B-A4B (MoE) | FP8 | L40S | RTX PRO 6000, H100 |
| `gemma4-31b` | Gemma 4 31B | FP8 | L40S | RTX PRO 6000, H100 |
| `qwen36-35b` | Qwen3.6-35B-A3B (MoE) | FP8 | **H100** | RTX PRO 6000 |
| `qwen36-27b-nvfp4`, `gemma4-31b-nvfp4` | (same models, dense) | NVFP4 | B200 | RTX PRO 6000 |
| `qwen36-35b-nvfp4`, `gemma4-26b-nvfp4` | (same models, MoE) | NVFP4 | B200 | — |
| `glm52-nvfp4` | GLM-5.2 (753B MoE) | NVFP4 | 4×B200 | — |
| `deepseek-v4-flash-vision` | DeepSeek-V4-Flash-Vision-Exp (285B-A13B MoE, **multimodal**) | FP4+FP8 | — (new) | 4×B200 — `requires_review` |
| `glm52` | GLM-5.2 | FP8 | — | 8×B200 — `requires_review` (kept gated: ~36 €/h to test) |

**The RTX PRO 6000 line.** 96 GB, compute capability 12.0. It is Blackwell, but a different family
from the B200's 10.0. Every FP8 profile runs on it with room to spare, and so does **dense** NVFP4.
At €1.65/h it is usually the tier with capacity when H100 and B200 are sold out. No profile has been
measured on it, so those deployments print an untested warning and serve.

**NVFP4 MoE does not run on it.** Those weights use a CUTLASS grouped block-scaled GEMM that returns
invalid output on cc 12.0 with a cu129 build, so the deploy refuses before any weights download.
Profiles declare all of this themselves via `min_compute_capability`,
`unsupported_compute_capabilities` and `untested_compute_capabilities`. Detail:
[docs/gpu-spinner.md](docs/gpu-spinner.md#cost).

**Qwen3.8-27B** is the newest generation here and is not yet measured on any tier. It is a dense hybrid-attention model (48 of 64 layers use linear attention) with a 262K native context, a vision tower, and an in-checkpoint MTP draft head. The NVFP4 build runs on RTX PRO 6000 because it is dense — see the profile comments for the measured KV-pool figures behind that choice.

**Qwen3.8-Flash-Next** is a Qwen4 architecture preview: an ultra-sparse MoE with 6B active parameters, a separate 51B N-gram embedding table, and Qwen Sparse Attention. It needs its own container image and four GPUs, and its weights are ~186 GB — raise `WEIGHTS_SIZE_GB` before the first pull. Upstream verified it on 4×H100 with the N-gram table offloaded to host RAM, which is the plan this profile targets.

**The H100 remains a full option** and is the validated tier for `qwen36-35b`. RTX PRO 6000 is
cheaper today, GPU pricing moves, and the H100 rows have measured numbers behind them.

The "validated tier" column means the profile has a dated live run in
[docs/validation.md](docs/validation.md) — context, KV pool, concurrency and VRAM. Anything in the
untested column should work and warns when you deploy it. Treat that run as a validation run and
record what you measure. Two profiles are gated behind
`requires_review` (pass `--allow-unvalidated` to run anyway): `glm52` FP8 because an 8×B200 node is
too costly to test, and `deepseek-v4-flash-vision` because it is newly added and its only published
multimodal runs are on hardware UpCloud does not offer.

All current model repos are **ungated** on Hugging Face, so no `HF_TOKEN` is required (but setting one
in `.env` avoids the anonymous download throttle). **LoRA** adapter serving and **multi-model swap**
are supported — see below and `docs/gpu-spinner.md`.

## Multi-model serving

Serve several models behind one endpoint with **llama-swap** — one model in VRAM at a time, loaded on
demand, chosen by the OpenAI `model` field:

```bash
bin/spin swap-profiles                                 # list presets
bin/spin up --swap-profile l40s --plan GPU-8xCPU-64GB-1xL40S
bin/spin up --swap-profile rtxpro6000 --plan GPU-16xCPU-80GB-1xRTXPRO6000
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

## Other providers

`terraform/providers/{runpod,lambda,vast,generic-openstack}/` are stubs documenting the provider
"contract". Only UpCloud is implemented.
