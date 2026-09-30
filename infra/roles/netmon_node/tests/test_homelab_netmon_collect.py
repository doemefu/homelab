"""Unit tests for files/homelab-netmon-collect.py (role netmon_node, homelab#117).

Run from the repo root (Python 3 standard library only):
    python3 -m unittest discover -s infra/roles/netmon_node/tests -v

The fixtures are captured-format samples of `conntrack -L`, `ip -o addr show` and
`journalctl -o short-unix`; expected.prom is the exact docs/060 §5.2 output for them.
"""
import importlib.machinery
import importlib.util
import os
import subprocess
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

    def test_missing_directory_fails_loudly(self):
        argv = self.argv[:-1] + [os.path.join(self.tmp.name, "missing", "homelab_netmon.prom")]
        with mock.patch.object(collect_mod, "run_command", FixtureRunner()):
            with self.assertRaises(FileNotFoundError):
                collect_mod.main(argv)


if __name__ == "__main__":
    unittest.main()
