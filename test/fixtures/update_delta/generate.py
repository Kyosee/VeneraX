"""Regenerate independent BSDIFF40 fixtures with bsdiff4==1.2.6."""

import base64
import hashlib
import json
from pathlib import Path

import bsdiff4


def encoded(data):
    return base64.b64encode(data).decode("ascii")


block_a = bytes(range(256)) * 3
block_b = bytes(reversed(range(256))) * 2
cases = [
    ("insert_delete", b"prefix:one:two:three:suffix", b"new:prefix:one:THREE:suffix!"),
    ("move_repeat", block_a + block_b + block_a, block_b + block_a + block_a + block_b),
    ("empty_old", b"", b"new bytes\x00\xff"),
    ("empty_new", b"removed bytes\x00\xff", b""),
    ("both_empty", b"", b""),
    ("unchanged", b"unchanged\x00\xff", b"unchanged\x00\xff"),
]
fixtures = []
for name, old, new in cases:
    patch = bsdiff4.diff(old, new)
    assert bsdiff4.patch(old, patch) == new
    fixtures.append({"name": name, "old": encoded(old), "new": encoded(new), "patch": encoded(patch)})

Path(__file__).with_name("bsdiff4.json").write_text(
    json.dumps({"generator": "bsdiff4 1.2.6", "cases": fixtures}, indent=2) + "\n",
    encoding="utf-8",
)

# Keep a large reconstruction fixture tiny on disk for cancellation coverage.
large_output = b"X" * (16 * 1024 * 1024)
large_patch = bsdiff4.diff(b"", large_output)
assert bsdiff4.patch(b"", large_patch) == large_output
Path(__file__).with_name("large-output.json").write_text(
    json.dumps({
        "generator": "bsdiff4 1.2.6",
        "size": len(large_output),
        "sha256": hashlib.sha256(large_output).hexdigest(),
        "patch": encoded(large_patch),
    }, indent=2) + "\n",
    encoding="utf-8",
)
