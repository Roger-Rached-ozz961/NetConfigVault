#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/config"
cp "$ROOT/backup.sh" "$tmp/backup.sh"
cp "$ROOT/config/retention.conf" "$tmp/config/retention.conf"
cp "$ROOT/config/vendors.tsv" "$tmp/config/vendors.tsv"
printf 'test-device\t192.0.2.5\t22\tbackup\tcisco_ios\tlab\t-\t-\ttrue\n' > "$tmp/config/inventory.tsv"
chmod 600 "$tmp/config/inventory.tsv"

cat > "$tmp/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
printf 'version 17.9\nhostname lab-router\ninterface Loopback0\n ip address 192.0.2.1 255.255.255.255\n'
MOCK
chmod +x "$tmp/bin/ssh"
export PATH="$tmp/bin:$PATH"
export CONFIG_DIR="$tmp/config" INVENTORY="$tmp/config/inventory.tsv"
export VENDOR_MAP="$tmp/config/vendors.tsv" RETENTION_FILE="$tmp/config/retention.conf"
export BACKUP_ROOT="$tmp/backups" LOG_DIR="$tmp/logs" REPORT_DIR="$tmp/reports" LOCK_FILE="$tmp/lock"

"$tmp/backup.sh" --dry-run
[[ ! -d "$tmp/backups/cisco_ios/lab/test-device" ]]
"$tmp/backup.sh"
mapfile -t snapshots < <(find "$tmp/backups" -name '*.conf' -type f)
[[ "${#snapshots[@]}" -eq 1 ]]
[[ -s "${snapshots[0]}.sha256" ]]
(cd "$(dirname "${snapshots[0]}")" && sha256sum -c "$(basename "${snapshots[0]}").sha256")
grep -q $'SUCCESS\ttest-device' "$tmp/reports/"*.tsv
echo "All NetConfigVault smoke tests passed."
