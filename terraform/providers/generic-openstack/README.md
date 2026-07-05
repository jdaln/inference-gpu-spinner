# Provider stub: generic OpenStack (not implemented)

UpCloud (`../upcloud`) is the reference implementation. No code here yet.
This is the most likely *second* target, since many EU/research clouds expose
OpenStack APIs (Nova/Neutron/Cinder) that map cleanly onto our needs.

## Provider contract

A provider stack under `terraform/providers/<name>/` must, on `tofu apply`,
produce a GPU host satisfying:

1. **SSH-reachable host** with our SSH key — output `ssh_host`.
2. **Stable public IP** across destroy/recreate — outputs `floating_ip` and
   `sslip_host` (`<dashed-ip>.sslip.io`). On OpenStack: a Neutron floating IP
   (re-associated to the new instance each spin-up) maps directly.
3. **Operator-IP firewall allowlist** — a Neutron security group with 22 + 443
   from the operator IP and 80 from `0.0.0.0/0` (ACME); vLLM on `127.0.0.1`.
4. **Persistent weights volume attached** at `/data` — a Cinder volume that is
   NOT deleted with the instance.
5. **Required outputs**: `ssh_host`, `floating_ip`, `sslip_host`, `endpoint`,
   `ssh_command`.

`tofu destroy` removes only the Nova instance (+ security group); the Cinder
volume and floating IP persist.

## Note

Use the `terraform-provider-openstack/openstack` provider. The persistent vs
ephemeral split mirrors the UpCloud design: Cinder volume + floating IP in the
persistent stack, Nova instance + security group in the ephemeral stack.
