#!/usr/bin/env python3
"""Fail closed on dependency drift or ABI differences across compiler boundaries."""
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
pin = "b59017b625de6b0dbfe5fd0b9f56248066da4497"
assert subprocess.check_output(["git", "-C", str(root / "lib/statics"), "rev-parse", "HEAD"], text=True).strip() == pin

def abi(path):
    return sorted(json.dumps(x, sort_keys=True) for x in json.loads(path.read_text())["abi"])

assert abi(root / "out/IStaticsExternalModules.sol/IStaticsExternalModules.json") == abi(root / "out-statics/IStaticsExternalModules.sol/IStaticsExternalModules.json"), "Statics ABI drift"
print("Pinned Statics external-module ABI parity: passed")
