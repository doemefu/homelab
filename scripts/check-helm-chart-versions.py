#!/usr/bin/env python3
"""Check whether any Helm chart pinned in .github/helm-tracking/Chart.yaml
has a newer version available upstream.

This replaces Dependabot's "helm" package-ecosystem, which ran for ~14
weekly cycles (2026-05-27 to 2026-09-04) against this same tracking chart
without ever opening a PR, despite real available updates on 4 of its 6
charts. See .github/dependabot.yml and CONTRIBUTING.md "Helm Chart Version
Tracking" for the full story. Run by
.github/workflows/helm-chart-freshness.yml on a weekly schedule, or
manually for a one-off check:

    python3 scripts/check-helm-chart-versions.py [--dry-run]

Always exits 0 in normal operation (the workflow step decides what to do
with the report); exits 1 only if every tracked chart's repository was
unreachable (a real infrastructure failure, not "everything is current").
--dry-run prints the report only, skipping the GITHUB_OUTPUT lines the
workflow step consumes.
"""

import argparse
import os
import re
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
CHART_YAML = REPO_ROOT / ".github" / "helm-tracking" / "Chart.yaml"
USER_AGENT = "homelab-helm-chart-freshness-check (+https://github.com/doemefu/homelab)"

# Fixed width for the padded numeric-release tuple in semver_key() — comfortably
# more than any real chart version's segment count (major.minor.patch plus margin).
_RELEASE_WIDTH = 6


def semver_key(version):
    """Semver-aware sort key.

    Numeric release segments compare numerically and are padded to a fixed
    width so unequal segment counts compare correctly — e.g. "2.0" and
    "2.0.0" must be equal for ordering purposes, not "2.0" < "2.0.0" purely
    because its tuple is shorter (a naive string-sort attempt hit exactly
    this class of bug during #62's research, on real data: "69.3.1" sorted
    below "9.4.9" as plain strings).

    A pre-release suffix (anything after the first "-") always sorts BELOW
    a bare release with the same numeric segments, per semver precedence
    (e.g. "1.7.2-rc1" < "1.7.2"), rather than "below" as an accident of a
    longer key tuple — this matters here because some of the chart
    repositories checked (e.g. cert-manager's) list alpha/beta/rc releases
    interleaved with stable ones in the same index.
    """
    stripped = version.lstrip("vV").split("+", 1)[0]  # ignore build metadata
    release_part, _, prerelease_part = stripped.partition("-")

    release_segments = []
    for segment in release_part.split("."):
        match = re.match(r"^\d+", segment)
        release_segments.append(int(match.group()) if match else 0)
    release_segments += [0] * (_RELEASE_WIDTH - len(release_segments))

    has_prerelease = bool(prerelease_part)
    prerelease_segments = []
    if has_prerelease:
        for part in re.split(r"[.\-]", prerelease_part):
            match = re.match(r"^\d+$", part)
            # Numeric identifiers sort before alphanumeric ones at the same
            # position, per semver precedence rules.
            prerelease_segments.append((0, int(part)) if match else (1, part))

    # `not has_prerelease` ranks any bare release above a prerelease of the
    # same numeric version (False < True in Python, so prerelease's False
    # sorts first / lower).
    return (tuple(release_segments), not has_prerelease, tuple(prerelease_segments))


def fetch_index(repository_url):
    url = repository_url.rstrip("/") + "/index.yaml"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        return yaml.safe_load(response.read())


def latest_version(index, chart_name):
    entries = (index or {}).get("entries", {}).get(chart_name)
    if not entries:
        return None
    versions = [entry["version"] for entry in entries if "version" in entry]
    if not versions:
        return None
    return sorted(versions, key=semver_key)[-1]


def build_report(outdated, current, errors):
    lines = ["# Helm chart freshness report", ""]
    if outdated:
        lines.append("| Chart | Pinned | Latest | Repository |")
        lines.append("|-------|--------|--------|------------|")
        for name, pinned, latest, repo in outdated:
            lines.append("| {} | {} | {} | {} |".format(name, pinned, latest, repo))
    else:
        lines.append("All tracked charts are at their latest available version.")
    if current:
        lines.append("")
        lines.append(
            "Up to date: "
            + ", ".join("{} ({})".format(name, version) for name, version in current)
        )
    if errors:
        lines.append("")
        lines.append("Errors (could not determine latest version):")
        for name, repo, message in errors:
            lines.append("- {} ({}): {}".format(name, repo, message))
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the report only, skip writing GITHUB_OUTPUT",
    )
    args = parser.parse_args()

    chart = yaml.safe_load(CHART_YAML.read_text())
    dependencies = chart.get("dependencies", [])

    outdated = []
    current = []
    errors = []
    for dependency in dependencies:
        name = dependency["name"]
        pinned = dependency["version"]
        repository = dependency["repository"]
        try:
            index = fetch_index(repository)
            latest = latest_version(index, name)
        except (urllib.error.URLError, ValueError, KeyError) as exc:
            errors.append((name, repository, str(exc)))
            continue
        if latest is None:
            errors.append((name, repository, "chart name not found in index.yaml"))
            continue
        if semver_key(latest) > semver_key(pinned):
            outdated.append((name, pinned, latest, repository))
        else:
            current.append((name, pinned))

    report = build_report(outdated, current, errors)
    print(report)

    if not args.dry_run:
        github_output = os.environ.get("GITHUB_OUTPUT")
        if github_output:
            with open(github_output, "a") as handle:
                handle.write("outdated={}\n".format("true" if outdated else "false"))
                handle.write("has_errors={}\n".format("true" if errors else "false"))
                # A random, unguessable delimiter — the report body embeds
                # `name`/`version` strings read from six *external*,
                # untrusted index.yaml files, so a fixed delimiter string
                # could in principle be used to inject extra key=value
                # lines into GITHUB_OUTPUT if an upstream index ever
                # contained a matching line.
                delimiter = "helm_freshness_report_{}".format(uuid.uuid4().hex)
                handle.write("report<<{}\n{}\n{}\n".format(delimiter, report, delimiter))

    # A hard failure (every chart errored, nothing resolvable at all) should
    # fail the workflow step so it's visible in the Actions log. A partial
    # failure (some charts errored, others resolved fine) is surfaced via
    # the `has_errors` output instead of a non-zero exit, so the workflow
    # can still open/update the tracking issue with the partial report
    # rather than silently dropping the error the way the Dependabot helm
    # channel this replaces used to (see the "R3" risk note in the plan).
    if errors and not outdated and not current:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
