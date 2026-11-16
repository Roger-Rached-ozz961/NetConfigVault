#!/usr/bin/env bash
# NetConfigVault v1.0.0 - authorized network configuration backup and audit.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_DIR="${CONFIG_DIR:-$SCRIPT_DIR/config}"
BACKUP_ROOT="${BACKUP_ROOT:-$SCRIPT_DIR/backups}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
REPORT_DIR="${REPORT_DIR:-$SCRIPT_DIR/reports}"
INVENTORY="${INVENTORY:-$CONFIG_DIR/inventory.tsv}"
VENDOR_MAP="${VENDOR_MAP:-$CONFIG_DIR/vendors.tsv}"
RETENTION_FILE="${RETENTION_FILE:-$CONFIG_DIR/retention.conf}"
LOCK_FILE="${LOCK_FILE:-$SCRIPT_DIR/.netconfigvault.lock}"
CONNECT_TIMEOUT=12
COMMAND_TIMEOUT=90
MIN_CONFIG_BYTES=20
DRY_RUN=false
FILTER_DEVICE=""

usage() {
  cat <<'EOF'
NetConfigVault - network configuration backup and audit

Usage:
  ./backup.sh [--dry-run] [--device DEVICE_NAME] [--help]

Options:
  --dry-run       Validate and list selected devices; no SSH or pruning.
  --device NAME   Process only the named inventory device.
  --help          Show this help.

Environment overrides:
  CONFIG_DIR, BACKUP_ROOT, LOG_DIR, REPORT_DIR, INVENTORY, VENDOR_MAP,
  RETENTION_FILE, LOCK_FILE
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
log() {
  local level="$1"; shift
  local message="$*"
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  printf '%s\t%s\t%s\n' "$now" "$level" "${message//$'\t'/ }" >> "$LOG_DIR/backup.log"
  printf '[%s] %s\n' "$level" "$message"
}
safe_component() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != "." && "$1" != ".." ]]
}
require_file() { [[ -r "$1" && -f "$1" ]] || die "Required readable file missing: $1"; }

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --device) (($# >= 2)) || die "--device requires a name"; FILTER_DEVICE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

for cmd in ssh sha256sum diff find sort flock stat date mktemp timeout; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done
require_file "$INVENTORY"
require_file "$VENDOR_MAP"
require_file "$RETENTION_FILE"

# Config is a local administrator-owned shell file. Never source an untrusted file.
# shellcheck source=config/retention.conf
source "$RETENTION_FILE"
: "${RETENTION_MAX_VERSIONS:=20}"
: "${RETENTION_MAX_DAYS:=30}"
: "${SSH_STRICT_HOST_KEY_CHECKING:=yes}"
: "${SSH_GLOBAL_KNOWN_HOSTS_FILE:=}"
: "${BACKUP_ROOT:=}"
[[ "$RETENTION_MAX_VERSIONS" =~ ^[1-9][0-9]*$ ]] || die "RETENTION_MAX_VERSIONS must be a positive integer"
[[ "$RETENTION_MAX_DAYS" =~ ^[1-9][0-9]*$ ]] || die "RETENTION_MAX_DAYS must be a positive integer"
[[ "$SSH_STRICT_HOST_KEY_CHECKING" == "yes" ]] || die "Strict host key checking must remain enabled"

mkdir -p "$BACKUP_ROOT" "$LOG_DIR" "$REPORT_DIR"
chmod 700 "$BACKUP_ROOT" "$LOG_DIR" "$REPORT_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another NetConfigVault run is active"

# Map vendor key to remote command. Mapping is tab-separated: vendor<TAB>command.
vendor_command() {
  local wanted="$1" line key value
  while IFS=$'\t' read -r key value; do
    [[ -z "$key" || "$key" == #* ]] && continue
    if [[ "$key" == "$wanted" ]]; then printf '%s' "$value"; return 0; fi
  done < "$VENDOR_MAP"
  return 1
}

# TSV inventory fields: name host port user vendor group jump_host identity_file enabled.
# '-' denotes an optional field. Fields cannot contain tabs or newlines.
run_stamp="$(date -u '+%Y-%m-%d_%H%M%S')"
report="$REPORT_DIR/run_$run_stamp.tsv"
printf 'timestamp\tdevice\thost\tvendor\tstatus\tbackup_file\tmessage\n' > "$report"
chmod 600 "$report"
total=0; succeeded=0; failed=0; skipped=0

record() {
  local device="$1" host="$2" vendor="$3" status="$4" path="$5" message="$6"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$device" "$host" "$vendor" "$status" "$path" "${message//$'\t'/ }" >> "$report"
  log "$status" "$device ($host): $message"
}

prune_device() {
  local dir="$1" max_versions="$2" max_days="$3"
  local -a snapshots=()
  local i file base
  mapfile -d '' -t snapshots < <(find "$dir" -maxdepth 1 -type f -name '*.conf' -printf '%T@ %p\0' | sort -z -nr | sed -z 's/^[^ ]* //')
  for ((i=0; i<${#snapshots[@]}; i++)); do
    file="${snapshots[$i]}"
    base="$file"
    if (( i >= max_versions )) || [[ "$file" -ot "$(date -d "$max_days days ago" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')" ]]; then
      rm -f -- "$base" "$base.sha256" "$base.diff"
      log "PRUNE" "Removed expired snapshot $base"
    fi
  done
}

process_device() {
  local name="$1" host="$2" port="$3" user="$4" vendor="$5" group="$6"
  local jump="$7" identity="$8" enabled="$9"
  local remote_cmd outdir outfile tmpfile previous checksum status message
  local -a ssh_args=()

  if [[ "$enabled" != "true" ]]; then
    ((skipped+=1)); record "$name" "$host" "$vendor" "SKIPPED" "-" "disabled in inventory"; return
  fi
  if ! safe_component "$name" || ! safe_component "$group" || ! safe_component "$vendor"; then
    ((failed+=1)); record "$name" "$host" "$vendor" "FAILED" "-" "unsafe path component"; return
  fi
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((port >= 1 && port <= 65535)) || {
    ((failed+=1)); record "$name" "$host" "$vendor" "FAILED" "-" "invalid SSH port"; return;
  }
  [[ "$host" =~ ^[A-Za-z0-9._:-]+$ ]] || {
    ((failed+=1)); record "$name" "$host" "$vendor" "FAILED" "-" "invalid host field"; return;
  }
  [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] || {
    ((failed+=1)); record "$name" "$host" "$vendor" "FAILED" "-" "invalid SSH username"; return;
  }
  if ! remote_cmd="$(vendor_command "$vendor")"; then
    ((failed+=1)); record "$name" "$host" "$vendor" "FAILED" "-" "no command mapping for vendor"; return
  fi

  outdir="$BACKUP_ROOT/$vendor/$group/$name"
  if [[ "$DRY_RUN" == true ]]; then
    record "$name" "$host" "$vendor" "DRY_RUN" "$outdir" "validated; no SSH or pruning performed"; return
  fi
  mkdir -p "$outdir"; chmod 700 "$outdir"
  ssh_args=(-T -p "$port" -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT"
    -o ConnectionAttempts=1 -o StrictHostKeyChecking="$SSH_STRICT_HOST_KEY_CHECKING"
    -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
  [[ -n "$SSH_GLOBAL_KNOWN_HOSTS_FILE" ]] && ssh_args+=(-o "GlobalKnownHostsFile=$SSH_GLOBAL_KNOWN_HOSTS_FILE")
  [[ "$identity" != "-" ]] && ssh_args+=(-i "$identity" -o IdentitiesOnly=yes)
  [[ "$jump" != "-" ]] && ssh_args+=(-J "$jump")

  tmpfile="$(mktemp "$outdir/.capture.XXXXXX")"
  chmod 600 "$tmpfile"
  if ! timeout "$COMMAND_TIMEOUT" ssh "${ssh_args[@]}" "$user@$host" "$remote_cmd" > "$tmpfile" 2>"$tmpfile.stderr"; then
    message="$(tr '\n\t' '  ' < "$tmpfile.stderr" | cut -c1-240)"
    rm -f "$tmpfile" "$tmpfile.stderr"
    ((failed+=1)); record "$name" "$host" "$vendor" "FAILED" "-" "${message:-SSH command failed or timed out}"; return
  fi
  rm -f "$tmpfile.stderr"
  if (( $(stat -c '%s' "$tmpfile") < MIN_CONFIG_BYTES )) ||
     grep -Eiq '(^|[[:space:]])(invalid input|unknown command|syntax error|permission denied|not authorized|command not found)([[:space:]]|$)' "$tmpfile"; then
    rm -f "$tmpfile"
    ((failed+=1)); record "$name" "$host" "$vendor" "FAILED" "-" "capture empty, too short, or contains a CLI error"; return
  fi

  outfile="$outdir/$run_stamp.conf"
  if [[ -e "$outfile" ]]; then
    outfile="$outdir/$run_stamp-$$.conf"
  fi
  previous="$(find "$outdir" -maxdepth 1 -type f -name '*.conf' ! -name "$(basename "$outfile")" -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2- || true)"
  if [[ -n "$previous" ]]; then
    if diff -u --label "previous:$(basename "$previous")" --label "current:$(basename "$outfile")" "$previous" "$tmpfile" > "$tmpfile.diff"; then
      :
    else
      # diff exit 1 means changes; exit >1 means an operational error.
      diff_rc=$?
      if (( diff_rc > 1 )); then
        rm -f "$tmpfile" "$tmpfile.diff"
        ((failed+=1)); record "$name" "$host" "$vendor" "FAILED" "-" "diff operation failed"; return
      fi
    fi
    if [[ -s "$tmpfile.diff" ]]; then mv "$tmpfile.diff" "$outfile.diff"; else rm -f "$tmpfile.diff"; fi
  fi
  mv "$tmpfile" "$outfile"
  chmod 600 "$outfile"
  checksum="$(sha256sum "$outfile" | awk '{print $1}')"
  printf '%s  %s\n' "$checksum" "$(basename "$outfile")" > "$outfile.sha256"
  chmod 600 "$outfile.sha256"
  prune_device "$outdir" "$RETENTION_MAX_VERSIONS" "$RETENTION_MAX_DAYS"
  ((succeeded+=1))
  record "$name" "$host" "$vendor" "SUCCESS" "$outfile" "backup saved; sha256=$checksum"
}

while IFS=$'\t' read -r name host port user vendor group jump identity enabled; do
  [[ -z "$name" || "$name" == #* ]] && continue
  if [[ -n "$FILTER_DEVICE" && "$name" != "$FILTER_DEVICE" ]]; then continue; fi
  ((total+=1))
  process_device "$name" "$host" "$port" "$user" "$vendor" "$group" "$jump" "$identity" "$enabled"
done < "$INVENTORY"

if (( total == 0 )); then
  [[ -n "$FILTER_DEVICE" ]] && die "Device '$FILTER_DEVICE' not found in inventory"
  log "INFO" "No enabled devices selected."
fi
log "SUMMARY" "selected=$total success=$succeeded failed=$failed skipped=$skipped report=$report"
(( failed == 0 )) || exit 1
exit 0
