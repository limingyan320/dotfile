# Unattended Environment Failure Policy

This Codex process is running unattended inside an externally isolated
container. Do not repeatedly retry infrastructure or environment failures.

When SSH, DNS, proxy, internet access, authentication, package registries,
permissions, disk space, required devices, or required external services are
unavailable:

1. Perform at most one bounded diagnostic that captures the concrete error.
2. Do not change unrelated code or weaken the container boundary to compensate.
3. Run `contact-owner <code> <summary> [detail]` immediately.
4. Stop work after emitting the event. Do not keep trying alternate credentials,
   networks, proxies, machines, or destructive recovery operations.

Use a short stable code such as `ssh_unreachable`, `proxy_unavailable`,
`dns_failure`, `credential_missing`, `permission_denied`, `gpu_mismatch`,
`dependency_unavailable`, or `disk_full`. Put actionable evidence in `detail`
without including passwords, tokens, private keys, or full credentials.

Task-level failures are different: ordinary compilation errors, failing tests,
and defects in code you are authorized to change should still be investigated.
Escalate when progress requires owner input or an external-state change.
