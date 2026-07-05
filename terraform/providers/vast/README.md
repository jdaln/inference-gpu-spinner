# Provider stub: Vast.ai (not implemented)

UpCloud (`../upcloud`) is the reference implementation. No code here yet.

## Provider contract

A provider stack under `terraform/providers/<name>/` must, on `tofu apply`,
produce a GPU host satisfying:

1. **SSH-reachable host** with our SSH key — output `ssh_host`.
2. **Stable public IP** across destroy/recreate — outputs `floating_ip` and
   `sslip_host` (`<dashed-ip>.sslip.io`); lets the TLS cert be reused, not re-issued.
3. **Operator-IP firewall allowlist** — 22 + 443 to operator IP; 80 open for ACME;
   vLLM bound to `127.0.0.1`.
4. **Persistent weights volume attached** at `/data` (HF cache + Caddy certs).
5. **Required outputs**: `ssh_host`, `floating_ip`, `sslip_host`, `endpoint`,
   `ssh_command`.

`tofu destroy` removes only compute (+ firewall); persistent volume + IP stay.

## Vast.ai note

Vast.ai is a marketplace of rented containers/instances with little network
control (often no stable public IP or per-host firewall). The stable-IP and
firewall parts of the contract likely need a different approach (e.g. Tailscale
or an SSH tunnel). Vast.ai is also natively supported by SkyPilot/dstack.
