# inference-gpu-spinner — architecture & operations

On-demand GPU inference, built to be **cheap to start and cheap to stop**. The GPU bills by the
hour, so creating and destroying it is the daily routine; only a small, cheap layer survives between
sessions. This doc covers the architecture, the security model, multi-model serving, and cost.
The live-validated model matrix is the separate system of record: [validation.md](validation.md).

## Architecture: two stacks + Ansible

```
PERSISTENT (terraform/persistent) — created once, prevent_destroy, billed 24/7 (see Cost)
  • storage.weights        → HF model cache + Caddy TLS store (mounted at /data)
  • floating_ip            → stable public IPv4 ⇒ stable <dashed-ip>.sslip.io host

EPHEMERAL (terraform/providers/<provider>) — created + destroyed every session
  • server (GPU, default 1xL40S, NVIDIA+CUDA image)
  • firewall (22←operator / 80←world for ACME / 443←operator / drop)
  • floating-IP rebind (API PATCH to the new NIC MAC) + cloud-init /32 on the guest

ANSIBLE (push over SSH)
  gpu(verify) → autostop → docker(verify) → vllm (vLLM + Caddy via docker compose, systemd)
                                          └→ llama_swap (multi-model, when enabled)
```

**Two stacks, because the split maps to the billing boundary.** The GPU server is disposable
(destroyed each evening). The disk (cached weights + TLS cert) and the public IP must persist, so
they live in their own stack guarded by `prevent_destroy`. Winding down uses `tofu destroy` on the
ephemeral stack only — it also frees the boot disk and keeps state clean.

## Why a floating IP

A stable public IP keeps the `<dashed-ip>.sslip.io` hostname constant across daily destroy/recreate,
so Caddy reuses the Let's Encrypt cert stored on the persistent disk instead of re-issuing it every
morning (sslip.io shares one LE rate-limit bucket — re-issuing daily would hit it).

The IP binds to each new server in **two** places, neither sufficient alone:
1. **API** — a `PATCH /ip_address/{ip}` sets the new server's NIC MAC.
2. **Guest** — cloud-init adds the IP as a `/32` on the primary interface (netplan).

The floating-IP resource lives **only** in the persistent stack — deleting it *releases* the IP —
so the ephemeral stack must never own it (`release_policy = keep`, `ignore_changes = [mac_address]`).

## Security model

- **Firewall**: SSH (22) and HTTPS (443) accept only the operator's source(s) — one IP
  (`OPERATOR_IP`, auto-detected if unset) or, for a rotating egress, CIDRs (`OPERATOR_CIDRS`; bare
  IP = /32). HTTP (80) is world-open **only** for the Let's Encrypt HTTP-01 challenge (its validators
  come from many un-allowlistable IPs). A catch-all `drop` is last.
- **vLLM** binds `127.0.0.1` and is never exposed directly; Caddy fronts it on 443.
- **Auth**: clients must send `Authorization: Bearer $VLLM_API_KEY`.
- **TLS**: Caddy forces HTTP-01 (`disable_tlsalpn_challenge`) because 443 is firewalled. `ACME_EMAIL`
  must be a real, deliverable address — Let's Encrypt rejects placeholder domains (the deploy
  preflights this).

These boxes are short-lived and IP-restricted, so there is deliberately no heavyweight OS-hardening
or on-box monitoring layer.

## Multi-model serving (llama-swap)

By default one model is served per box. To serve **several models behind the one endpoint**, enable
llama-swap: it starts and stops a vLLM backend per model on demand, keeping **one model in VRAM at a
time**. Clients pick a model with the OpenAI `model` field; an idle backend unloads after
`swap_idle_ttl` (default 30 min).

```bash
bin/spin swap-profiles                                   # list presets
bin/spin up --swap-profile l40s      --plan GPU-8xCPU-64GB-1xL40S       # qwen36 + gemma4-26b/31b
bin/spin up --swap-profile b200-nvfp4 --plan GPU-12xCPU-240GB-1xB200    # the four NVFP4 models
```

- **Presets** live in `ansible/swap-profiles/<name>.yml` — just a list of model-profile names
  (`swap_profiles:`). Each model's repo, context, and vLLM args come from its `ansible/models/`
  profile, so a model is defined once. Add a preset by dropping in a new file.
- **On-demand swap**: the first request for a model loads it (cold: add its weight-download time;
  warm: seconds). Requests to a different model swap the backend — one in VRAM at a time. Size the
  box for the **largest** model in the set, not the sum.
- **Disk**: every model in a preset downloads to the shared `/data` HF cache. `/data` is an LRU
  cache — a preset whose weights exceed the disk will fail a cold pull with "No space left". Grow
  `weights_size_gb` (see Cost) or trim the preset.
- **Networking note**: swap backends run with `--network host`. On some providers (UpCloud) a
  container on the default Docker bridge cannot reach any DNS resolver, so the model-config fetch
  fails; host networking (the same mode Caddy uses) avoids it. Compose services are unaffected.

`bin/spin status` and `bin/spin logs` auto-detect whichever mode is running. Validated live on an
H100 (cached + uncached swap-in, hot handoff) — see [validation.md](validation.md).

## Cost

Two cost buckets, and the whole design is about keeping the first near-zero when you're not working:

| Bucket | When it bills | Driver |
|---|---|---|
| **Compute** | only while the GPU server exists | GPU plan, €/hour |
| **Standing** | 24/7, even when the GPU is gone | persistent disk (€/GB·month) + floating IP (€/month) |

`bin/spin down` destroys the GPU server → **compute drops to €0**. The standing bucket keeps billing
until you fully decommission (below). This is provider-agnostic; the numbers below are UpCloud
`fi-hel2` list prices (2026-07, 1 credit = €0.01) — add a column per provider as others are wired up.

**Compute — GPU plans (€/hour):**

| Tier | Plan | €/h | Spot €/h | Fits |
|---|---|---|---|---|
| L40S 48 GB | `GPU-8xCPU-64GB-1xL40S` | 1.11 | 0.83 | FP8 ≤ ~31B (default, validated) |
| RTX PRO 6000 96 GB | `GPU-16xCPU-80GB-1xRTXPRO6000` | 1.65 | 0.87 | every FP8 profile, dense NVFP4 — untested |
| H100 80 GB | `GPU-12xCPU-240GB-1xH100` | 1.79 | 1.78 | FP8 MoE (qwen36-35b, validated) |
| B200 192 GB | `GPU-12xCPU-240GB-1xB200` | 4.50 | 3.38 | all NVFP4, single-GPU |
| 2×RTX PRO 6000 | `GPU-32xCPU-160GB-2xRTXPRO6000` | 3.30 | 1.74 | — |
| 4×RTX PRO 6000 | `GPU-64xCPU-320GB-4xRTXPRO6000` | 6.60 | 3.48 | — |
| 8×RTX PRO 6000 | `GPU-128xCPU-640GB-8xRTXPRO6000` | 13.20 | 6.96 | — |
| 4×B200 | `GPU-48xCPU-960GB-4xB200` | 18.00 | 13.50 | GLM-5.2 NVFP4 (TP=4), DeepSeek vision |
| 8×B200 | `GPU-96xCPU-1920GB-8xB200` | 36.00 | 27.00 | GLM-5.2 FP8 (TP=8) |

Plan identifiers come from UpCloud's [GPU Server configurations](https://upcloud.com/docs/products/gpu-servers/configurations/);
the number before `xCPU` is **cores**, not threads. L4 (24 GB, €0.58/h) and B300 (€6.67/h) are also
offered — the L4 fits none of the current profiles, and no profile targets B300 yet.

**Where RTX PRO 6000 fits.** 96 GB of GDDR7 at 1.6 TB/s, PCIe, **no NVLink**, compute capability
12.0. It is Blackwell, but a different family from the B200's 10.0, which changes what runs:

- Every **FP8** profile runs on it, with far more headroom than the 48 GB L40S — including
  `qwen36-35b`, whose validated tier remains the H100.
- **Dense NVFP4** (`qwen36-27b-nvfp4`, `gemma4-31b-nvfp4`) runs on it: those use the NVFP4
  scaled-mm path, which has SM120 kernels. Their validated tier remains the B200.
- Nothing has been **measured** on it yet. Profiles that permit it list cc 12.0 in
  `untested_compute_capabilities`, so the deploy prints a warning and serves; the numbers in
  [validation.md](validation.md) are from other hardware until someone records a run.
- **NVFP4 MoE** does not. Those weights go through a CUTLASS grouped block-scaled GEMM that returns
  invalid output on compute capability 12.0 unless FlashInfer is patched and built against CUDA 13.0;
  the pinned images are cu129, and [vllm-project/vllm#35566](https://github.com/vllm-project/vllm/issues/35566)
  is still open. Those profiles declare `unsupported_compute_capabilities: [12.0]` and stay on B200.
- Multi-GPU RTX PRO 6000 plans exist but no profile targets them: without NVLink, tensor parallelism
  runs over PCIe, and the checkpoints large enough to need it are all NVFP4 MoE.

Measured cold/warm timings and per-session costs
are in [validation.md](validation.md) (“Timings & session cost”) — read those before an expensive tier.

**Standing — disk + IP (billed 24/7 whether or not a GPU exists):**

| Item | Rate | Example |
|---|---|---|
| Persistent disk, MaxIOPS | €0.220 / GB·month | 150 GB ≈ **€33/mo**, 500 GB ≈ **€110/mo** |
| Persistent disk, standard | €0.085 / GB·month | 500 GB ≈ **€43/mo** |
| Floating IP (IPv4) | €3.47 / month | — |
| Public egress | €0.00 / GB | zero-cost egress, fair-use policy applies |

So the "off" state is **not free**: the default 150 GB MaxIOPS disk + IP is **~€36/mo** (a 500 GB
disk would be ~€114/mo). Size the disk to what you actually cache — set **`WEIGHTS_SIZE_GB`** and
**`WEIGHTS_TIER`** in `.env` (used by `bin/spin persistent-init`; e.g. bump to `500` for GLM-5.2, or
`WEIGHTS_TIER=standard` for cheaper/slower). An existing disk grows to the new size on the next
`persistent-init` (UpCloud can't shrink one — `bin/spin persistent-destroy` then re-init to go smaller).

**Big-model tradeoff (e.g. GLM-5.2 NVFP4, ~377 GB weights):** keeping it on a 500 GB MaxIOPS disk
costs ~€110/mo standing, but each spin-up is warm (~18–20 min to serving). Deleting the disk between
uses drops standing cost to just the IP (~€3.47/mo) but every spin-up re-downloads ~447 GB (~1 h,
plus egress). Keep-warm pays off above roughly one spin per few days; otherwise delete and re-pull.

**Winding down:**
- **Daily:** `bin/spin down` — destroys the GPU server + firewall (compute → €0). By **default** it
  then auto-decommissions the weights disk if it's ≥ `DECOMMISSION_THRESHOLD_GB` (default 150 GB), to
  stop the standing cost — it prints a visible warning and **keeps the floating IP** (stable hostname;
  the next `bin/spin up` recreates the disk, re-downloads weights, and re-issues the cert, ~1 min).
  Keep the disk warm for fast restarts with `bin/spin down --keep-disk` or `DECOMMISSION_ON_DOWN=never`
  (or raise the threshold). Small disks (< threshold) are always kept.
- **Auto-shutdown safety (default ON):** an on-box systemd timer powers the box OFF at a fixed local
  time (default 21:00 Europe/Zurich) so a forgotten server stops billing compute. It only powers
  off (never destroys), and only saves money where the provider doesn't bill stopped servers
  (verified: UpCloud). Tune with `bin/spin up --shutdown-at HH:MM --shutdown-tz Area/City` /
  `--no-shutdown`. An opt-in idle watchdog (`-e autostop_idle_enabled=true`) powers off after
  sustained GPU inactivity.
- **Full decommission (→ €0):** `bin/spin persistent-destroy --yes` deletes the disk + releases the
  IP (it prints what it will remove and refuses without `--yes`). Irreversible: the cached weights and
  the stable IP/cert are lost, so the next spin-up re-downloads everything and gets a new IP + cert.
  `prevent_destroy` still guards `terraform/persistent/main.tf` against a stray `tofu destroy`, so
  the command (which deletes via the API, then drops the resources from state) is the supported path.
