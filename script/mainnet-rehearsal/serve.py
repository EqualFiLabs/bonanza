#!/usr/bin/env python3
"""Detached Anvil owner. Never persist the upstream URL or its error messages."""
import json
import os
import signal
import subprocess
import sys
from pathlib import Path

run = Path(sys.argv[1])
state = json.loads((run / "environment.json").read_text())
upstream = os.environ["ROBINHOOD_MAINNET"]
command = ["anvil", "--silent", "--host", "127.0.0.1", "--port", str(state["port"]),
           "--fork-url", upstream, "--fork-block-number", str(state["forkBlock"]),
           "--chain-id", "4663", "--hardfork", "osaka", "--accounts", "12",
           "--balance", "10000", "--gas-limit", "30000000"]
child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(run / "anvil.pid").write_text(str(child.pid))
signal.signal(signal.SIGTERM, lambda *_: child.terminate())
with (run / "anvil.log").open("a") as log:
    for line in child.stdout:
        # Provider errors can include credentials in encoded/partial URLs: discard their text.
        text = line.decode(errors="replace")
        log.write("[Anvil diagnostic suppressed: may contain upstream credentials]\n" if
                  any(x in text.lower() for x in ("http", "rpc", "url", "provider", "apikey"))
                  else text.replace(upstream, "[private upstream]"))
        log.flush()
sys.exit(child.wait())
