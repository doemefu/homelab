#!/usr/bin/env python3
# Managed by Ansible (role netmon_node) — do not edit manually.
#
# homelab-netmon-collect — node-exporter textfile metrics for LAN visibility (NM-3, homelab#117).
# Contract: docs/060-network-monitoring.md §5 (metric names, labels, bucket semantics).
#
# Every run (systemd timer, once a minute) writes ONE file atomically:
#   - homelab_lan_connections           current conntrack TCP entries to the watched ports
#   - homelab_ufw_blocks_bucket         [UFW BLOCK] kernel log lines in the last COMPLETED bucket
#   - homelab_sshd_auth_bucket          sshd accepted/failed/invalid_user in the same bucket
#   - homelab_netmon_bucket_end_timestamp_seconds, homelab_netmon_last_success_timestamp_seconds,
#     homelab_netmon_truncated_series
#
# No state is kept on the node: the bucket is recomputed from the journal on every run.
# All-or-nothing: if any command fails, the previous file stays in place (its last-success
# timestamp ages and NetmonNodeScriptStale fires). Usernames are parsed only to classify a
# line and are never emitted.
#
# Python 3 standard library only (no pip), compatible with python3 >= 3.8.
from __future__ import annotations

import argparse
import ipaddress
import os
import re
import subprocess
import sys
import time
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Set, Tuple

OTHER = "other"

METRIC_LAN = "homelab_lan_connections"
METRIC_UFW = "homelab_ufw_blocks_bucket"
METRIC_SSHD = "homelab_sshd_auth_bucket"
METRIC_BUCKET_END = "homelab_netmon_bucket_end_timestamp_seconds"
METRIC_LAST_SUCCESS = "homelab_netmon_last_success_timestamp_seconds"
METRIC_TRUNCATED = "homelab_netmon_truncated_series"

HELP = {
    METRIC_LAN: "Current conntrack TCP entries to a watched local port, by original source.",
    METRIC_UFW: "UFW BLOCK log lines in the last completed 15-minute bucket "
    "(see homelab_netmon_bucket_end_timestamp_seconds).",
    METRIC_SSHD: "sshd authentication results in the last completed 15-minute bucket "
    "(failed is a lower bound).",
    METRIC_BUCKET_END: "End (exclusive, unix seconds) of the bucket the *_bucket gauges describe.",
    METRIC_LAST_SUCCESS: "Unix time of the last successful script run.",
    METRIC_TRUNCATED: 'Series dropped into src_ip="other" because netmon_node_max_series '
    "was exceeded, per metric.",
}

# Label order per metric, as in the contract examples.
LABELS = {
    METRIC_LAN: ("dport", "src_ip", "state"),
    METRIC_UFW: ("src_ip", "dport", "proto"),
    METRIC_SSHD: ("src_ip", "outcome"),
}

# A series key is a tuple of label values in LABELS order.
Key = Tuple[str, ...]
Series = Dict[Key, int]
Runner = Callable[[Sequence[str]], str]

_CONNTRACK_SRC = re.compile(r"\bsrc=(\S+)")
_IP_ADDR = re.compile(r"\binet6? (\S+?)/\d+")
_CONNTRACK_STATE = re.compile(r"^[A-Z_]+$")
_KV = re.compile(r"\b(SRC|DPT|PROTO)=(\S*)")
# The username is attacker-controlled and may itself contain " from <ip> port <n>", so the
# patterns are greedy and anchored at the END of the line: the peer address sshd appends
# last always wins. Outcomes are disjoint: a connection for a non-existent user counts once
# as invalid_user ("Invalid user ..."); its follow-up "Failed ... for invalid user ..." line
# is not counted as failed. "Connection closed by / Disconnected from invalid user ..."
# lines are not counted either (they repeat the same attempt).
_SSHD_PATTERNS = (
    # "Accepted publickey for <user> from <ip> port <n> ssh2: ED25519 SHA256:..."
    ("accepted", re.compile(r"^Accepted \S+ for .* from (\S+) port \d+ ssh2(?:: .*)?$")),
    # "Failed <method> for <user> from <ip> port <n> ssh2[: <key>]" (existing users only)
    (
        "failed",
        re.compile(r"^Failed \S+ for (?!invalid user ).* from (\S+) port \d+ ssh2(?:: .*)?$"),
    ),
    # "Invalid user <user> from <ip> port <n>"
    ("invalid_user", re.compile(r"^Invalid user .* from (\S+) port \d+$")),
)
_KNOWN_PROTOS = {"TCP": "TCP", "UDP": "UDP", "ICMP": "ICMP", "ICMPV6": "ICMP"}


class Classifier:
    """Maps a source IP to the value of the src_ip label (docs/060 §5.2)."""

    def __init__(self, lan_cidr: str, pod_cidr: str) -> None:
        self.lan = ipaddress.ip_network(lan_cidr, strict=False)
        self.pod = ipaddress.ip_network(pod_cidr, strict=False)
        self.pod_label = str(self.pod)

    def classify(self, raw: str, keep_public: bool) -> str:
        try:
            ip = ipaddress.ip_address(raw)
        except ValueError:
            return OTHER
        if ip.version == self.lan.version and ip in self.lan:
            return str(ip)
        if ip.version == self.pod.version and ip in self.pod:
            return self.pod_label
        if keep_public and ip.is_global:
            return str(ip)
        return OTHER


def _normalise(raw: str) -> str:
    try:
        return str(ipaddress.ip_address(raw))
    except ValueError:
        return raw


def _add(series: Series, key: Key, value: int = 1) -> None:
    series[key] = series.get(key, 0) + value


def parse_local_addresses(text: str) -> Set[str]:
    """Parse `ip -o addr show` into the set of this node's own addresses."""
    found = set()
    for raw in _IP_ADDR.findall(text):
        try:
            found.add(str(ipaddress.ip_address(raw)))
        except ValueError:
            continue
    return found


def parse_conntrack(
    text: str, port: int, classifier: Classifier, series: Series, local: Set[str]
) -> None:
    """Parse `conntrack -L -p tcp --orig-port-dst <port>` output into METRIC_LAN series.

    IPv4 only: `conntrack -L` lists the IPv4 table by default and the LAN is IPv4.

    Entries whose original source is one of this node's own addresses are skipped: those
    are this node acting as a client (e.g. the API server calling a kubelet on :10250),
    and the receiving node already counts them as inbound.

    Example line:
    tcp  6 431999 ESTABLISHED src=192.168.1.50 dst=192.168.1.61 sport=51234 dport=1883 \
        src=10.42.0.31 ... [ASSURED] mark=0 use=1
    """
    for line in text.splitlines():
        head, sep, _ = line.partition("src=")
        if not sep:
            continue
        match = _CONNTRACK_SRC.search(line)
        if match is None:
            continue
        state = "NONE"
        for token in head.split():
            if _CONNTRACK_STATE.match(token):
                state = token
        if _normalise(match.group(1)) in local:
            continue
        src = classifier.classify(match.group(1), keep_public=False)
        _add(series, (str(port), src, state))


def _journal_entries(text: str, start: int, end: int) -> Iterable[str]:
    """Yield the message part of `journalctl -o short-unix` lines with start <= ts < end."""
    for line in text.splitlines():
        parts = line.split(" ", 2)
        if len(parts) < 3:
            continue
        try:
            ts = float(parts[0])
        except ValueError:
            continue
        if start <= ts < end:
            # "<ts> <hostname> <identifier>[pid]: <message>" — drop everything up to the
            # identifier's colon so the sshd patterns can anchor on the message start.
            _, sep, message = parts[2].partition(": ")
            if sep:
                yield message


def parse_ufw(text: str, start: int, end: int, classifier: Classifier, series: Series) -> None:
    """Count [UFW BLOCK] kernel log lines by SRC, DPT (absent -> 0) and PROTO."""
    for msg in _journal_entries(text, start, end):
        if "[UFW BLOCK]" not in msg:
            continue
        fields = dict(_KV.findall(msg))
        if "SRC" not in fields:
            continue
        src = classifier.classify(fields["SRC"], keep_public=True)
        dport = fields.get("DPT", "")
        dport = dport if dport.isdigit() else "0"
        proto = _KNOWN_PROTOS.get(fields.get("PROTO", "").upper(), "OTHER")
        _add(series, (src, str(int(dport)), proto))


def parse_sshd(text: str, start: int, end: int, classifier: Classifier, series: Series) -> None:
    """Count sshd authentication outcomes by source IP; usernames are never kept."""
    for msg in _journal_entries(text, start, end):
        for outcome, pattern in _SSHD_PATTERNS:
            match = pattern.match(msg)
            if match:
                src = classifier.classify(match.group(1), keep_public=True)
                _add(series, (src, outcome))
                break


def _fold_key(metric: str, key: Key) -> Key:
    """The key a series is summed into when the cap folds it (src_ip -> "other")."""
    if metric == METRIC_LAN:
        dport, _, state = key
        return (dport, OTHER, state)
    if metric == METRIC_UFW:
        # dport is folded too: one scanner sweeping ports would otherwise stay unbounded.
        _, _, proto = key
        return (OTHER, "0", proto)
    _, outcome = key
    return (OTHER, outcome)


def apply_cap(metric: str, series: Series, max_series: int) -> Tuple[Series, int]:
    """Bound the series count of one metric to max_series.

    The highest-valued series are kept verbatim; the rest are summed into src_ip="other"
    (see _fold_key). Returns (series, number of input series that were folded). The folded
    keys are bounded by the other label domains (ports x states, protos, outcomes), so the
    result stays within max_series unless even zero verbatim series would not fit.
    """
    if len(series) <= max_series:
        return dict(series), 0
    ranked = sorted(series.items(), key=lambda kv: (-kv[1], kv[0]))
    best: Optional[Series] = None
    kept = 0
    for keep in range(min(max_series, len(ranked)), -1, -1):
        result: Series = dict(ranked[:keep])
        for key, value in ranked[keep:]:
            _add(result, _fold_key(metric, key), value)
        best, kept = result, keep
        if len(result) <= max_series:
            break
    assert best is not None
    return best, len(ranked) - kept


def _escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def _labels(pairs: Sequence[Tuple[str, str]]) -> str:
    return "{" + ",".join('{}="{}"'.format(k, _escape(v)) for k, v in pairs) + "}"


def render(
    node: str,
    data: Dict[str, Series],
    truncated: Dict[str, int],
    bucket_end: int,
    now: int,
) -> str:
    lines: List[str] = []

    def header(metric: str) -> None:
        lines.append("# HELP {} {}".format(metric, HELP[metric]))
        lines.append("# TYPE {} gauge".format(metric))

    def sort_key(key: Key) -> Tuple[object, ...]:
        # Numeric ports sort numerically; everything else lexicographically.
        return tuple((0, int(v), "") if v.isdigit() else (1, 0, v) for v in key)

    for metric in (METRIC_LAN, METRIC_UFW, METRIC_SSHD):
        header(metric)
        for key in sorted(data[metric], key=sort_key):
            pairs = [("node", node)] + list(zip(LABELS[metric], key))
            lines.append("{}{} {}".format(metric, _labels(pairs), data[metric][key]))
    header(METRIC_BUCKET_END)
    lines.append("{}{} {}".format(METRIC_BUCKET_END, _labels([("node", node)]), bucket_end))
    header(METRIC_LAST_SUCCESS)
    lines.append("{}{} {}".format(METRIC_LAST_SUCCESS, _labels([("node", node)]), now))
    header(METRIC_TRUNCATED)
    for metric in (METRIC_LAN, METRIC_UFW, METRIC_SSHD):
        pairs = [("node", node), ("metric", metric)]
        lines.append("{}{} {}".format(METRIC_TRUNCATED, _labels(pairs), truncated[metric]))
    return "\n".join(lines) + "\n"


def write_atomic(path: str, content: str) -> None:
    """Write to .<name>.tmp in the same directory, then rename (a scrape never sees half a file).

    The temp name does not end in .prom, so node-exporter ignores a leftover. The directory
    itself is created by Ansible (roles netmon_node and storage), not by this script.
    """
    directory, name = os.path.split(path)
    if not os.path.isdir(directory):
        raise FileNotFoundError(
            "textfile collector directory {} is missing (created by the netmon_node and "
            "storage roles)".format(directory)
        )
    tmp = os.path.join(directory, "." + name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def run_command(argv: Sequence[str]) -> str:
    result = subprocess.run(
        list(argv),
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        universal_newlines=True,
        timeout=20,
    )
    return result.stdout


def bucket_bounds(now: float, bucket_seconds: int) -> Tuple[int, int]:
    """Return [start, end) of the last completed bucket, aligned to the epoch."""
    end = int(now // bucket_seconds) * bucket_seconds
    return end - bucket_seconds, end


def collect(
    node: str,
    lan_cidr: str,
    pod_cidr: str,
    ports: Sequence[int],
    max_series: int,
    bucket_seconds: int,
    now: float,
    runner: Runner = run_command,
    sshd_unit: str = "ssh",
) -> str:
    classifier = Classifier(lan_cidr, pod_cidr)
    start, end = bucket_bounds(now, bucket_seconds)
    data: Dict[str, Series] = {METRIC_LAN: {}, METRIC_UFW: {}, METRIC_SSHD: {}}

    local = parse_local_addresses(runner(["ip", "-o", "addr", "show"]))
    for port in ports:
        out = runner(["conntrack", "-L", "-p", "tcp", "--orig-port-dst", str(port)])
        parse_conntrack(out, port, classifier, data[METRIC_LAN], local)

    window = ["--since", "@{}".format(start), "--until", "@{}".format(end)]
    journal = ["journalctl", "--no-pager", "-q", "-o", "short-unix"]
    parse_ufw(runner(journal + ["-k"] + window), start, end, classifier, data[METRIC_UFW])
    parse_sshd(
        runner(journal + ["-u", sshd_unit] + window), start, end, classifier, data[METRIC_SSHD]
    )

    truncated: Dict[str, int] = {}
    for metric in list(data):
        data[metric], truncated[metric] = apply_cap(metric, data[metric], max_series)
    return render(node, data, truncated, end, int(now))


def _ports(value: str) -> List[int]:
    ports = [int(p) for p in value.split(",") if p.strip()]
    if not ports or any(not 0 < p < 65536 for p in ports):
        raise argparse.ArgumentTypeError("expected a comma-separated list of TCP ports")
    return ports


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--node", required=True, help="value of the node label")
    parser.add_argument("--lan-cidr", required=True)
    parser.add_argument("--pod-cidr", required=True)
    parser.add_argument("--ports", required=True, type=_ports, help="e.g. 1883,22,8123")
    parser.add_argument("--max-series", type=int, default=200)
    parser.add_argument("--bucket-seconds", type=int, default=900)
    parser.add_argument("--sshd-unit", default="ssh")
    parser.add_argument("--output", required=True, help="path of the .prom file")
    args = parser.parse_args(argv)
    if args.max_series < 1 or args.bucket_seconds < 60:
        parser.error("--max-series must be >= 1 and --bucket-seconds >= 60")

    content = collect(
        node=args.node,
        lan_cidr=args.lan_cidr,
        pod_cidr=args.pod_cidr,
        ports=args.ports,
        max_series=args.max_series,
        bucket_seconds=args.bucket_seconds,
        now=time.time(),
        # Looked up at call time (not a default argument) so tests can substitute it.
        runner=run_command,
        sshd_unit=args.sshd_unit,
    )
    write_atomic(args.output, content)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (subprocess.SubprocessError, OSError, ValueError) as exc:
        # Short reason only — never dump command output (it contains IPs, not secrets, but
        # the journal is the place for it, not this unit's status line).
        print("homelab-netmon-collect: {}: {}".format(type(exc).__name__, exc), file=sys.stderr)
        sys.exit(1)
