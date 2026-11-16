# Operations

## Routine execution

```bash
./backup.sh                 # all enabled devices
./backup.sh --device edge1  # one device
./backup.sh --dry-run       # validate selection without connecting or pruning
```

The script acquires a non-blocking `flock` lock to prevent overlapping runs. Exit codes: 0 = no device failures; 1 = one or more device failures; 2 = invalid setup or invocation.

## Output locations

- Backups: `backups/<vendor>/<group>/<device>/YYYY-MM-DD_HHMMSS.conf`
- SHA-256: same filename with `.sha256` appended.
- Diff: same filename with `.diff` appended when the current capture differs from the preceding snapshot.
- Event log: `logs/backup.log` (UTC timestamp, level/status, message).
- Per-run report: `reports/run_<timestamp>.tsv`.

Runtime directories and captured files are created with restrictive permissions. Keep them on encrypted storage with access limited to the backup operator and authorized auditors.

## Retention behavior

Set `RETENTION_MAX_VERSIONS` and `RETENTION_MAX_DAYS` in `config/retention.conf`. A snapshot is removed when it is older than the configured age OR falls outside the newest configured number of versions. Its matching checksum and diff sidecars are removed with it. Test policy changes on a non-production dataset before enabling.

## Change review and integrity

Review `.diff` files to understand changes. Verify a stored snapshot with:

```bash
cd backups/cisco_ios/branch-a/edge-router-01
sha256sum -c YYYY-MM-DD_HHMMSS.conf.sha256
```

A checksum detects accidental or unauthorized modification only if the checksum itself is protected. For stronger audit integrity, ship logs and checksums to an access-controlled remote system or sign them using a separately protected key.

## Scheduling with cron

Create a cron entry under the dedicated service account (use absolute paths):

```cron
15 2 * * * /opt/netconfigvault/backup.sh >> /opt/netconfigvault/logs/cron.out 2>&1
```

Ensure the service account has a predictable PATH, access to the SSH key/agent, and a populated known_hosts file. Cron does not load an interactive shell profile. Monitor the exit code and per-run report; do not rely solely on cron mail.

## Troubleshooting

| Symptom | Checks |
|---|---|
| Host unreachable / timeout | Routing, ACLs, SSH port, device availability |
| Host key verification failed | Verify fingerprint independently; update known_hosts only after validation |
| Permission denied | Public key installation, username, key permissions, device AAA policy |
| Unknown command / incomplete capture | Vendor mapping, firmware syntax, privilege level, command authorization |
| No diff generated | First successful backup or identical content |
| No report rows | Inventory header/comments only, or device filter did not match |
| Lock already held | Check whether another run is active before removing a stale lock |

## Restore discipline

NetConfigVault does not push configurations back to devices. Restore must be a separately reviewed change with a device-specific procedure, maintenance window, validated syntax, and out-of-band recovery plan. Test restore procedures regularly in a lab.
