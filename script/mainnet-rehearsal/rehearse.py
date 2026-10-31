#!/usr/bin/env python3
"""Pinned mainnet state, local deployments, mined abuse and lifecycle evidence."""
import argparse
import datetime
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

from web3 import Web3
from hexbytes import HexBytes
from common import ROOT, Rehearsal, ZERO, WAD, write, require, plain

HERE = Path(__file__).resolve().parent
ARTIFACTS = ROOT / ".rehearsal"


def upstream(method, params):
    url = os.environ.get("ROBINHOOD_MAINNET")
    require(bool(url), "Load the canonical RPC environment first")
    try:
        request = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1,
            "method": method, "params": params}).encode(), {"Content-Type": "application/json"})
        result = json.load(urllib.request.urlopen(request, timeout=45))
        require("error" not in result, "Upstream RPC returned an error")
        return result["result"]
    except Exception:
        raise RuntimeError(f"Configured upstream {method} failed; private endpoint withheld") from None


def provenance(run, environment):
    environment["sourceCommit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    environment["sourceDiffHash"] = plain(Web3.keccak(subprocess.check_output(["git", "diff", "HEAD"], cwd=ROOT)))
    paths = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT).decode().split("\0")
    sources = {name: plain(Web3.keccak((ROOT / name).read_bytes())) for name in paths if name and (ROOT / name).is_file()}
    write(run / "source-files.json", sources)
    environment["sourceFilesHash"] = plain(Web3.keccak(text=json.dumps(sources, sort_keys=True)))
    environment["submodules"] = subprocess.check_output(["git", "submodule", "status"], cwd=ROOT, text=True).strip().splitlines()
    environment["tools"] = {tool: subprocess.check_output([tool, "--version"], text=True).splitlines()[0] for tool in ["forge", "anvil", "cast"]}
    write(run / "environment.json", environment)


def start(args):
    require(1 <= args.port <= 65535 and 1 <= args.steps <= 10000, "Invalid port or soak bounds")
    with socket.socket() as sock:
        require(sock.connect_ex(("127.0.0.1", args.port)) != 0, "Port already occupied; choose another")
    config = json.loads((HERE / "mainnet.json").read_text())
    require(int(upstream("eth_chainId", []), 16) == 4663, "Wrong upstream chain")
    head = upstream("eth_getBlockByNumber", ["latest", False])
    if args.fork_block:
        height = args.fork_block
    else:
        # Leave real, already published beacons available after the Router's 24-hour timelock.
        target = int(head["timestamp"], 16) - 30 * 3600
        low, high = config["drand"]["deploymentBlock"], int(head["number"], 16)
        while low < high:
            mid = (low + high + 1) // 2
            block = upstream("eth_getBlockByNumber", [hex(mid), False])
            if int(block["timestamp"], 16) <= target:
                low = mid
            else:
                high = mid - 1
        height = low
    block = upstream("eth_getBlockByNumber", [hex(height), False])
    require(height >= config["drand"]["deploymentBlock"], "Fork predates drand deployment")
    runtime = upstream("eth_getCode", [config["drand"]["address"], hex(height)])
    require(plain(Web3.keccak(HexBytes(runtime))) == config["drand"]["runtimeCodeHash"], "Drand runtime mismatch")
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run = ARTIFACTS / stamp
    run.mkdir(parents=True, exist_ok=False)
    environment = {"port": args.port, "forkBlock": height, "forkHash": block["hash"],
        "forkTimestamp": int(block["timestamp"], 16),
        "chainId": 4663, "seed": args.seed, "soakSteps": args.steps}
    provenance(run, environment)
    service = subprocess.Popen([sys.executable, str(HERE / "serve.py"), str(run)],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    (run / "service.pid").write_text(str(service.pid))
    w3 = Web3(Web3.HTTPProvider(f"http://127.0.0.1:{args.port}", request_kwargs={"timeout": 2}))
    for _ in range(120):
        try:
            if w3.is_connected():
                break
        except Exception:
            pass
        if service.poll() is not None:
            raise RuntimeError(f"Anvil exited; inspect {run / 'anvil.log'}")
        time.sleep(0.5)
    require(w3.is_connected(), "Anvil failed to start")
    metadata = w3.provider.make_request("anvil_metadata", [])["result"]
    environment["instanceId"] = metadata["instanceId"]
    environment["initialSnapshot"] = w3.provider.make_request("evm_snapshot", [])["result"]
    write(run / "environment.json", environment)
    (ARTIFACTS / "current").write_text(str(run))
    print(f"Pinned fork {height} {block['hash']}; local RPC http://127.0.0.1:{args.port}", flush=True)
    return run


def build(run):
    builds = [
        ("lottery", ["forge", "build", "--skip", "test"]),
        ("statics", ["forge", "build", "--config-path", "integration/foundry.toml"]),
        ("router", ["forge", "build", "--root", "lib/operator-fee-router", "--skip", "test", "--skip", "script"]),
    ]
    for group, command in builds:
        command += ["--out", str(run / f"out-{group}"), "--cache-path", str(run / f"cache-{group}"),
                    "--extra-output", "evm.deployedBytecode.immutableReferences"]
        print(f"Building isolated {group} artifacts", flush=True)
        with (run / f"build-{group}.log").open("w") as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        require(result.returncode == 0, f"{group} build failed; inspect local build log")


def stop():
    run = Path((ARTIFACTS / "current").read_text())
    rehearsal = Rehearsal(run)
    rehearsal.guard()
    pid = int((run / "service.pid").read_text())
    command = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
    require(str(HERE / "serve.py").encode() in command and str(run).encode() in command,
            "Service PID is no longer owned by this run")
    os.kill(pid, signal.SIGTERM)
    print("Stopped the owned rehearsal Anvil; artifacts retained")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["run", "start", "resume", "stop"], nargs="?", default="run")
    parser.add_argument("--port", type=int, default=8855)
    parser.add_argument("--fork-block", type=int)
    parser.add_argument("--seed", type=int, default=2631)
    parser.add_argument("--steps", type=int, default=80)
    args = parser.parse_args()
    if args.command == "stop":
        stop()
        return
    if args.command == "resume":
        run = Path((ARTIFACTS / "current").read_text())
        r = Rehearsal(run)
        snapshot = r.environment.get("initialSnapshot")
        require(snapshot, "No restart snapshot; start a new run")
        require(r.rpc("evm_revert", [snapshot]), "Initial snapshot is unavailable")
        r.environment["initialSnapshot"] = r.rpc("evm_snapshot", [])
        # Keep failed attempt evidence; never overwrite receipts or a previous result.
        attempts = run / "attempts"
        attempts.mkdir(exist_ok=True)
        archive = attempts / str(time.time_ns())
        archive.mkdir()
        write(archive / "environment.json", json.loads((run / "environment.json").read_text()))
        for item in list(run.iterdir()):
            if item.name in {"source-files.json", "receipts", "deployments.json", "summary.json", "results.json", "selector-coverage.json", "bindings.json", "fixture-provenance.json", "soak-actions.json"} or item.name.startswith("reconciliation-"):
                item.rename(archive / item.name)
        provenance(run, r.environment)
    else:
        run = start(args)
    if args.command == "start":
        return
    build(run)
    from scenarios import Campaign
    campaign = Campaign(run)
    try:
        campaign.execute()
    except Exception as error:
        safe_error = re.sub(r"https?://[^\s\x22\x27)]+", "[endpoint withheld]", str(error))
        write(run / "summary.json", {"passed": False, "error": safe_error, "environment": campaign.environment})
        raise


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        message = re.sub(r"https?://[^\s\x22\x27)]+", "[endpoint withheld]", str(error))
        print(f"Rehearsal failed: {type(error).__name__}: {message}", file=sys.stderr)
        sys.exit(1)
