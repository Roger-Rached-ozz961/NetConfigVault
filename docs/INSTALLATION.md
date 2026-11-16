# Installation

## 1. Install dependencies

On Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y bash openssh-client coreutils findutils util-linux diffutils
```

NetConfigVault uses Bash 4+, OpenSSH, GNU `timeout`, `flock`, `find`, `sort`, `stat`, `sha256sum`, and `diff`.

## 2. Create a dedicated operator account

Run the collector as a dedicated, non-root Linux account. Protect the project directory and runtime directories from other local users:

```bash
sudo install -d -o netbackup -g netbackup -m 0700 /opt/netconfigvault
```

Place the project files in that directory and make the script executable:

```bash
chmod 700 /opt/netconfigvault/backup.sh
chmod 600 /opt/netconfigvault/config/retention.conf
```

## 3. Configure SSH keys

Generate a dedicated key as the service account (use an approved passphrase/agent strategy for unattended jobs):

```bash
sudo -u netbackup ssh-keygen -t ed25519 -f /home/netbackup/.ssh/id_ed25519
```

Install the public key for a dedicated read-only or least-privilege account on each network device. Do not reuse a personal administrator key. Enroll and verify host keys out-of-band before the first run:

```bash
sudo -u netbackup ssh-keyscan -H DEVICE_HOST
```

Treat `ssh-keyscan` output as unverified until its fingerprint is checked against a trusted source. Then add the verified key to the service account's `known_hosts`. Strict host key checking stays enabled.

## 4. Configure inventory and commands

Edit `config/inventory.tsv` and replace example addresses, usernames, groups, and identity paths. The sample includes a disabled row as a template. Inventory columns are tab-separated and must remain in this order:

1. name — safe device identifier
2. host — DNS name or IP address
3. port — SSH TCP port
4. user — SSH username
5. vendor — key from `vendors.tsv`
6. group — site or logical grouping
7. jump_host — SSH jump host or `-`
8. identity_file — private key path or `-` (agent/default identity may be used)
9. enabled — `true` or `false`

The inventory parser expects exactly nine tab-delimited values. Do not use tabs/newlines inside fields. Keep the inventory local and mode `0600`.

Review each command in `config/vendors.tsv`. Some platforms require a dedicated privilege level or command authorization policy. Do not grant configuration-write privileges to the backup account.

## 5. Run

```bash
sudo -u netbackup /opt/netconfigvault/backup.sh --dry-run
sudo -u netbackup /opt/netconfigvault/backup.sh --device edge-router-01
sudo -u netbackup /opt/netconfigvault/backup.sh
```

The first real run should be supervised. Confirm the saved configuration is complete and useful for recovery before enabling a schedule.
