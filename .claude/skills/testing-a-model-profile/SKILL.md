---
name: testing-a-model-profile
description: "Live-test a model profile in inference-gpu-spinner on real, billed UpCloud GPUs: pre-spend gates, prefetching weights on a cheap box, bin/spin up, reading the vLLM engine log, validate, soak, finding the max_model_len token ceiling, debugging a wrong or broken deploy, and recording the docs/validation.md row. Use BEFORE any command that provisions, starts or resizes a server — \"test this model\", \"validate the profile\", \"soak it\", \"what context can it take?\", \"why is it answering garbage?\", \"is it ready to ship?\". Every step here spends money."
---

# Testing a model profile

Everything in this skill costs money by the hour. The GPU plans run from €1.11/h to €36/h, and
sessions are usually wasted on something dull: downloading weights on a GPU, giving up 15 minutes
into a 90-minute pull, or recording a number nobody measured.

## Rules

1. **`bin/spin status` is step zero**, before anything else. This repo has sat with a €6.60/h
   server record in tofu state and nobody knew. Check before you plan, and again before you stop.
2. **State the euros before every spend**, keep a running total, and print it at each batch
   boundary. Stop and ask when you reach the ceiling the user gave you.
3. **Every number you record must come from output you actually saw.** Paste the command and its
   output into the run log. Never carry a figure over from another tier, another model, or a
   profile comment.
4. **Never download weights on a GPU.** Use `bin/spin prefetch` (below). This is ~150x cheaper.
5. **Do not leave the session without saying what is still running**, and what it costs per hour.

## Pre-spend checklist

```bash
bin/spin status                 # is anything already billing?
make test                       # every free gate; must be green
bash --version                  # soak's tally needs bash 4+; never hardcode an interpreter path
grep -n 'min_disk_gb\|health_wait_retries\|validated' ansible/models/<m>.yml
grep -E '^GPU-' tests/plans.txt # the price you are about to pay
```

Then size the disk. `min_disk_gb` is now enforced by a preflight, but the preflight runs *on the
box you already paid for* — get it right first:
```bash
# WEIGHTS_SIZE_GB in .env, then:
bin/spin persistent-init        # grows the disk. UpCloud CANNOT shrink one afterwards.
```

Two flags that prevent expensive accidents:
- `--shutdown-at HH:MM` past your session end. The 21:00 Europe/Zurich timer has already killed a
  4×B200 mid-engine-load.
- `bin/spin down --keep-disk` between runs in a campaign. A plain `down` **deletes** any disk
  ≥150 GB and the next run re-pulls everything.

## 1. Prefetch (cheap box), then spin up (expensive box)

```bash
bin/spin prefetch <profile> [<profile>...]   # ~€0.045/h CPU box; pulls weights AND images, then self-destructs
bin/spin up --model <profile> --plan <plan> --shutdown-at 23:30
```

An UpCloud disk attaches to one server at a time, so prefetch and GPU sessions are strictly
sequential; `bin/spin prefetch` refuses while a GPU server exists.

Use the **spot** plan id for validation runs — it is a plan id, not a flag, and it is 25% off:
`GPU-SPOT-16xCPU-80GB-1xRTXPRO6000` (€1.24/h), `GPU-SPOT-64xCPU-320GB-4xRTXPRO6000` (€4.95/h). A
spot box can be reclaimed; with weights already on `/data` that costs minutes, not a re-download.

**Chaining models on one live box** saves the provision+teardown cycle (~€0.15 on L40S, ~€2.50 on
4×B200):
```bash
bin/spin up --model <next> --plan "$(tofu -chdir=terraform/providers/upcloud show -json \
  | jq -r '.values.root_module.resources[]|select(.type=="upcloud_server").values.plan')"
```
You must pass `--plan` with **exactly the value already in state**: without it the mismatch guard
dies, and with a *different* value `tofu apply -auto-approve` resizes the live server. Chains can
only stay inside one `min_plan` lane — the compute-capability gates forbid the rest. And if the box
is *stopped*, `bin/spin start` first: the resume path refuses `--model`.

## 2. Read the engine log before believing anything

```bash
bin/spin ssh 'docker logs gpu-spinner-vllm-1 2>&1 | grep -iE "attention backend|MoE backend|Capturing|graph|GPU KV cache size|Maximum concurrency"'
```

Check, in order: the attention backend is the one the profile expects · the MoE backend line names
what actually ran (it is often not what the flags suggest) · CUDA graphs captured unless the
profile sets `--enforce-eager` · the KV pool and max concurrency, which are two of the columns in
`docs/validation.md`.

## 3. validate, then soak

```bash
bin/spin validate
bin/spin soak --rounds 3 --concurrency 20 --context 32768
```

`validate` proves it serves and returns coherent text. **It grades nothing.** A short prompt
answering correctly proves very little: vllm#55757 is specifically a path that passes short
prompts and fails at realistic lengths.

`soak` is the real check — a factual battery, fabrication traps, then graded needle-in-haystack
under parallel load at three depths. What its output means:

- **a wrong needle fails the command**; rejections and timeouts do not (those are admission
  control, not correctness).
- `--concurrency` below 3 exercises only the head depth. Never go below 3.
- the ~8-request factual battery runs on **every** invocation. On a €36/h box ten probes is ~€70 of
  battery alone — budget it.
- p50/p95 latency is **not a throughput number**: all requests at one context share a single
  haystack, so tail-depth requests share most of their prefill.
- **the context clamp is a false pass.** Ask for more than `max_model_len - 2048` and soak silently
  reduces it and warns. A green run at "131072" may have been ~96k. Record
  `usage.prompt_tokens`, never the number you asked for.

In **swap mode**, `bin/spin validate` reports idle VRAM and a null `max_model_len` with no error —
do not paste it. Pre-warm each entry with a throwaway curl, pass `--model <entry>` to soak
explicitly, and take real numbers from `docker logs vllm-swap-<entry>` inside the idle TTL (the
container is `--rm`; the logs vanish after it).

## 4. The token ceiling

Three different ceilings. Only one needs a search:

| Kind | How you find it | Cost |
|---|---|---|
| **Capacity** — the KV pool cannot hold one full-length request | read "GPU KV cache size" from `validate`, divide by the context. vLLM refuses at startup rather than crashing | free |
| **Crash** — the engine dies above some length, KV barely touched | `bin/spin ceiling` | one engine reload per failure |
| **Mode floor** — the checkpoint needs a minimum context for a documented mode | read the recipe | free |

Check capacity **first**: deploying at native when native does not fit burns a reload and teaches
you nothing.

```bash
# No request can exceed the deployed max_model_len, so redeploy high before searching:
bin/spin up --model <m> --plan <plan in state> -e max_model_len=<native>
bin/spin ceiling --start 32768
```

`ceiling` ascends (a pass costs a minute; a crash costs a full reload, so bisecting is the
expensive way) and judges every probe on the container's **restart counter** — `restart:
unless-stopped` brings a crashed engine back, and a fast reload finishes inside soak's own tally,
so soak files the crash as a "rejected" request and still prints `Soak OK`.

Then set `max_model_len` below the last passing `prompt_tokens`, record the whole pass/fail matrix
and the fault from the engine log in the profile comment, and re-soak at the cap:
```bash
bin/spin soak --context <cap> --concurrency 10
```

After an `-e max_model_len=N` redeploy the file and the running config disagree. **State the
deployed value in every row you record**, and redeploy cleanly from the profile before teardown.

## 5. Failure signatures

| Symptom | Cause | Action |
|---|---|---|
| One token repeated forever | NVFP4 MoE activation scale read 0.0 — every expert output multiplied by zero (vllm#54189, **closed 2026-08-30**) | Check the image carries the fix, or that the profile's `extra_env` scale took effect |
| Garbage on cc 12.0, NVFP4 MoE | CUTLASS grouped block-scaled GEMM (flashinfer#2708, **closed 2026-04-20**) | Needs a cu130 image. No cu130 *release* tag exists — only model-specific builds |
| Short prompts fine, long prompts wrong | Sparse MLA on sm_120 (vllm#55757, open) | This is exactly what soak's graded needles catch. Do not clear it with a smoke test |
| `CUDA error: an illegal memory access` in `chunk_kda_with_fused_gate` | KDA linear attention above ~100k tokens (vllm#54317, open) | Cap `max_model_len` below the boundary you measure |
| Xid 13 warp errors after hours of load | Marlin MoE on RTX PRO 6000 (vllm#52225, open) | Only a long run surfaces it. Record the duration you actually exercised |
| 100% GPU, no output, NCCL watchdog kills it | flashinfer autotune | `--no-enable-flashinfer-autotune` |
| Engine never becomes healthy | `health_wait_retries` too short for the download | Recompute: `(GB / 7.56 + init_min) x 1.5 x 6` |
| OOM at load | wrong plan, or `gpu_memory_utilization` | CUDA graph capture allocates *outside* the budget; 0.95 fails |
| Hangs in NCCL at init | no NVLink on multi-GPU RTX PRO 6000 | `NCCL_P2P_DISABLE: 1` in `extra_env`, at a throughput cost |
| `No space left on device` mid-pull | `min_disk_gb` > free space | The preflight catches it now; if it fired, grow the disk or delete a cached model |

**Before you trust a profile comment, check the ticket.** Several claims in this repo were stale by
months. `curl -s https://api.github.com/repos/vllm-project/vllm/issues/N | jq '{state,updated_at}'`.
When a fresh measurement disagrees with a recorded one, **suspect the record**, name both numbers,
and do not silently overwrite.

## 6. Record it

Add the `docs/validation.md` row: profile, model, quant, tier measured, `max_model_len`, KV pool,
concurrency at max, VRAM used/total, date, and the evidence. Then update the profile: flip
`validated:`, and write the evidence comment in the `glm53-flash-nvfp4.yml` house style — measured
figures with dates, the flags that are not preferences, upstream issue numbers, and a "ruled out,
so nobody re-chases them" list.

If it did **not** pass, that is a result too. Record what broke, at what length, with the fault
from the log — and leave `validated: false`.

## 7. Wind down

```bash
bin/spin down --keep-disk    # more runs coming within ~2 days
bin/spin down                # done: also deletes a disk >=150 GB; keeps IP, hostname, TLS cert
bin/spin persistent-destroy --yes   # €0 standing, but LOSES the IP, hostname and cert. Rarely right.
```

Then verify by hand — no `bin/spin` command reports standing resources:
```bash
set -a; . ./.env; set +a
curl -fsS -H "Authorization: Bearer $UPCLOUD_TOKEN" https://api.upcloud.com/1.3/server  | jq '.servers.server[]|{hostname,plan,state}'
curl -fsS -H "Authorization: Bearer $UPCLOUD_TOKEN" https://api.upcloud.com/1.3/storage | jq '.storages.storage[]|select(.type=="normal")|{title,size,tier}'
```
Watch for a disk left in the 110–149 GB band (kept forever by design) and an orphaned 100 GB
`terraform-gpu-spinner-disk` boot disk. **Never delete `gpu-spinner-weights` by hand.**

A **stopped** server still bills its disks. Stopped is not wound down.
