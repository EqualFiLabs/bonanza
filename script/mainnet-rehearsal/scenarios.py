"""Scenario assertions use mined receipts and independent custody/entitlement reconciliation."""
import json
import random
import subprocess
import time
import urllib.request
from fractions import Fraction
from pathlib import Path

from eth_utils.abi import abi_to_signature
from hexbytes import HexBytes
from web3 import Web3

from common import ROOT, Rehearsal, ZERO, ZERO32, WAD, RAY, MAX, write, plain, require

HERE = Path(__file__).resolve().parent


def allocation(config, quantities, staker_bps):
    """Independent rational model from purchase sizes and the configured economic split."""
    gross = sum(quantities) * config[1]
    winner = int(gross * Fraction(config[6], 10000))
    operator = int((gross - winner) * Fraction(config[7], 10000))
    staker = sum(int(q * config[1] * Fraction(10000 - config[6], 10000)
                     * Fraction(staker_bps, 10000)) for q in quantities)
    remainder = gross - winner - operator - staker
    tip = min(config[8], remainder)
    return gross, winner, operator, staker, tip, remainder - tip


def soak_modes(seed, steps, action_count=12):
    """Deterministic shuffled schedule that covers every action when the phase is long enough."""
    modes = [index % action_count for index in range(steps)]
    random.Random(seed).shuffle(modes)
    return modes


def combined(artifacts):
    entries = {}
    for artifact in artifacts:
        for entry in artifact["abi"]:
            if entry["type"] in ("function", "event", "error"):
                entries[(entry["type"], abi_to_signature(entry))] = entry
    return list(entries.values())


class Campaign(Rehearsal):
    def execute(self):
        self.setup()
        for name in ["lifecycle", "authorization", "locks_and_boosts", "hostile_assets",
                     "bonanza_payments", "same_block_ordering", "drand_adversarial",
                     "module_dependency", "router_rotation", "governance", "boundaries",
                     "multi_boost_capacity", "persistent_soak"]:
            self.reset(name)
            print(f"Running {name}", flush=True)
            getattr(self, name)()
            self.reconcile()
            self.result("financial reconciliation", "exact custody and scaled entitlements")
        self.coverage_gate()
        write(self.run / "summary.json", {"passed": True, "environment": self.environment,
            "transactions": self.counter, "scenarios": self.results, "coverage": self.coverage,
            "limitations": ["Local fork only; no mainnet transactions", "Minimal actual-source Statics account module deployment",
                             "Adversarial tokens are explicit local fixtures", "No formal verification"]})
        print(f"Complete: {self.counter} mined calls; Anvil remains at {self.url}; evidence {self.run}", flush=True)

    def setup(self):
        config = json.loads((HERE / "mainnet.json").read_text())
        pin = subprocess.check_output(["git", "-C", "lib/statics", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        require(pin == config["staticsCommit"], "Statics candidate changed")
        manifest = json.loads((ROOT / "lib/statics/deployments/robinhood-mainnet-genesis.json").read_text())
        dependencies = {key: manifest["contracts"][key] for key in ["staticsToken", "operatorsNft", "activationRegistry", "genesisVault"]}
        dependencies["weth"] = manifest["externalDependencies"]["weth"]
        dependencies["drand"] = config["drand"]
        for key, entry in dependencies.items():
            runtime = self.w3.eth.get_code(entry["address"])
            require(plain(Web3.keccak(runtime)) == entry["runtimeCodeHash"], f"Mainnet runtime mismatch: {key}")
        write(self.run / "dependencies.json", dependencies)
        self.underlying = dependencies["staticsToken"]["address"]
        self.weth = dependencies["weth"]["address"]
        self.operators = self.contract(dependencies["operatorsNft"]["address"], "StaticsGenesis", "statics")
        self.activation = self.contract(dependencies["activationRegistry"]["address"], "GenesisActivationRegistry", "statics")
        require(self.call(self.activation.functions.genesisCollection()) == self.operators.address, "Activation collection mismatch")
        self.drand = self.contract(dependencies["drand"]["address"], "IEqualFiDrandRegistry")
        self.drand_chain = config["quicknetChainHash"]
        # Public Anvil accounts may have delegated EOA code on the source chain. Only reset test actors.
        for actor in self.actors:
            self.rpc("anvil_setCode", [actor, "0x"])
        self.deploy_position()
        self.timelock = self.deploy("OperatorFeeRouterTimelock", ([self.owner], [self.owner]), "router")
        self.router = self.deploy("OperatorFeeRouter", (self.operators.address, self.activation.address,
            dependencies["genesisVault"]["address"], self.timelock.address), "router")
        self.vault = dependencies["genesisVault"]["address"]
        for getter, expected in [("operatorCollection", self.operators.address), ("activationRegistry", self.activation.address),
                                 ("operatorVault", dependencies["genesisVault"]["address"]), ("routerTimelock", self.timelock.address)]:
            require(self.call(getattr(self.router.functions, getter)()) == expected, f"Router binding {getter}")
        while self.call(self.router.functions.nextOperatorId()) <= self.call(self.router.functions.LAST_OPERATOR_ID()):
            self.tx(self.router.functions.bootstrapOperators(100))
            cursor = self.call(self.router.functions.nextOperatorId())
            if cursor % 500 == 1:
                print(f"Router bootstrap: {cursor - 1}/5555 Operators", flush=True)
        self.tx(self.router.functions.finalizeBootstrap())
        # A second fully bootstrapped Router shares the same initial timelock wait. The rotation
        # scenario can then settle against genuine published beacons before testing later outages.
        self.timelock_b = self.deploy("OperatorFeeRouterTimelock", ([self.owner], [self.owner]), "router")
        self.router_b = self.deploy("OperatorFeeRouter", (self.operators.address, self.activation.address,
            self.vault, self.timelock_b.address), "router")
        while self.call(self.router_b.functions.nextOperatorId()) <= self.call(self.router_b.functions.LAST_OPERATOR_ID()):
            self.tx(self.router_b.functions.bootstrapOperators(100))
        self.tx(self.router_b.functions.finalizeBootstrap())
        self.hostile = self.deploy("RehearsalToken")
        self.assets = [self.underlying, self.weth, self.hostile.address]
        self.deploy_lottery()
        self.assets.append(self.lottery.address)
        # Exercise real Router governance delay; all schedules precede one time advance.
        operations = []
        for asset in self.assets:
            data = self.router.functions.registerRewardAsset(asset)._encode_transaction_data()
            salt = Web3.keccak(text=asset)
            self.tx(self.timelock.functions.schedule(self.router.address, 0, HexBytes(data), ZERO32, salt, 86400))
            operations.append((HexBytes(data), salt))
        router_b_data = HexBytes(self.router_b.functions.registerRewardAsset(self.weth)._encode_transaction_data())
        router_b_salt = Web3.keccak(text=self.router_b.address + self.weth)
        self.tx(self.timelock_b.functions.schedule(
            self.router_b.address, 0, router_b_data, ZERO32, router_b_salt, 86400
        ))
        self.tx(self.timelock.functions.execute(self.router.address, 0, *[operations[0][0], ZERO32, operations[0][1]]),
                error="TimelockUnexpectedOperationState(bytes32,bytes32)")
        self.advance(86401)
        for data, salt in operations:
            self.tx(self.timelock.functions.execute(self.router.address, 0, data, ZERO32, salt))
        self.tx(self.timelock_b.functions.execute(
            self.router_b.address, 0, router_b_data, ZERO32, router_b_salt
        ))
        require(self.call(self.router.functions.totalEffectiveWeight()) > 0, "Router has no weight")
        self.tx(self.position.functions.setExternalModule(self.lottery.address, Web3.keccak(text="statics.lottery.fiddy.account.v1"), True))
        for actor in [self.alice, self.bob, self.carol]:
            self.tx(self.position.functions.createPosition(actor), actor)
            self.positions.append(len(self.positions) + 1)
        self.borrower = self.deploy("RehearsalBorrower")
        self.tx(self.borrower.functions.create(self.position.address))
        self.positions.append(self.call(self.borrower.functions.position()))
        self.seed_assets(manifest)
        self.tx(self.lottery.functions.fundBonanzaReserve(1000 * WAD), self.alice)
        require(tuple(self.call(self.lottery.functions.bonanzaReserve())[3:]) == (False, False, 0, 0), "Unsafe launch conversion defaults")
        self.result("deployment identity", "mainnet dependency hashes, source runtimes and selector routes verified")
        write(self.run / "bindings.json", {"lottery": self.lottery.address, "position": self.position.address,
            "router": self.router.address, "timelock": self.timelock.address,
            "rotationRouter": self.router_b.address, "rotationTimelock": self.timelock_b.address,
            "actors": self.actors,
            "assets": self.assets, "operatorId": self.operator_id, "positions": self.positions,
            "borrower": self.borrower.address})

    def deploy_position(self):
        names = ["DiamondCutFacet", "DiamondLoupeFacet", "OwnershipFacet", "PositionNFTFacet", "ExternalModuleFacet"]
        facets = [self.deploy(name, group="statics") for name in names]
        cuts = []
        for name, facet in zip(names, facets):
            methods = self.artifact(name, "statics")["methodIdentifiers"]
            # ERC165 is owned by the loupe; other inherited ERC721 selectors stay on PositionNFT.
            selectors = [HexBytes(value) for sig, value in methods.items() if not (name == "PositionNFTFacet" and sig == "supportsInterface(bytes4)")]
            cuts.append((facet.address, 0, selectors))
        initializer = self.deploy("StaticsProtocolInit", group="statics")
        data = initializer.functions.genesisInitialize(cuts, self.guardian, self.treasury, self.underlying, 0, 0, 0, 5)._encode_transaction_data()
        core = self.deploy("StaticsDiamond", (self.owner, ZERO, initializer.address, HexBytes(data)), "statics")
        self.position = self.w3.eth.contract(address=core.address, abi=combined([self.artifact(n, "statics") for n in names]))
        require(self.call(self.position.functions.owner()) == self.owner, "Position authority mismatch")

    def deploy_lottery(self):
        names = ["DiamondCutFacet", "DiamondLoupeFacet", "GovernanceFacet", "LotteryFacet", "SettlementFacet", "ClaimsFacet",
                 "RevenueFacet", "LotteryViewFacet", "BonanzaTokenFacet", "BonanzaStakingFacet", "BonanzaViewFacet"]
        facets = [self.deploy(name) for name in names]
        diamond = self.deploy("StaticsLotteryDiamond", (self.owner, facets[0].address))
        self.lottery = self.w3.eth.contract(address=diamond.address, abi=combined([self.artifact(n) for n in names]))
        self.installed = {}
        cuts = []
        for name, facet in zip(names, facets):
            methods = self.artifact(name)["methodIdentifiers"]
            for sig, selector in methods.items():
                require(selector not in self.installed, "Duplicate selector")
                self.installed[selector] = {"signature": sig, "facet": facet.address, "name": name}
            if name != "DiamondCutFacet":
                cuts.append((facet.address, 0, [HexBytes(s) for s in methods.values()]))
        initializer = self.deploy("LotteryInit")
        params = (self.owner, self.guardian, self.treasury, 100, (self.drand.address, self.router.address),
                  [self.config(self.underlying), self.config(self.weth)])
        bindings = (self.underlying, self.position.address, self.operators.address, self.activation.address)
        data = initializer.functions.initializeWithBonanza(params, bindings)._encode_transaction_data()
        receipt = self.tx(self.lottery.functions.diamondCut(cuts, initializer.address, HexBytes(data)))
        require(tuple(self.call(self.lottery.functions.bonanzaBindings())) == bindings, "BONANZA binding mismatch")
        self.initialization_evidence = {"transactionHash": plain(receipt.transactionHash),
            "method": "LotteryInit.initializeWithBonanza", "bindingsVerified": True}
        for selector, row in self.installed.items():
            require(self.call(self.lottery.functions.facetAddress(HexBytes(selector))) == row["facet"], "Selector route mismatch")
        write(self.run / "selectors.json", self.installed)

    def seed_assets(self, manifest):
        token = self.token(self.underlying)
        candidates = [manifest["roles"]["treasury"], manifest["contracts"]["treasuryVesting"]["address"],
                      manifest["contracts"]["genesisVault"]["address"]]
        holder = next((a for a in candidates if self.call(token.functions.balanceOf(a)) >= 250_000 * WAD), None)
        require(holder, "No manifest-backed funding holder has enough STATICS")
        self.impersonate(holder)
        for actor in [self.alice, self.bob, self.carol]:
            self.tx(token.functions.transfer(actor, 50_000 * WAD), holder)
            # WETH deposit uses native test gas funding, with a real deposit and ERC20 transfer.
            weth_abi = [{"type": "function", "name": "deposit", "inputs": [], "outputs": [], "stateMutability": "payable"}]
            wrapped = self.w3.eth.contract(address=self.weth, abi=weth_abi)
            self.tx(wrapped.functions.deposit(), actor, value=10 * WAD)
            self.tx(self.hostile.functions.mint(actor, 10 * WAD))
            for asset in self.assets:
                self.tx(self.token(asset).functions.approve(self.lottery.address, MAX), actor)
        self.tx(token.functions.transfer(self.borrower.address, WAD), self.alice)
        self.tx(self.token(self.weth).functions.transfer(self.borrower.address, WAD), self.alice)
        self.operator_id = 3
        holder = self.call(self.operators.functions.ownerOf(self.operator_id))
        self.impersonate(holder)
        self.tx(self.operators.functions.transferFrom(holder, self.alice, self.operator_id), holder)
        self.tx(token.functions.approve(self.activation.address, MAX), self.alice)
        self.tx(self.activation.functions.activate(self.operator_id, 1), self.alice)
        write(self.run / "fixture-provenance.json", {"statics": "real transfer from impersonated manifest holder",
            "weth": "real WETH deposits funded by local Anvil native balances", "operator": "real transfer from impersonated current owner",
            "position": "actual pinned Statics account facets and initializer; no market or lending deployment",
            "hostileAsset": "explicit local synthetic test token", "testActors": "Anvil EOAs; any inherited delegation code cleared"})

    def stakes(self):
        self.tx(self.lottery.functions.setBonanzaConversions(True, True, 10000 * WAD))
        for position, actor, amount in [(1, self.alice, 100 * WAD), (2, self.bob, 70 * WAD)]:
            self.tx(self.lottery.functions.wrapBonanza(position, amount), actor)
            self.tx(self.lottery.functions.stakeBonanza(position, amount), actor)
        self.tx(self.lottery.functions.setBonanzaBoostsEnabled(True))
        self.tx(self.lottery.functions.registerBonanzaOperator(1, self.operator_id), self.alice)

    def activate_operator(self, operator_id, actor):
        require(self.call(self.operators.functions.ownerOf(operator_id)) == actor,
                "Operator activation owner mismatch")
        self.tx(self.token(self.underlying).functions.approve(self.activation.address, MAX), actor)
        if self.call(self.activation.functions.tierOf(operator_id)) == 0:
            self.tx(self.activation.functions.activate(operator_id, 1), actor)

    def acquire_operator(self, operator_id, actor):
        owner = self.call(self.operators.functions.ownerOf(operator_id))
        if owner != actor:
            self.impersonate(owner)
            self.tx(self.operators.functions.transferFrom(owner, actor, operator_id), owner)
        self.activate_operator(operator_id, actor)

    def transferable_operators(self, count):
        operators = []
        for operator_id in range(1, 256):
            if operator_id != self.operator_id and not self.call(self.operators.functions.locked(operator_id)):
                operators.append(operator_id)
                if len(operators) == count:
                    return operators
        raise AssertionError("Not enough transferable Genesis Operators")

    def modeled_bonanza_credit(self, position, asset, weight):
        revenue = self.call(self.lottery.functions.bonanzaAsset(asset))
        credit = self.call(self.lottery.functions.bonanzaCredit(position, asset))
        delta = revenue[0] - credit[0]
        scaled = weight * delta
        whole = credit[1] + scaled // RAY
        fraction = scaled % RAY + credit[2]
        return whole + fraction // RAY, fraction % RAY, delta

    def modeled_bonanza_forfeit(self, position, asset):
        """Independent exact state transition for an invalid boost forfeiture."""
        f = self.lottery.functions
        account = self.call(f.bonanzaAccount(position))
        total_weight = self.call(f.bonanzaStaking())[0]
        revenue = self.call(f.bonanzaAsset(asset))
        accounting = self.call(f.assetAccounting(asset))
        whole, remainder, delta = self.modeled_bonanza_credit(position, asset, account[1])
        index, reserved, dust = revenue[:3]
        treasury = accounting[5]
        excess_weight = account[2] - account[1]
        other_weight = total_weight - account[2]
        scaled_dust = 0
        if excess_weight and delta:
            numerator = excess_weight * delta
            if other_weight:
                index_increment, scaled_dust = divmod(numerator, other_weight)
                index += index_increment
            else:
                amount, scaled_dust = divmod(numerator, RAY)
                reserved -= amount
                treasury += amount
        dust_whole, dust = divmod(dust + scaled_dust, RAY)
        reserved -= dust_whole
        treasury += dust_whole
        return {"index": index, "reserved": reserved, "dust": dust, "treasury": treasury,
                "claimable": whole, "remainder": remainder, "delta": delta}

    def assert_modeled_bonanza_forfeit(self, position, asset, expected, claimed=False):
        f = self.lottery.functions
        revenue = self.call(f.bonanzaAsset(asset))
        credit = self.call(f.bonanzaCredit(position, asset))
        accounting = self.call(f.assetAccounting(asset))
        paid = expected["claimable"] if claimed else 0
        require(tuple(revenue[:3]) == (expected["index"], expected["reserved"] - paid,
                                      expected["dust"]),
                "Forfeit asset transition differs from independent model")
        require(tuple(credit) == (expected["index"], 0 if claimed else expected["claimable"],
                                  expected["remainder"]),
                "Forfeit credit transition differs from independent model")
        require(accounting[5] == expected["treasury"],
                "Forfeit Treasury transition differs from independent model")

    def beacon(self, round_id):
        record = self.call(self.lottery.functions.round(round_id))
        return record, self.beacon_signature(record[7])

    def beacon_signature(self, beacon_round):
        timestamp = self.call(self.drand.functions.roundTime(beacon_round))
        require(timestamp <= int(time.time()), "Required Quicknet beacon is still in the real future")
        path = self.run / "beacons" / f"{beacon_round}.json"
        path.parent.mkdir(exist_ok=True)
        if path.exists():
            response = json.loads(path.read_text())
        else:
            url = f"https://api.drand.sh/{self.drand_chain}/public/{beacon_round}"
            response = json.load(urllib.request.urlopen(url, timeout=30))
            require(response["round"] == beacon_round, "Quicknet response round mismatch")
            write(path, response)
        return HexBytes(response["signature"])

    def settle(self, round_id, cached=False):
        record, signature = self.beacon(round_id)
        f = self.lottery.functions
        quantities, end = [], 0
        for i in range(self.call(f.purchaseEntryCount(round_id))):
            next_end = self.call(f.purchaseEntry(round_id, i))[1]
            quantities.append(next_end - end)
            end = next_end
        gross, winner_amount, operator, staker, tip, treasury = allocation(
            record[0], quantities, self.call(f.bonanzaRoundConfig(round_id))[1])
        require(end == record[8] and gross == record[12], "Purchase receipts mismatch")
        require(self.call(f.bonanzaRoundRevenue(round_id)) == staker, "Purchase-time staker allocation mismatch")
        before = self.call(f.assetAccounting(record[0][0]))
        before_tip = self.call(f.finalizerCredit(record[0][0], self.carol))
        before_operator = self.call(f.pendingOperatorRevenue(record[2], record[0][0]))
        close = record[5] if record[10] == 2 else record[4]
        timestamp = max(close + 1, self.call(self.drand.functions.roundTime(record[7])))
        now = self.w3.eth.get_block("latest").timestamp
        if now < timestamp:
            self.advance(timestamp - now)
        if cached:
            self.tx(self.drand.functions.postSig(record[7], signature), self.carol)
        self.tx(self.lottery.functions.settleRound(round_id, b"" if cached else signature), self.carol)
        result = self.call(self.lottery.functions.round(round_id))
        require(result[13] == winner_amount, "Winner allocation differs from purchase model")
        after = self.call(f.assetAccounting(record[0][0]))
        require(tuple(a - b for a, b in zip(after, before)) ==
                (-gross + staker, winner_amount, 0, tip, operator, treasury), "Settlement split mismatch")
        require(self.call(f.finalizerCredit(record[0][0], self.carol)) - before_tip == tip, "Finalizer split mismatch")
        require(self.call(f.pendingOperatorRevenue(record[2], record[0][0])) - before_operator == operator,
                "Operator split mismatch")
        require(result[10] == 3 and result[9] < result[8], "Settlement ticket outside sold range")
        require(self.call(self.lottery.functions.ticketOwner(round_id, result[9])) == result[11], "Winner ownership mismatch")
        return result

    def claim_round(self, round_id):
        record = self.call(self.lottery.functions.round(round_id))
        asset, winner, amount = record[0][0], record[11], record[13]
        before = self.call(self.token(asset).functions.balanceOf(winner))
        receipt = self.tx(self.lottery.functions.claimWinner(round_id, winner), winner)
        require(self.call(self.token(asset).functions.balanceOf(winner)) - before == amount, "Winner delta mismatch")
        return receipt

    def verify_protocol_self_call(self, receipt):
        signature = "protocolMoveBonanza(address,address,uint256)"
        selector = "0x" + Web3.keccak(text=signature)[:4].hex()
        trace = self.rpc("debug_traceTransaction", [plain(receipt.transactionHash), {"tracer": "callTracer"}])
        pending, matches = [trace], []
        while pending:
            node = pending.pop()
            pending.extend(node.get("calls", []))
            if (node.get("type") == "CALL" and node.get("from", "").lower() == self.lottery.address.lower()
                    and node.get("to", "").lower() == self.lottery.address.lower()
                    and node.get("input", "").startswith(selector) and not node.get("error")):
                matches.append(node)
        write(self.run / "protocol-self-call.json", {"transactionHash": plain(receipt.transactionHash), "trace": trace})
        require(matches, "No successful authenticated protocol self-call in payout trace")
        self.coverage.setdefault(signature, {"view": [], "success": [], "revert": []})["internal"] = [
            {"scenario": self.scenario, "transactionHash": plain(receipt.transactionHash), "calls": len(matches)}]

    def flush(self):
        for asset in self.assets:
            amount = self.call(self.lottery.functions.pendingOperatorRevenue(1, asset))
            if amount:
                before = self.call(self.token(asset).functions.balanceOf(self.router.address))
                self.tx(self.lottery.functions.flushOperatorRevenue(1, asset, amount), self.carol)
                require(self.call(self.token(asset).functions.balanceOf(self.router.address)) - before == amount, "Router delta mismatch")
            amount = self.call(self.lottery.functions.assetAccounting(asset))[5]
            if amount:
                before = self.call(self.token(asset).functions.balanceOf(self.treasury))
                self.tx(self.lottery.functions.flushTreasury(asset, amount), self.carol)
                require(self.call(self.token(asset).functions.balanceOf(self.treasury)) - before == amount, "Treasury delta mismatch")
            if self.call(self.lottery.functions.finalizerCredit(asset, self.carol)):
                self.tx(self.lottery.functions.claimFinalizerTips(asset, self.carol), self.carol)

    def lifecycle(self):
        self.stakes()
        version_a = self.new_config(self.underlying)
        version_b = self.new_config(self.weth)
        first = self.open(version_a, 3)
        second = self.open(version_b, 4, 2, self.bob)
        self.tx(self.lottery.functions.buyTicketsForPosition(first, 7, 2), self.bob)
        self.tx(self.lottery.functions.buyTicketsForPosition(first, 1, 2), self.bob,
                error="RoundNotOpen(uint256)", check=self.financial_state)
        self.tx(self.lottery.functions.settleRound(first, b"\x01"), self.carol,
                error="UnsupportedSignatureLength(uint256)", check=self.financial_state)
        self.tx(self.lottery.functions.settleRound(second, b""), self.carol,
                error="RoundNotReady(uint256)", check=self.financial_state)
        self.settle(first)
        self.settle(second, cached=True)
        for rid in [first, second]:
            self.claim_round(rid)
            self.tx(self.lottery.functions.claimWinner(rid, self.alice),
                    self.call(self.lottery.functions.round(rid))[11], error="NoWinnerClaim()", check=self.financial_state)
        for position, actor in [(1, self.alice), (2, self.bob)]:
            for asset in self.assets:
                self.tx(self.lottery.functions.claimBonanzaRevenue(position, asset, actor), actor)
        self.flush()
        # Real Router distribution to the Operator holder, including canonical ownership sync.
        pending = self.call(self.router.functions.pendingOperatorRewards(self.operator_id, self.underlying))
        if pending:
            self.tx(self.router.functions.claimOperatorRewards(self.operator_id, self.underlying, self.alice), self.alice)
        self.read_surface(first, version_a)
        self.result("sellout and deadline draws", "genuine Quicknet proofs, exact claims, Router/Treasury delivery")

    def read_surface(self, rid, version):
        f = self.lottery.functions
        calls = [f.facets(), f.facetAddresses(), f.integrationConfig(), f.paused(), f.guardian(), f.treasuryRecipient(),
            f.protocolFinalized(), f.latestLotteryConfigVersion(), f.latestRoundId(), f.round(rid), f.roundConfig(rid),
            f.ticketOwner(rid, 0), f.purchaseEntryCount(rid), f.purchaseEntry(rid, 0), f.lotteryConfig(version),
            f.currentIntegration(), f.integrationAt(1), f.activeRoundCount(), f.maxActiveRounds(), f.activeRoundForConfig(version),
            f.name(), f.symbol(), f.decimals(), f.totalSupply(), f.balanceOf(self.alice), f.allowance(self.alice, self.lottery.address),
            f.isBonanzaConsumer(self.router.address), f.bonanzaBindings(), f.bonanzaReserve(), f.bonanzaAccount(1), f.bonanzaConfig(version),
            f.bonanzaRoundConfig(rid), f.bonanzaOperatorAccount(self.operator_id), f.bonanzaStaking(), f.bonanzaRoundRevenue(rid), f.bonanzaRevenueAssets()]
        for asset in self.assets:
            calls += [f.pendingOperatorRevenue(1, asset), f.assetAccounting(asset), f.finalizerCredit(asset, self.carol),
                f.bonanzaAsset(asset), f.bonanzaCredit(1, asset), f.indexedBonanzaRevenue(1, asset)]
            # Only configured assets are admitted to the base Lottery surplus view.
            if asset in [self.underlying, self.weth]:
                calls += [f.availableTokenSurplus(asset)]
        for call in calls:
            self.call(call)
        for address in self.call(f.facetAddresses()):
            self.call(f.facetFunctionSelectors(address))

    def authorization(self):
        self.stakes()
        f = self.lottery.functions
        privileged = [f.setGuardian(self.carol), f.setTreasuryRecipient(self.carol), f.setMaxActiveRounds(1),
            f.setIntegrationConfig((self.drand.address, self.router.address)), f.setLotteryConfigEnabled(1, False),
            f.createLotteryConfig(self.config(self.weth)), f.createRewardLotteryConfig(self.config(self.weth), (1, 1, True)),
            f.setBonanzaConversions(True, True, MAX), f.setBonanzaConsumer(self.carol, True), f.setBonanzaBoostsEnabled(False),
            f.initializeBonanza(self.underlying, self.position.address, self.operators.address, self.activation.address),
            f.finalizeProtocol(), f.diamondCut([], ZERO, b"")]
        for fn in privileged:
            self.tx(fn, self.carol, error="NotAuthority(address)", check=self.financial_state)
        self.tx(self.position.functions.approve(self.carol, 1), self.alice)
        for fn in [f.withdrawBonanza(1, 1), f.depositBonanza(1, 1), f.wrapBonanza(1, 1), f.unwrapBonanza(1, 1, self.carol),
                   f.stakeBonanza(1, 1), f.unstakeBonanza(1, 1), f.registerBonanzaOperator(1, self.operator_id),
                   f.removeBonanzaOperator(1), f.claimBonanzaRevenue(1, self.weth, self.carol), f.cleanupBonanzaAccount(1)]:
            self.tx(fn, self.carol, error="NotPositionOwner()", check=self.financial_state)
        self.tx(f.protocolMoveBonanza(self.lottery.address, self.carol, 1), self.carol,
                error="OnlyProtocol()", check=self.financial_state)
        self.tx(f.setPaused(True), self.carol, error="NotGuardian(address)")
        self.result("authority and approvals", "NFT approval never grants financial control")

    def locks_and_boosts(self):
        self.stakes()
        f = self.lottery.functions
        version = self.new_config(self.weth)
        rid = self.open(version, 10)
        nonce = self.call(f.bonanzaAccount(1))[6]
        self.tx(f.checkpointBonanzaAccount(1), self.carol)
        require(self.call(f.bonanzaAccount(1))[6] == nonce, "Third party checkpoint changed nonce")
        self.tx(f.unstakeBonanza(1, 1), self.alice, error="StakeLocked(uint256)", check=self.financial_state)
        self.tx(self.operators.functions.transferFrom(self.alice, self.bob, self.operator_id), self.alice)
        self.tx(f.registerBonanzaOperator(2, self.operator_id), self.bob)
        require(not self.call(f.bonanzaAccount(1))[7], "Stale registration retained")
        require(self.call(f.bonanzaAccount(1))[6] == nonce + 1, "Forfeit nonce missing")
        self.tx(self.position.functions.transferFrom(self.bob, self.carol, 2), self.bob)
        self.tx(f.checkpointBonanzaAccount(2), self.alice)
        require(self.call(f.bonanzaAccount(2))[2] == self.call(f.bonanzaAccount(2))[1], "Position sale retained boost")
        self.settle(rid)
        self.claim_round(rid)
        self.advance(86400)
        self.tx(f.wrapBonanza(1, 100 * WAD), self.alice)
        self.tx(f.stakeBonanza(1, 100 * WAD), self.alice)
        start = self.call(f.bonanzaAccount(1))[5]
        require(abs(self.w3.eth.get_block("latest").timestamp - start - 43200) <= 2, "Weighted top-up lock mismatch")
        self.tx(f.unstakeBonanza(1, 1), self.alice, error="StakeLocked(uint256)", check=self.financial_state)
        self.advance(43201)
        self.tx(f.unstakeBonanza(1, 200 * WAD), self.alice)
        self.tx(f.removeBonanzaOperator(1), self.alice)
        self.tx(f.withdrawBonanza(1, WAD), self.alice)
        self.tx(f.depositBonanza(1, WAD), self.alice)
        for i in [1, 2]:
            actor = self.call(self.position.functions.ownerOf(i))
            account = self.call(f.bonanzaAccount(i))
            if account[1]:
                self.tx(f.unstakeBonanza(i, account[1]), actor)
            for asset in self.assets:
                self.tx(f.claimBonanzaRevenue(i, asset, actor), actor)
            amount = self.call(f.bonanzaAccount(i))[0]
            self.tx(f.unwrapBonanza(i, amount, actor), actor)
            self.tx(f.cleanupBonanzaAccount(i), actor)
            require(self.call(self.position.functions.isPositionClosable(i)), "External leg did not detach")
        self.flush()
        self.result("lock and ownership transitions", "weighted reset, takeover, forfeiture, nonce, exit and detach")

    def hostile_assets(self):
        self.stakes()
        f = self.lottery.functions
        version = self.new_config(self.hostile.address)
        for mode in [1, 2]:
            self.tx(self.hostile.functions.configure(mode, ZERO, b""))
            self.tx(f.openRoundForPosition(version, 1, 1), self.alice,
                error="InexactTokenTransfer(address,uint256,uint256,uint256)", check=self.financial_state)
        self.tx(self.hostile.functions.configure(4, self.lottery.address, HexBytes(f.buyTickets(1, 1)._encode_transaction_data())))
        self.tx(f.openRoundForPosition(version, 1, 1), self.alice, error="Reentrancy()", check=self.financial_state)
        self.tx(self.hostile.functions.configure(0, ZERO, b""))
        rid = self.open(version, 10)
        self.tx(self.hostile.functions.configure(3, ZERO, b""))
        self.settle(rid)
        winner = self.call(f.round(rid))[11]
        self.tx(f.claimWinner(rid, winner), winner, error="Error(string)", check=self.financial_state)
        self.tx(f.claimBonanzaRevenue(1, self.hostile.address, self.alice), self.alice, error="Error(string)", check=self.financial_state)
        self.tx(self.hostile.functions.configure(0, ZERO, b""))
        self.claim_round(rid)
        self.tx(f.claimBonanzaRevenue(1, self.hostile.address, self.alice), self.alice)
        # Both loan sources fail atomically on the 24-hour stake lock.
        plain_version = self.new_config(self.weth, rewards=None)
        self.tx(f.wrapBonanza(1, WAD), self.alice)
        self.tx(f.withdrawBonanza(1, WAD), self.alice)
        self.tx(f.setBonanzaConsumer(self.borrower.address, True))
        self.tx(f.approve(self.borrower.address, WAD), self.alice)
        self.tx(self.token(self.underlying).functions.approve(self.borrower.address, WAD), self.alice)
        for wrap, payment in [(False, self.weth), (True, self.underlying)]:
            v = plain_version if not wrap else self.new_config(self.underlying, rewards=None)
            self.tx(self.borrower.functions.attack(self.lottery.address, payment, v, WAD, wrap), self.alice,
                    error="StakeLocked(uint256)", check=self.financial_state)
        self.result("hostile callbacks and flash funding", "mined reverts with exact financial rollback")

    def bonanza_payments(self):
        self.stakes()
        f = self.lottery.functions
        self.tx(f.wrapBonanza(1, 100 * WAD), self.alice)
        self.tx(f.withdrawBonanza(1, 100 * WAD), self.alice)
        self.tx(f.transfer(self.bob, 1), self.alice, error="TransferRestricted()", check=self.financial_state)
        self.tx(f.createLotteryConfig(self.config(self.lottery.address)), error="OperatorRouterUnavailable(address,address)")
        self.tx(f.setBonanzaConsumer(self.router.address, True))
        version = self.new_config(self.lottery.address, rewards=(0, 5000, False))
        rid = self.open(version, 2, position=0)
        self.tx(f.buyTickets(rid, 8), self.alice)
        self.settle(rid)
        self.tx(f.claimWinner(rid, self.bob), self.alice, error="ReceiverRestricted(address)", check=self.financial_state)
        self.verify_protocol_self_call(self.claim_round(rid))
        self.tx(f.claimBonanzaRevenue(1, self.lottery.address, self.bob), self.alice,
                error="ReceiverRestricted(address)", check=self.financial_state)
        self.tx(f.claimBonanzaRevenue(1, self.lottery.address, self.alice), self.alice)
        self.tx(f.setBonanzaConsumer(self.router.address, False))
        pending = self.call(f.pendingOperatorRevenue(1, self.lottery.address))
        self.tx(f.flushOperatorRevenue(1, self.lottery.address, pending), self.carol,
                error="OperatorRouterUnavailable(address,address)", check=self.financial_state)
        self.tx(f.setBonanzaConsumer(self.router.address, True))
        self.flush()
        # Approved endpoints can redistribute; allowances alone cannot bypass movement policy.
        self.tx(f.setBonanzaConsumer(self.bob, True))
        self.tx(f.transfer(self.bob, 100), self.alice)
        self.tx(f.approve(self.carol, 50), self.bob)
        self.tx(f.transferFrom(self.bob, self.carol, 50), self.carol)
        self.result("restricted payment token", "owner payouts, consumer routing and retryable Router delivery")

    def same_block_ordering(self):
        f = self.lottery.functions
        self.tx(f.setBonanzaConversions(True, True, 10000 * WAD))
        self.tx(f.wrapBonanza(1, 100 * WAD), self.alice)
        version = self.new_config(self.weth, rewards=(0, 5000, False), operator=0)
        rid = self.open(version, 1)
        share = self.config(self.weth, operator=0)[1] * 5000 * 5000 // (10000 * 10000)

        branch = self.rpc("evm_snapshot", [])
        reserved = self.call(f.bonanzaAsset(self.weth))[1]
        receipts = self.same_block([
            {"fn": f.stakeBonanza(1, 100 * WAD), "sender": self.alice},
            {"fn": f.buyTicketsForPosition(rid, 1, 1), "sender": self.alice},
        ])
        require(receipts[0].blockNumber == receipts[1].blockNumber, "Stake/purchase ordering split")
        require(self.call(f.bonanzaAsset(self.weth))[1] - reserved == share,
                "Stake-before-purchase did not earn the purchase share")

        require(self.rpc("evm_revert", [branch]), "Ordering branch revert failed")
        treasury = self.call(f.assetAccounting(self.weth))[5]
        reserved = self.call(f.bonanzaAsset(self.weth))[1]
        receipts = self.same_block([
            {"fn": f.buyTicketsForPosition(rid, 1, 1), "sender": self.alice},
            {"fn": f.stakeBonanza(1, 100 * WAD), "sender": self.alice},
        ])
        require(self.call(f.bonanzaAsset(self.weth))[1] == reserved,
                "Purchase-before-stake paid retrospective revenue")
        require(self.call(f.assetAccounting(self.weth))[5] - treasury == share,
                "Zero-weight purchase share did not reach Treasury")

        # Book a claim, then prove transaction order controls old-owner authority within one block.
        self.tx(f.buyTicketsForPosition(rid, 1, 1), self.alice)
        earned = self.call(f.indexedBonanzaRevenue(1, self.weth))[0]
        require(earned > 0, "No revenue available for claim ordering")
        branch = self.rpc("evm_snapshot", [])
        balance = self.call(self.token(self.weth).functions.balanceOf(self.alice))
        self.same_block([
            {"fn": self.position.functions.transferFrom(self.alice, self.bob, 1), "sender": self.alice},
            {"fn": f.claimBonanzaRevenue(1, self.weth, self.alice), "sender": self.alice,
             "error": "NotPositionOwner()"},
        ])
        require(self.call(self.position.functions.ownerOf(1)) == self.bob, "Position transfer did not win ordering")
        require(self.call(self.token(self.weth).functions.balanceOf(self.alice)) == balance,
                "Failed old-owner claim moved funds")

        require(self.rpc("evm_revert", [branch]), "Claim ordering branch revert failed")
        balance = self.call(self.token(self.weth).functions.balanceOf(self.alice))
        self.same_block([
            {"fn": f.claimBonanzaRevenue(1, self.weth, self.alice), "sender": self.alice},
            {"fn": self.position.functions.transferFrom(self.alice, self.bob, 1), "sender": self.alice},
        ])
        require(self.call(self.token(self.weth).functions.balanceOf(self.alice)) - balance == earned,
                "Claim-before-transfer paid the wrong amount")
        require(self.call(self.position.functions.ownerOf(1)) == self.bob, "Claim ordering transfer failed")

        # After the deadline the final purchase always fails, regardless of transaction order,
        # while the partial round settles against its original deadline beacon.
        deadline_version = self.new_config(self.weth, rewards=None, count=2, operator=0)
        deadline_round = self.open(deadline_version, 1, position=0)
        record = self.call(f.round(deadline_round))
        signature = self.beacon_signature(record[7])
        timestamp = max(record[4] + 1, self.call(self.drand.functions.roundTime(record[7])))
        branch = self.rpc("evm_snapshot", [])
        self.same_block([
            {"fn": f.buyTickets(deadline_round, 1), "sender": self.alice,
             "error": "RoundExpired(uint256)"},
            {"fn": f.settleRound(deadline_round, signature), "sender": self.carol},
        ], timestamp)
        require(self.call(f.round(deadline_round))[10] == 3, "Deadline round did not settle after rejected purchase")
        require(self.call(f.round(deadline_round))[8] == 1, "Deadline purchase changed sold tickets")

        require(self.rpc("evm_revert", [branch]), "Deadline ordering branch revert failed")
        self.same_block([
            {"fn": f.settleRound(deadline_round, signature), "sender": self.carol},
            {"fn": f.buyTickets(deadline_round, 1), "sender": self.alice,
             "error": "RoundNotOpen(uint256)"},
        ], timestamp)
        require(self.call(f.round(deadline_round))[10] == 3, "Settlement-first ordering failed")
        self.result("same-block ordering", "stake, claim, transfer, deadline purchase and settlement orderings mined")

    def drand_adversarial(self):
        f = self.lottery.functions
        version = self.new_config(self.weth, rewards=None, operator=0)
        rid = self.open(version, 10, position=0)
        record = self.call(f.round(rid))
        target = record[7]
        signature = self.beacon_signature(target)
        wrong_round_signature = self.beacon_signature(target + 1)
        corrupted = bytearray(signature)
        corrupted[0] ^= 0x20  # Valid compressed point with the sign bit reversed.
        timestamp = max(record[5] + 1, self.call(self.drand.functions.roundTime(target)))
        now = self.w3.eth.get_block("latest").timestamp
        if now < timestamp:
            self.advance(timestamp - now)

        self.tx(f.settleRound(rid, wrong_round_signature), self.carol,
                error="InvalidQuicknetSignature(uint64)", check=self.financial_state)
        self.tx(f.settleRound(rid, bytes(corrupted)), self.carol,
                error="InvalidQuicknetSignature(uint64)", check=self.financial_state)
        receipts = self.same_block([
            {"fn": f.settleRound(rid, signature), "sender": self.carol},
            {"fn": f.settleRound(rid, signature), "sender": self.carol,
             "error": "RoundNotReady(uint256)"},
        ])
        require(receipts[0].blockNumber == receipts[1].blockNumber, "Competing settlements split blocks")
        require(self.call(f.round(rid))[10] == 3 and self.call(self.drand.functions.hasSig(target)),
                "Winning settlement did not cache and finalize")
        self.claim_round(rid)

        # The committed target remains usable after a long permissionless delay and failed proofs.
        delayed_version = self.new_config(self.weth, rewards=None, operator=0)
        delayed = self.open(delayed_version, 10, position=0)
        delayed_record = self.call(f.round(delayed))
        delayed_target = delayed_record[7]
        delayed_signature = self.beacon_signature(delayed_target)
        delayed_wrong = self.beacon_signature(delayed_target + 1)
        self.tx(f.settleRound(delayed, delayed_wrong), self.carol,
                error="InvalidQuicknetSignature(uint64)", check=self.financial_state)
        target_time = self.call(self.drand.functions.roundTime(delayed_target)) + 7 * 86400
        now = self.w3.eth.get_block("latest").timestamp
        if now < target_time:
            self.advance(target_time - now)
        committed = self.call(f.round(delayed))[7]
        self.settle(delayed)
        require(self.call(f.round(delayed))[7] == committed, "Delayed settlement changed its committed beacon")
        self.claim_round(delayed)
        self.result("drand rejection and retry", "wrong-round, corrupted, competing and seven-day delayed proofs")

    def module_dependency(self):
        self.stakes()
        f = self.lottery.functions
        version = self.new_config(self.weth)
        rid = self.open(version, 10)
        self.settle(rid)
        self.claim_round(rid)
        module_type = Web3.keccak(text="statics.lottery.fiddy.account.v1")
        self.tx(self.position.functions.setExternalModule(self.lottery.address, module_type, False))
        self.advance(86401)
        account = self.call(f.bonanzaAccount(1))
        self.tx(f.unstakeBonanza(1, account[1]), self.alice)
        self.tx(f.claimBonanzaRevenue(1, self.weth, self.alice), self.alice)
        account = self.call(f.bonanzaAccount(1))
        self.tx(f.unwrapBonanza(1, account[0], self.alice), self.alice)
        self.tx(f.cleanupBonanzaAccount(1), self.alice)
        require(self.call(self.position.functions.externalLegCount(1)) == 0,
                "Disabled module blocked an existing account exit")

        # Fill another PositionNFT through the real module API and prove first attachment rolls
        # back both the token pull and account credit at the capacity boundary.
        self.tx(self.position.functions.setExternalModule(self.lottery.address, module_type, True))
        filler = self.deploy("RehearsalModule")
        filler_type = Web3.keccak(text="rehearsal.capacity.module")
        self.tx(self.position.functions.setExternalModule(filler.address, filler_type, True))
        capacity = self.call(self.position.functions.externalLegCapacity())
        require(capacity == 64, "Unexpected Statics external-leg capacity")
        self.tx(filler.functions.fill(self.position.address, 3, filler_type, capacity), gas=20_000_000)
        require(self.call(self.position.functions.externalLegCount(3)) == capacity,
                "Capacity fixture did not fill the actual PositionNFT")
        self.tx(f.wrapBonanza(3, WAD), self.carol,
                error="ExternalLegCapacityReached(uint256)", check=self.financial_state)
        require(self.call(f.bonanzaAccount(3))[0] == 0 and not self.call(f.bonanzaAccount(3))[8],
                "Failed attachment leaked BONANZA account state")
        self.result("Statics module liveness", "disabled-module exits and capacity attachment rollback")

    def set_router_asset_enabled(self, timelock, router, asset, enabled, salt_label):
        data = HexBytes(router.functions.setRewardAssetEnabled(asset, enabled)._encode_transaction_data())
        salt = Web3.keccak(text=salt_label)
        self.tx(timelock.functions.schedule(router.address, 0, data, ZERO32, salt, 86400))
        self.advance(86401)
        self.tx(timelock.functions.execute(router.address, 0, data, ZERO32, salt))

    def router_rotation(self):
        f = self.lottery.functions
        old_version = self.call(f.currentIntegration())[1]
        version_a = self.new_config(self.weth, rewards=None)
        round_a = self.open(version_a, 10, position=0)
        self.settle(round_a)
        pending_a = self.call(f.pendingOperatorRevenue(old_version, self.weth))
        require(pending_a > 1, "No historical Router liability")

        timelock_b, router_b = self.timelock_b, self.router_b
        self.tx(f.setIntegrationConfig((self.drand.address, router_b.address)))
        current, new_version = self.call(f.currentIntegration())
        require(new_version == old_version + 1 and current[1] == router_b.address,
                "Router rotation did not create a distinct integration")
        require(self.call(f.pendingOperatorRevenue(old_version, self.weth)) == pending_a,
                "Rotation changed historical Router liability")

        version_b = self.new_config(self.weth, rewards=None)
        round_b = self.open(version_b, 10, position=0)
        self.settle(round_b)
        pending_b = self.call(f.pendingOperatorRevenue(new_version, self.weth))
        require(pending_b > 1, "No new Router liability")

        # Historical liabilities continue to the snapshotted Router after rotation.
        old_before = self.call(self.token(self.weth).functions.balanceOf(self.router.address))
        first_a = pending_a // 2
        self.tx(f.flushOperatorRevenue(old_version, self.weth, first_a), self.carol)
        require(self.call(self.token(self.weth).functions.balanceOf(self.router.address)) - old_before == first_a,
                "Historical partial flush reached the wrong Router")
        require(self.call(f.pendingOperatorRevenue(old_version, self.weth)) == pending_a - first_a,
                "Historical partial flush changed the wrong liability")

        # Disable actual Router B deposits, verify atomic failure, then re-enable and retry in parts.
        self.set_router_asset_enabled(timelock_b, router_b, self.weth, False, "router-b-disable-weth")
        self.tx(f.flushOperatorRevenue(new_version, self.weth, pending_b), self.carol,
                error="OperatorRouterUnavailable(address,address)", check=self.financial_state)
        require(self.call(f.pendingOperatorRevenue(new_version, self.weth)) == pending_b,
                "Failed Router B delivery consumed liability")
        self.set_router_asset_enabled(timelock_b, router_b, self.weth, True, "router-b-enable-weth")
        new_before = self.call(self.token(self.weth).functions.balanceOf(router_b.address))
        first_b = pending_b // 2
        self.tx(f.flushOperatorRevenue(new_version, self.weth, first_b), self.alice)
        self.tx(f.flushOperatorRevenue(new_version, self.weth, pending_b - first_b), self.bob)
        require(self.call(self.token(self.weth).functions.balanceOf(router_b.address)) - new_before == pending_b,
                "Router B retry delivered the wrong amount")
        self.tx(f.flushOperatorRevenue(old_version, self.weth, pending_a - first_a), self.carol)
        require(self.call(f.pendingOperatorRevenue(old_version, self.weth)) == 0 and
                self.call(f.pendingOperatorRevenue(new_version, self.weth)) == 0,
                "Router rotation left Operator revenue pending")
        self.result("Router rotation and retry", "historical routing, disabled deposits and partial retries")

    def governance(self):
        self.stakes()
        f = self.lottery.functions
        version = self.new_config(self.weth)
        rid = self.open(version, 4)
        immutable = self.call(f.round(rid))[0:3]
        self.tx(f.setGuardian(self.bob))
        self.tx(f.setTreasuryRecipient(self.carol))
        self.tx(f.setTreasuryRecipient(self.treasury))
        self.tx(f.setMaxActiveRounds(2))
        self.tx(f.setLotteryConfigEnabled(version, False))
        self.tx(f.setIntegrationConfig((self.drand.address, self.router.address)))
        require(self.call(f.round(rid))[0:3] == immutable, "Open round snapshot changed")
        self.tx(f.setPaused(True), self.bob)
        self.tx(f.buyTicketsForPosition(rid, 1, 1), self.alice, error="ProtocolPaused()", check=self.financial_state)
        self.tx(f.stakeBonanza(1, 1), self.alice, error="ProtocolPaused()", check=self.financial_state)
        self.tx(f.setPaused(False), self.bob, error="UnpauseRequiresAuthority(address)")
        self.settle(rid)
        self.claim_round(rid)
        self.tx(f.claimBonanzaRevenue(1, self.weth, self.alice), self.alice)
        self.flush()
        self.tx(f.setPaused(False))
        helper = self.deploy("RehearsalFacet")
        selector = Web3.keccak(text="rehearsalPing()")[:4]
        self.tx(f.diamondCut([(helper.address, 0, [selector])], ZERO, b""))
        require(self.call(self.contract(self.lottery.address, "RehearsalFacet").functions.rehearsalPing()) == Web3.keccak(text="lottery-rehearsal"), "New route failed")
        replacement = self.deploy("RehearsalFacet")
        self.tx(f.diamondCut([(replacement.address, 1, [selector])], ZERO, b""))
        self.tx(f.diamondCut([(ZERO, 2, [selector])], ZERO, b""))
        self.tx(f.finalizeProtocol())
        self.tx(f.diamondCut([(helper.address, 0, [selector])], ZERO, b""), error="CutsDisabled()")
        self.tx(f.finalizeProtocol(), error="AlreadyFinalized()")
        self.tx(f.setMaxActiveRounds(100))
        self.result("governance and exit liveness", "pause-safe deadline settlement; cuts finalized, configuration retained")

    def boundaries(self):
        f = self.lottery.functions
        self.tx(f.initializeBonanza(self.underlying, self.position.address, self.operators.address, self.activation.address),
                error="AlreadyInitialized()")
        self.tx(f.wrapBonanza(1, 1), self.alice, error="ConversionDisabled()", check=self.financial_state)
        self.tx(f.setBonanzaConversions(True, True, 1))
        self.tx(f.wrapBonanza(1, 2), self.alice, error="WrapCapacityExceeded()", check=self.financial_state)
        self.tx(f.wrapBonanza(1, 1), self.alice)
        self.tx(f.unwrapBonanza(1, 1, self.alice), self.alice)
        self.tx(f.createRewardLotteryConfig(self.config(self.weth), (1, 9000, True)), error="InvalidRewardsConfig()")
        version = self.new_config(self.weth, rewards=(2000 * WAD, 5000, True))
        self.tx(f.setMaxActiveRounds(0))
        self.tx(f.openRoundForPosition(version, 1, 1), self.alice, error="ActiveRoundLimitReached()", check=self.financial_state)
        self.tx(f.setMaxActiveRounds(100))
        self.tx(f.openRound(version, 1), self.alice, error="PositionRequired()", check=self.financial_state)
        rid = self.open(version, 1)
        require(self.call(f.bonanzaReserve())[0] == 0, "Inventory exhaustion not reached")
        balance = self.call(f.bonanzaAccount(1))[0]
        self.tx(f.buyTicketsForPosition(rid, 1, 1), self.alice)
        require(self.call(f.bonanzaAccount(1))[0] == balance, "Unfunded rewards issued")
        self.tx(f.openRoundForPosition(version, 1, 1), self.alice, error="ConfigAlreadyActive(uint64,uint256)", check=self.financial_state)
        self.tx(f.buyTicketsForPosition(rid, 9, 1), self.alice, error="InvalidTicketQuantity()", check=self.financial_state)
        self.tx(f.buyTicketsForPosition(rid, 0, 1), self.alice, error="InvalidTicketQuantity()", check=self.financial_state)
        # Winner-zero and winner-full, tiny-denomination and week-long configurations remain valid.
        for winner in [0, 10000]:
            before_treasury = self.call(f.assetAccounting(self.hostile.address))[5]
            v = self.new_config(self.hostile.address, rewards=(0, 8000, False), price=1, winner=winner, tip=0)
            r = self.open(v, 10, position=0)
            self.settle(r)
            require(self.call(f.round(r))[13] == (10 if winner == 10000 else 0), "Extreme winner split mismatch")
            require(self.call(f.assetAccounting(self.hostile.address))[5] - before_treasury ==
                    (8 if winner == 0 else 0), "Zero-weight staker share was not redirected to Treasury")
            if self.call(f.round(r))[13]:
                self.claim_round(r)
        self.new_config(self.weth, duration=7 * 86400)
        self.settle(rid)
        self.claim_round(rid)
        # Exact surplus absorption cannot consume accounted reserves.
        self.tx(self.token(self.underlying).functions.transfer(self.lottery.address, 123), self.alice)
        require(self.call(f.availableTokenSurplus(self.underlying)) == 123, "Wrong surplus")
        self.tx(f.absorbTokenSurplus(self.underlying), self.carol)
        self.tx(f.absorbTokenSurplus(self.underlying), self.carol, error="NoTokenSurplus()")
        self.flush()
        self.tx(f.name(), self.alice, value=1, error="NativeEthRejected()", check=self.financial_state)
        force = self.deploy("RehearsalForceNative")
        self.tx(force.functions.force(self.lottery.address), value=123)
        before = self.w3.eth.get_balance(self.treasury)
        self.tx(f.flushNativeSurplus(), self.carol)
        require(self.w3.eth.get_balance(self.treasury) - before == 123, "Forced native surplus delta mismatch")
        self.tx(f.flushNativeSurplus(), self.carol, error="NoNativeSurplus()")
        self.result("boundary economics", "inventory cap, zero-weight Treasury, exact floors and surplus isolation")

    def persistent_soak(self):
        require(self.environment["soakSteps"] >= 12,
                "Persistent soak requires at least 12 steps per seed")
        self.stakes()
        f = self.lottery.functions
        actors = [self.alice, self.bob, self.carol]
        active_positions = [1, 2, 3]
        for actor in actors:
            position = self.call(self.position.functions.nextPositionId())
            self.tx(self.position.functions.createPosition(actor), actor)
            self.positions.append(position)
            active_positions.append(position)
        for position in active_positions[2:]:
            actor = self.call(self.position.functions.ownerOf(position))
            amount = (20 + position) * WAD
            self.tx(f.wrapBonanza(position, amount), actor)
            self.tx(f.stakeBonanza(position, amount // 2), actor)
        operator_b, operator_c = self.transferable_operators(2)
        self.acquire_operator(operator_b, self.bob)
        self.acquire_operator(operator_c, self.carol)
        operators = [self.operator_id, operator_b, operator_c]

        versions = [self.new_config(asset) for asset in [self.underlying, self.weth]]
        opened = [self.open(v, 1, i + 1, actors[i]) for i, v in enumerate(versions)]
        inventory = self.call(f.bonanzaReserve())[0]
        depletion = self.new_config(self.weth, rewards=(inventory, 5000, True), count=1)
        opened.append(self.open(depletion, 1, active_positions[0], self.alice))
        require(self.call(f.bonanzaReserve())[0] == 0, "Reserve depletion setup left inventory")
        self.tx(f.fundBonanzaReserve(25 * WAD), self.alice)

        base_seed = self.environment["seed"]
        seeds = [base_seed, base_seed ^ 0x9E3779B9, base_seed + 0x85EBCA6B]
        action_log = []
        for phase, seed in enumerate(seeds):
            rng = random.Random(seed)
            modes = soak_modes(seed, self.environment["soakSteps"])
            rounds_closed = phase == len(seeds) - 1
            if rounds_closed:
                for rid in opened:
                    self.settle(rid)
                    self.claim_round(rid)
                opened = []
                self.advance(86401)
                before_count = self.counter
                self.tx(f.unstakeBonanza(3, 1), self.call(self.position.functions.ownerOf(3)))
                self.reconcile()
                action_log.append({"phase": phase, "seed": seed, "step": -1, "mode": 7,
                                   "action": "unstake",
                                   "position": 3, "owner": self.call(self.position.functions.ownerOf(3)),
                                   "firstReceipt": before_count + 1, "lastReceipt": self.counter})
            for step, mode in enumerate(modes):
                before_count = self.counter
                position = rng.choice(active_positions)
                actor = self.call(self.position.functions.ownerOf(position))
                if mode == 0:
                    if rounds_closed:
                        self.tx(f.checkpointBonanzaAccount(position), self.carol)
                        action = "checkpoint"
                    else:
                        rid = rng.choice(opened)
                        record = self.call(f.round(rid))
                        if record[10] == 2 or self.w3.eth.get_block("latest").timestamp >= record[4]:
                            self.settle(rid)
                            self.claim_round(rid)
                            opened[opened.index(rid)] = self.open(record[1], 1, position, actor)
                        else:
                            self.tx(f.buyTicketsForPosition(rid, 1, position), actor)
                        action = "round"
                elif mode == 1:
                    self.tx(f.checkpointBonanzaAccount(position), self.carol)
                    action = "checkpoint"
                elif mode == 2:
                    self.tx(f.claimBonanzaRevenue(position, rng.choice(self.assets[:2]), actor), actor)
                    action = "claim"
                elif mode == 3:
                    self.tx(f.wrapBonanza(position, rng.randrange(1, 10**15)), actor)
                    action = "wrap"
                elif mode == 4:
                    recipient = rng.choice([candidate for candidate in actors if candidate != actor])
                    self.tx(self.position.functions.transferFrom(actor, recipient, position), actor)
                    action = "transfer"
                elif mode == 5:
                    self.tx(f.setPaused(True), self.guardian)
                    self.tx(f.setPaused(False))
                    action = "pause"
                elif mode == 6:
                    account = self.call(f.bonanzaAccount(position))
                    available = account[0] - account[1]
                    if available == 0:
                        amount = rng.randrange(1, 10**15)
                        self.tx(f.wrapBonanza(position, amount), actor)
                        available = amount
                    self.tx(f.stakeBonanza(position, rng.randrange(1, min(available, 10**15) + 1)), actor)
                    action = "stake"
                elif mode == 7:
                    account = self.call(f.bonanzaAccount(position))
                    if account[1] and self.w3.eth.get_block("latest").timestamp >= account[5] + 86400:
                        amount = rng.randrange(1, min(account[1], 10**15) + 1)
                        self.tx(f.unstakeBonanza(position, amount), actor)
                        action = "unstake"
                    else:
                        self.tx(f.checkpointBonanzaAccount(position), self.carol)
                        action = "checkpoint"
                elif mode == 8:
                    operator_id = rng.choice(operators)
                    current = self.call(self.operators.functions.ownerOf(operator_id))
                    candidates = [candidate for candidate in active_positions
                                  if self.call(self.position.functions.ownerOf(candidate)) != current]
                    if candidates:
                        target = rng.choice(candidates)
                        next_owner = self.call(self.position.functions.ownerOf(target))
                        cost = self.call(self.activation.functions.tierCost(1))
                        if self.call(self.token(self.underlying).functions.balanceOf(next_owner)) >= cost:
                            self.tx(self.operators.functions.transferFrom(current, next_owner, operator_id), current)
                            self.activate_operator(operator_id, next_owner)
                            self.tx(f.registerBonanzaOperator(target, operator_id), next_owner)
                            action = "operator-activation-registration"
                        else:
                            self.tx(f.checkpointBonanzaAccount(target), self.carol)
                            action = "checkpoint"
                    else:
                        self.tx(f.checkpointBonanzaAccount(position), self.carol)
                        action = "checkpoint"
                elif mode == 9:
                    reserve = self.call(f.bonanzaReserve())[0]
                    if rounds_closed:
                        funder = max(actors, key=lambda candidate: self.call(
                            self.token(self.underlying).functions.balanceOf(candidate)))
                        self.tx(f.fundBonanzaReserve(rng.randrange(1, 6) * WAD), funder)
                        action = "reserve-refill"
                    elif reserve:
                        retired = rng.choice(opened)
                        record = self.call(f.round(retired))
                        remaining = record[0][2] - record[8]
                        max_purchase = record[0][5] or remaining
                        purchases = (remaining + max_purchase - 1) // max_purchase
                        now = self.w3.eth.get_block("latest").timestamp
                        if record[10] == 1 and now + purchases < record[4]:
                            while remaining:
                                quantity = min(remaining, max_purchase)
                                self.tx(f.buyTicketsForPosition(retired, quantity, position), actor)
                                remaining -= quantity
                        self.settle(retired)
                        self.claim_round(retired)
                        opened.remove(retired)
                        version = self.new_config(rng.choice(self.assets[:2]),
                                                  rewards=(reserve, 5000, True), count=1)
                        opened.append(self.open(version, 1, position, actor))
                        require(self.call(f.bonanzaReserve())[0] == 0, "Random reserve depletion left inventory")
                        action = "reserve-depletion"
                    else:
                        funder = max(actors, key=lambda candidate: self.call(
                            self.token(self.underlying).functions.balanceOf(candidate)))
                        self.tx(f.fundBonanzaReserve(rng.randrange(1, 6) * WAD), funder)
                        action = "reserve-refill"
                elif mode == 10:
                    if rounds_closed:
                        self.advance(rng.randrange(1, 3601))
                        action = "time-advance"
                    else:
                        headroom = int(time.time()) - self.w3.eth.get_block("latest").timestamp - 120
                        if headroom > 0:
                            self.advance(min(rng.randrange(1, 31), headroom))
                            action = "time-advance"
                        else:
                            action = "checkpoint"
                    self.tx(f.checkpointBonanzaAccount(position), self.carol)
                else:
                    if self.call(f.bonanzaAccount(position))[7]:
                        self.tx(f.removeBonanzaOperator(position), actor)
                        action = "operator-remove"
                    else:
                        self.tx(f.checkpointBonanzaAccount(position), self.carol)
                        action = "checkpoint"
                self.reconcile()
                require(self.counter > before_count, "Persistent soak choice performed no transaction")
                action_log.append({"phase": phase, "seed": seed, "step": step, "mode": mode,
                                   "action": action, "position": position, "owner": actor,
                                   "firstReceipt": before_count + 1, "lastReceipt": self.counter})
                if step % 20 == 0:
                    print(f"Soak seed {phase + 1}/3, step {step + 1}/{len(modes)}: exact conservation",
                          flush=True)

        for rid in opened:
            self.settle(rid)
            self.claim_round(rid)
        self.advance(86401)
        for position in active_positions:
            actor = self.call(self.position.functions.ownerOf(position))
            account = self.call(f.bonanzaAccount(position))
            if account[1]:
                self.tx(f.unstakeBonanza(position, account[1]), actor)
            self.tx(f.removeBonanzaOperator(position), actor)
            for asset in self.assets:
                self.tx(f.claimBonanzaRevenue(position, asset, actor), actor)
            balance = self.call(f.bonanzaAccount(position))[0]
            if balance:
                self.tx(f.unwrapBonanza(position, balance, actor), actor)
            self.tx(f.cleanupBonanzaAccount(position), actor)
            require(self.call(self.position.functions.externalLegCount(position)) == 0, "Soak leg remains")
        self.flush()
        require(self.call(f.activeRoundCount()) == 0, "Soak active rounds remain")
        for asset in self.assets:
            require(sum(self.call(f.assetAccounting(asset))) == 0, "Soak liabilities remain")
            require(self.call(f.bonanzaAsset(asset))[1] == 0, "Soak staker liability remains")
        write(self.run / "soak-actions.json", action_log)
        action_counts = {}
        for row in action_log:
            action_counts[row["action"]] = action_counts.get(row["action"], 0) + 1
        scheduled_modes = sorted({row["mode"] for row in action_log if row["step"] >= 0})
        required = {"round", "checkpoint", "claim", "wrap", "transfer", "pause", "stake", "unstake",
                    "operator-activation-registration", "reserve-depletion",
                    "reserve-refill", "time-advance"}
        require(required <= action_counts.keys(), "Persistent soak did not execute every required action")
        self.result("multi-seed terminal reconciliation", {
            "seeds": seeds, "steps": len(action_log), "accounts": len(active_positions),
            "scheduledModes": scheduled_modes, "scheduledModeCount": len(scheduled_modes),
            "executedActions": action_counts, "reserveDepletedAndRefilled": True,
        })

    def multi_boost_capacity(self):
        self.stakes()
        f = self.lottery.functions
        operator_b, operator_c = self.transferable_operators(2)
        self.acquire_operator(operator_b, self.bob)
        self.acquire_operator(operator_c, self.carol)
        self.tx(f.wrapBonanza(3, 60 * WAD), self.carol)
        self.tx(f.stakeBonanza(3, 60 * WAD), self.carol)
        self.tx(f.registerBonanzaOperator(2, operator_b), self.bob)
        self.tx(f.registerBonanzaOperator(3, operator_c), self.carol)
        listed = []
        # Each distinct token has its own real transfer, purchase and revenue index.
        for index in range(64):
            token = self.deploy("RehearsalToken")
            self.tx(token.functions.mint(self.alice, 10000))
            self.tx(token.functions.approve(self.lottery.address, MAX), self.alice)
            version = self.new_config(token.address, rewards=(0, 10000, False), price=1000,
                                      operator=0, tip=0, duration=2 * 86400)
            rid = self.open(version, 1, position=0)
            listed.append((token, rid))
            require(self.call(f.bonanzaAsset(token.address))[1] == 500, "Capacity fixture revenue not booked")
            if (index + 1) % 16 == 0:
                print(f"Revenue capacity: {index + 1}/64 funded assets", flush=True)
        require(len(self.call(f.bonanzaRevenueAssets())) == 64, "Revenue asset count mismatch")
        extra = self.deploy("RehearsalToken")
        before = self.call(f.latestLotteryConfigVersion())
        self.tx(f.createRewardLotteryConfig(self.config(extra.address, operator=0), (0, 10000, False)),
                error="RevenueAssetLimitReached()")
        require(self.call(f.latestLotteryConfigVersion()) == before, "Failed listing leaked config")
        # Already-listed assets still allow new configurations at capacity.
        self.new_config(listed[0][0].address, rewards=(0, 10000, False), operator=0)
        self.tx(self.operators.functions.transferFrom(self.alice, self.bob, self.operator_id), self.alice)
        self.tx(self.operators.functions.transferFrom(self.bob, self.carol, operator_b), self.bob)
        self.tx(self.operators.functions.transferFrom(self.carol, self.alice, operator_c), self.carol)

        expected_one = {token.address: self.modeled_bonanza_forfeit(1, token.address)
                        for token, _ in listed}
        checkpoint = self.tx(f.checkpointBonanzaAccount(1), self.carol)
        for token, _ in listed:
            self.assert_modeled_bonanza_forfeit(1, token.address, expected_one[token.address])

        expected_two = {token.address: self.modeled_bonanza_forfeit(2, token.address)
                        for token, _ in listed}
        claim_token = listed[0][0]
        balance = self.call(claim_token.functions.balanceOf(self.bob))
        claim = self.tx(f.claimBonanzaRevenue(2, claim_token.address, self.bob), self.bob)
        require(self.call(claim_token.functions.balanceOf(self.bob)) - balance ==
                expected_two[claim_token.address]["claimable"],
                "Claim-order entitlement mismatch")
        for token, _ in listed:
            self.assert_modeled_bonanza_forfeit(2, token.address, expected_two[token.address],
                                              claimed=token.address == claim_token.address)

        expected_three = {token.address: self.modeled_bonanza_forfeit(3, token.address)
                          for token, _ in listed}
        self.advance(86401)
        unstake = self.tx(f.unstakeBonanza(3, 1), self.carol)
        for token, _ in listed:
            self.assert_modeled_bonanza_forfeit(3, token.address, expected_three[token.address])

        self.activate_operator(self.operator_id, self.bob)
        self.tx(f.registerBonanzaOperator(2, self.operator_id), self.bob)
        for _, rid in listed:
            self.tx(f.buyTicketsForPosition(rid, 1, 1), self.alice)
        self.tx(self.operators.functions.transferFrom(self.bob, self.alice, self.operator_id), self.bob)
        self.activate_operator(self.operator_id, self.alice)
        takeover_expected = {token.address: self.modeled_bonanza_forfeit(2, token.address)
                             for token, _ in listed}
        require(all(expected["delta"] > 0 for expected in takeover_expected.values()),
                "Takeover fixture has no fresh boosted accrual")
        takeover = self.tx(f.registerBonanzaOperator(1, self.operator_id), self.alice)
        for token, _ in listed:
            self.assert_modeled_bonanza_forfeit(2, token.address, takeover_expected[token.address])

        remaining = self.call(f.bonanzaAccount(3))[1]
        self.tx(f.unstakeBonanza(3, remaining), self.carol)
        for token, _ in listed:
            account = self.call(f.bonanzaAccount(3))
            expected = self.modeled_bonanza_credit(3, token.address, account[2])
            before_balance = self.call(token.functions.balanceOf(self.carol))
            self.tx(f.claimBonanzaRevenue(3, token.address, self.carol), self.carol)
            require(self.call(token.functions.balanceOf(self.carol)) - before_balance == expected[0],
                    "Cleanup claim paid the wrong individual entitlement")
            require(self.call(f.bonanzaCredit(3, token.address))[2] == expected[1],
                    "Cleanup claim changed the modeled remainder")
        balance = self.call(f.bonanzaAccount(3))[0]
        self.tx(f.unwrapBonanza(3, balance, self.carol), self.carol)
        cleanup = self.tx(f.cleanupBonanzaAccount(3), self.carol)
        require(self.call(self.position.functions.externalLegCount(3)) == 0, "First cleanup left an external leg")

        self.tx(f.wrapBonanza(3, 1), self.carol)
        self.tx(f.stakeBonanza(3, 1), self.carol)
        self.activate_operator(operator_b, self.carol)
        self.tx(f.registerBonanzaOperator(3, operator_b), self.carol)
        self.advance(86401)
        self.tx(f.unstakeBonanza(3, 1), self.carol)
        self.tx(f.removeBonanzaOperator(3), self.carol)
        self.tx(f.unwrapBonanza(3, 1, self.carol), self.carol)
        reentry_cleanup = self.tx(f.cleanupBonanzaAccount(3), self.carol)
        require(self.call(self.position.functions.externalLegCount(3)) == 0,
                "Tiny re-entry cleanup left an external leg")

        gas = {"checkpoint": checkpoint.gasUsed, "claim": claim.gasUsed, "unstake": unstake.gasUsed,
               "takeover": takeover.gasUsed, "cleanup": cleanup.gasUsed,
               "reentryCleanup": reentry_cleanup.gasUsed}
        require(all(value < 12_000_000 for value in gas.values()),
                "Maximum-asset multi-boost path exceeded transaction budget")
        for token, rid in listed:
            require(self.call(token.functions.balanceOf(self.lottery.address)) ==
                    sum(self.call(f.assetAccounting(token.address))) + self.call(f.bonanzaAsset(token.address))[1],
                    "Capacity scenario token liability mismatch")
            book = self.call(f.bonanzaAsset(token.address))
            scaled = book[2]
            for position in self.positions:
                account = self.call(f.bonanzaAccount(position))
                credit = self.call(f.bonanzaCredit(position, token.address))
                scaled += credit[1] * RAY + credit[2] + account[2] * (book[0] - credit[0])
            require(scaled == book[1] * RAY, "Capacity asset scaled entitlement mismatch")
        self.result("maximum-asset multi-boost abuse", {
            "assets": 64, "invalidBoosts": 3, "65thRejected": True,
            "individualEntitlements": True, "tinyReentry": True, "gas": gas,
        })

    def coverage_gate(self):
        exceptions = {
            "protocolMoveBonanza(address,address,uint256)": "Authenticated Diamond self-call; direct unauthorized revert plus successful value-moving paths",
            "initializeBonanza(address,address,address,address)": "Already initialized atomically in the installation cut; duplicate and unauthorized reverts",
        }
        abi = {abi_to_signature(a): a for a in self.lottery.abi if a["type"] == "function"}
        missing = []
        report = []
        for row in self.installed.values():
            signature = row["signature"]
            evidence = self.coverage.get(signature, {"view": [], "success": [], "revert": []})
            view = abi[signature]["stateMutability"] in ("view", "pure")
            satisfied = bool(evidence["view"] if view else evidence["success"])
            exception_evidence = None
            errors = {e.get("expectedError") for e in evidence["revert"]}
            if signature == "protocolMoveBonanza(address,address,uint256)":
                exception_evidence = evidence.get("internal", [])
                satisfied = bool(exception_evidence and "OnlyProtocol()" in errors)
            elif signature == "initializeBonanza(address,address,address,address)":
                exception_evidence = getattr(self, "initialization_evidence", None)
                satisfied = bool(exception_evidence and {"AlreadyInitialized()", "NotAuthority(address)"} <= errors)
            if not satisfied:
                missing.append(signature)
            report.append({**row, "evidence": evidence, "exceptionEvidence": exception_evidence,
                           "classification": exceptions.get(signature, "view" if view else "direct transaction")})
        write(self.run / "selector-coverage.json", report)
        require(not missing, "Missing direct selector coverage: " + ", ".join(missing))
        self.result("selector coverage", f"{len(report)} installed selectors classified with execution evidence")
