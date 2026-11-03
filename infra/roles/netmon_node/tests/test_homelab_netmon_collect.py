"""Unit tests for files/homelab-netmon-collect.py (role netmon_node, homelab#117).

Run from the repo root (Python 3 standard library only):
    python3 -m unittest discover -s infra/roles/netmon_node/tests -v

The fixtures are captured-format samples of `conntrack -L`, `ip -o addr show` and
`journalctl -o short-unix`; expected.prom is the exact docs/060 §5.2 output for them.
"""
import importlib.machinery
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
SCRIPT = os.path.join(HERE, "..", "files", "homelab-netmon-collect.py")

_loader = importlib.machinery.SourceFileLoader("homelab_netmon_collect", SCRIPT)
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
collect_mod = importlib.util.module_from_spec(_spec)
_loader.exec_module(collect_mod)

NOW = 1758620765.4  # bucket [1758619800, 1758620700), the docs/060 §5.2 example
PORTS = [1883, 22, 8123, 6443, 10250]
LAN = "192.168.1.0/24"
POD = "10.42.0.0/16"


def fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as handle:
        return handle.read()


class FixtureRunner:
    """Stands in for subprocess: maps each command the script runs to a fixture."""

    def __init__(self):
        self.calls = []

    def __call__(self, argv):
        argv = list(argv)
        self.calls.append(argv)
        if argv[0] == "ip":
            return fixture("ip_addr.txt")
        if argv[0] == "conntrack":
            path = os.path.join(FIXTURES, "conntrack_{}.txt".format(argv[-1]))
            return fixture(os.path.basename(path)) if os.path.exists(path) else ""
        if argv[0] == "journalctl" and "-k" in argv:
            return fixture("journal_kernel.txt")
        if argv[0] == "journalctl" and "-u" in argv:
            return fixture("journal_ssh.txt")
        raise AssertionError("unexpected command {}".format(argv))


def run_collect(max_series=200, runner=None):
    return collect_mod.collect(
        node="raspi5",
        lan_cidr=LAN,
        pod_cidr=POD,
        ports=PORTS,
        max_series=max_series,
        bucket_seconds=900,
        now=NOW,
        runner=runner or FixtureRunner(),
    )


class GoldenOutputTest(unittest.TestCase):
    def test_output_matches_contract_example(self):
        self.assertEqual(run_collect(), fixture("expected.prom"))

    def test_commands_follow_contract_shape(self):
        runner = FixtureRunner()
        run_collect(runner=runner)
        conntrack = [c for c in runner.calls if c[0] == "conntrack"]
        self.assertEqual(
            conntrack,
            [["conntrack", "-L", "-p", "tcp", "--orig-port-dst", str(p)] for p in PORTS],
        )
        journal = [c for c in runner.calls if c[0] == "journalctl"]
        self.assertEqual(len(journal), 2)
        for call in journal:
            self.assertIn("@1758619800", call)
            self.assertIn("@1758620700", call)
        self.assertIn(["-u", "ssh"], [call[i:i + 2] for call in journal for i in range(len(call))])

    def test_usernames_are_never_emitted(self):
        out = run_collect()
        for name in ("ansible", "admin", "root"):
            self.assertNotIn(name, out)


class ParserTest(unittest.TestCase):
    def setUp(self):
        self.classifier = collect_mod.Classifier(LAN, POD)

    def test_node_own_source_is_skipped(self):
        series = {}
        collect_mod.parse_conntrack(
            fixture("conntrack_1883.txt"), 1883, self.classifier, series, {"192.168.1.61"}
        )
        self.assertNotIn(("1883", "192.168.1.61", "SYN_SENT"), series)
        self.assertEqual(series[("1883", "192.168.1.50", "ESTABLISHED")], 2)

    def test_bucket_edges_are_half_open(self):
        series = {}
        collect_mod.parse_ufw(
            fixture("journal_kernel.txt"), 1758619800, 1758620700, self.classifier, series
        )
        # :59.999999 before the start and the line exactly at the end are excluded.
        self.assertEqual(series[("192.168.1.77", "23", "TCP")], 3)

    def test_classification(self):
        c = self.classifier
        self.assertEqual(c.classify("192.168.1.5", keep_public=False), "192.168.1.5")
        self.assertEqual(c.classify("10.42.3.4", keep_public=True), "10.42.0.0/16")
        self.assertEqual(c.classify("8.8.8.8", keep_public=False), "other")
        self.assertEqual(c.classify("8.8.8.8", keep_public=True), "8.8.8.8")
        self.assertEqual(c.classify("10.43.0.10", keep_public=True), "other")
        self.assertEqual(c.classify("not-an-ip", keep_public=True), "other")

    def test_injected_username_cannot_spoof_source_ip(self):
        # The username "x from 192.168.1.10 port 1" must not turn a public attacker into
        # a trusted LAN source: the peer address sshd appends last wins.
        start, end = 1758619800, 1758620700
        lines = "\n".join(
            "1758620000.0 raspi5 sshd[1]: " + msg
            for msg in (
                "Invalid user x from 192.168.1.10 port 1 from 45.155.205.4 port 41100",
                "Failed publickey for x from 192.168.1.10 port 1 ssh2 from 45.155.205.4 "
                "port 41101 ssh2: RSA SHA256:abc",
                "Accepted publickey for x from 192.168.1.10 port 1 ssh2 from 45.155.205.4 "
                "port 41102 ssh2: ED25519 SHA256:abc",
            )
        )
        series = {}
        collect_mod.parse_sshd(lines, start, end, self.classifier, series)
        self.assertEqual(
            series,
            {
                ("45.155.205.4", "invalid_user"): 1,
                ("45.155.205.4", "failed"): 1,
                ("45.155.205.4", "accepted"): 1,
            },
        )

    def test_sshd_outcomes_are_disjoint(self):
        # One connection for a non-existent user: "Invalid user", then "Failed ... for
        # invalid user", then "Connection closed/Disconnected" -> exactly one invalid_user.
        series = {}
        collect_mod.parse_sshd(
            fixture("journal_ssh.txt"), 1758619800, 1758620700, self.classifier, series
        )
        self.assertEqual(series[("45.155.205.3", "invalid_user")], 1)
        self.assertNotIn(("45.155.205.3", "failed"), series)
        self.assertEqual(series[("45.155.205.4", "invalid_user")], 1)
        self.assertNotIn(("192.168.1.10", "invalid_user"), series)
        self.assertEqual(series[("10.42.0.0/16", "failed")], 2)

    def test_bucket_bounds(self):
        self.assertEqual(collect_mod.bucket_bounds(1758620700.0, 900), (1758619800, 1758620700))
        self.assertEqual(collect_mod.bucket_bounds(1758621599.9, 900), (1758619800, 1758620700))


class CapTest(unittest.TestCase):
    def test_lan_overflow_folds_into_other_and_is_counted(self):
        series = {("1883", "192.168.1.{}".format(i), "ESTABLISHED"): i for i in range(1, 11)}
        capped, truncated = collect_mod.apply_cap(collect_mod.METRIC_LAN, series, 5)
        self.assertLessEqual(len(capped), 5)
        self.assertEqual(sum(capped.values()), sum(series.values()))
        self.assertEqual(truncated, 10 - 4)  # 4 kept verbatim + 1 "other"
        self.assertEqual(capped[("1883", "other", "ESTABLISHED")], 1 + 2 + 3 + 4 + 5 + 6)
        self.assertIn(("1883", "192.168.1.10", "ESTABLISHED"), capped)

    def test_ufw_port_sweep_stays_bounded(self):
        # One scanner hitting 500 ports: folding src_ip alone would leave 500 series.
        series = {("45.155.205.3", str(p), "TCP"): 1 for p in range(1, 501)}
        series[("192.168.1.77", "23", "TCP")] = 50
        capped, truncated = collect_mod.apply_cap(collect_mod.METRIC_UFW, series, 200)
        self.assertLessEqual(len(capped), 200)
        self.assertEqual(sum(capped.values()), sum(series.values()))
        self.assertEqual(capped[("192.168.1.77", "23", "TCP")], 50)
        self.assertIn(("other", "0", "TCP"), capped)
        self.assertEqual(truncated, len(series) - (len(capped) - 1))

    def test_under_cap_is_untouched(self):
        series = {("1.2.3.4", "accepted"): 1}
        self.assertEqual(
            collect_mod.apply_cap(collect_mod.METRIC_SSHD, series, 200), (series, 0)
        )

    def test_truncated_gauge_is_rendered(self):
        out = run_collect(max_series=2)
        self.assertIn(
            'homelab_netmon_truncated_series{node="raspi5",metric="homelab_ufw_blocks_bucket"} ',
            out,
        )
        self.assertNotIn(
            'homelab_netmon_truncated_series{node="raspi5",metric="homelab_ufw_blocks_bucket"} 0',
            out,
        )


class K3sStateDbTest(unittest.TestCase):
    """homelab_k3s_state_db_bytes (homelab#150): control-plane only, opt-in via a flag."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = os.path.join(self.tmp.name, "state.db")
        with open(self.db, "wb") as handle:
            handle.write(b"\0" * 4096)
        # The fake database also makes the lag gauge warn ("k3s kine lag skipped").
        self._stderr = mock.patch.object(collect_mod.sys, "stderr", io.StringIO())
        self._stderr.start()

    def tearDown(self):
        self._stderr.stop()
        self.tmp.cleanup()

    def collect(self, path):
        return collect_mod.collect(
            node="raspi5", lan_cidr=LAN, pod_cidr=POD, ports=PORTS, max_series=200,
            bucket_seconds=900, now=NOW, runner=FixtureRunner(), k3s_state_db=path,
        )

    def test_db_and_wal_are_summed(self):
        with open(self.db + "-wal", "wb") as handle:
            handle.write(b"\0" * 1000)
        out = self.collect(self.db)
        self.assertTrue(out.startswith(fixture("expected.prom")))
        self.assertEqual(
            out[len(fixture("expected.prom")):],
            "# HELP homelab_k3s_state_db_bytes Size on disk of the k3s kine SQLite datastore "
            "(state.db plus state.db-wal).\n"
            "# TYPE homelab_k3s_state_db_bytes gauge\n"
            'homelab_k3s_state_db_bytes{node="raspi5"} 5096\n',
        )

    def test_missing_wal_counts_as_zero(self):
        self.assertIn('homelab_k3s_state_db_bytes{node="raspi5"} 4096\n', self.collect(self.db))

    def test_missing_db_skips_only_the_gauge(self):
        stderr = io.StringIO()
        with mock.patch.object(collect_mod.sys, "stderr", stderr):
            out = self.collect(os.path.join(self.tmp.name, "missing.db"))
        self.assertEqual(out, fixture("expected.prom"))
        self.assertIn("k3s state db skipped: FileNotFoundError", stderr.getvalue())

    def test_without_flag_no_k3s_metric(self):
        self.assertNotIn("homelab_k3s_", self.collect(None))


LAG_HEADER = (
    "# HELP homelab_k3s_kine_compaction_lag_revisions Revisions between the newest kine row and the "
    "compaction marker (MAX(id) - compact_rev_key).\n"
    "# TYPE homelab_k3s_kine_compaction_lag_revisions gauge\n"
)


KINE_SCHEMA = (
    "CREATE TABLE kine (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, created INTEGER, "
    "deleted INTEGER, create_revision INTEGER, prev_revision INTEGER, lease INTEGER, "
    "value BLOB, old_value BLOB)",
    "CREATE INDEX kine_name_index ON kine (name)",
)

# Stands in for k3s: a SEPARATE process that keeps the WAL database open (its -shm mapping
# read-write), like kine on raspi5. A writer in the test process would share SQLite's
# per-process shm handle with the reader, which then never takes the read-only -shm path.
WRITER = r"""
import sqlite3, sys, time
db, mode, seconds, schema = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4:]
c = sqlite3.connect(db)
c.execute("PRAGMA journal_mode=WAL")
c.execute("PRAGMA wal_autocheckpoint=0")
for statement in schema:
    c.execute(statement)
c.execute("INSERT INTO kine (name, prev_revision) VALUES ('compact_rev_key', 0)")
c.executemany("INSERT INTO kine (name, prev_revision) VALUES (?, 0)", [("/registry/leases/x",)] * 5000)
c.execute("UPDATE kine SET prev_revision = 3800 WHERE name = 'compact_rev_key'")
c.commit()
print("ready", flush=True)
if mode == "busy":
    end = time.time() + seconds
    while time.time() < end:
        c.execute("INSERT INTO kine (name, prev_revision) VALUES ('/registry/leases/x', 0)")
        c.commit()
    print("done", flush=True)
sys.stdin.read()
"""


def _kine_writer(path, rows=5000, compact_rev=3800):
    """A kine-like WAL database written from the test process (setup only, then closed)."""
    import sqlite3

    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA wal_autocheckpoint=0")
    for statement in KINE_SCHEMA:
        conn.execute(statement)
    if compact_rev is not None:
        conn.execute("INSERT INTO kine (name, prev_revision) VALUES ('compact_rev_key', 0)")
    conn.executemany(
        "INSERT INTO kine (name, prev_revision) VALUES (?, 0)",
        [("/registry/leases/flux-system/x",)] * rows,
    )
    if compact_rev is not None:
        conn.execute(
            "UPDATE kine SET prev_revision = ? WHERE name = 'compact_rev_key'", (compact_rev,)
        )
    conn.commit()
    return conn


def _snapshot(directory):
    return {
        name: (os.stat(os.path.join(directory, name)).st_size,
               os.stat(os.path.join(directory, name)).st_mtime_ns)
        for name in sorted(os.listdir(directory))
    }


class K3sKineLagTest(unittest.TestCase):
    """homelab_k3s_kine_compaction_lag_revisions (homelab#129): read-only, never fatal."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = os.path.join(self.tmp.name, "db")
        os.mkdir(self.dir)
        self.db = os.path.join(self.dir, "state.db")
        self.stderr = io.StringIO()
        self._patch = mock.patch.object(collect_mod.sys, "stderr", self.stderr)
        self._patch.start()

    def tearDown(self):
        self._patch.stop()
        os.chmod(self.dir, 0o755)
        for name in os.listdir(self.dir):
            os.chmod(os.path.join(self.dir, name), 0o644)
        proc = getattr(self, "proc", None)
        if proc is not None:  # stop the writer after its files are writable again
            proc.stdin.close()
            proc.wait(timeout=30)
            proc.stdout.close()
        self.tmp.cleanup()

    def collect(self):
        return collect_mod.collect(
            node="raspi5", lan_cidr=LAN, pod_cidr=POD, ports=PORTS, max_series=200,
            bucket_seconds=900, now=NOW, runner=FixtureRunner(), k3s_state_db=self.db,
        )

    def read_only(self):
        """What ProtectSystem=strict gives the unit: read-only files and directory."""
        for name in os.listdir(self.dir):
            os.chmod(os.path.join(self.dir, name), 0o444)
        os.chmod(self.dir, 0o555)

    def assert_lag(self, out, value):
        self.assertIn(LAG_HEADER + 'homelab_k3s_kine_compaction_lag_revisions{node="raspi5"} '
                      + str(value) + "\n", out)

    def assert_lag_skipped(self, out):
        self.assertNotIn("homelab_k3s_kine_compaction_lag_revisions", out)
        self.assertIn("k3s kine lag skipped", self.stderr.getvalue())

    def start_writer(self, mode, seconds=0.0):
        self.proc = subprocess.Popen(
            [sys.executable, "-c", WRITER, self.db, mode, str(seconds)] + list(KINE_SCHEMA),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, universal_newlines=True,
        )
        self.assertEqual(self.proc.stdout.readline().strip(), "ready")

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root ignores file modes")
    def test_live_wal_idle_writer_read_only_and_unchanged(self):
        self.start_writer("idle")  # 5001 rows, compact_rev 3800 -> lag 1201, all in WAL frames
        self.assertGreater(os.path.getsize(self.db + "-wal"), 0)
        self.read_only()
        before = _snapshot(self.dir)
        for _ in range(20):
            self.assertEqual(collect_mod.k3s_kine_compaction_lag(self.db), 1201)
        out = self.collect()
        self.assertEqual(before, _snapshot(self.dir))
        self.assert_lag(out, 1201)
        self.assertIn('homelab_k3s_state_db_bytes{node="raspi5"}', out)
        self.assertEqual(self.stderr.getvalue(), "")

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root ignores file modes")
    def test_live_wal_busy_writer_never_fails(self):
        self.start_writer("busy", seconds=2.0)  # commits as fast as it can for 2 s
        self.read_only()
        lags = [collect_mod.k3s_kine_compaction_lag(self.db) for _ in range(200)]
        self.assertTrue(all(lag >= 1201 for lag in lags))
        self.assertEqual(self.proc.stdout.readline().strip(), "done")

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root ignores file modes")
    def test_wal_left_behind_without_writer(self):
        # A crash-like copy: -wal and -shm exist but no process holds the database open.
        src = os.path.join(self.tmp.name, "src")
        os.mkdir(src)
        writer = _kine_writer(os.path.join(src, "state.db"), rows=10, compact_rev=5)
        for name in os.listdir(src):
            with open(os.path.join(src, name), "rb") as fin, \
                    open(os.path.join(self.dir, name), "wb") as fout:
                fout.write(fin.read())
        writer.close()
        self.read_only()
        out = self.collect()
        self.assert_lag(out, 6)  # 11 rows, compact_rev 5

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root ignores file modes")
    def test_no_wal_and_read_only_dir_skips_without_writing(self):
        # k3s stopped cleanly: Linux SQLite checkpoints and deletes -wal/-shm on the last close
        # (Apple's keeps them, so do it by hand). The read-only directory cannot get new ones.
        writer = _kine_writer(self.db, rows=10, compact_rev=5)
        writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        writer.close()
        for suffix in ("-wal", "-shm"):
            if os.path.exists(self.db + suffix):
                os.remove(self.db + suffix)
        self.read_only()
        before = _snapshot(self.dir)
        out = self.collect()
        self.assertEqual(before, _snapshot(self.dir))
        self.assert_lag_skipped(out)
        self.assertIn('homelab_k3s_state_db_bytes{node="raspi5"}', out)

    def test_missing_db_is_not_created(self):
        out = self.collect()
        self.assertFalse(os.path.exists(self.db))
        self.assertEqual(out, fixture("expected.prom"))
        self.assert_lag_skipped(out)

    def test_missing_compact_rev_key_skips_only_lag(self):
        _kine_writer(self.db, rows=10, compact_rev=None).close()
        out = self.collect()
        self.assertIn('homelab_k3s_state_db_bytes{node="raspi5"}', out)
        self.assert_lag_skipped(out)

    def test_empty_table_skips_only_lag(self):
        _kine_writer(self.db, rows=0, compact_rev=None).close()
        out = self.collect()
        self.assert_lag_skipped(out)

    def test_not_a_database_skips_only_lag(self):
        with open(self.db, "wb") as handle:
            handle.write(b"\0" * 4096)
        out = self.collect()
        self.assertIn('homelab_k3s_state_db_bytes{node="raspi5"} 4096\n', out)
        self.assert_lag_skipped(out)


class MainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = os.path.join(self.tmp.name, "homelab_netmon.prom")
        self.argv = [
            "--node", "raspi5", "--lan-cidr", LAN, "--pod-cidr", POD,
            "--ports", "1883,22,8123,6443,10250", "--output", self.out,
        ]

    def tearDown(self):
        self.tmp.cleanup()

    def test_writes_file_atomically_with_readable_mode(self):
        with mock.patch.object(collect_mod, "run_command", FixtureRunner()), \
                mock.patch.object(collect_mod.time, "time", return_value=NOW):
            self.assertEqual(collect_mod.main(self.argv), 0)
        with open(self.out, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), fixture("expected.prom"))
        self.assertEqual(os.stat(self.out).st_mode & 0o777, 0o644)
        self.assertEqual(os.listdir(self.tmp.name), ["homelab_netmon.prom"])

    def test_failed_command_keeps_previous_file(self):
        with open(self.out, "w", encoding="utf-8") as handle:
            handle.write("previous\n")

        def failing(argv):
            if argv[0] == "journalctl":
                raise subprocess.CalledProcessError(1, argv)
            return FixtureRunner()(argv)

        with mock.patch.object(collect_mod, "run_command", failing):
            with self.assertRaises(subprocess.CalledProcessError):
                collect_mod.main(self.argv)
        with open(self.out, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "previous\n")

    def test_missing_k3s_state_db_still_writes_lan_metrics(self):
        with open(self.out, "w", encoding="utf-8") as handle:
            handle.write("previous\n")
        argv = self.argv + ["--k3s-state-db", os.path.join(self.tmp.name, "state.db")]
        with mock.patch.object(collect_mod, "run_command", FixtureRunner()), \
                mock.patch.object(collect_mod.time, "time", return_value=NOW), \
                mock.patch.object(collect_mod.sys, "stderr", io.StringIO()):
            self.assertEqual(collect_mod.main(argv), 0)
        with open(self.out, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), fixture("expected.prom"))

    def test_missing_directory_fails_loudly(self):
        argv = self.argv[:-1] + [os.path.join(self.tmp.name, "missing", "homelab_netmon.prom")]
        with mock.patch.object(collect_mod, "run_command", FixtureRunner()):
            with self.assertRaises(FileNotFoundError):
                collect_mod.main(argv)


if __name__ == "__main__":
    unittest.main()
