# Provider stub: Lambda Cloud (not implemented)

UpCloud (`../upcloud`) is the reference implementation. No code here yet.

## Provider contract

A provider stack under `terraform/providers/<name>/` must, on `tofu apply`,
produce a GPU host satisfying:

1. **SSH-reachable host** with our SSH key — output `ssh_host`.
2. **Stable public IP** across destroy/recreate — outputs `floating_ip` and
   `sslip_host` (`<dashed-ip>.sslip.io`), so the TLS cert is reused, not re-issued.
3. **Operator-IP firewall allowlist** — 22 + 443 to the operator IP only; 80 open
   for ACME HTTP-01; vLLM stays on `127.0.0.1`.
4. **Persistent weights volume attached** at `/data` (HF cache + Caddy certs),
   surviving teardown.
5. **Required outputs**: `ssh_host`, `floating_ip`, `sslip_host`, `endpoint`,
   `ssh_command`.

`tofu destroy` removes only compute (+ firewall); the persistent volume + IP stay.

## Lambda note

Lambda has no per-VM firewall API in some regions and IPs are not always stable;
the "stable IP" requirement may need a DNS record updated on apply instead of a
floating IP. Revisit when implementing.
