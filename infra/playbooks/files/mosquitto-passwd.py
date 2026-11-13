#!/usr/bin/env python3
"""Render a Mosquitto password_file with deterministic `$7$` hashes (homelab#122).

Input (stdin, JSON): a list of {"name": "<user>", "password": "<plaintext>"}.
Output (stdout): one line per user, in input order:

    <user>:$7$<iterations>$<base64 salt>$<base64 hash>

`$7$` is Mosquitto's PBKDF2-HMAC-SHA512 format with a 64-byte derived key.
Mosquitto 2.1 accepts a salt of exactly 12 or 64 bytes
(libcommon/password_common.c, pw__decode_sha512_pbkdf2). The salt here is
PBKDF2-HMAC-SHA512(password, "mosquitto-passwd-salt:" + username) with the
same 100 000 iterations, truncated to 12 bytes. It is deterministic, so a
second playbook run renders the same file and Ansible reports no change, and
different users or passwords still get different salts. Because the salt
costs as much to compute as the hash, the published salt is no faster to
test a password guess against than the hash itself (a single fast keyed hash
of the password as salt would let an attacker skip the work factor).

Passwords are read from stdin only, never from argv or the environment, and
are never printed. Standard library only.
"""

import base64
import hashlib
import json
import re
import sys

ITERATIONS = 100_000
SALT_BYTES = 12
HASH_BYTES = 64
USERNAME = re.compile(r"[A-Za-z0-9_-]{1,64}")
SALT_CONTEXT = b"mosquitto-passwd-salt:"


def hash_line(name, password):
    pw = password.encode("utf-8")
    salt = hashlib.pbkdf2_hmac("sha512", pw, SALT_CONTEXT + name.encode("utf-8"), ITERATIONS, SALT_BYTES)
    derived = hashlib.pbkdf2_hmac("sha512", pw, salt, ITERATIONS, HASH_BYTES)
    salt64 = base64.b64encode(salt).decode("ascii")
    hash64 = base64.b64encode(derived).decode("ascii")
    return f"{name}:$7${ITERATIONS}${salt64}${hash64}"


def fail(message):
    print(f"mosquitto-passwd: {message}", file=sys.stderr)
    sys.exit(2)


def main():
    try:
        users = json.load(sys.stdin)
    except json.JSONDecodeError:
        fail("stdin is not valid JSON")
    if not isinstance(users, list) or not users:
        fail("expected a non-empty JSON list of users")

    seen = set()
    lines = []
    for index, user in enumerate(users):
        if not isinstance(user, dict):
            fail(f"entry {index} is not an object")
        name = user.get("name")
        password = user.get("password")
        if not isinstance(name, str) or not USERNAME.fullmatch(name):
            fail(f"entry {index}: name must match [A-Za-z0-9_-]{{1,64}}")
        if name in seen:
            fail(f"duplicate user {name}")
        if not isinstance(password, str) or not password or "\n" in password or "\r" in password:
            fail(f"user {name}: password must be a non-empty single-line string")
        seen.add(name)
        lines.append(hash_line(name, password))

    sys.stdout.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
