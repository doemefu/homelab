#!/usr/bin/env bash
# copy-restic-repo.sh — off-node copy of raspi5's restic repository to the operator's Mac (#91)
#
# The restic repository (/var/lib/backup/restic-repo, written by homelab-backup.sh at 03:00) lives
# on raspi5's root SD card, the same disk it protects. This script pulls a byte-identical copy into
# a dated directory on the Mac, next to the app-data dumps of scripts/backup-app-data.sh.
#
# - Read-only on the repository: rsync runs on the node as the sender only, under a SHARED flock on
#   the lock homelab-backup.sh takes exclusively, so the copy never overlaps a backup or prune.
#   The only node writes are that lock file and, after a successful run, the freshness marker
#   (`homelab-backup-mark restic-copy`, #301; skip with --no-mark).
# - No password: the repository is encrypted by restic and is copied as is. Restoring from the copy
#   needs the restic password (DEPLOYMENT.md "Off-node copy to the operator's Mac (#91)").
# - Every copy is an independent full copy (no hard links), verified by file list + sizes against
#   the source and by SHA-256: restic names data, index, key and snapshot files by the SHA-256 of
#   their content.
#
# Usage:
#   ./scripts/copy-restic-repo.sh [--host USER@HOST] [--ssh-config FILE] [--repo PATH]
#                                 [--dest DIR] [--retain N] [--accept-shrink] [--no-mark] [--dry-run]
#
# See DEPLOYMENT.md "Off-node copy to the operator's Mac (#91)".

set -euo pipefail

# The copy holds every cluster Secret (restic-encrypted) — never group/world readable.
umask 077

# --- Constants -------------------------------------------------------------------------------
# The lock homelab-backup.sh takes with `flock -n 9` (infra/roles/storage/tasks/main.yml).
readonly REMOTE_LOCK="/var/lock/homelab-backup.lock"
# Upper bound for every remote command that holds the lock, so a vanished Mac (sleep, Wi-Fi)
# cannot keep the lock past the 03:00 backup. Must stay below the start-guard margin.
readonly REMOTE_TIMEOUT=3600
# No run may start while the node clock reads 02:00-03:44: the restic cron runs at 03:00, and
# each remote command of a run started before 02:00 is cut off by REMOTE_TIMEOUT before 03:00
# (a whole run is three short remote commands; today's copy takes about 12 s).
readonly GUARD_FROM=200
readonly GUARD_UNTIL=345
# Exit status of `flock -E` when the backup holds the lock.
readonly LOCK_BUSY_RC=75
# Exit status of the remote manifest when restic itself holds a recent lock (manual restic run).
readonly RESTIC_LOCK_RC=76
readonly FRESH_LOCK_MINUTES=60

# Copy directories are named <YYYY-MM-DD_HHMMSS> and start their MANIFEST.txt with MARKER.
# They never contain a SHA256SUMS file: that file is what scripts/backup-app-data.sh uses to
# recognise (and prune) its own run directories, so its absence keeps that retention away.
readonly RUN_DIR_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$'
readonly MARKER="homelab restic repo copy"
readonly WORK_NAME=".in-progress"

# Shrink guard: a copy whose source lost more than this many snapshot files or more than half
# of its bytes since the last copy that passed the guard is kept, but no older copy is pruned.
# The guard stays tripped on every later run until the operator passes --accept-shrink.
readonly MAX_SNAPSHOT_DROP=3

readonly RSYNC_BIN="/usr/bin/rsync"
readonly LOCAL_LOCK_DIR="${TMPDIR:-/tmp}/copy-restic-repo.lock"

# --- Options ---------------------------------------------------------------------------------
readonly DEFAULT_REPO="/var/lib/backup/restic-repo"
HOST="ansible@192.168.1.61"
SSH_CONFIG=""
REPO="$DEFAULT_REPO"
DEST="${HOME}/informatik/homelab/backups/restic"
RETAIN=5
DRY_RUN=false
ACCEPT_SHRINK=false
NO_MARK=false

usage() {
  cat <<'USAGE'
copy-restic-repo.sh — off-node copy of raspi5's restic repository to this Mac (#91)

Pulls the restic repository from raspi5 with rsync over SSH into a new dated directory and
verifies it. Read-only on the repository; needs no restic password and no restic on the Mac.
After a successful run it records the copy's freshness on the node (homelab-backup-mark
restic-copy, #301), which feeds an alert when the newest copy gets old.

Options:
  --host USER@HOST    SSH target (default: ansible@192.168.1.61, needs passwordless sudo)
  --ssh-config FILE   ssh config file passed as "ssh -F FILE"; off-LAN use
                      ~/.ssh/homelab-offlan.conf (see DEPLOYMENT.md "Off-LAN kubectl / Ansible
                      Access"). The path must not contain whitespace.
  --repo PATH         repository path on the node (default: /var/lib/backup/restic-repo)
  --dest DIR          copy root on this Mac (default: $HOME/informatik/homelab/backups/restic).
                      Absolute, dedicated path; never the app-data backup folder itself.
  --retain N          keep the N newest complete copies, delete older ones (default: 5).
                      Pruning only happens after a fully verified run.
  --accept-shrink     accept a source that shrank since the last good copy (after checking the
                      repository on the node); the copy is recorded as accepted and retention
                      runs again.
  --no-mark           do not record the freshness marker on the node (it is also skipped for a
                      non-default --repo and when the shrink guard trips).
  --dry-run           run every check and print the totals and the rsync command; copies,
                      creates and deletes nothing.
  --help              show this help.

Layout:
  <dest>/<YYYY-MM-DD_HHMMSS>/repo/        byte-identical copy of the repository (locks/ empty)
  <dest>/<YYYY-MM-DD_HHMMSS>/MANIFEST.txt run metadata, totals and verification results
  <dest>/.in-progress/                    a copy that has not finished verification yet; the
                                          next run resumes it

When it refuses to run:
  - the node clock reads 02:00-03:44 (restic backup at 03:00)
  - homelab-backup.sh holds the lock (exit 75), or restic holds a lock younger than 60 min
  - <dest> contains a YYYY-MM-DD_HHMMSS directory that is not a restic copy

Copies made while the shrink guard tripped count against --retain once --accept-shrink is
given, so the oldest copies from before the shrink are pruned first.

Exit status: 0 success; 1 error; 2 copy verified but the source shrank (no pruning, see
--accept-shrink); 75 the backup is running, try again later; 130 interrupted.
USAGE
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; }
err()  { printf 'ERROR %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      [[ $# -ge 2 ]] || die "--host needs a value"
      HOST="$2"; shift 2 ;;
    --ssh-config)
      [[ $# -ge 2 ]] || die "--ssh-config needs a value"
      SSH_CONFIG="$2"; shift 2 ;;
    --repo)
      [[ $# -ge 2 ]] || die "--repo needs a value"
      REPO="$2"; shift 2 ;;
    --dest)
      [[ $# -ge 2 ]] || die "--dest needs a value"
      DEST="$2"; shift 2 ;;
    --retain)
      [[ $# -ge 2 ]] || die "--retain needs a value"
      RETAIN="$2"; shift 2 ;;
    --accept-shrink) ACCEPT_SHRINK=true; shift ;;
    --no-mark)  NO_MARK=true; shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --help|-h)  usage; exit 0 ;;
    *)          err "unknown option: $1"; echo; usage; exit 1 ;;
  esac
done

# --- Validation ------------------------------------------------------------------------------
if ! [[ "$RETAIN" =~ ^[1-9][0-9]*$ ]]; then
  die "--retain must be a positive integer, got: $RETAIN"
fi
# Values below end up in commands that run as root on the node, so accept plain paths only.
[[ "$HOST" =~ ^([A-Za-z0-9._-]+@)?[A-Za-z0-9._-]+$ ]] || die "--host must look like user@host, got: $HOST"
[[ "$REPO" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "--repo must be an absolute path of [A-Za-z0-9._/-], got: $REPO"
case "/${REPO}/" in
  */../*|*/./*) die "--repo must not contain . or .. path components, got: $REPO" ;;
esac
REPO="${REPO%/}"
[[ -n "$REPO" && "$REPO" != "/" && "$REPO" != *//* ]] || die "--repo must be a plain absolute path other than /, got: $REPO"
if [[ -n "$SSH_CONFIG" ]]; then
  # rsync splits its -e string on whitespace.
  [[ "$SSH_CONFIG" != *[[:space:]]* ]] || die "--ssh-config must not contain whitespace"
  [[ -r "$SSH_CONFIG" ]] || die "--ssh-config not readable: $SSH_CONFIG"
fi
[[ -n "$DEST" ]] || die "--dest must not be empty"
[[ "$DEST" == /* ]] || die "--dest must be an absolute path, got: $DEST"
DEST="${DEST%/}"
case "$DEST" in
  ""|"$HOME") die "--dest must not be / or your home directory" ;;
esac
case "/${DEST}/" in
  */./*|*/../*) die "--dest must not contain . or .. path components, got: $DEST" ;;
esac

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
if [[ -n "$SSH_CONFIG" ]]; then
  SSH_OPTS=(-F "$SSH_CONFIG" "${SSH_OPTS[@]}")
fi
RSYNC_RSH="ssh ${SSH_OPTS[*]}"
# Remote command strings are expanded here on purpose: they only carry the validated --repo and
# constants of this script.
# shellcheck disable=SC2029
remote() { ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }

RUN_TS="$(date +%Y-%m-%d_%H%M%S)"
RUN_DIR="${DEST}/${RUN_TS}"
WORK_DIR="${DEST}/${WORK_NAME}"
TMP_DIR=""
LOCK_HELD=false

# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() {
  if [[ -n "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
  if [[ "$LOCK_HELD" == true ]]; then
    rmdir "$LOCAL_LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'err "interrupted — ${WORK_DIR} is kept, the next run resumes it"; exit 130' INT TERM

# --- Helpers ---------------------------------------------------------------------------------
# is_copy_dir <dir> — a complete copy written by this script.
is_copy_dir() {
  local d="$1"
  [[ -f "${d}/MANIFEST.txt" && -f "${d}/repo/config" && ! -e "${d}/SHA256SUMS" ]] || return 1
  [[ "$(head -n 1 "${d}/MANIFEST.txt")" == "$MARKER" ]]
}

# list_copies — complete copies under DEST, oldest first (names sort chronologically).
list_copies() {
  local name
  [[ -d "$DEST" ]] || return 0
  find "${DEST}/" -mindepth 1 -maxdepth 1 -type d -print | sed 's#.*/##' | LC_ALL=C sort \
    | while IFS= read -r name; do
        if [[ "$name" =~ $RUN_DIR_PATTERN ]] && is_copy_dir "${DEST}/${name}"; then
          printf '%s\n' "$name"
        fi
      done
}

# refuse_foreign_dirs — a YYYY-MM-DD_HHMMSS directory that is not a restic copy means --dest
# points at the wrong folder (for example the app-data backups); never write or prune there.
refuse_foreign_dirs() {
  local name
  [[ -d "$DEST" ]] || return 0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$name" =~ $RUN_DIR_PATTERN ]] && ! is_copy_dir "${DEST}/${name}"; then
      die "${DEST}/${name} is not a restic copy (wrong --dest?) — refusing to write or prune here"
    fi
  done <<< "$(find "${DEST}/" -mindepth 1 -maxdepth 1 -type d -print | sed 's#.*/##')"
}

# manifest_value <MANIFEST.txt> <key>
manifest_value() {
  awk -v k="$2" '$1 == k { print $2; exit }' "$1"
}

# lock_state — 0 free, LOCK_BUSY_RC busy, anything else: the probe itself failed.
lock_state() {
  local rc=0
  remote "sudo -n flock -s -n -E ${LOCK_BUSY_RC} ${REMOTE_LOCK} true" || rc=$?
  return "$rc"
}

# remote_manifest <out> — "path size" per file (locks/ excluded), sorted, plus a final
# "#config-sha256 <hex>" line; taken under the shared backup lock.
remote_manifest() {
  local out="$1" rc=0
  remote "sudo -n timeout ${REMOTE_TIMEOUT} flock -s -n -E ${LOCK_BUSY_RC} ${REMOTE_LOCK} sh -s -- ${REPO} ${FRESH_LOCK_MINUTES} ${RESTIC_LOCK_RC}" \
    > "$out" <<'REMOTE' || rc=$?
set -eu
repo="$1"; fresh_minutes="$2"; restic_lock_rc="$3"
cd "$repo"
fresh="$(find locks -type f -mmin "-${fresh_minutes}" | wc -l)"
if [ "$fresh" -gt 0 ]; then
  echo "restic lock younger than ${fresh_minutes} min in ${repo}/locks" >&2
  exit "$restic_lock_rc"
fi
find . -path ./locks -prune -o -type f -printf '%P %s\n' | LC_ALL=C sort
echo "#config-sha256 $(sha256sum config | cut -d ' ' -f 1)"
echo "#stale-locks $(find locks -type f | wc -l)"
REMOTE
  return "$rc"
}

# explain_remote_failure <rc> <what>
explain_remote_failure() {
  local rc="$1" what="$2"
  case "$rc" in
    "$LOCK_BUSY_RC")
      err "${what}: homelab-backup.sh holds ${REMOTE_LOCK} on the node — try again later"
      exit "$LOCK_BUSY_RC" ;;
    "$RESTIC_LOCK_RC")
      die "${what}: a restic command holds a recent lock in ${REPO}/locks — try again later" ;;
    124)
      die "${what}: timed out after ${REMOTE_TIMEOUT}s on the node" ;;
    *)
      die "${what} failed (exit ${rc})" ;;
  esac
}

# local_manifest <repo dir> <out> — same format as remote_manifest, without the # lines.
local_manifest() {
  ( cd "$1" && find . -path ./locks -prune -o -type f -exec stat -f '%N %z' {} + ) \
    | sed 's#^\./##' | LC_ALL=C sort > "$2"
}

manifest_files() { grep -v '^#' "$1" | grep -c . || true; }
manifest_bytes() { grep -v '^#' "$1" | awk '{ s += $2 } END { printf "%.0f\n", s }'; }
manifest_count() { grep -c "^$2/" "$1" || true; }

run_rsync() {
  if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -i "$RSYNC_BIN" "$@"
  else
    "$RSYNC_BIN" "$@"
  fi
}

# mark_freshness — best effort: a failed mark never fails the copy.
mark_freshness() {
  if [[ "$NO_MARK" == true ]]; then
    log "Freshness marker skipped (--no-mark)"
    return 0
  fi
  if [[ "$REPO" != "$DEFAULT_REPO" ]]; then
    log "Freshness marker skipped (non-default --repo)"
    return 0
  fi
  if remote "sudo -n /usr/local/bin/homelab-backup-mark restic-copy" < /dev/null; then
    log "Freshness marker recorded on ${HOST} (restic-copy)"
  else
    warn "could not record the freshness marker on ${HOST} (storage role not rolled out yet?) — later: ssh ${SSH_CONFIG:+-F ${SSH_CONFIG} }${HOST} sudo -n /usr/local/bin/homelab-backup-mark restic-copy"
  fi
}

# --- Main ------------------------------------------------------------------------------------
command -v ssh >/dev/null 2>&1 || die "ssh not found"
[[ -x "$RSYNC_BIN" ]] || die "${RSYNC_BIN} not found"
mkdir "$LOCAL_LOCK_DIR" 2>/dev/null || die "another copy-restic-repo.sh run is active (lock ${LOCAL_LOCK_DIR})"
LOCK_HELD=true
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/copy-restic-repo.XXXXXX")"

refuse_foreign_dirs
if [[ -e "$WORK_DIR" && ! -d "$WORK_DIR" ]]; then
  die "${WORK_DIR} exists and is not a directory"
fi

log "restic repository copy"
log "  run         ${RUN_TS}"
log "  source      ${HOST}:${REPO}"
log "  destination ${RUN_DIR}"
log "  retain      ${RETAIN}"
[[ "$DRY_RUN" == true ]] && log "  MODE        dry-run — nothing is copied, created or deleted"

# Preflight: access, tools, repository shape, clock.
log ""
log "== preflight =="
PREFLIGHT="${TMP_DIR}/preflight"
if ! remote "sh -s -- ${REPO}" > "$PREFLIGHT" <<'REMOTE'
repo="$1"
if ! sudo -n true 2>/dev/null; then echo "ERR passwordless sudo is not available"; exit 0; fi
for t in rsync flock timeout find sha256sum; do
  command -v "$t" >/dev/null 2>&1 || echo "ERR tool missing on the node: $t"
done
echo "NOW $(date +%H%M)"
if ! sudo -n test -f "$repo/config"; then echo "ERR $repo/config not found — not a restic repository"; exit 0; fi
for e in $(sudo -n find "$repo" -mindepth 1 -maxdepth 1 -printf '%f\n'); do
  case "$e" in
    config|data|index|keys|locks|snapshots) ;;
    *) echo "ERR unexpected entry in $repo: $e" ;;
  esac
done
echo "KEYS $(sudo -n find "$repo/keys" -type f 2>/dev/null | wc -l)"
echo "SNAPSHOTS $(sudo -n find "$repo/snapshots" -type f 2>/dev/null | wc -l)"
if sudo -n grep -q 'flock -n 9' /usr/local/bin/homelab-backup.sh 2>/dev/null; then
  echo "BACKUPLOCK yes"
else
  echo "BACKUPLOCK no"
fi
REMOTE
then
  die "cannot reach ${HOST} over SSH (on the LAN? off-LAN use --ssh-config ~/.ssh/homelab-offlan.conf)"
fi
if grep -q '^ERR ' "$PREFLIGHT"; then
  sed -n 's/^ERR /ERROR /p' "$PREFLIGHT" >&2
  exit 1
fi
# COPY_RESTIC_NOW_HHMM is a test hook for the time guard (it replaces the node clock); never
# set it for a real run — it can switch the 02:00-03:44 guard off.
NODE_NOW="${COPY_RESTIC_NOW_HHMM:-$(awk '$1 == "NOW" { print $2 }' "$PREFLIGHT")}"
[[ "$NODE_NOW" =~ ^[0-9]{4}$ ]] || die "could not read the node clock"
if (( 10#$NODE_NOW >= GUARD_FROM && 10#$NODE_NOW < GUARD_UNTIL )); then
  die "node clock reads ${NODE_NOW}: no copy between 02:00 and 03:44 (restic backup at 03:00)"
fi
PRE_KEYS="$(awk '$1 == "KEYS" { print $2 }' "$PREFLIGHT")"
PRE_SNAPSHOTS="$(awk '$1 == "SNAPSHOTS" { print $2 }' "$PREFLIGHT")"
if [[ "${PRE_KEYS:-0}" -lt 1 || "${PRE_SNAPSHOTS:-0}" -lt 1 ]]; then
  die "source has ${PRE_KEYS:-0} key file(s) and ${PRE_SNAPSHOTS:-0} snapshot file(s) — refusing to copy an empty repository"
fi
if ! grep -q '^BACKUPLOCK yes' "$PREFLIGHT"; then
  warn "/usr/local/bin/homelab-backup.sh on the node does not take the flock — the manifest comparison is the only guard against a concurrent backup"
fi
rc=0; lock_state || rc=$?
[[ "$rc" -eq 0 ]] || explain_remote_failure "$rc" "lock probe"
log "      node clock ${NODE_NOW}, ${PRE_KEYS} key file(s), ${PRE_SNAPSHOTS} snapshot file(s), backup lock free"

log ""
log "== source manifest (before) =="
BEFORE="${TMP_DIR}/before"
rc=0; remote_manifest "$BEFORE" || rc=$?
[[ "$rc" -eq 0 ]] || explain_remote_failure "$rc" "source manifest"
SRC_FILES="$(manifest_files "$BEFORE")"
SRC_BYTES="$(manifest_bytes "$BEFORE")"
log "      ${SRC_FILES} files, ${SRC_BYTES} bytes"
STALE_LOCKS="$(awk '$1 == "#stale-locks" { print $2 }' "$BEFORE")"
if [[ "${STALE_LOCKS:-0}" -gt 0 ]]; then
  warn "${STALE_LOCKS} restic lock file(s) older than ${FRESH_LOCK_MINUTES} min in ${REPO}/locks (not copied) — check with 'restic list locks' on the node"
fi

RSYNC_ARGS=(-rlpt --delete "--exclude=/locks/*" -e "$RSYNC_RSH"
  "--rsync-path=sudo -n timeout ${REMOTE_TIMEOUT} flock -s -n -E ${LOCK_BUSY_RC} ${REMOTE_LOCK} rsync"
  "${HOST}:${REPO}/" "${WORK_DIR}/repo/")

if [[ "$DRY_RUN" == true ]]; then
  log ""
  log "      [dry-run] mkdir -p ${WORK_DIR}/repo"
  log "      [dry-run] ${RSYNC_BIN} ${RSYNC_ARGS[*]}"
  log "      [dry-run] verify, write MANIFEST.txt, mv ${WORK_DIR} ${RUN_DIR}"
  log "      [dry-run] ssh ${HOST} sudo -n /usr/local/bin/homelab-backup-mark restic-copy (unless --no-mark)"
  count="$(list_copies | grep -c . || true)"
  excess=$(( count + 1 - RETAIN ))
  if [[ "$excess" -gt 0 ]]; then
    list_copies | sed -n "1,${excess}p" | while IFS= read -r old; do
      log "      [dry-run] rm -rf ${DEST}/${old}"
    done
  fi
  log "Dry run complete — nothing was written."
  exit 0
fi

# --- Copy ------------------------------------------------------------------------------------
if [[ ! -d "$DEST" ]]; then
  mkdir -p "$DEST"
  chmod 700 "$DEST"
fi
if [[ -d "$WORK_DIR" ]]; then
  log ""
  log "      resuming ${WORK_DIR} from an earlier run"
fi
mkdir -p "${WORK_DIR}/repo"   # mode 700 through umask 077

log ""
log "== copy =="
rc=0; run_rsync "${RSYNC_ARGS[@]}" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  lrc=0; lock_state || lrc=$?
  if [[ "$lrc" -eq "$LOCK_BUSY_RC" ]]; then
    explain_remote_failure "$lrc" "rsync"
  fi
  die "rsync failed (exit ${rc}); ${WORK_DIR} is kept, the next run resumes it"
fi

# --- Verify ----------------------------------------------------------------------------------
log ""
log "== verify =="
AFTER="${TMP_DIR}/after"
LOCAL="${TMP_DIR}/local"
rc=0; remote_manifest "$AFTER" || rc=$?
[[ "$rc" -eq 0 ]] || explain_remote_failure "$rc" "source manifest (after)"
if ! cmp -s <(grep -v '^#' "$BEFORE") <(grep -v '^#' "$AFTER"); then
  die "the source changed during the copy — run again (${WORK_DIR} is kept)"
fi
local_manifest "${WORK_DIR}/repo" "$LOCAL"
if ! cmp -s <(grep -v '^#' "$AFTER") "$LOCAL"; then
  diff <(grep -v '^#' "$AFTER") "$LOCAL" | head -n 20 >&2 || true
  die "the copy does not match the source file list and sizes (first differences above)"
fi
FILES="$(manifest_files "$LOCAL")"
BYTES="$(manifest_bytes "$LOCAL")"
log "      file list and sizes match the source: ${FILES} files, ${BYTES} bytes"

REMOTE_CONFIG_SHA="$(awk '$1 == "#config-sha256" { print $2 }' "$AFTER")"
LOCAL_CONFIG_SHA="$(shasum -a 256 "${WORK_DIR}/repo/config" | cut -d ' ' -f 1)"
[[ -n "$REMOTE_CONFIG_SHA" && "$REMOTE_CONFIG_SHA" == "$LOCAL_CONFIG_SHA" ]] \
  || die "config differs from the source"

HASHES="${TMP_DIR}/hashes"
( cd "${WORK_DIR}/repo" && find data index keys snapshots -type f -exec shasum -a 256 {} + ) > "$HASHES"
hash_ok=0; hash_bad=0; unexpected=0
while read -r sum path; do
  name="${path##*/}"
  if ! [[ "$name" =~ ^[0-9a-f]{64}$ ]]; then
    err "unexpected file in the copy: ${path}"
    unexpected=$(( unexpected + 1 ))
  elif [[ "$sum" == "$name" ]]; then
    hash_ok=$(( hash_ok + 1 ))
  else
    # rsync's quick check (size + mtime) would skip this file on the next run; remove it so the
    # resume fetches it again.
    err "content does not match its name: ${path} — removed from the copy"
    rm -f "${WORK_DIR}/repo/${path}"
    hash_bad=$(( hash_bad + 1 ))
  fi
done < "$HASHES"
if [[ "$hash_bad" -ne 0 || "$unexpected" -ne 0 ]]; then
  err "${hash_bad} damaged and ${unexpected} unexpected file(s); ${WORK_DIR} is kept and the next run re-fetches the damaged files"
  die "if the same file fails again, the source is damaged: run 'restic check --read-data' on raspi5 (DEPLOYMENT.md \"Backup (Restic)\")"
fi
if [[ $(( hash_ok + 1 )) -ne "$FILES" ]]; then
  die "hashed ${hash_ok} files + config, but the copy has ${FILES} files"
fi
log "      config identical; ${hash_ok}/${hash_ok} data, index, key and snapshot files match their SHA-256 names"

KEY_FILES="$(manifest_count "$LOCAL" keys)"
SNAPSHOT_FILES="$(manifest_count "$LOCAL" snapshots)"
INDEX_FILES="$(manifest_count "$LOCAL" index)"
DATA_FILES="$(manifest_count "$LOCAL" data)"
newest=0
for f in "${WORK_DIR}"/repo/snapshots/*; do
  [[ -f "$f" ]] || continue
  m="$(stat -f '%m' "$f")"
  if [[ "$m" -gt "$newest" ]]; then newest="$m"; fi
done
NEWEST_SNAPSHOT="$(date -r "$newest" '+%Y-%m-%d %H:%M:%S %Z')"

# Shrink guard against the newest copy that passed it (a tripped copy is never the baseline,
# so the guard keeps firing until --accept-shrink).
SHRUNK=false
SHRINK_STATE="ok"
PREVIOUS=""
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  case "$(manifest_value "${DEST}/${name}/MANIFEST.txt" shrink_guard)" in
    ok|accepted) PREVIOUS="$name" ;;
    *) ;;
  esac
done <<< "$(list_copies)"
if [[ -n "$PREVIOUS" ]]; then
  prev_snapshots="$(manifest_value "${DEST}/${PREVIOUS}/MANIFEST.txt" snapshot_files)"
  prev_bytes="$(manifest_value "${DEST}/${PREVIOUS}/MANIFEST.txt" bytes)"
  if [[ "$prev_snapshots" =~ ^[0-9]+$ && "$prev_bytes" =~ ^[0-9]+$ ]]; then
    if (( SNAPSHOT_FILES + MAX_SNAPSHOT_DROP < prev_snapshots )) || (( BYTES * 2 < prev_bytes )); then
      warn "source shrank since ${PREVIOUS}: snapshots ${prev_snapshots} -> ${SNAPSHOT_FILES}, bytes ${prev_bytes} -> ${BYTES}"
      if [[ "$ACCEPT_SHRINK" == true ]]; then
        SHRINK_STATE="accepted (vs ${PREVIOUS})"
      else
        SHRUNK=true
        SHRINK_STATE="TRIPPED (vs ${PREVIOUS})"
      fi
    fi
  else
    warn "could not read the totals of ${PREVIOUS}/MANIFEST.txt — shrink guard skipped"
  fi
fi

# --- Finish ----------------------------------------------------------------------------------
{
  printf '%s\n' "$MARKER"
  printf 'run              %s\n' "$RUN_TS"
  printf 'created          %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf 'host             %s\n' "$(hostname)"
  printf 'source           %s:%s\n' "$HOST" "$REPO"
  printf 'rsync            %s\n' "$("$RSYNC_BIN" --version 2>&1 | head -n 1)"
  printf 'files            %s\n' "$FILES"
  printf 'bytes            %s\n' "$BYTES"
  printf 'key_files        %s\n' "$KEY_FILES"
  printf 'snapshot_files   %s\n' "$SNAPSHOT_FILES"
  printf 'index_files      %s\n' "$INDEX_FILES"
  printf 'data_files       %s\n' "$DATA_FILES"
  printf 'newest_snapshot  %s\n' "$NEWEST_SNAPSHOT"
  printf 'file_list        identical to the source before and after the copy (path + size)\n'
  printf 'config           identical to the source (sha256)\n'
  printf 'content          %s/%s files match their SHA-256 names (data, index, keys, snapshots)\n' "$hash_ok" "$hash_ok"
  printf 'shrink_guard     %s\n' "$SHRINK_STATE"
} > "${WORK_DIR}/MANIFEST.txt"

[[ ! -e "$RUN_DIR" ]] || die "${RUN_DIR} already exists — not overwriting it (${WORK_DIR} is kept)"
mv "$WORK_DIR" "$RUN_DIR"
chmod 700 "$RUN_DIR"
log ""
log "Copy complete: ${RUN_DIR} (newest snapshot file ${NEWEST_SNAPSHOT})"

if [[ "$SHRUNK" == true ]]; then
  err "the source shrank — no older copy is pruned; check the repository on the node, then re-run with --accept-shrink if the shrink is intended"
  exit 2
fi

# --- Retention -------------------------------------------------------------------------------
count="$(list_copies | grep -c . || true)"
excess=$(( count - RETAIN ))
if [[ "$excess" -le 0 ]]; then
  log "Retention: ${count} copies, --retain ${RETAIN} not exceeded"
else
  log "Retention: ${count} copies, deleting the ${excess} oldest"
  { list_copies | grep -v -x "$RUN_TS" || true; } | sed -n "1,${excess}p" | while IFS= read -r old; do
    [[ -n "$old" ]] || continue
    log "  deleting ${DEST}/${old}"
    # Rename first: an interrupted delete must not leave a dated directory without MANIFEST.txt,
    # which refuse_foreign_dirs would then treat as a foreign directory on every later run.
    mv "${DEST}/${old}" "${DEST}/${old}.deleting"
    rm -rf "${DEST:?}/${old}.deleting"
  done
fi
# Leftovers of an interrupted delete — only this script's own <YYYY-MM-DD_HHMMSS>.deleting names.
find "${DEST}/" -mindepth 1 -maxdepth 1 -type d -name '*.deleting' -print | while IFS= read -r left; do
  base="${left##*/}"
  [[ "${base%.deleting}" =~ $RUN_DIR_PATTERN ]] || continue
  log "  removing leftover ${left}"
  rm -rf "${left:?}"
done
mark_freshness
exit 0
