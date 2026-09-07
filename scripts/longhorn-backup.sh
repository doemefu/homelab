#!/usr/bin/env bash
# longhorn-backup.sh — manual off-cluster backup of the homelab's Longhorn volumes (#64)
#
# Runs on the operator's Mac, which also hosts the NFS export that Longhorn uses as its
# BackupTarget. There is deliberately no `backup` RecurringJob on the cluster: the Mac is not
# always on, so backups are triggered by hand with this script.
#
# Usage:
#   ./scripts/longhorn-backup.sh [--kubeconfig PATH] [--retain N] [--pvc ns/name]...
#                                [--keep-snapshot] [--dry-run] [--help]
#
# See DEPLOYMENT.md "Off-cluster backups (Longhorn BackupTarget)" for the export setup,
# verification steps and the restore procedure.

set -euo pipefail

# --- Constants -------------------------------------------------------------------------------
# Must stay in sync with defaultSettings.backupTarget in cluster/values/longhorn.yaml.
readonly BACKUP_TARGET_URL="nfs://192.168.1.78:/Users/dominic/informatik/homelab/backups/longhorn"
readonly LONGHORN_NS="longhorn-system"

# Kubernetes labels. `backup-volume` is not ours: longhorn-manager v1.7.2 resolves the volume of
# a Backup CR exclusively from this metadata label (controller/backup_controller.go
# getBackupVolumeName -> types.LonghornLabelBackupVolume = "backup-volume"), so a hand-created
# Backup CR without it is silently ignored by the controller.
readonly LABEL_VOLUME="backup-volume"
readonly LABEL_MANUAL="homelab.furchert.ch/manual-backup"
readonly LABEL_PVC="homelab.furchert.ch/pvc"

# Timeouts (seconds).
readonly POLL_INTERVAL=10
readonly TARGET_TIMEOUT=330      # Longhorn re-polls the backup target every 300 s
readonly SNAPSHOT_TIMEOUT=300
readonly BACKUP_TIMEOUT=3600     # per volume; the whole set is ~5.7 GB over the LAN
readonly PROGRESS_EVERY=30

# The default backup set. Deliberately does NOT include the Prometheus TSDB
# (prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0,
# 20 Gi / ~35 GB actual): it is fully regenerable, has 14 d retention anyway, and would dominate
# both the transfer time and the space on the Mac. Add it explicitly with --pvc if ever needed.
DEFAULT_PVCS=(
  "apps/data-postgresql-0"
  "apps/influxdb2"
  "apps/mosquitto-data"
  "apps/n8n-data"
  "apps/open-webui-data"
  "monitoring/kube-prometheus-stack-grafana"
)

# --- Options ---------------------------------------------------------------------------------
KUBECONFIG_PATH="${HOME}/.kube/homelab.yaml"
RETAIN=7
KEEP_SNAPSHOT=false
DRY_RUN=false
PVCS=()

usage() {
  cat <<'USAGE'
longhorn-backup.sh — manual off-cluster backup of the homelab's Longhorn volumes (#64)

Takes a Longhorn snapshot of each selected PVC's volume, backs that snapshot up to the
BackupTarget (an NFS export on this Mac), prunes old manual backups, and removes the
snapshot again.

Options:
  --kubeconfig PATH   kubeconfig to use (default: $HOME/.kube/homelab.yaml)
  --retain N          keep the N newest completed backups per volume that were created by
                      this script (default: 7). Older ones are deleted.
  --pvc ns/name       back up this PVC instead of the default set; repeatable.
  --keep-snapshot     do not delete the Longhorn snapshot after the backup completed.
                      Keeping it lets the next run compute a cheaper delta; the default is to
                      delete it so snapshots do not pile up on the nodes' root disks.
  --dry-run           resolve everything and print what would happen; change nothing.
  --help              show this help.

Default backup set (Prometheus is deliberately excluded — regenerable, 20 Gi):
  apps/data-postgresql-0  apps/influxdb2  apps/mosquitto-data  apps/n8n-data
  apps/open-webui-data    monitoring/kube-prometheus-stack-grafana

Prerequisites:
  - This Mac exports the backup folder over NFS and is on the LAN. Without /etc/exports:
      echo '/Users/dominic/informatik/homelab/backups/longhorn -network 192.168.1.0 -mask 255.255.255.0 -mapall=dominic:staff' | sudo tee -a /etc/exports
      sudo nfsd enable && sudo nfsd update
      showmount -e localhost
  - The cluster's backup target is set (infra/playbooks/30_longhorn.yml).

Retention notes:
  - Deleting a Backup CR also deletes the backup data on the target — Longhorn's backup
    controller removes the remote data when the CR goes away. Pruning is therefore
    destructive, and it only ever touches backups labelled homelab.furchert.ch/manual-backup=true.
  - Backups that Longhorn re-imported from the target (e.g. after a cluster rebuild) do not
    carry that label and are never pruned automatically; delete them by hand if needed.

What this does and does not protect:
  - Crash-consistent block-level copies of the volumes, good for disaster recovery.
  - NOT application-consistent and NOT off-site (same flat as the cluster). The manual
    pre-upgrade dumps remain the application-consistent path.

Exit status: 0 if every selected volume was backed up, 1 otherwise.
USAGE
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; }
err()  { printf 'ERROR %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)
      [[ $# -ge 2 ]] || die "--kubeconfig needs a value"
      KUBECONFIG_PATH="$2"; shift 2 ;;
    --retain)
      [[ $# -ge 2 ]] || die "--retain needs a value"
      RETAIN="$2"; shift 2 ;;
    --pvc)
      [[ $# -ge 2 ]] || die "--pvc needs a value"
      PVCS+=("$2"); shift 2 ;;
    --keep-snapshot) KEEP_SNAPSHOT=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --help|-h)       usage; exit 0 ;;
    *)               err "unknown option: $1"; echo; usage; exit 1 ;;
  esac
done

if ! [[ "$RETAIN" =~ ^[1-9][0-9]*$ ]]; then
  die "--retain must be a positive integer, got: $RETAIN"
fi
if [[ ${#PVCS[@]} -eq 0 ]]; then
  PVCS=("${DEFAULT_PVCS[@]}")
fi

# Host and export path are derived from the target URL so they can never drift apart.
NFS_HOST="${BACKUP_TARGET_URL#nfs://}"
NFS_HOST="${NFS_HOST%%:*}"
NFS_EXPORT_PATH="${BACKUP_TARGET_URL#nfs://*:}"

kc() { kubectl --kubeconfig "$KUBECONFIG_PATH" --request-timeout=30s "$@"; }

# Reads one field of one object; empty string when the object or the field is absent.
field() {
  local kind="$1" name="$2" path="$3"
  kc get "$kind" "$name" -n "$LONGHORN_NS" -o "jsonpath={$path}" 2>/dev/null || true
}

# --- Preflight -------------------------------------------------------------------------------
preflight_nfs_server() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    warn "not running on macOS — skipping the local NFS server checks."
    warn "The BackupTarget availability check below is the authoritative one."
    return 0
  fi

  local hint
  hint="$(cat <<HINT
The NFS export is missing or nfsd is not running. On this Mac:

  echo '${NFS_EXPORT_PATH} -network 192.168.1.0 -mask 255.255.255.0 -mapall=dominic:staff' | sudo tee -a /etc/exports
  sudo nfsd enable && sudo nfsd update
  showmount -e localhost

If 'Block all incoming connections' is enabled in the macOS firewall, nfsd stays unreachable
even when it is running — turn that off or allow incoming connections for nfsd.
HINT
)"

  if ! /sbin/nfsd status >/dev/null 2>&1; then
    err "'/sbin/nfsd status' reports nfsd is not running."
    printf '%s\n' "$hint" >&2
    exit 1
  fi

  local exports
  exports="$(showmount -e localhost 2>/dev/null || true)"
  if ! printf '%s\n' "$exports" | grep -q -- "$NFS_EXPORT_PATH"; then
    err "'showmount -e localhost' does not list ${NFS_EXPORT_PATH}."
    printf '%s\n' "$hint" >&2
    exit 1
  fi
  log "OK    nfsd is running and exports ${NFS_EXPORT_PATH}"
}

preflight_cluster() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
  [[ -r "$KUBECONFIG_PATH" ]] || die "kubeconfig not readable: $KUBECONFIG_PATH"
  kc get namespace "$LONGHORN_NS" -o name >/dev/null 2>&1 \
    || die "cannot reach the cluster or namespace ${LONGHORN_NS} (kubeconfig: ${KUBECONFIG_PATH})"
  log "OK    cluster reachable, namespace ${LONGHORN_NS} present"

  local configured
  configured="$(field settings.longhorn.io backup-target .value)"
  if [[ "$configured" != "$BACKUP_TARGET_URL" ]]; then
    err "the cluster's backup target does not match this script."
    err "  cluster:  ${configured:-<empty>}"
    err "  expected: ${BACKUP_TARGET_URL}"
    die "Run 'ansible-playbook infra/playbooks/30_longhorn.yml' to apply the target from cluster/values/longhorn.yaml."
  fi
  log "OK    backup target is ${BACKUP_TARGET_URL}"
}

preflight_backup_target_available() {
  local deadline available
  deadline=$(( $(date +%s) + TARGET_TIMEOUT ))
  while :; do
    available="$(field backuptargets.longhorn.io default .status.available)"
    if [[ "$available" == "true" ]]; then
      log "OK    BackupTarget 'default' is available"
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      err "BackupTarget 'default' did not become available within ${TARGET_TIMEOUT}s."
      err "Longhorn re-polls the target every 300 s. Check that this Mac is on the LAN at"
      err "${NFS_HOST}, that nfsd exports ${NFS_EXPORT_PATH}, and look at:"
      err "  kubectl -n ${LONGHORN_NS} get backuptargets.longhorn.io default -o yaml"
      exit 1
    fi
    log "...   waiting for the BackupTarget to become available (Longhorn polls every 300 s)"
    sleep "$POLL_INTERVAL"
  done
}

# --- Helpers ---------------------------------------------------------------------------------
resolve_volume() {
  local ns="$1" name="$2" volume
  volume="$(kc get pvc "$name" -n "$ns" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  printf '%s' "$volume"
}

wait_snapshot_ready() {
  local snap="$1" deadline ready snap_err
  deadline=$(( $(date +%s) + SNAPSHOT_TIMEOUT ))
  while :; do
    ready="$(field snapshots.longhorn.io "$snap" .status.readyToUse)"
    if [[ "$ready" == "true" ]]; then
      return 0
    fi
    snap_err="$(field snapshots.longhorn.io "$snap" .status.error)"
    if [[ -n "$snap_err" ]]; then
      err "snapshot ${snap} failed: ${snap_err}"
      return 1
    fi
    if (( $(date +%s) >= deadline )); then
      err "snapshot ${snap} was not ready within ${SNAPSHOT_TIMEOUT}s"
      return 1
    fi
    sleep "$POLL_INTERVAL"
  done
}

wait_backup_completed() {
  local backup="$1" deadline started now state backup_err progress last_progress_log
  started="$(date +%s)"
  deadline=$(( started + BACKUP_TIMEOUT ))
  last_progress_log="$started"
  while :; do
    state="$(field backups.longhorn.io "$backup" .status.state)"
    case "$state" in
      Completed) return 0 ;;
      Error|Unknown)
        backup_err="$(field backups.longhorn.io "$backup" .status.error)"
        err "backup ${backup} ended in state ${state}: ${backup_err:-<no error message>}"
        return 1 ;;
    esac
    now="$(date +%s)"
    if (( now >= deadline )); then
      err "backup ${backup} did not complete within ${BACKUP_TIMEOUT}s (last state: ${state:-<none>})"
      return 1
    fi
    if (( now - last_progress_log >= PROGRESS_EVERY )); then
      progress="$(field backups.longhorn.io "$backup" .status.progress)"
      log "...   ${backup}: state=${state:-<none>} progress=${progress:-0}% elapsed=$(( now - started ))s"
      last_progress_log="$now"
    fi
    sleep "$POLL_INTERVAL"
  done
}

# Deletes the completed manual backups of one volume beyond --retain, oldest first.
prune_backups() {
  local volume="$1" listing completed total excess victims name
  listing="$(kc get backups.longhorn.io -n "$LONGHORN_NS" \
    -l "${LABEL_MANUAL}=true,${LABEL_VOLUME}=${volume}" --no-headers \
    -o "custom-columns=CREATED:.status.backupCreatedAt,NAME:.metadata.name,STATE:.status.state" \
    2>/dev/null || true)"
  # Only completed backups with a real creation timestamp are prune candidates; anything still
  # running or errored is left alone so a failed run never eats a good backup.
  completed="$(printf '%s\n' "$listing" | awk '$3 == "Completed" && $1 != "<none>" { print $1" "$2 }' | sort)"
  total="$(printf '%s\n' "$completed" | grep -c '[^[:space:]]' || true)"
  if (( total <= RETAIN )); then
    log "      retention: ${total} completed manual backup(s) <= --retain ${RETAIN}, nothing to prune"
    return 0
  fi
  excess=$(( total - RETAIN ))
  victims="$(printf '%s\n' "$completed" | sed -n "1,${excess}p" | awk '{ print $2 }')"
  while IFS= read -r name; do
    if [[ -z "$name" ]]; then
      continue
    fi
    if [[ "$DRY_RUN" == true ]]; then
      log "      DRY-RUN would delete backup ${name} (and its data on the target)"
    else
      log "      deleting backup ${name} (removes its data from the target)"
      kc delete backups.longhorn.io "$name" -n "$LONGHORN_NS" --wait=false >/dev/null
    fi
  done <<< "$victims"
}

# --- Main ------------------------------------------------------------------------------------
RUN_TS="$(date +%Y%m%d-%H%M)"
SUMMARY=""
FAILED=0

log "Longhorn manual backup — run ${RUN_TS}"
log "Target: ${BACKUP_TARGET_URL}"
if [[ "$DRY_RUN" == true ]]; then
  log "Mode:   DRY RUN (nothing will be created, changed or deleted)"
fi
log ""

preflight_nfs_server
preflight_cluster
preflight_backup_target_available
log ""

for pvc_ref in "${PVCS[@]}"; do
  if [[ "$pvc_ref" != */* ]]; then
    err "--pvc expects ns/name, got: ${pvc_ref}"
    SUMMARY="${SUMMARY}${pvc_ref}\tFAILED\tmalformed reference\n"
    FAILED=1
    continue
  fi
  ns="${pvc_ref%%/*}"
  pvc_name="${pvc_ref#*/}"

  log "=== ${pvc_ref} ==="
  volume="$(resolve_volume "$ns" "$pvc_name")"
  if [[ -z "$volume" ]]; then
    err "PVC ${pvc_ref} not found or not bound to a volume"
    SUMMARY="${SUMMARY}${pvc_ref}\tFAILED\tPVC not bound\n"
    FAILED=1
    continue
  fi
  log "      volume: ${volume}"

  # Longhorn object names must be DNS-1123; the PVC part is truncated so the timestamped
  # prefix always survives.
  short="$(printf '%s' "${pvc_name:0:20}" | sed 's/-*$//')"
  suffix="${RUN_TS}-${short}"
  snap_name="manual-${suffix}"
  backup_name="backup-${suffix}"

  if [[ "$DRY_RUN" == true ]]; then
    log "      DRY-RUN would create snapshot ${snap_name} on ${volume}"
    log "      DRY-RUN would create backup ${backup_name} from that snapshot"
    prune_backups "$volume"
    if [[ "$KEEP_SNAPSHOT" == false ]]; then
      log "      DRY-RUN would delete snapshot ${snap_name} afterwards"
    fi
    SUMMARY="${SUMMARY}${pvc_ref}\tDRY-RUN\t${backup_name}\n"
    log ""
    continue
  fi

  log "      creating snapshot ${snap_name}"
  kc create -f - >/dev/null <<YAML
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata:
  name: ${snap_name}
  namespace: ${LONGHORN_NS}
  labels:
    "${LABEL_MANUAL}": "true"
    "${LABEL_PVC}": "${ns}_${pvc_name}"
spec:
  volume: ${volume}
  createSnapshot: true
  labels:
    "${LABEL_MANUAL}": "true"
    "${LABEL_PVC}": "${ns}_${pvc_name}"
YAML

  if ! wait_snapshot_ready "$snap_name"; then
    SUMMARY="${SUMMARY}${pvc_ref}\tFAILED\tsnapshot ${snap_name}\n"
    FAILED=1
    log ""
    continue
  fi
  log "      snapshot ready"

  log "      creating backup ${backup_name}"
  kc create -f - >/dev/null <<YAML
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata:
  name: ${backup_name}
  namespace: ${LONGHORN_NS}
  labels:
    "${LABEL_VOLUME}": "${volume}"
    "${LABEL_MANUAL}": "true"
    "${LABEL_PVC}": "${ns}_${pvc_name}"
spec:
  snapshotName: ${snap_name}
  labels:
    "${LABEL_MANUAL}": "true"
    "${LABEL_PVC}": "${ns}_${pvc_name}"
YAML

  if ! wait_backup_completed "$backup_name"; then
    SUMMARY="${SUMMARY}${pvc_ref}\tFAILED\tbackup ${backup_name}\n"
    FAILED=1
    log ""
    continue
  fi

  size="$(field backups.longhorn.io "$backup_name" .status.size)"
  uploaded="$(field backups.longhorn.io "$backup_name" .status.newlyUploadDataSize)"
  url="$(field backups.longhorn.io "$backup_name" .status.url)"
  log "      completed: size=${size:-?} newlyUploaded=${uploaded:-?}"
  log "      url: ${url:-?}"

  prune_backups "$volume"

  if [[ "$KEEP_SNAPSHOT" == false ]]; then
    log "      deleting snapshot ${snap_name}"
    kc delete snapshots.longhorn.io "$snap_name" -n "$LONGHORN_NS" --wait=false >/dev/null
  fi

  SUMMARY="${SUMMARY}${pvc_ref}\tOK\t${backup_name} (${size:-?} bytes)\n"
  log ""
done

log "Summary"
log "-------"
printf 'PVC\tRESULT\tDETAIL\n'
printf '%b' "$SUMMARY"

if (( FAILED != 0 )); then
  err "at least one volume failed — see above"
  exit 1
fi
log ""
log "All selected volumes backed up to ${BACKUP_TARGET_URL}"
