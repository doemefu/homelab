#!/bin/bash
# kine-offline-compact.sh — offline compaction runbook for the k3s kine/SQLite datastore
# (homelab#129, 2026-09-23 incident). Read DEPLOYMENT.md "k3s datastore (kine/SQLite)
# maintenance" first — it covers the symptoms that justify running this and the read-only
# diagnostics to check before reaching for an offline compaction at all.
#
# Merges the two scripts run by hand on raspi5 during the incident — stop + checkpoint + backup
# + compact (formerly kine-phase1.sh) and start + verify (formerly kine-phase2.sh) — into one
# script with a confirmation prompt before each state-changing stage (stop / backup / compact /
# start), so an operator can abort between any two stages. Requires kine-offline-compact.py in
# the same directory.
#
# Must run as root (sudo) on the k3s SERVER node (raspi5), with k3s at its default install
# paths. Free disk space on the datastore's filesystem must be at least 2x the current state.db
# size — the backup stage copies the full pre-compaction datastore.
#
# Usage:
#   sudo ./kine-offline-compact.sh --dry-run       # read-only: prints rows/target, no changes,
#                                                   # k3s is left running throughout
#   sudo ./kine-offline-compact.sh                 # full run, confirms before each stage
#   sudo ./kine-offline-compact.sh --yes            # full run, no prompts (unattended)
#
# k3s is stopped from the "stop" stage until "start" completes — the Kubernetes API is
# unavailable for that whole window (22 minutes measured on 2026-09-23 for a 5 GB / 1.77M-row
# datastore: 661s compaction + backup/checkpoint/restart overhead). Containers keep running
# throughout (k3s.service ships with KillMode=process) and public endpoints stay up; only the
# API and anything that calls it (kubectl, controllers, Flux) is affected.
set -euo pipefail

DB="/var/lib/rancher/k3s/server/db/state.db"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPACT_PY="${SCRIPT_DIR}/kine-offline-compact.py"
TS="$(date +%Y%m%dT%H%M%S)"
LOG="/tmp/kine-offline-compact-${TS}.log"

DRY_RUN=false
ASSUME_YES=false

usage() {
  cat <<'EOF'
Usage: sudo ./kine-offline-compact.sh [--dry-run] [--yes]

  --dry-run   Read-only: print the rows/current_rev/compact_rev/target report and exit.
              Does not stop k3s, take a backup, delete rows, or start/stop anything.
  --yes       Skip the confirmation prompt before each stage (for scripted/unattended runs).
  -h, --help  Show this message.

See DEPLOYMENT.md "k3s datastore (kine/SQLite) maintenance" before running a real (non
--dry-run) pass.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

confirm() {
  local prompt="$1"
  if $ASSUME_YES; then
    return 0
  fi
  read -r -p "${prompt} [y/N] " reply
  case "$reply" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) log "Aborted by operator at: ${prompt}"; exit 1 ;;
  esac
}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Must run as root (sudo). Aborting." >&2
  exit 1
fi

if [[ ! -f "$COMPACT_PY" ]]; then
  echo "kine-offline-compact.py not found next to this script at ${COMPACT_PY}" >&2
  exit 1
fi

if [[ ! -f "$DB" ]]; then
  echo "kine datastore not found at ${DB} — is this the k3s server node?" >&2
  exit 1
fi

log "=== kine offline compaction runbook (homelab#129) ==="
log "DB=${DB}  LOG=${LOG}  dry_run=${DRY_RUN}  assume_yes=${ASSUME_YES}"

DB_SIZE=$(stat -c%s "$DB" 2>/dev/null || stat -f%z "$DB")
FREE_KB=$(df -Pk "$(dirname "$DB")" | awk 'NR==2 {print $4}')
FREE_BYTES=$((FREE_KB * 1024))
log "state.db size: ${DB_SIZE} bytes. Free space on $(dirname "$DB"): ${FREE_BYTES} bytes."
if (( FREE_BYTES < DB_SIZE * 2 )); then
  echo "Free space (${FREE_BYTES}B) is less than 2x state.db (${DB_SIZE}B) — refusing to continue." >&2
  echo "The backup stage copies the full datastore; free at least 2x its current size first." >&2
  exit 1
fi

if $DRY_RUN; then
  log "--- dry-run: read-only report (k3s left running, no changes made) ---"
  python3 "$COMPACT_PY" --dry-run 2>&1 | tee -a "$LOG"
  log "--- dry-run complete. Log: ${LOG} ---"
  exit 0
fi

# --- Stage 1: stop -----------------------------------------------------------------------
confirm "Stage 1/4 STOP: this stops k3s now — the Kubernetes API becomes unavailable until stage 4 completes. Continue?"
log "--- stage stop ---"
systemctl stop k3s
systemctl is-active k3s >>"$LOG" 2>&1 || true
log "k3s stopped."

# --- Stage 2: backup ----------------------------------------------------------------------
confirm "Stage 2/4 BACKUP: checkpoint the WAL and copy state.db (~1-3 min per GB on an SD card). Continue?"
log "--- stage backup ---"
python3 -c "import sqlite3; c=sqlite3.connect('${DB}'); print(c.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone())" | tee -a "$LOG"
BACKUP="${DB}.bak-${TS}"
cp -a "$DB" "$BACKUP"
# shellcheck disable=SC2012  # DB is a known fixed path (no adversarial filenames); ls -la gives a human-readable size/mtime log line
ls -la "${DB}"* | tee -a "$LOG"
log "Backup written to ${BACKUP}. Keep it until 24h of stable operation after this run, then remove it."

# --- Stage 3: compact ----------------------------------------------------------------------
confirm "Stage 3/4 COMPACT: run the dry-run report, then the real compaction + VACUUM. This deletes rows. Continue?"
log "--- stage compact: dry run ---"
python3 "$COMPACT_PY" --dry-run 2>&1 | tee -a "$LOG"
log "--- stage compact: real run ---"
python3 "$COMPACT_PY" 2>&1 | tee -a "$LOG"
# shellcheck disable=SC2012  # DB is a known fixed path (no adversarial filenames); ls -la gives a human-readable size/mtime log line
ls -la "${DB}"* | tee -a "$LOG"
log "Compaction complete. Backup remains at ${BACKUP} — see the rollback procedure in DEPLOYMENT.md if the verification output above looks wrong."

# --- Stage 4: start ----------------------------------------------------------------------
confirm "Stage 4/4 START: start k3s and wait for the API to come back. Continue?"
log "--- stage start ---"
systemctl start k3s --no-block
HEALTHY=false
for i in $(seq 1 36); do
  sleep 10
  if k3s kubectl get --raw /healthz --request-timeout=10s >/dev/null 2>&1; then
    log "healthz ok after $((i * 10))s"
    HEALTHY=true
    break
  fi
done
if ! $HEALTHY; then
  log "WARNING: /healthz did not become ok within 360s. Check 'journalctl -u k3s -f' and 'systemctl show k3s -p NRestarts'."
fi
{ systemctl show k3s -p ActiveState,NRestarts | tr '\n' ' '; echo; } | tee -a "$LOG"
log "--- readyz ---"
k3s kubectl get --raw /readyz --request-timeout=20s 2>&1 | tail -1 | cut -c1-40 | tee -a "$LOG"
log "--- nodes ---"
k3s kubectl get nodes --request-timeout=30s | tee -a "$LOG"
log "--- pods not Running/Completed (top 10) ---"
k3s kubectl get pods -A --request-timeout=30s 2>/dev/null | grep -vE "Running|Completed|NAME" | head -10 | tee -a "$LOG" || true
log "=== done. Backup kept at ${BACKUP} — remove after 24h of stable operation. Log: ${LOG} ==="
