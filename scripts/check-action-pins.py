#!/usr/bin/env python3
"""Allowlist gate for GitHub Actions `uses:` refs (homelab-device-service#126).

Parses every workflow file under the given directory (default:
.github/workflows) and checks every `uses` value found anywhere in the
document (job-level reusable workflows, steps, flow-style mappings, quoted
keys). Each value must have one of these shapes:

  - ./local/path                          (an action or workflow in this repo)
  - owner/repo[/path]@<40-hex commit SHA>
  - docker://image@sha256:<64-hex digest>

This is an allowlist on purpose: a denylist that looks for `@v1`-style refs
misses bare tags (`@2.0.0`), branches (`@main`, `@stable`), short SHAs and
docker tags. Parsing the YAML (instead of grepping lines) means comments are
never checked and no line layout can hide a ref. A file that does not parse
fails the check.

GitHub's per-repo setting `sha_pinning_required` is the control enforced at
run time; this script gives fast feedback on pull requests.

Usage: scripts/check-action-pins.py [directory]
Needs PyYAML (CI installs a pinned version).
"""

import pathlib
import re
import sys

import yaml

ALLOWED = (
    re.compile(r"\./[^\s]+"),
    re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}"),
    re.compile(r"docker://[^\s@]+@sha256:[0-9a-f]{64}"),
)


def find_uses(node, path):
    """Yield (path, value) for every `uses` key in the parsed document."""
    if isinstance(node, dict):
        for key, value in node.items():
            child = f"{path}.{key}"
            if key == "uses":
                yield child, value
            else:
                yield from find_uses(value, child)
    elif isinstance(node, list):
        for index, item in enumerate(node):
            yield from find_uses(item, f"{path}[{index}]")


def is_pinned(value):
    return isinstance(value, str) and any(p.fullmatch(value) for p in ALLOWED)


def main():
    directory = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".github/workflows")
    if not directory.is_dir():
        print(f"No such directory: {directory}", file=sys.stderr)
        return 2

    files = sorted(p for p in directory.rglob("*") if p.suffix in (".yml", ".yaml") and p.is_file())
    bad = []
    count = 0
    for file in files:
        try:
            documents = list(yaml.safe_load_all(file.read_text(encoding="utf-8")))
        except yaml.YAMLError as exc:
            bad.append(f"{file}: does not parse as YAML ({exc.__class__.__name__})")
            continue
        for document in documents:
            for path, value in find_uses(document, ""):
                count += 1
                if not is_pinned(value):
                    bad.append(f"{file}: {path.lstrip('.')} = {value!r}")

    if bad:
        print("\n".join(bad))
        print(
            "Unpinned uses: ref(s) found. Allowed: ./local/path, "
            "owner/repo@<40-hex commit SHA>, docker://image@sha256:<64-hex digest>.",
            file=sys.stderr,
        )
        return 1

    print(f"All {count} uses: refs in {len(files)} file(s) under {directory} are pinned.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
