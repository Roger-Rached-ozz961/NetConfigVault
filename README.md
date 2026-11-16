# NetConfigVault

**Automated Network Configuration Backup & Audit System**

NetConfigVault is a Bash-based, SSH-driven tool for collecting, versioning, comparing, and retaining network-device configurations. It is designed for authorized network administration in mixed-vendor environments.

> **Status:** v1.0.0 — initial implementation. Validate vendor command behavior and access controls in a lab before production deployment.

## Features

- SSH key-based, non-interactive collection (no passwords stored in inventory).
- External TSV inventory; add devices without editing the engine.
- Vendor command mappings for Cisco IOS/IOS-XE, Juniper Junos, Arista EOS, and MikroTik RouterOS.
- Timestamped, per-device configuration snapshots.
- SHA-256 checksums and change diffs against the previous successful snapshot.
- Retention by maximum versions and age.
- Protected backup files, audit log, per-device status and summary.
- Optional SSH jump host and per-device identity file.
- Cron-friendly operation, lock protection, and dry-run mode.

## Project layout

```text
NetConfigVault/
├── backup.sh
├── config/
│   ├── inventory.tsv
│   ├── vendors.tsv
│   └── retention.conf
├── backups/                 # created at runtime; never commit real configs
├── logs/                    # created at runtime; never commit logs
├── reports/                 # created at runtime
├── docs/
│   ├── INSTALLATION.md
│   ├── OPERATIONS.md
│   └── SECURITY.md
├── tests/
│   └── test_backup.sh
├── .gitignore
└── LICENSE
```

## Requirements

- Linux (Bash 4+, OpenSSH client, GNU coreutils/findutils, `flock`, `sha256sum`, `diff`).
- SSH access and a dedicated read-only configuration account on each device.
- Device host keys enrolled in the operator's `known_hosts` file.
- Optional: `timeout` (GNU coreutils) for bounded SSH sessions.

## Quick start

1. Review [installation](docs/INSTALLATION.md) and [security](docs/SECURITY.md).
2. Create a dedicated service account and SSH key. Install its public key on each network device.
3. Copy and edit the inventory:

   ```bash
   cp config/inventory.tsv.example config/inventory.tsv
   chmod 600 config/inventory.tsv
   ```

   (The repository includes a sample `config/inventory.tsv`; replace all example values before running.)
4. Edit `config/retention.conf` and verify vendor commands in `config/vendors.tsv`.
5. Run a connectivity/collection test:

   ```bash
   chmod 700 backup.sh
   ./backup.sh --dry-run
   ./backup.sh
   ```

6. Inspect `backups/`, `logs/backup.log`, and `reports/`.

## Inventory format

Tab-separated, exactly nine columns:

`name host port user vendor group jump_host identity_file enabled`

Use `-` for optional values. Supported vendor keys are `cisco_ios`, `juniper_junos`, `arista_eos`, and `mikrotik_routeros`. Set `enabled` to `true` or `false`. Names/groups must be safe path components. See [operations](docs/OPERATIONS.md).

## Usage

```bash
./backup.sh                 # back up enabled devices
./backup.sh --dry-run       # show selected devices; do not connect or prune
./backup.sh --device edge1  # run one inventory device by name
./backup.sh --help
```

Exit status: `0` all selected devices succeeded; `1` one or more device operations failed; `2` invalid configuration or invocation.

## Backup structure

```text
backups/<vendor>/<group>/<device>/
  YYYY-MM-DD_HHMMSS.conf
  YYYY-MM-DD_HHMMSS.conf.sha256
  YYYY-MM-DD_HHMMSS.diff       # only when a prior snapshot exists
```

Each successful capture is written atomically with mode `0600`. A checksum is generated for every snapshot. Diffs are unified diffs against the immediately preceding successful snapshot. Retention applies to configuration snapshots and their matching sidecars.

## Audit and reporting

- `logs/backup.log`: timestamped TSV event log.
- `reports/run_<timestamp>.tsv`: one result row per selected device.
- Statuses include `SUCCESS`, `FAILED`, `SKIPPED`, and `DRY_RUN`.

Do not treat a successful SSH exit alone as proof that the captured configuration is complete. NetConfigVault checks for empty/trivially short output and common CLI error responses, but device-specific validation remains an operator responsibility.

## Scheduling

Example cron entry (adjust the absolute path and account):

```cron
15 2 * * * /opt/netconfigvault/backup.sh >> /opt/netconfigvault/logs/cron.out 2>&1
```

See [operations](docs/OPERATIONS.md) for scheduling, restore validation, monitoring, and maintenance.

## Scope and limitations

- This is a configuration collection and change-audit utility, not a configuration deployment or remediation tool.
- It does not discover devices, configure devices, or verify that a backup can be restored.
- Vendor commands and privilege requirements vary by firmware and device role; validate mappings and read-only permissions before use.
- SSH key authentication is the supported credential method. Passwords and secrets must not be placed in inventory or command-line arguments.
- No central database, web dashboard, SIEM transport, email/Teams notification, encryption-at-rest automation, or HA orchestration is included in v1.0.0.
- Configuration files can contain sensitive data. Restrict storage, protect host access, and define an off-host encrypted backup strategy.

## Contributing

Use a lab device or mocked SSH command for tests. Keep credentials, live inventories, configuration backups, and logs out of version control. See [security guidance](docs/SECURITY.md).

## License

MIT — see [LICENSE](LICENSE).
