#!/usr/bin/env python3
"""Offline compaction of the k3s kine SQLite datastore (homelab#129, 2026-09-23 incident).

Purpose
-------
kine's built-in online compactor runs every 5 minutes (`compactInterval`) with a 5 second
per-batch timeout (`compactTimeout`) and a 1000-row batch size (`compactBatchSize`) — see
`pkg/logstructured/sqllog/sql.go` in kine v0.13.9. On a large enough backlog (here: ~1.77M rows,
~5 GB) each DELETE batch routinely exceeds that 5 second budget, Go's `database/sql` rolls the
transaction back ("transaction has already been committed or rolled back"), and the compactor
never makes forward progress — `state.db` keeps growing and SQLite query latency keeps
degrading (Slow SQL, apiserver `/readyz` etcd-check failures, load). None of `compactInterval`,
`compactTimeout`, `compactBatchSize` or `compactMinRetain` (also 1000 — the number of most
recent revisions kine always retains) are tunable via k3s flags. This script runs the exact same
compaction kine's compactor would run, offline (k3s stopped, no 5 second timeout, larger
batches), so a stalled backlog can be cleared in one pass.

kine v0.13.9 source it mirrors:
  - `pkg/drivers/sqlite/sqlite.go`             — `dialect.CompactSQL` (the DELETE below, verbatim)
  - `pkg/drivers/generic/generic.go`           — `UpdateCompactSQL` template + `SetCompactRevision`
  - `pkg/logstructured/sqllog/sql.go`          — `compactMinRetain = 1000` (this script's MIN_RETAIN)

Safety
------
Run this ONLY with k3s stopped (`systemctl stop k3s`) and only after taking a backup copy of
`state.db` (a plain `cp -a`, after a `PRAGMA wal_checkpoint(TRUNCATE)` so the copy is complete).
The DELETE is destructive and irreversible within the datastore itself — the backup is the only
way back. See `scripts/kine-offline-compact.sh` for the full runbook (stop, checkpoint, backup,
compact, start, verify) and DEPLOYMENT.md "k3s datastore (kine/SQLite) maintenance" for when to
reach for this at all versus letting the online compactor catch up on its own.

Usage (as root, k3s stopped, backup already taken):
    python3 kine-offline-compact.py --dry-run   # print rows/current_rev/compact_rev/target only
    python3 kine-offline-compact.py             # compact in batches of BATCH revisions, then VACUUM

Verification semantics
-----------------------
The script's own post-run checks are stricter than kine's actual invariants, by design (fail
loud rather than miss a real problem) — read the two counts this way:

  - "tombstones <= target": rows marked deleted with id <= target. Expected 0 — every
    tombstone at or before the compaction target should have been removed.
  - "superseded <= target": rows at or before target that are some other row's prev_revision.
    This is expected to be a SMALL NON-ZERO number, not 0. kine's compactMinRetain (1000) keeps
    the most recent 1000 revisions of the compact_rev_key chain and everything those 1000
    revisions point back to as their immediate predecessor stays until compaction moves past
    them too — this query counts exactly those predecessors of the 1000 retained revisions. On
    the 2026-09-23 run this was 66 out of 2,334 total rows post-compaction; a count in the tens
    for a healthy cluster is expected kine behavior, not a bug in this script.
"""
import sqlite3, sys, time

DB = "/var/lib/rancher/k3s/server/db/state.db"
MIN_RETAIN = 1000      # kine compactMinRetain
BATCH = 50000          # revisions per commit (kine uses 1000 online; larger is fine offline)
DRY = "--dry-run" in sys.argv

COMPACT_SQL = """
DELETE FROM kine AS kv
WHERE kv.id IN (
    SELECT kp.prev_revision AS id FROM kine AS kp
    WHERE kp.name != 'compact_rev_key' AND kp.prev_revision != 0 AND kp.id <= ?
    UNION
    SELECT kd.id AS id FROM kine AS kd
    WHERE kd.deleted != 0 AND kd.id <= ?
)"""
UPDATE_COMPACT_SQL = "UPDATE kine SET prev_revision = ? WHERE name = 'compact_rev_key'"

con = sqlite3.connect(DB, isolation_level=None, timeout=60)
cur = con.cursor()
q = lambda s, p=(): cur.execute(s, p).fetchone()

# Cheap report queries only — kept out of the dry-run's way is PRAGMA integrity_check below,
# an O(N log N) full-table scan that would add real I/O load to an already-struggling live
# datastore. The dry-run is meant to be safe to run with k3s still up.
print("legacy key_value table rows:", q("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='key_value'")[0])
rows0 = q("SELECT COUNT(*) FROM kine")[0]
current_rev = q("SELECT MAX(id) FROM kine")[0] or 0
compact_rev = q("SELECT MAX(prev_revision) FROM kine WHERE name='compact_rev_key'")[0] or 0
target = max(current_rev - MIN_RETAIN, 0)
print(f"rows={rows0} current_rev={current_rev} compact_rev={compact_rev} target={target}")
if DRY:
    sys.exit(0)

integrity_pre = q("PRAGMA integrity_check")[0]
print("integrity_check (pre):", integrity_pre)
if integrity_pre != "ok":
    print(f"ABORT: pre-compaction integrity_check returned {integrity_pre!r}, not 'ok' — "
          "refusing to compact a datastore that already fails an integrity check.",
          file=sys.stderr)
    sys.exit(1)

t0 = time.time()
iter_rev = compact_rev
while iter_rev < target:
    iter_rev = min(iter_rev + BATCH, target)
    tb = time.time()
    cur.execute("BEGIN IMMEDIATE")
    cur.execute(COMPACT_SQL, (iter_rev, iter_rev))
    deleted = cur.rowcount
    cur.execute(UPDATE_COMPACT_SQL, (iter_rev,))
    con.commit()
    print(f"compacted to {iter_rev}/{target}  deleted={deleted}  {time.time()-tb:.1f}s", flush=True)

print("checkpoint:", q("PRAGMA wal_checkpoint(TRUNCATE)"))
tv = time.time(); cur.execute("VACUUM"); print(f"VACUUM done in {time.time()-tv:.0f}s")

integrity_post = q("PRAGMA integrity_check")[0]
rows_final = q("SELECT COUNT(*), MIN(id), MAX(id) FROM kine")
compact_rev_final = q("SELECT prev_revision FROM kine WHERE name='compact_rev_key'")[0]
tombstones = q("SELECT COUNT(*) FROM kine WHERE deleted != 0 AND id <= ?", (target,))[0]
superseded = q("SELECT COUNT(*) FROM kine kv WHERE kv.id <= ? AND kv.id IN (SELECT prev_revision FROM kine WHERE prev_revision != 0 AND name != 'compact_rev_key')", (target,))[0]
con.close()

print("integrity_check (post):", integrity_post)
print("rows:", rows_final)
print("compact_rev_key:", compact_rev_final, "(expect", target, ")")
print("tombstones <= target:", tombstones, "(expect 0)")
print("superseded <= target:", superseded, "(expect a small non-zero count — see docstring)")
print(f"total {time.time()-t0:.0f}s")

# Hard-fail the whole run (nonzero exit) on any of these — the caller (kine-offline-compact.sh)
# must not start k3s back up against a datastore that fails its own verification. "superseded"
# is deliberately excluded: a small non-zero count there is expected kine behavior, not a fault.
failures = []
if integrity_post != "ok":
    failures.append(f"integrity_check (post) = {integrity_post!r}, expected 'ok'")
if compact_rev_final != target:
    failures.append(f"compact_rev_key = {compact_rev_final}, expected {target}")
if tombstones != 0:
    failures.append(f"{tombstones} tombstone(s) remain at/before target, expected 0")
if failures:
    print("VERIFICATION FAILED after compaction — state.db has already been modified:", file=sys.stderr)
    for f in failures:
        print(" -", f, file=sys.stderr)
    print("Do not start k3s against this datastore without investigating. Restore the backup "
          "instead — see the Rollback section in DEPLOYMENT.md \"k3s datastore (kine/SQLite) "
          "maintenance\".", file=sys.stderr)
    sys.exit(1)
