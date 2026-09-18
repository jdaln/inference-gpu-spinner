# Getting started

A walkthrough from a fresh clone to a served model and back down to no GPU bill. Read it once in
order; after that, `bin/spin up` and `bin/spin down` are the whole daily routine.

Architecture and the full cost model are in [gpu-spinner.md](gpu-spinner.md). The measured
per-model matrix is in [validation.md](validation.md).

## What you get

A single cloud GPU server running vLLM behind Caddy, reachable over HTTPS at a stable hostname,
firewalled to your own address and gated by an API key you choose. The API is OpenAI-compatible,
so any client that talks to `/v1/chat/completions` works against it.

The server is created when you want it and destroyed when you are done. A small always-on layer —
a data disk and a public IP — survives between sessions so that spinning up again does not mean
re-downloading weights and re-issuing a TLS certificate.

## Before you start

You need:

- An UpCloud account with GPU plans enabled. GPUs exist only in the `fi-hel2` zone.
- An UpCloud API token, created in the control panel under People → API tokens.
- A machine to drive it from, with `tofu` (OpenTofu 1.7 or newer), `ansible-playbook`, `curl`,
  `jq` and `ssh` on `PATH`. `bin/spin` checks all five at startup and stops with a clear error if
  one is missing. `upctl`, the UpCloud CLI, is optional but makes one setup step much easier.

Understand the two cost buckets before you create anything:

| Bucket | Bills | Driver |
|---|---|---|
| Compute | only while the GPU server exists | GPU plan, per hour |
| Standing | 24 hours a day, GPU or no GPU | persistent disk and floating IP |

The default L40S tier runs at roughly €1.11/hour. The default 150 GB disk plus a floating IP is
roughly €36/month and keeps billing after `bin/spin down`. Getting to zero takes a separate
command, `bin/spin persistent-destroy`, covered in step 7.

## Step 1 — Prepare the control machine

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

Nothing in this step touches the cloud.

## Step 2 — Fill in `.env`

```bash
cp .env.example .env
```

`.env` is gitignored. `bin/spin` sources it on every run, so you do not need to export anything by
hand. If you run `ansible-playbook` directly rather than through `bin/spin`, source it first
(`set -a; . ./.env; set +a`) — Ansible reads the secrets from the control machine's environment.

Required:

| Variable | Purpose |
|---|---|
| `UPCLOUD_TOKEN` | Authenticates every API call and every Terraform apply. |
| `ACME_EMAIL` | Let's Encrypt contact address. Must be a real, deliverable address. |
| `VLLM_API_KEY` | The bearer token your clients send. Generate one: `openssl rand -hex 32`. |

`ACME_EMAIL` is checked before deployment, not after. Let's Encrypt refuses placeholder domains,
and Caddy would then never obtain a certificate while everything else reported success, so the
deploy fails fast on an address ending in `example.com`, `example.org`, `example.net`, `.invalid`,
`.local` or `.test`. Use an address you actually receive mail at.

Worth setting:

| Variable | Purpose |
|---|---|
| `OPERATOR_CIDRS` | Comma-separated ranges allowed through the firewall. Set this if your egress IP rotates — a VPN or carrier NAT — otherwise a changed IP locks you out of your own server. Takes priority over `OPERATOR_IP`. |
| `OPERATOR_IP` | A single allowed address. Left empty, your current address is detected automatically at apply time. |
| `HF_TOKEN` | A Hugging Face token. No current model profile requires one, but anonymous downloads are throttled, which matters when weights run to hundreds of gigabytes. |
| `VLLM_MODEL` | The model profile to deploy when `--model` is not passed. Defaults to `qwen36`. |
| `WEIGHTS_SIZE_GB` | Size of the persistent disk. Set it explicitly — it is the main standing-cost knob, and `persistent-init` compares the value you set against the live disk. |
| `WEIGHTS_TIER` | `maxiops` or `standard`. Standard is cheaper per GB and slower. |
| `DECOMMISSION_ON_DOWN` | `auto` or `never`. See step 7 before leaving it at the default. |
| `AUTO_SHUTDOWN_TZ` | Timezone for the on-box automatic power-off. The default is `Europe/Zurich`; set yours. |

## Step 3 — Fill in the provider variables

```bash
cp terraform/providers/upcloud/terraform.tfvars.example \
   terraform/providers/upcloud/terraform.tfvars
```

Two values are required and have no defaults:

- `os_template` — the UpCloud public template that ships the NVIDIA driver, CUDA and Docker. Find
  its exact title or UUID with `upctl storage list --public --template`. The Terraform plan refuses
  to run while it is unset.
- `ssh_public_keys` — the keys installed for root login on the GPU box. Without one you cannot
  reach the server you just paid for.

Everything else in that file is an optional override, including `plan`, which defaults to
`GPU-8xCPU-64GB-1xL40S`.

`terraform/persistent/terraform.tfvars` is entirely optional — every variable in that stack has a
default, and `WEIGHTS_SIZE_GB` in `.env` covers the one you are likely to change.

## Step 4 — Create the persistent layer

Run this once:

```bash
bin/spin persistent-init
```

This creates the weights disk and the floating IP, and prints the IP. The dashed form of that IP
is your permanent hostname, `<dashed-ip>.sslip.io`. Because the hostname never changes, the TLS
certificate stored on the disk stays valid across sessions.

Both resources are guarded against a stray `tofu destroy`. The standing bill starts here.

## Step 5 — First spin-up

```bash
bin/spin up
```

That deploys the default profile, `qwen36`, on an L40S. To pick something else:

```bash
bin/spin up --model qwen36-35b --plan GPU-12xCPU-240GB-1xH100
bin/spin up --model qwen36 --plan GPU-16xCPU-80GB-1xRTXPRO6000
```

`up` runs through: create the server and firewall, rebind the floating IP, wait for SSH, then
Ansible — verify the GPU, install the automatic power-off timer, verify Docker, render and start
the vLLM and Caddy stack, and wait for vLLM to report healthy.

Expect ten to twenty minutes for a first run on a small model; most of it is the weight download.
The health wait allows 15 minutes by default, and larger profiles raise their own limit. A second
spin-up with the same model and a kept disk is much faster, because the weights and the container
image are already on `/data`.

Two things look like failures but are not:

- **No capacity.** GPU tiers sell out. `up` recognises the refusal and suggests retrying or
  choosing another tier. Nothing was created, and nothing is billing.
- **A long silence during the download.** Progress shows as growth under `/data/hf-cache`, not as
  console output.

## Step 6 — First request

The endpoint is `https://<dashed-ip>.sslip.io/v1`. It only answers from an address on the firewall
allowlist, and only with the bearer token from `.env`.

The name you put in the `model` field is not always the profile name you deployed. In
single-model mode it is the profile's served name — deploying `qwen36` serves
`qwen3.6-27b-fp8`. In multi-model mode it is the profile name itself. `bin/spin up` prints the
correct value at the end of a successful run, and the endpoint will always tell you:

```bash
curl https://<dashed-ip>.sslip.io/v1/models \
  -H "Authorization: Bearer $VLLM_API_KEY"
```

Then:

```bash
curl https://<dashed-ip>.sslip.io/v1/chat/completions \
  -H "Authorization: Bearer $VLLM_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.6-27b-fp8","messages":[{"role":"user","content":"hello"}]}'
```

For a fuller check, `bin/spin validate` reports the served model, context length, KV cache size and
VRAM use, and runs a test generation. `bin/spin soak` grades a short factual battery and fires
parallel requests to confirm the box stays healthy under load.

## Step 7 — Shutting down

Three levels, in increasing order of what they destroy:

| Command | Stops billing for | Keeps | Cost of coming back |
|---|---|---|---|
| `bin/spin stop` | the GPU | server, disks, IP, on-box config | `bin/spin start`, under a minute |
| `bin/spin down` | the GPU | the floating IP, and the disk only with `--keep-disk` | a few minutes warm, or a full re-download |
| `bin/spin persistent-destroy --yes` | everything | nothing | new IP, new certificate, full re-download |

`bin/spin down` is the daily habit. It destroys the server and firewall, so compute billing ends.

**It also deletes the weights disk by default.** The rule is to remove any disk at or above
`DECOMMISSION_THRESHOLD_GB`, which defaults to 150 — the same as the default disk size. So with
stock settings, a teardown frees the standing cost and the next spin-up re-downloads every model.
That suits occasional use. If you spin up daily, keep the cache:

```bash
bin/spin down --keep-disk
```

or set `DECOMMISSION_ON_DOWN=never` in `.env`, which applies to every teardown. Either way the
floating IP is kept, so the hostname and certificate stay valid.

`bin/spin persistent-destroy --yes` is the only path to zero. It deletes the disk and releases the
IP, refuses to run while a GPU server still exists, and refuses without `--yes`. It is
irreversible: you lose the cached weights, the IP and the certificate.

Every deploy also installs a systemd timer that powers the box off at a fixed local time,
defaulting to 21:00 `Europe/Zurich`, so a forgotten server stops billing. It only powers off, and
`bin/spin start` brings it back. Set your own time and zone at deploy time:

```bash
bin/spin up --shutdown-at 23:30 --shutdown-tz Area/City
bin/spin up --no-shutdown
```

The timer fires regardless of what the box is doing, including a deployment in progress. On a
model that takes an hour to load, start early or turn the timer off for that run.

## Choosing a model and a tier

Profiles live in `ansible/models/`, one file per model and quantisation. Pick one with `--model`.
The README carries the full table; the rules behind it are short:

- FP8 profiles run on any tier from the L40S up.
- NVFP4 profiles need Blackwell. They are roughly half the size and faster, and they will not load
  on an L40S or H100 at all.
- Which Blackwell tier matters. The RTX PRO 6000 (96 GB, €1.65/h) is compute capability 12.0; the
  B200 (192 GB, €4.50/h) is 10.0. Dense NVFP4 runs on both. NVFP4 **MoE** runs only on the B200: on
  12.0 its kernels return invalid output, so those profiles refuse to deploy there.
- Every profile declares the VRAM, GPU generation and GPU count it needs. A deploy onto the wrong
  plan fails in preflight, before vLLM starts and before any weights download. It will not run out
  of memory on a GPU you are already paying for.
- A profile marked `requires_review` needs `--allow-unvalidated` and a large multi-GPU plan.

Each profile also names the tier it has been measured on. Running it elsewhere is allowed and
prints a warning. Treat that deployment as a validation run: capture `bin/spin validate` and
`bin/spin soak` and add the row to [validation.md](validation.md).

H100 and B200 both run short of capacity regularly. The RTX PRO 6000 is usually available and covers
every FP8 profile and the two dense NVFP4 ones. It has no measured runs yet, so expect the untested
warning. The H100 remains the validated tier for `qwen36-35b`.

To serve several models from one endpoint, use a swap preset. One model sits in VRAM at a time and
the rest load on demand, so size the box for the largest member of the set, not their sum:

```bash
bin/spin swap-profiles
bin/spin up --swap-profile l40s --plan GPU-8xCPU-64GB-1xL40S
bin/spin up --swap-profile rtxpro6000 --plan GPU-16xCPU-80GB-1xRTXPRO6000
```

Presets are just lists of profile names in `ansible/swap-profiles/`; add one by dropping in a file.
In this mode clients select a model by its profile name.

## Day to day

```bash
bin/spin status          # tofu outputs, GPU utilisation, service state
bin/spin logs            # follow vLLM and Caddy, or llama-swap in multi-model mode
bin/spin ssh             # root shell on the box
bin/spin plan            # tofu plan for the ephemeral stack, changes nothing
bin/spin validate        # served model, context, KV cache, VRAM, test generation
bin/spin soak            # answer-quality battery plus a concurrent-load round
bin/spin help            # every command and flag
```

`make` wraps the common ones — `make up`, `make down`, `make status`, `make logs`, `make ssh`,
`make plan` — and passes extra arguments through `ARGS`:

```bash
make up ARGS="--model qwen36-35b --plan GPU-12xCPU-240GB-1xH100"
```

`make lint` runs `ansible-lint`. `make fmt` rewrites Terraform formatting in place.

`bin/spin validate` reads the single-model container by name, so its KV-cache and VRAM section
stays empty in multi-model mode. The rest of it, and all of `soak`, work either way.

## When something fails

| Symptom | Cause | Fix |
|---|---|---|
| `required tool 'X' not found in PATH` | Missing dependency on the control machine. | Install it, or point `TOFU` at a non-standard OpenTofu binary. |
| `UPCLOUD_TOKEN not set` | `.env` missing or not filled in. | Complete step 2. Run `bin/spin` from the repository root. |
| Deploy fails on `ACME_EMAIL must be a REAL deliverable address` | A placeholder contact address. | Use an address you receive mail at. |
| `UpCloud has no '<plan>' capacity in fi-hel2 right now` | The tier is sold out. | Retry shortly or pass a different `--plan`. Nothing was created. |
| `timed out waiting for SSH` | Your egress address changed and the firewall no longer allows you, or the server did not boot. | Set `OPERATOR_CIDRS` to a range that covers your egress and re-run `bin/spin up`. |
| A deploy fails at `Wait for vLLM to report healthy`, but the box looks fine | A large model outlasted the health wait. | Poll `https://<dashed-ip>.sslip.io/v1/models` before tearing anything down — the model usually finishes loading. |
| `404` from a chat completion | Wrong name in the `model` field. | Query `/v1/models` and use exactly what it returns. |
| `needs ~N GB of VRAM but this GPU reports M GB` | Profile too large for the plan. | Use the plan named in the message, or a larger one. |
| `No space left on device` during a download | `/data` is full. It is a fixed-size LRU cache. | Raise `WEIGHTS_SIZE_GB` and re-run `bin/spin persistent-init`, or trim a swap preset. |
| `Unknown model profile 'X'` | Typo, or a profile that does not exist. | List `ansible/models/`. |

If a server ends up in a state Terraform cannot reconcile, `bin/spin status` and the UpCloud
control panel are the fastest way to see what actually exists. Recovery procedures for orphaned
resources and lost state are in [validation.md](validation.md).

## Where things live

`bin/spin` is the entry point for everything; read `bin/spin help` before reaching for Terraform or
Ansible directly. `terraform/persistent/` holds the disk and floating IP that outlive a session, and
`terraform/providers/upcloud/` holds the server and firewall that do not — the other directories
under `terraform/providers/` are notes on what a new provider would have to supply, not working
code. `ansible/` configures the box: `models/` defines what can be served, `swap-profiles/` groups
models into multi-model presets, and `roles/` does the work. `tests/` renders templates to catch
broken profiles without spending money on a GPU.

## Next

- [gpu-spinner.md](gpu-spinner.md) — architecture, the security model, and the full cost breakdown.
- [validation.md](validation.md) — measured context, concurrency, VRAM, timings and session cost
  per model, plus operational notes.
