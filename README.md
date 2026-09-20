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

**Main lane** is the plan `bin/spin up --model <name>` deploys when you don't pass `--plan`; it
comes from the profile's `min_plan`. **Measured on** is where a dated live run exists in
[docs/validation.md](docs/validation.md). They differ wherever the cheapest plan that runs a model
is not the one someone has measured.

| Profile | Model | Quant | Main lane (default plan) | Measured on |
|---|---|---|---|---|
| `qwen36` (default) | Qwen3.6-27B | FP8 | L40S | L40S |
| `qwen38` | Qwen3.8-27B | FP8 | L40S | — (new) |
| `qwen38-nvfp4` | Qwen3.8-27B | NVFP4 | RTX PRO 6000 | — (new) |
| `qwen38-flash-next` | Qwen3.8-Flash-Next (125B-A6B MoE + 51B N-gram) | FP8 | **4×RTX PRO 6000** | — (new; upstream verified 4×H100) |
| `glm53-flash-nvfp4` | GLM-5.3-Flash (321B-A18B MoE, **multimodal**) | NVFP4 | **4×RTX PRO 6000** | — (new; needs a plugin overlay) |
| `gemma4-26b` | Gemma 4 26B-A4B (MoE) | FP8 | L40S | L40S |
| `gemma4-31b` | Gemma 4 31B | FP8 | L40S | L40S |
| `qwen36-35b` | Qwen3.6-35B-A3B (MoE) | FP8 | H100 | **H100** |
| `qwen36-27b-nvfp4`, `gemma4-31b-nvfp4` | (same models, dense) | NVFP4 | B200 | B200 |
| `qwen36-35b-nvfp4`, `gemma4-26b-nvfp4` | (same models, MoE) | NVFP4 | B200 | B200 |
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
have **no NVLink**, so tensor parallelism runs over PCIe. Nothing has been measured on any of it
yet, so these deployments print an untested warning and serve — record what you measure.

**What keeps the rest on B200 is sparse attention, not quantisation.** Every remaining large model
here is a DeepSeek-style sparse MLA (DSA) architecture, and that has no working SM120 path:
[vllm#55757](https://github.com/vllm-project/vllm/issues/55757) reports GLM-5.3, GLM-5.2 and
DeepSeek-V4 unservable on 8× RTX PRO 6000, and it fails *late* — a short-prompt smoke test passes
and only realistic prompt lengths break. `glm53-flash-nvfp4` gets around it by carrying a pinned,
third-party kernel overlay; the DeepSeek profiles keep their cc 12.0 gate until the upstream fixes
land, with the exact trigger recorded in each profile.

The older claim that NVFP4 MoE is broken on this card is **out of date**: that CUTLASS grouped-GEMM
fault is reported fixed on cu130 builds, and much of the symptom was a separate silent fault
([vllm#54189](https://github.com/vllm-project/vllm/issues/54189)) that zeroed every expert output.
Profiles declare their own limits via `min_compute_capability`,
`unsupported_compute_capabilities` and `untested_compute_capabilities`. Detail:
[docs/gpu-spinner.md](docs/gpu-spinner.md#cost).

**Qwen3.8-27B** is the newest generation here and is not yet measured on any tier. It is a dense
hybrid-attention model (48 of 64 layers use linear attention) with a 262K native context, a vision
tower, and an in-checkpoint MTP draft head. The NVFP4 build runs on RTX PRO 6000 because it is dense
— see the profile comments for the measured KV-pool figures behind that choice.

**Qwen3.8-Flash-Next** is a Qwen4 architecture preview: an ultra-sparse MoE with 6B active
parameters, a separate 51B N-gram embedding table, and Qwen Sparse Attention. It needs its own
container image and four GPUs, and its weights are ~186 GB — raise `WEIGHTS_SIZE_GB` before the
first pull. Upstream verified it on 4×H100 with the N-gram table offloaded to host RAM, which is the
plan this profile targets.

**The two DeepSeek flagships are the heaviest profiles here.** `deepseek-v41-flash` needs four B200s
(~511 GB of weights, of which 183 GiB is its Engram n-gram memory) and a dated vLLM nightly, because
no release serves the architecture yet. `deepseek-v4-pro-0813` needs eight (~893 GB of weights) at
roughly €36/h. Both need a much larger `WEIGHTS_SIZE_GB` than the default 150 GB — 600 and 1000
respectively — and that disk bills 24/7 until you remove it. Read the profile comments before either
first run.

**Kimi K3 does not fit any UpCloud plan.** Its floor is 8× GB300 (2304 GB) and its weights alone are
~1561 GB, against ~1538 GB on the largest plan here (8× B200). Its image is also a CUDA 13 build
needing an r580+ driver. The profile exists so the requirement is recorded and so it works the day a
large enough tier appears; until then every preflight refuses it.

**The H100 remains a full option** and is where `qwen36-35b` was measured. RTX PRO 6000 is cheaper
today, GPU pricing moves, and the H100 rows have measured numbers behind them.

The "Measured on" column means the profile has a dated live run in
[docs/validation.md](docs/validation.md) — context, KV pool, concurrency and VRAM. Where the main
lane differs, that lane should work and warns when you deploy it: treat the deployment as a
validation run, then capture `bin/spin validate` **and `bin/spin soak`** and add the row. Nine
profiles are gated behind `requires_review` (pass `--allow-unvalidated` to run anyway): `glm52`,
`glm53` and `deepseek-v4-pro-0813` because an 8×B200 node costs ~€36/h to test; `glm53-flash`,
`deepseek-v41-flash` and `deepseek-v4-flash-vision` because they need four B200s and a container
image outside the shared pin; `k2-horizon-375b` and `glm53-flash-nvfp4` because they are large
multi-GPU runs with no measurement behind them; and `kimi-k3` because no plan here fits it.

All current model repos are **ungated** on Hugging Face, so no `HF_TOKEN` is required (but setting one
in `.env` avoids the anonymous download throttle). **LoRA** adapter serving and **multi-model swap**
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

`tests/check-vllm-compat.py` reads vLLM's source at the ref each pinned image corresponds to and
verifies, for every profile, that the checkpoint's architecture is in that build's model registry,
that the reasoning and tool-call parsers it names are registered, and that every flag it passes
exists. It needs no GPU and runs in CI:

```bash
python3 tests/check-vllm-compat.py            # all profiles
python3 tests/check-vllm-compat.py qwen38     # just one
```

Presence in the model registry does not imply support. A recipe often states a higher version
floor than the release that first carried the architecture. Read the recipe, then pin
accordingly.

## Other providers

`terraform/providers/{runpod,lambda,vast,generic-openstack}/` are stubs documenting the provider
"contract". Only UpCloud is implemented.
