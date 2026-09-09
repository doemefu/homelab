#!/usr/bin/env bash
# backup-app-data.sh — manual application-data backup of the homelab's stateful workloads (#64)
#
# Runs on the operator's Mac and writes one directory per run into a local backup folder.
# It automates the per-component procedure that DEPLOYMENT.md documents by hand under
# "Backup & rollback for image updates (Open WebUI, LiteLLM, n8n, PostgreSQL, cloudflared)" —
# same commands, same helper-pod pattern, but for every component in one go, with verification,
# checksums and retention.
#
# There is deliberately no Longhorn BackupTarget: Longhorn 1.7.2 mounts NFS backupstores as
# NFSv4 only and macOS ships no NFSv4 server, and no cloud target is wanted (owner decision,
# 2026-09-08). These dumps are the off-cluster copy; Longhorn's daily snapshots stay local.
#
# Usage:
#   ./scripts/backup-app-data.sh [--kubeconfig PATH] [--context NAME] [--dest DIR]
#                                [--retain N] [--only COMPONENT]... [--quiesce] [--dry-run]
#
# See DEPLOYMENT.md "App-data backups to the operator's Mac (#64)".

set -euo pipefail

# Every artifact can contain credentials or PII — never create them group/world readable.
umask 077

# --- Constants -------------------------------------------------------------------------------
readonly APPS_NS="apps"
readonly MONITORING_NS="monitoring"

# Same pinned helper image as the manual runbook in DEPLOYMENT.md.
readonly HELPER_IMAGE="busybox:1.37.0"

# Canonical component order. --only filters this list, it never reorders it.
readonly ALL_COMPONENTS="postgresql influxdb2 n8n open-webui mosquitto grafana"

readonly PG_POD="postgresql-0"
readonly PG_CONTAINER="postgresql"
# Databases are dumped individually on top of pg_dumpall (custom format = selective restore).
# The list is read from the server at runtime, so a database created later is never silently
# missed. Template databases and the "postgres" maintenance database are covered by pg_dumpall.
readonly PG_DATABASE_QUERY="SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'"

readonly INFLUX_POD="influxdb2-0"

# Run directories are named <YYYY-MM-DD_HHMMSS>. Retention only ever touches directories
# matching this pattern exactly, so anything else in --dest is safe.
readonly RUN_DIR_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$'

readonly HELPER_READY_TIMEOUT=120
readonly SCALE_DELETE_TIMEOUT=180

# Run lock. macOS ships bash 3.2 without flock, but mkdir is atomic — the directory is the lock.
readonly LOCK_DIR="${TMPDIR:-/tmp}/backup-app-data.lock"

# --- Options ---------------------------------------------------------------------------------
KUBECONFIG_PATH="${HOME}/.kube/homelab.yaml"
CONTEXT=""
DEST="${HOME}/informatik/homelab/backups"
RETAIN=5
QUIESCE=false
DRY_RUN=false
ONLY=""

usage() {
  cat <<'USAGE'
backup-app-data.sh — manual application-data backup of the homelab's stateful workloads (#64)

Dumps every stateful workload of the cluster into one timestamped directory on this Mac:
PostgreSQL, InfluxDB 2, n8n, Open WebUI, mosquitto and Grafana. Automates the per-component
runbook in DEPLOYMENT.md "Backup & rollback for image updates".

Options:
  --kubeconfig PATH   kubeconfig to use (default: $HOME/.kube/homelab.yaml)
  --context NAME      kubectl context to use (default: the kubeconfig's current context).
                      Use "tunnel" when off-LAN — see the note on stream sizes below.
  --dest DIR          backup root (default: $HOME/informatik/homelab/backups). Must be an
                      absolute path and may be neither / nor your home directory itself.
  --retain N          keep the N newest run directories, delete older ones (default: 5).
                      Pruning is skipped when the current run had any failure.
  --only COMPONENT    back up only this component; repeatable. One of:
                      postgresql influxdb2 n8n open-webui mosquitto grafana
  --quiesce           scale open-webui and n8n to 0 replicas while their PVC is archived and
                      scale them back to the previous replica count afterwards (always, even
                      on error or Ctrl-C). Both store SQLite databases, so without this their
                      archives are only crash-consistent.
  --dry-run           resolve pods/nodes read-only and print what would happen. Creates no
                      run directory, no helper pods, changes no replica counts, deletes
                      nothing.
  --help              show this help.

What lands in <dest>/<YYYY-MM-DD_HHMMSS>/:
  pg-dumpall.sql.gz          all databases, roles and grants (pg_dumpall --clean --if-exists)
  pg-<db>.dump               custom-format dump per database for selective pg_restore; the
                             database list is read from the server at run time
  influxdb2-backup.tgz       "influx backup" output (bolt + engine + SQL metadata store)
  n8n-workflows.json         all workflows (n8n export:workflow --all)
  n8n-credentials.json       all credentials, ENCRYPTED — restoring them needs the same
                             N8N_ENCRYPTION_KEY (Secret n8n-secrets, SOPS). Never rotate that
                             key between backup and restore.
  n8n-data.tgz               full n8n PVC (the n8n image has no tar, so a helper pod does it)
  open-webui-data.tgz        full Open WebUI PVC (webui.db + vector_db + uploads)
  mosquitto.db               persistence DB, flushed with kill -USR1 first
  grafana-data.tgz           full Grafana PVC (dashboards, users, grafana.db)
  MANIFEST.txt               run metadata plus one row per artifact
  SHA256SUMS                 shasum -a 256 over every artifact and MANIFEST.txt

Consistency:
  - pg_dumpall / pg_dump / influx backup / n8n export are application-consistent.
  - The .tgz PVC archives are crash-consistent unless --quiesce is used.
  - mosquitto.db is flushed with kill -USR1 before it is copied.

Where to run it:
  On the LAN. n8n-data.tgz and open-webui-data.tgz are hundreds of megabytes to a few
  gigabytes; streaming those through the Cloudflare Tunnel port-forward has timed out before.
  Off-LAN (--context tunnel) the small components work fine; the big archives may not.
  Helper pods sleep for 4 hours, so a single PVC archive must finish inside that window.

After the first run:
  Check the run directory by hand once — "ls -l <dest>/<run>" for plausible sizes, and open
  n8n-workflows.json to confirm the export really contains every workflow.

What this does NOT do:
  - It is not off-site: the dumps sit in the same flat as the cluster.
  - It does not replace Longhorn's daily local snapshots (02:00, retain 7) — those are the
    fast whole-volume rollback path and stay on the cluster's own disks.
  - There is no Longhorn BackupTarget: Longhorn 1.7.2 mounts NFS backupstores as NFSv4 only,
    macOS has no NFSv4 server, and no cloud target is wanted (owner decision 2026-09-08).
  - Secrets stored in Kubernetes are not dumped here; restic on raspi5 covers the k3s
    datastore (see DEPLOYMENT.md "Backup (Restic)").

Retention:
  Only directories directly under --dest whose name matches YYYY-MM-DD_HHMMSS and that contain
  SHA256SUMS are considered, oldest first, and only when the run finished without failures.
  An interrupted run is renamed to <run>.incomplete and is neither counted nor deleted — check
  and remove those by hand.

Exit status: 0 when every selected component succeeded, 1 otherwise.
USAGE
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; }
err()  { printf 'ERROR %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
plan() { printf '      [dry-run] %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)
      [[ $# -ge 2 ]] || die "--kubeconfig needs a value"
      KUBECONFIG_PATH="$2"; shift 2 ;;
    --context)
      [[ $# -ge 2 ]] || die "--context needs a value"
      CONTEXT="$2"; shift 2 ;;
    --dest)
      [[ $# -ge 2 ]] || die "--dest needs a value"
      DEST="$2"; shift 2 ;;
    --retain)
      [[ $# -ge 2 ]] || die "--retain needs a value"
      RETAIN="$2"; shift 2 ;;
    --only)
      [[ $# -ge 2 ]] || die "--only needs a value"
      ONLY="${ONLY} $2"; shift 2 ;;
    --quiesce)  QUIESCE=true; shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --help|-h)  usage; exit 0 ;;
    *)          err "unknown option: $1"; echo; usage; exit 1 ;;
  esac
done

if ! [[ "$RETAIN" =~ ^[1-9][0-9]*$ ]]; then
  die "--retain must be a positive integer, got: $RETAIN"
fi
[[ -n "$DEST" ]] || die "--dest must not be empty"
# Run directories are created inside --dest and retention deletes directories under it, so
# accept only a real, dedicated absolute path.
[[ "$DEST" == /* ]] || die "--dest must be an absolute path, got: $DEST"
case "$DEST" in
  /|"$HOME"|"${HOME}/") die "--dest must not be / or your home directory, got: $DEST" ;;
esac
# "." and ".." components would let --dest resolve somewhere else (e.g. "$HOME/backups/.."
# is $HOME), so reject them instead of trying to normalise the path.
case "/${DEST}/" in
  */./*|*/../*) die "--dest must not contain . or .. path components, got: $DEST" ;;
esac

COMPONENTS=""
if [[ -z "${ONLY// /}" ]]; then
  COMPONENTS="$ALL_COMPONENTS"
else
  for requested in $ONLY; do
    case " ${ALL_COMPONENTS} " in
      *" ${requested} "*) ;;
      *) die "unknown component: ${requested} (valid: ${ALL_COMPONENTS})" ;;
    esac
  done
  # Keep the canonical order regardless of the order the flags were given in.
  for known in $ALL_COMPONENTS; do
    case " ${ONLY} " in
      *" ${known} "*) COMPONENTS="${COMPONENTS} ${known}" ;;
      *) ;;
    esac
  done
fi

COMPONENTS="${COMPONENTS# }"

KUBECTL=(kubectl --kubeconfig "$KUBECONFIG_PATH")
if [[ -n "$CONTEXT" ]]; then
  KUBECTL+=(--context "$CONTEXT")
fi

# Control-plane calls: bounded, so a dead API server fails fast instead of hanging.
kc() { "${KUBECTL[@]}" --request-timeout=30s "$@"; }
# Streaming calls (exec, cp, wait): no request timeout, they legitimately run for minutes.
kcl() { "${KUBECTL[@]}" "$@"; }

RUN_TS="$(date +%Y-%m-%d_%H%M%S)"
POD_TS="$(date +%Y%m%d%H%M%S)"
RUN_DIR="${DEST}/${RUN_TS}"

HELPER_PODS=()
SCALED=()
ARTIFACTS=()
COMP_RESULTS=""
FAILED=0
LOCK_HELD=false

# --- Cleanup ---------------------------------------------------------------------------------
restore_scales() {
  local entry ns rest name reps
  local remaining=()
  if [[ ${#SCALED[@]} -eq 0 ]]; then
    return 0
  fi
  for entry in "${SCALED[@]}"; do
    ns="${entry%%/*}"; rest="${entry#*/}"; name="${rest%%/*}"; reps="${rest##*/}"
    if kc -n "$ns" scale "deploy/${name}" --replicas="$reps" >/dev/null 2>&1; then
      log "      restored ${ns}/${name} to ${reps} replicas"
    else
      warn "could not scale ${ns}/${name} back to ${reps} replicas — do it by hand"
      FAILED=1
      remaining+=("$entry")
    fi
  done
  # Drop everything that is back up so neither a later component nor the EXIT trap scales it
  # a second time; only deployments that could not be restored stay on the list.
  SCALED=()
  if [[ ${#remaining[@]} -gt 0 ]]; then
    SCALED=("${remaining[@]}")
  fi
}

# A run is complete once SHA256SUMS exists. Anything else (crash, Ctrl-C, aborted stream)
# leaves a partially written directory — rename it instead of deleting it, so retention skips
# it and the operator decides what to keep.
mark_incomplete() {
  if [[ "$DRY_RUN" == true ]] || [[ ! -d "$RUN_DIR" ]] || [[ -f "${RUN_DIR}/SHA256SUMS" ]]; then
    return 0
  fi
  if [[ -e "${RUN_DIR}.incomplete" ]]; then
    warn "incomplete run left at ${RUN_DIR} (${RUN_DIR}.incomplete exists) — delete it by hand"
    return 0
  fi
  if mv "$RUN_DIR" "${RUN_DIR}.incomplete"; then
    warn "incomplete run — renamed to ${RUN_DIR}.incomplete; check and delete it by hand"
  else
    warn "incomplete run at ${RUN_DIR} could not be renamed — check and delete it by hand"
  fi
}

cleanup() {
  local entry ns name
  if [[ ${#HELPER_PODS[@]} -gt 0 ]]; then
    for entry in "${HELPER_PODS[@]}"; do
      ns="${entry%%/*}"; name="${entry#*/}"
      kc -n "$ns" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done
  fi
  restore_scales
  mark_incomplete
  if [[ "$LOCK_HELD" == true ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'err "interrupted — cleaning up"; exit 130' INT TERM

# --- Bookkeeping -----------------------------------------------------------------------------
record() { ARTIFACTS+=("$1|$2|$3|$4"); }

# reject <component> <path> <reason> — a corrupt artifact is deleted so that a later run,
# a restore or the checksum file can never treat a partial download as a usable backup.
reject() {
  local comp="$1" path="$2" reason="$3"
  err "$(basename "$path") ${reason} — deleting it"
  record "$comp" "$(basename "$path")" "0" "FAILED"
  rm -f "$path"
}

# verify_artifact <component> <path> <gzip|tgz|pgdump|json|raw>
verify_artifact() {
  local comp="$1" path="$2" kind="$3" base bytes
  base="$(basename "$path")"
  if [[ "$DRY_RUN" == true ]]; then
    record "$comp" "$base" "-" "PLANNED"
    return 0
  fi
  if [[ ! -s "$path" ]]; then
    err "${base} is missing or empty"
    record "$comp" "$base" "0" "FAILED"
    rm -f "$path"
    return 1
  fi
  case "$kind" in
    gzip)
      if ! gzip -t "$path" 2>/dev/null; then
        reject "$comp" "$path" "is not a valid gzip stream"; return 1
      fi ;;
    tgz)
      if ! tar -tzf "$path" >/dev/null 2>&1; then
        reject "$comp" "$path" "is not a readable tar.gz archive"; return 1
      fi ;;
    pgdump)
      if [[ "$(head -c 5 "$path")" != "PGDMP" ]]; then
        reject "$comp" "$path" "does not start with the PGDMP custom-format magic"; return 1
      fi ;;
    json)
      case "$(head -c 1 "$path")" in
        "["|"{") ;;
        *) reject "$comp" "$path" "does not look like JSON"; return 1 ;;
      esac ;;
    raw) ;;
    *) err "internal: unknown verification kind ${kind}"; return 1 ;;
  esac
  bytes="$(wc -c < "$path" | tr -d ' ')"
  record "$comp" "$base" "$bytes" "OK"
  log "      ${base} (${bytes} bytes) verified"
  return 0
}

# --- kubectl building blocks -----------------------------------------------------------------
# stream_to_file <dest> <kubectl args...>
stream_to_file() {
  local dest="$1"; shift
  if [[ "$DRY_RUN" == true ]]; then
    plan "kubectl $* > $(basename "$dest")"
    return 0
  fi
  if ! kcl "$@" > "$dest"; then
    err "kubectl $* failed"
    rm -f "$dest"
    return 1
  fi
}

# stream_gzip_to_file <dest> <kubectl args...> — same, but gzips the stream locally.
stream_gzip_to_file() {
  local dest="$1"; shift
  if [[ "$DRY_RUN" == true ]]; then
    plan "kubectl $* | gzip > $(basename "$dest")"
    return 0
  fi
  if ! kcl "$@" | gzip > "$dest"; then
    err "kubectl $* failed"
    rm -f "$dest"
    return 1
  fi
}

resolve_pod() {
  local ns="$1" selector="$2" pod
  pod="$(kc -n "$ns" get pod -l "$selector" --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$pod" ]]; then
    err "no pod found in namespace ${ns} for selector ${selector}"
    return 1
  fi
  printf '%s' "$pod"
}

resolve_node() {
  local ns="$1" pod="$2" node
  node="$(kc -n "$ns" get pod "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  if [[ -z "$node" ]]; then
    err "could not resolve the node of pod ${ns}/${pod}"
    return 1
  fi
  printf '%s' "$node"
}

# quiesce_deploy <ns> <deployment> <pod selector>
quiesce_deploy() {
  local ns="$1" name="$2" selector="$3" reps
  reps="$(kc -n "$ns" get deploy "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  # Never guess the replica count: scaling to 0 without knowing what to scale back to would
  # leave the workload down.
  if [[ -z "$reps" ]]; then
    err "could not read .spec.replicas of ${ns}/${name} — refusing to scale it down"
    return 1
  fi
  if [[ "$DRY_RUN" == true ]]; then
    plan "kubectl -n ${ns} scale deploy/${name} --replicas=0 (restored to ${reps} afterwards)"
    return 0
  fi
  log "      quiescing ${ns}/${name} (${reps} -> 0 replicas)"
  SCALED+=("${ns}/${name}/${reps}")
  if ! kc -n "$ns" scale "deploy/${name}" --replicas=0 >/dev/null; then
    err "could not scale ${ns}/${name} to 0"
    return 1
  fi
  if ! kcl -n "$ns" wait --for=delete pod -l "$selector" \
       --timeout="${SCALE_DELETE_TIMEOUT}s" >/dev/null; then
    err "pods of ${ns}/${name} did not terminate within ${SCALE_DELETE_TIMEOUT}s"
    return 1
  fi
}

# helper_pod_tar <component> <ns> <claim> <node> <dest>
# Longhorn PVCs are RWO: the helper must land on the node that currently holds the volume,
# which is the node the workload pod runs (or last ran) on.
helper_pod_tar() {
  local comp="$1" ns="$2" claim="$3" node="$4" dest="$5" name overrides
  name="backup-helper-${comp}-${POD_TS}"
  overrides="$(printf '{"spec":{"nodeName":"%s","containers":[{"name":"helper","image":"%s","command":["sleep","14400"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"%s"}}]}}' \
    "$node" "$HELPER_IMAGE" "$claim")"

  if [[ "$DRY_RUN" == true ]]; then
    plan "kubectl -n ${ns} run ${name} --image=${HELPER_IMAGE} on node ${node}, PVC ${claim}"
    plan "kubectl -n ${ns} exec ${name} -c helper -- tar czf - -C /data . > $(basename "$dest")"
    plan "kubectl -n ${ns} delete pod ${name}"
    return 0
  fi

  log "      helper pod ${name} on node ${node} (PVC ${claim})"
  # Register before creating it: if the client times out after the API server already created
  # the pod, cleanup must still delete it.
  HELPER_PODS+=("${ns}/${name}")
  if ! kc -n "$ns" run "$name" --image="$HELPER_IMAGE" --restart=Never \
       --override-type=merge --overrides="$overrides" >/dev/null; then
    err "could not create helper pod ${ns}/${name}"
    return 1
  fi

  if ! kcl -n "$ns" wait --for=condition=Ready "pod/${name}" \
       --timeout="${HELPER_READY_TIMEOUT}s" >/dev/null; then
    err "helper pod ${ns}/${name} was not ready within ${HELPER_READY_TIMEOUT}s"
    return 1
  fi

  local rc=0
  kcl -n "$ns" exec "$name" -c helper -- tar czf - -C /data . > "$dest" || rc=1
  kc -n "$ns" delete pod "$name" --grace-period=1 >/dev/null 2>&1 || true
  if [[ "$rc" -ne 0 ]]; then
    err "tar of PVC ${claim} failed"
    rm -f "$dest"
    return 1
  fi
}

# --- Components ------------------------------------------------------------------------------
comp_postgresql() {
  local rc=0 db db_list
  local databases=()
  log "      pg_dumpall (all databases, roles and grants)"
  # The password is expanded inside the pod only; it never reaches this shell or any log line.
  # shellcheck disable=SC2016  # $POSTGRES_PASSWORD must be expanded by the pod's shell
  if stream_gzip_to_file "${RUN_DIR}/pg-dumpall.sql.gz" \
       exec -n "$APPS_NS" "$PG_POD" -c "$PG_CONTAINER" -- \
       sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dumpall -U postgres --clean --if-exists'; then
    verify_artifact postgresql "${RUN_DIR}/pg-dumpall.sql.gz" gzip || rc=1
  else
    record postgresql "pg-dumpall.sql.gz" "0" "FAILED"; rc=1
  fi

  if [[ "$DRY_RUN" == true ]]; then
    plan "kubectl exec ${PG_POD} -- psql -Atc \"${PG_DATABASE_QUERY}\""
    plan "kubectl exec ${PG_POD} -- pg_dump -Fc <db> > pg-<db>.dump   (one per database)"
    verify_artifact postgresql "${RUN_DIR}/pg-<db>.dump" pgdump
    return "$rc"
  fi

  # The database list comes from the server, never from a hard-coded list in this script.
  # shellcheck disable=SC2016  # $POSTGRES_PASSWORD must be expanded by the pod's shell
  if ! db_list="$(kcl exec -n "$APPS_NS" "$PG_POD" -c "$PG_CONTAINER" -- \
       sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -Atc "$1"' sh "$PG_DATABASE_QUERY")"; then
    err "could not read the database list from ${PG_POD}"
    record postgresql "pg-<db>.dump" "0" "FAILED"
    return 1
  fi
  while IFS= read -r db; do
    db="$(printf '%s' "$db" | tr -d '\r')"
    [[ -n "$db" ]] || continue
    databases+=("$db")
  done <<< "$db_list"
  if [[ ${#databases[@]} -eq 0 ]]; then
    err "the database list from ${PG_POD} is empty"
    record postgresql "pg-<db>.dump" "0" "FAILED"
    return 1
  fi

  for db in "${databases[@]}"; do
    log "      pg_dump -Fc ${db}"
    # shellcheck disable=SC2016  # $POSTGRES_PASSWORD must be expanded by the pod's shell
    if stream_to_file "${RUN_DIR}/pg-${db}.dump" \
         exec -n "$APPS_NS" "$PG_POD" -c "$PG_CONTAINER" -- \
         sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -Fc -U postgres "$1"' sh "$db"; then
      verify_artifact postgresql "${RUN_DIR}/pg-${db}.dump" pgdump || rc=1
    else
      record postgresql "pg-${db}.dump" "0" "FAILED"; rc=1
    fi
  done
  return "$rc"
}

comp_influxdb2() {
  log "      influx backup (bolt + engine + SQL metadata store)"
  # `influx backup` exits 0 even when the server answers 404 for a shard (it logs
  # "Shard N removed during backup" and drops it), so the archive is only trusted when every
  # shard directory on disk has a matching shard archive in the backup. Precreated but still
  # empty shard groups have no directory and are expected to be skipped.
  # shellcheck disable=SC2016  # the admin token and the engine path must be expanded by the pod's shell
  if ! stream_to_file "${RUN_DIR}/influxdb2-backup.tgz" \
       exec -n "$APPS_NS" "$INFLUX_POD" -- sh -c 'set -e; engine="${INFLUXD_ENGINE_PATH:-/var/lib/influxdb2/engine}/data"; [ -d "$engine" ] || { echo "influx backup: engine data dir $engine not found" >&2; exit 1; }; rm -rf /tmp/influx-backup; influx backup /tmp/influx-backup --token "$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN" >/dev/null; [ -d /tmp/influx-backup ] && ls /tmp/influx-backup/*.manifest >/dev/null 2>&1 || { echo "influx backup: no backup manifest written" >&2; exit 1; }; on_disk=$(find "$engine" -mindepth 3 -maxdepth 3 -type d -path "*/autogen/*" -print | wc -l); in_backup=$(find /tmp/influx-backup -maxdepth 1 -name "*.tar.gz" -print | wc -l); echo "influx backup: ${on_disk} shard(s) on disk, ${in_backup} in the backup" >&2; [ "$on_disk" -eq "$in_backup" ] || { echo "influx backup incomplete: shard count mismatch" >&2; exit 1; }; tar czf - -C /tmp influx-backup; rm -rf /tmp/influx-backup'; then
    record influxdb2 "influxdb2-backup.tgz" "0" "FAILED"
    return 1
  fi
  verify_artifact influxdb2 "${RUN_DIR}/influxdb2-backup.tgz" tgz
}

comp_n8n() {
  local rc=0 pod node
  pod="$(resolve_pod "$APPS_NS" app=n8n)" || return 1
  node="$(resolve_node "$APPS_NS" "$pod")" || return 1
  log "      pod ${pod} on node ${node}"

  # Exports need a running pod, so they run before any quiescing.
  # Credentials stay encrypted (never pass --decrypted): restoring them requires the same
  # N8N_ENCRYPTION_KEY from the n8n-secrets Secret (SOPS).
  n8n_export "$pod" workflow  "${RUN_DIR}/n8n-workflows.json"   || rc=1
  n8n_export "$pod" credentials "${RUN_DIR}/n8n-credentials.json" || rc=1

  if [[ "$QUIESCE" == true ]]; then
    if ! quiesce_deploy "$APPS_NS" n8n app=n8n; then
      restore_scales
      return 1
    fi
  else
    warn "n8n-data.tgz will be crash-consistent (SQLite) — use --quiesce for a clean archive"
  fi

  # The n8n image has no tar, so the PVC is archived through a helper pod.
  if helper_pod_tar n8n "$APPS_NS" n8n-data "$node" "${RUN_DIR}/n8n-data.tgz"; then
    verify_artifact n8n "${RUN_DIR}/n8n-data.tgz" tgz || rc=1
  else
    record n8n "n8n-data.tgz" "0" "FAILED"; rc=1
  fi
  restore_scales
  return "$rc"
}

# n8n_export <pod> <workflow|credentials> <dest>
n8n_export() {
  local pod="$1" kind="$2" dest="$3" remote
  remote="/tmp/$(basename "$dest")"
  log "      n8n export:${kind} --all"
  if [[ "$DRY_RUN" == true ]]; then
    plan "kubectl -n ${APPS_NS} exec ${pod} -- n8n export:${kind} --all --output=${remote}"
    plan "kubectl -n ${APPS_NS} exec ${pod} -- cat ${remote} > $(basename "$dest")"
    verify_artifact n8n "$dest" json
    return 0
  fi
  if ! kcl -n "$APPS_NS" exec "$pod" -- \
       n8n "export:${kind}" --all "--output=${remote}" >/dev/null; then
    err "n8n export:${kind} failed"
    record n8n "$(basename "$dest")" "0" "FAILED"
    return 1
  fi
  local rc=0
  stream_to_file "$dest" exec -n "$APPS_NS" "$pod" -- cat "$remote" || rc=1
  kcl -n "$APPS_NS" exec "$pod" -- rm -f "$remote" >/dev/null 2>&1 || true
  if [[ "$rc" -ne 0 ]]; then
    record n8n "$(basename "$dest")" "0" "FAILED"
    return 1
  fi
  verify_artifact n8n "$dest" json
}

comp_open_webui() {
  local pod node
  pod="$(resolve_pod "$APPS_NS" app=open-webui)" || return 1
  node="$(resolve_node "$APPS_NS" "$pod")" || return 1
  log "      pod ${pod} on node ${node}"

  if [[ "$QUIESCE" == true ]]; then
    if ! quiesce_deploy "$APPS_NS" open-webui app=open-webui; then
      restore_scales
      return 1
    fi
  else
    warn "open-webui-data.tgz will be crash-consistent (SQLite + vector_db) — use --quiesce"
  fi

  local rc=0
  if helper_pod_tar open-webui "$APPS_NS" open-webui-data "$node" \
       "${RUN_DIR}/open-webui-data.tgz"; then
    verify_artifact open-webui "${RUN_DIR}/open-webui-data.tgz" tgz || rc=1
  else
    record open-webui "open-webui-data.tgz" "0" "FAILED"; rc=1
  fi
  restore_scales
  return "$rc"
}

comp_mosquitto() {
  local pod
  pod="$(resolve_pod "$APPS_NS" app=mosquitto)" || return 1
  log "      pod ${pod}"
  if [[ "$DRY_RUN" == true ]]; then
    plan "kubectl -n ${APPS_NS} exec ${pod} -- kill -USR1 1   (flush persistence)"
    plan "kubectl -n ${APPS_NS} cp ${APPS_NS}/${pod}:/mosquitto/data/mosquitto.db mosquitto.db"
    verify_artifact mosquitto "${RUN_DIR}/mosquitto.db" raw
    return 0
  fi
  # mosquitto writes mosquitto.db only periodically / on shutdown — force a save first.
  if ! kcl -n "$APPS_NS" exec "$pod" -- kill -USR1 1 >/dev/null; then
    err "could not signal mosquitto to flush its persistence DB"
    record mosquitto "mosquitto.db" "0" "FAILED"
    return 1
  fi
  sleep 2
  if ! kcl cp "${APPS_NS}/${pod}:/mosquitto/data/mosquitto.db" "${RUN_DIR}/mosquitto.db"; then
    err "kubectl cp of mosquitto.db failed"
    record mosquitto "mosquitto.db" "0" "FAILED"
    return 1
  fi
  verify_artifact mosquitto "${RUN_DIR}/mosquitto.db" raw
}

comp_grafana() {
  local pod node
  pod="$(resolve_pod "$MONITORING_NS" app.kubernetes.io/name=grafana)" || return 1
  node="$(resolve_node "$MONITORING_NS" "$pod")" || return 1
  log "      pod ${pod} on node ${node}"
  if helper_pod_tar grafana "$MONITORING_NS" kube-prometheus-stack-grafana "$node" \
       "${RUN_DIR}/grafana-data.tgz"; then
    verify_artifact grafana "${RUN_DIR}/grafana-data.tgz" tgz
  else
    record grafana "grafana-data.tgz" "0" "FAILED"
    return 1
  fi
}

# --- Manifest, checksums, retention ----------------------------------------------------------
write_manifest() {
  local entry comp name bytes status manifest="${RUN_DIR}/MANIFEST.txt"
  {
    printf 'homelab app-data backup\n'
    printf 'run          %s\n' "$RUN_TS"
    printf 'created      %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'host         %s\n' "$(hostname)"
    printf 'kubeconfig   %s\n' "$KUBECONFIG_PATH"
    printf 'context      %s\n' "$CONTEXT_NAME"
    printf 'components   %s\n' "$COMPONENTS"
    printf 'quiesce      %s\n' "$QUIESCE"
    printf 'retain       %s\n' "$RETAIN"
    printf '\n'
    printf '%-12s %-26s %14s  %s\n' COMPONENT ARTIFACT BYTES STATUS
    if [[ ${#ARTIFACTS[@]} -gt 0 ]]; then
      for entry in "${ARTIFACTS[@]}"; do
        comp="${entry%%|*}"; entry="${entry#*|}"
        name="${entry%%|*}"; entry="${entry#*|}"
        bytes="${entry%%|*}"; status="${entry##*|}"
        printf '%-12s %-26s %14s  %s\n' "$comp" "$name" "$bytes" "$status"
      done
    fi
  } > "$manifest"
}

write_checksums() {
  local entry name status names=()
  if [[ ${#ARTIFACTS[@]} -gt 0 ]]; then
    for entry in "${ARTIFACTS[@]}"; do
      entry="${entry#*|}"
      name="${entry%%|*}"
      status="${entry##*|}"
      if [[ "$status" == "OK" && -f "${RUN_DIR}/${name}" ]]; then
        names+=("$name")
      fi
    done
  fi
  names+=("MANIFEST.txt")
  ( cd "$RUN_DIR" && shasum -a 256 "${names[@]}" > SHA256SUMS )
}

prune_runs() {
  local candidates existing="" count excess dir incomplete dry_note=""
  incomplete="$(find "$DEST" -mindepth 1 -maxdepth 1 -type d -name '*.incomplete' -print 2>/dev/null \
    | grep -c . || true)"
  if [[ "$incomplete" -gt 0 ]]; then
    warn "${incomplete} incomplete run(s) in ${DEST} — never counted, never pruned; delete by hand"
  fi
  if [[ "$FAILED" -ne 0 ]]; then
    warn "run had failures — skipping retention pruning"
    return 0
  fi
  candidates="$(find "$DEST" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
    | sed 's#.*/##' | grep -E "$RUN_DIR_PATTERN" | sort || true)"
  # Only complete runs (SHA256SUMS present) count against --retain and may be deleted.
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    if [[ -f "${DEST}/${dir}/SHA256SUMS" ]]; then
      existing="${existing}${dir}"$'\n'
    fi
  done <<< "$candidates"
  count="$(printf '%s' "$existing" | grep -c . || true)"
  if [[ "$DRY_RUN" == true ]]; then
    # The directory of this run does not exist in dry-run mode — count it anyway.
    count=$(( count + 1 ))
    dry_note=" (+1 for this run)"
  fi
  excess=$(( count - RETAIN ))
  if [[ "$excess" -le 0 ]]; then
    log "Retention: ${count} complete run(s)${dry_note}, --retain ${RETAIN} not exceeded"
    return 0
  fi
  log "Retention: ${count} complete run(s)${dry_note}, deleting the ${excess} oldest"
  printf '%s\n' "$existing" | sed -n "1,${excess}p" | while IFS= read -r dir; do
    [[ -n "$dir" && -d "${DEST}/${dir}" ]] || continue
    if [[ "$DRY_RUN" == true ]]; then
      plan "rm -rf ${DEST}/${dir}"
    else
      log "  deleting ${DEST}/${dir}"
      rm -rf "${DEST:?}/${dir}"
    fi
  done
}

# --- Main ------------------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[[ -r "$KUBECONFIG_PATH" ]] || die "kubeconfig not readable: ${KUBECONFIG_PATH}"
mkdir "$LOCK_DIR" 2>/dev/null || die "another backup-app-data.sh run is active (lock $LOCK_DIR)"
LOCK_HELD=true
kc get namespace "$APPS_NS" -o name >/dev/null 2>&1 \
  || die "cannot reach the cluster (kubeconfig: ${KUBECONFIG_PATH}, context: ${CONTEXT:-current})"
CONTEXT_NAME="${CONTEXT:-$(kc config current-context 2>/dev/null || echo unknown)}"

log "homelab app-data backup"
log "  run         ${RUN_TS}"
log "  destination ${RUN_DIR}"
log "  context     ${CONTEXT_NAME}"
log "  components  ${COMPONENTS}"
log "  quiesce     ${QUIESCE}"
log "  retain      ${RETAIN}"
if [[ "$DRY_RUN" == true ]]; then
  log "  MODE        dry-run — nothing is created, scaled or deleted"
else
  # Only tighten what this script creates: an existing --dest keeps the mode it has.
  if [[ ! -d "$DEST" ]]; then
    mkdir -p "$DEST"
    chmod 700 "$DEST"
  fi
  mkdir -m 700 "$RUN_DIR"
fi

for component in $COMPONENTS; do
  log ""
  log "== ${component} =="
  component_fn="comp_$(printf '%s' "$component" | tr '-' '_')"
  if "$component_fn"; then
    COMP_RESULTS="${COMP_RESULTS}${component}|OK"$'\n'
  else
    COMP_RESULTS="${COMP_RESULTS}${component}|FAILED"$'\n'
    FAILED=1
    err "component ${component} failed — continuing with the next one"
  fi
done

log ""
if [[ "$DRY_RUN" != true ]]; then
  write_manifest
  write_checksums
fi

log "Summary"
log "-------"
printf '%-12s %-26s %14s  %s\n' COMPONENT ARTIFACT BYTES STATUS
if [[ ${#ARTIFACTS[@]} -gt 0 ]]; then
  for artifact in "${ARTIFACTS[@]}"; do
    a_comp="${artifact%%|*}"; artifact="${artifact#*|}"
    a_name="${artifact%%|*}"; artifact="${artifact#*|}"
    a_bytes="${artifact%%|*}"; a_status="${artifact##*|}"
    printf '%-12s %-26s %14s  %s\n' "$a_comp" "$a_name" "$a_bytes" "$a_status"
  done
fi
log ""
log ""
log "Components: $(printf '%s' "$COMP_RESULTS" | tr '|' '=' | tr '\n' ' ')"
log ""

prune_runs

if [[ "$FAILED" -ne 0 ]]; then
  err "at least one component failed — see above"
  exit 1
fi
if [[ "$DRY_RUN" == true ]]; then
  log "Dry run complete — nothing was written."
else
  log "Backup complete: ${RUN_DIR}"
fi
