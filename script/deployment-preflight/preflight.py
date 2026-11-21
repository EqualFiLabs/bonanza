"""Read-only dependency checks before a fresh Bonanza deployment."""

import argparse
import json
import os
import re
import sys
from pathlib import Path

from web3 import Web3


REQUIRED_CONTRACTS = (
    "registry",
    "statics",
    "positionNFT",
    "router",
    "operatorCollection",
    "activationRegistry",
    "operatorVault",
    "authority",
)
ROUTER_BINDINGS = ("operatorCollection", "activationRegistry", "operatorVault")
ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}\Z")
HASH = re.compile(r"0x[0-9a-fA-F]{64}\Z")
STATICS_EXTERNAL_MODULE_INTERFACE = "2795ac62"


def validate_manifest(manifest):
    """Reject incomplete or ambiguous expectations before making any RPC call."""
    if (not isinstance(manifest, dict) or not isinstance(manifest.get("chainId"), int)
            or isinstance(manifest["chainId"], bool)):
        raise ValueError("chainId must be an integer")
    if manifest["chainId"] <= 0:
        raise ValueError("chainId must be positive")

    contracts = manifest.get("contracts")
    if not isinstance(contracts, dict) or not set(REQUIRED_CONTRACTS) <= set(contracts):
        raise ValueError(f"contracts must contain: {', '.join(REQUIRED_CONTRACTS)}")
    for name, entry in contracts.items():
        if not isinstance(entry, dict) or set(entry) != {"address", "runtimeCodeHash"}:
            raise ValueError(f"contracts.{name} needs address and runtimeCodeHash")
        if not isinstance(entry["address"], str) or not ADDRESS.fullmatch(entry["address"]):
            raise ValueError(f"contracts.{name}.address must be a 20-byte hex address")
        if not isinstance(entry["runtimeCodeHash"], str) or not HASH.fullmatch(entry["runtimeCodeHash"]):
            raise ValueError(f"contracts.{name}.runtimeCodeHash must be a 32-byte hex hash")
        if int(entry["address"], 16) == 0:
            raise ValueError(f"contracts.{name}.address cannot be zero")

    assets = manifest.get("rewardAssets")
    if not isinstance(assets, list):
        raise ValueError("rewardAssets must be a list of contract names")
    if (any(not isinstance(asset, str) for asset in assets)
            or len(set(assets)) != len(assets)
            or any(asset not in contracts for asset in assets)):
        raise ValueError("rewardAssets must name distinct entries in contracts")

    delay = manifest.get("minimumAuthorityDelaySeconds")
    if not isinstance(delay, int) or isinstance(delay, bool) or delay <= 0:
        raise ValueError("minimumAuthorityDelaySeconds must be a positive integer")
    if set(manifest) != {"chainId", "contracts", "rewardAssets", "minimumAuthorityDelaySeconds"}:
        raise ValueError("manifest has unknown or missing top-level fields")
    return manifest


def _call(w3, block, address, signature, argument=None):
    selector = Web3.keccak(text=signature)[:4]
    if signature == "supportsInterface(bytes4)":
        encoded = bytes.fromhex(argument[2:]).ljust(32, b"\0")
    else:
        encoded = bytes.fromhex(argument[2:]).rjust(32, b"\0") if argument else b""
    data = selector + encoded
    result = bytes(w3.eth.call({"to": Web3.to_checksum_address(address), "data": data},
                               block_identifier=block))
    if len(result) != 32:
        raise ValueError("unexpected return length")
    return int.from_bytes(result, "big")


def _block_hash(w3, block):
    block_hash = bytes(w3.eth.get_block(block)["hash"])
    if len(block_hash) != 32:
        raise ValueError("invalid block hash")
    return block_hash


def check(manifest, w3):
    """Return all failed checks; never send a transaction."""
    failures = []
    contracts = manifest["contracts"]
    try:
        actual_chain = w3.eth.chain_id
        if actual_chain != manifest["chainId"]:
            return [f"chain ID: expected {manifest['chainId']}, got {actual_chain}"]
    except Exception:
        return ["chain ID: RPC read failed"]
    try:
        block = w3.eth.block_number
    except Exception:
        return failures + ["block number: RPC read failed"]
    try:
        original_hash = _block_hash(w3, block)
    except Exception:
        return failures + ["block hash: initial RPC read failed"]
    block_ref = {"blockHash": "0x" + original_hash.hex(), "requireCanonical": True}

    for name, entry in contracts.items():
        try:
            code = bytes(w3.eth.get_code(Web3.to_checksum_address(entry["address"]),
                                         block_identifier=block_ref))
            if not code:
                failures.append(f"{name}: no contract code")
            elif Web3.keccak(code).hex().removeprefix("0x").lower() != entry["runtimeCodeHash"][2:].lower():
                failures.append(f"{name}: runtime code hash mismatch")
        except Exception:
            failures.append(f"{name}: code read failed")

    position = contracts["positionNFT"]["address"]
    try:
        result = _call(w3, block_ref, position, "supportsInterface(bytes4)",
                       "0x" + STATICS_EXTERNAL_MODULE_INTERFACE)
        if result != 1:
            failures.append("positionNFT: Statics external-module interface unsupported")
    except Exception:
        failures.append("positionNFT: interface read failed")

    router = contracts["router"]["address"]
    for name in ROUTER_BINDINGS:
        try:
            actual = _call(w3, block_ref, router, f"{name}()")
            expected = int(contracts[name]["address"], 16)
            if actual != expected:
                failures.append(f"router: {name} binding mismatch")
        except Exception:
            failures.append(f"router: {name} read failed")
    if manifest["rewardAssets"]:
        try:
            if _call(w3, block_ref, router, "bootstrapFinalized()") != 1:
                failures.append("router: bootstrap is not finalized")
        except Exception:
            failures.append("router: bootstrap read failed")
        try:
            if _call(w3, block_ref, router, "totalEffectiveWeight()") == 0:
                failures.append("router: effective weight is zero")
        except Exception:
            failures.append("router: effective weight read failed")
    for asset_name in manifest["rewardAssets"]:
        asset = contracts[asset_name]["address"]
        for signature, label in (("isRewardAsset(address)", "not registered"),
                                 ("rewardAssetEnabled(address)", "disabled")):
            try:
                if _call(w3, block_ref, router, signature, asset) != 1:
                    failures.append(f"router: {asset_name} {label}")
            except Exception:
                failures.append(f"router: {asset_name} readiness read failed")

    authority = contracts["authority"]["address"]
    try:
        delay = _call(w3, block_ref, authority, "getMinDelay()")
        if delay < manifest["minimumAuthorityDelaySeconds"]:
            failures.append("authority: timelock delay below required minimum")
    except Exception:
        failures.append("authority: getMinDelay() read failed")
    try:
        if _block_hash(w3, block) != original_hash:
            failures.append("block hash: selected height changed during preflight")
    except Exception:
        failures.append("block hash: final RPC read failed")
    return failures


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--rpc-env", default="ROBINHOOD_MAINNET",
                        help="name of an environment variable containing the RPC URL")
    args = parser.parse_args(argv)
    try:
        manifest = validate_manifest(json.loads(args.manifest.read_text()))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"Invalid preflight manifest: {exc}", file=sys.stderr)
        return 2
    rpc_url = os.environ.get(args.rpc_env)
    if not rpc_url:
        print(f"Missing RPC environment variable: {args.rpc_env}", file=sys.stderr)
        return 2
    # Do not print the URL or transport exceptions, which can contain credentials.
    w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": 15}))
    failures = check(manifest, w3)
    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1
    print("PASS deployment dependency preflight")
    return 0


if __name__ == "__main__":
    sys.exit(main())
