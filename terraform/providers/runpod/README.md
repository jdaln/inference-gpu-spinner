# Provider stub: RunPod (not implemented)

UpCloud (`../upcloud`) is the reference implementation. This directory is a
placeholder so the multi-provider layout exists; there is no code here yet.

## Provider contract

A provider stack under `terraform/providers/<name>/` must, on `tofu apply`,
produce a GPU host satisfying the contract the rest of the system depends on:

1. **SSH-reachable host** with our SSH key installed — output `ssh_host`.
2. **Stable public IP** that survives the daily destroy/recreate — outputs
   `floating_ip` and `sslip_host` (`<dashed-ip>.sslip.io`). Stability lets the
   Caddy/Let's-Encrypt cert be *reused* instead of re-issued each spin-up.
3. **Operator-IP firewall allowlist** — 22 + 443 restricted to the operator's
   IP; 80 open to `0.0.0.0/0` (ACME HTTP-01); vLLM never exposed directly.
4. **Persistent weights volume attached** — durable disk for the HF cache +
   Caddy cert store (Ansible mounts it at `/data`), surviving teardown.
5. **Required outputs** (consumed by `bin/spin` + Ansible): `ssh_host`,
   `floating_ip`, `sslip_host`, `endpoint`, `ssh_command`.

`tofu destroy` must remove only the compute (+ firewall), leaving the persistent
volume and IP intact.

## RunPod note

RunPod is natively supported by SkyPilot and dstack. If we ever target it,
weigh reusing one of those for RunPod specifically, while keeping this repo's
output contract so `bin/spin`/Ansible stay unchanged.
