"""Receipt-backed operations restricted to one owned loopback Anvil instance."""
import json
import subprocess
from pathlib import Path
from urllib.parse import urlsplit

from eth_utils.abi import abi_to_signature
from hexbytes import HexBytes
from web3 import Web3

ROOT = Path(__file__).resolve().parents[2]
ZERO = "0x" + "00" * 20
ZERO32 = b"\0" * 32
WAD = 10**18
RAY = 10**27
MAX = 2**256 - 1


def plain(value):
    if isinstance(value, (bytes, bytearray, HexBytes)):
        return "0x" + value.hex()
    if isinstance(value, dict) or hasattr(value, "items"):
        return {str(k): plain(v) for k, v in value.items()}
    if isinstance(value, (tuple, list)):
        return [plain(v) for v in value]
    return value


def write(path, value):
    Path(path).write_text(json.dumps(plain(value), indent=2) + "\n")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def local_url(url):
    parsed = urlsplit(url)
    require(parsed.scheme == "http" and parsed.hostname == "127.0.0.1"
            and parsed.port and not parsed.username and not parsed.password
            and parsed.path in ("", "/") and not parsed.query and not parsed.fragment,
            "Only an explicit loopback Anvil URL is allowed")
    return parsed.port


class Rehearsal:
    def __init__(self, run):
        self.run = Path(run)
        self.environment = json.loads((self.run / "environment.json").read_text())
        self.url = f'http://127.0.0.1:{self.environment["port"]}'
        local_url(self.url)
        self.w3 = Web3(Web3.HTTPProvider(self.url, request_kwargs={"timeout": 90}))
        self.guard()
        self.actors = self.w3.eth.accounts
        self.owner, self.alice, self.bob, self.carol, self.treasury, self.guardian = self.actors[:6]
        self.counter = 0
        self.scenario = "deployment"
        self.coverage = {}
        self.deployed = {}
        self.rounds = []
        self.positions = []
        self.assets = []
        self.lottery = None
        self.results = []

    def rpc(self, method, params):
        result = self.w3.provider.make_request(method, params)
        if "error" in result:
            # This provider is local, but it may relay a private upstream error.
            raise RuntimeError(f"Local RPC {method} failed (details withheld)")
        return result["result"]

    def guard(self):
        require(self.w3.eth.chain_id == 4663, "Wrong local chain")
        require("anvil" in self.w3.client_version.lower(), "Not Anvil")
        meta = self.rpc("anvil_metadata", [])
        expected = self.environment.get("instanceId")
        require(not expected or meta["instanceId"] == expected, "Anvil instance changed")
        fork = meta["forkedNetwork"]
        require(int(fork["forkBlockNumber"]) == self.environment["forkBlock"], "Fork changed")
        require(fork["forkBlockHash"].lower() == self.environment["forkHash"].lower(), "Fork hash changed")

    def artifact(self, name, group="lottery"):
        matches = list((self.run / f"out-{group}").glob(f"**/{name}.json"))
        matches = [p for p in matches if p.parent.name.endswith(".sol")]
        require(len(matches) == 1, f"Ambiguous/missing {group} artifact {name}")
        return json.loads(matches[0].read_text())

    def contract(self, address, name, group="lottery"):
        return self.w3.eth.contract(address=Web3.to_checksum_address(address),
                                   abi=self.artifact(name, group)["abi"])

    def call(self, fn, sender=None):
        result = fn.call({"from": sender or self.owner})
        if self.lottery and fn.address == self.lottery.address:
            self.record_coverage(fn, "view", None)
        return result

    def record_coverage(self, fn, kind, receipt):
        signature = abi_to_signature(fn.abi)
        row = self.coverage.setdefault(signature, {"view": [], "success": [], "revert": []})
        row[kind].append({"scenario": self.scenario,
                          "transactionHash": plain(receipt["transactionHash"]) if receipt else None})

    def tx(self, fn, sender=None, value=0, error=None, check=None, gas=12_000_000):
        self.guard()
        before = check() if check else None
        transaction = {"from": sender or self.owner, "gas": gas, "value": value,
                       "gasPrice": max(self.w3.eth.gas_price, 100_000_000)}
        transaction["to"] = fn.address
        transaction["data"] = fn._encode_transaction_data()
        receipt = self.w3.eth.wait_for_transaction_receipt(self.w3.eth.send_transaction(transaction))
        self.counter += 1
        path = self.run / "receipts" / f"{self.counter:05d}.json"
        path.parent.mkdir(exist_ok=True)
        row = {"scenario": self.scenario, "signature": abi_to_signature(fn.abi),
               "expectedError": error, "transaction": transaction, "receipt": receipt}
        write(path, row)  # Retain evidence even when the assertion below fails.
        if error:
            require(receipt.status == 0, f"Expected revert: {error}")
            trace = self.rpc("debug_traceTransaction", [plain(receipt.transactionHash), {"tracer": "callTracer"}])
            row["trace"] = trace
            write(path, row)
            output = trace.get("output", "0x")
            expected = "0x" + Web3.keccak(text=error)[:4].hex()
            require(output.startswith(expected), f"Expected {error}, got {output[:10]}")
            if check:
                after = check()
                row["before"] = before
                row["after"] = after
                write(path, row)
                require(before == after, f"Failed rollback: {error}")
        else:
            require(receipt.status == 1, f"Unexpected mined revert: {row['signature']} tx {plain(receipt.transactionHash)}")
        write(path, row)
        if self.lottery and fn.address == self.lottery.address:
            self.record_coverage(fn, "revert" if error else "success", receipt)
        return receipt

    def deploy(self, name, args=(), group="lottery"):
        self.guard()
        artifact = self.artifact(name, group)
        factory = self.w3.eth.contract(abi=artifact["abi"], bytecode=artifact["bytecode"]["object"])
        receipt = self.w3.eth.wait_for_transaction_receipt(factory.constructor(*args).transact(
            {"from": self.owner, "gas": 15_000_000, "gasPrice": max(self.w3.eth.gas_price, 100_000_000)}))
        require(receipt.status == 1, f"Deployment failed: {name}")
        contract = self.w3.eth.contract(address=receipt.contractAddress, abi=artifact["abi"])
        runtime = self.w3.eth.get_code(contract.address)
        expected = bytearray(HexBytes(artifact["deployedBytecode"]["object"]))
        actual = bytearray(runtime)
        require(len(expected) == len(actual), f"Runtime size mismatch: {name}")
        for entries in artifact["deployedBytecode"].get("immutableReferences", {}).values():
            for entry in entries:
                start, size = entry["start"], entry["length"]
                expected[start:start+size] = actual[start:start+size] = b"\0" * size
        require(expected == actual, f"Runtime mismatch: {name}")
        self.deployed[contract.address] = {"name": name, "group": group,
            "runtimeHash": Web3.keccak(runtime), "receipt": receipt,
            "constructorArguments": args, "immutableMaskedRuntimeMatches": True}
        write(self.run / "deployments.json", self.deployed)
        return contract

    def impersonate(self, address):
        self.guard()
        self.rpc("anvil_impersonateAccount", [address])
        self.rpc("anvil_setBalance", [address, hex(100 * WAD)])

    def advance(self, seconds):
        self.guard()
        self.rpc("evm_increaseTime", [seconds])
        self.rpc("evm_mine", [])

    def result(self, name, details):
        row = {"scenario": self.scenario, "check": name, "details": details}
        self.results.append(row)
        write(self.run / "results.json", self.results)
        print(f"PASS {self.scenario}: {name}", flush=True)

    def reset(self, name):
        self.guard()
        if hasattr(self, "snapshot"):
            require(self.rpc("evm_revert", [self.snapshot]), "Snapshot revert failed")
        self.snapshot = self.rpc("evm_snapshot", [])
        self.scenario = name
        self.rounds = []

    def config(self, asset, price=10**15, count=10, duration=60, winner=5000, operator=2000, tip=10**12):
        return (asset, price, count, duration, 3, count, winner, operator, tip)

    def new_config(self, asset, rewards=(10**16, 5000, True), **kwargs):
        config = self.config(asset, **kwargs)
        if rewards is None:
            self.tx(self.lottery.functions.createLotteryConfig(config))
        else:
            self.tx(self.lottery.functions.createRewardLotteryConfig(config, rewards))
        version = self.call(self.lottery.functions.latestLotteryConfigVersion())
        self.tx(self.lottery.functions.setLotteryConfigEnabled(version, True))
        return version

    def open(self, version, quantity, position=1, sender=None):
        sender = sender or self.alice
        fn = self.lottery.functions.openRoundForPosition(version, quantity, position) if position else self.lottery.functions.openRound(version, quantity)
        self.tx(fn, sender)
        round_id = self.call(self.lottery.functions.latestRoundId())
        self.rounds.append(round_id)
        return round_id

    def financial_state(self):
        accounts = [self.call(self.lottery.functions.fiddyAccount(i)) for i in self.positions]
        credits = [[self.call(self.lottery.functions.fiddyCredit(i, asset)) for asset in self.assets] for i in self.positions]
        return plain({"reserve": self.call(self.lottery.functions.fiddyReserve()),
            "roundCount": self.call(self.lottery.functions.latestRoundId()),
            "activeRounds": self.call(self.lottery.functions.activeRoundCount()),
            "configVersion": self.call(self.lottery.functions.latestLotteryConfigVersion()),
            "accounts": accounts, "credits": credits,
            "assets": [[self.call(self.lottery.functions.assetAccounting(asset)),
                        self.call(self.lottery.functions.fiddyAsset(asset))] for asset in self.assets],
            "rounds": [self.call(self.lottery.functions.round(i)) for i in self.rounds],
            "balances": [[self.call(self.token(asset).functions.balanceOf(holder)) for holder in
                           [self.lottery.address, self.alice, self.bob, self.carol, self.treasury, self.router.address, self.borrower.address]]
                          for asset in self.assets]})

    def token(self, address):
        return self.w3.eth.contract(address=Web3.to_checksum_address(address), abi=self.artifact("FiddyTokenFacet")["abi"])

    def reconcile(self):
        reserve = self.call(self.lottery.functions.fiddyReserve())
        inventory, backing, custody = reserve[:3]
        require(self.call(self.lottery.functions.totalSupply()) == backing, "Backing/supply mismatch")
        require(self.call(self.lottery.functions.balanceOf(self.lottery.address)) == inventory + custody +
                sum(self.call(self.lottery.functions.assetAccounting(self.lottery.address))) +
                self.call(self.lottery.functions.fiddyAsset(self.lottery.address))[1], "FIDDY custody mismatch")
        accounts = [self.call(self.lottery.functions.fiddyAccount(i)) for i in self.positions]
        require(custody == sum(a[0] for a in accounts), "Account custody sum mismatch")
        require(self.call(self.lottery.functions.fiddyStaking())[0] == sum(a[2] for a in accounts), "Weight sum mismatch")
        require(all(a[1] <= a[0] for a in accounts), "Stake exceeds balance")
        for asset in self.assets:
            accounting = self.call(self.lottery.functions.assetAccounting(asset))
            book = self.call(self.lottery.functions.fiddyAsset(asset))
            extra = backing if asset == self.underlying else (inventory + custody if asset == self.lottery.address else 0)
            require(self.call(self.token(asset).functions.balanceOf(self.lottery.address)) == sum(accounting) + book[1] + extra,
                    f"Asset liabilities/custody mismatch: {asset}")
            scaled = book[2]
            for i, a in zip(self.positions, accounts):
                c = self.call(self.lottery.functions.fiddyCredit(i, asset))
                scaled += c[1] * RAY + c[2] + a[2] * (book[0] - c[0])
            require(scaled == book[1] * RAY, "Scaled entitlement mismatch")
        write(self.run / f"reconciliation-{self.scenario}.json", self.financial_state())
