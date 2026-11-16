# Security considerations

Network configurations can expose credentials, SNMP communities, VPN parameters, topology, management addresses, routing policy, and other sensitive information. Treat every backup and diff as confidential.

## Required controls

- Use a dedicated non-root Linux service account and least-privilege device accounts.
- Prefer SSH public-key authentication; never place passwords, private keys, tokens, or enable secrets in inventory, source control, logs, or command arguments.
- Enforce SSH host key checking. Verify fingerprints out-of-band; do not blindly trust first-seen keys.
- Restrict backup, log, report, and inventory permissions. Use encrypted disks and encrypted off-host replication.
- Restrict network reachability from the collector to approved management interfaces.
- Use a jump host where required and secure it as a privileged access path.
- Keep the inventory and retention configuration writable only by trusted administrators.
- Rotate keys, review access, monitor failures, and test recovery.

## Operational caveats

- Vendor command output may include secrets. MikroTik's `/export` is used to omit sensitive values by default; validate behavior on your RouterOS release. Never switch to a sensitive export mode without an explicit risk review.
- Some vendors require enable/privilege elevation. Configure narrowly scoped command authorization rather than granting full administrative access.
- Configuration diffs may reveal newly added secrets or removed security controls. Apply the same controls as for full backups.
- SHA-256 sidecars are integrity checks, not tamper-proof audit evidence when an attacker can modify both files. Forward logs/checksums to a separately controlled system for stronger assurance.
- The collector checks minimum output size and common error strings, but cannot guarantee semantic completeness for every platform.
- Review retention settings and legal/regulatory obligations before deleting historical backups.

## Safe use

Use only on devices and networks you own or are explicitly authorized to administer. NetConfigVault is designed for read-only collection; do not use it to bypass access controls or alter device configurations.
