"""Scenario assertions use mined receipts and independent custody/entitlement reconciliation."""
import json
import random
import subprocess
import time
import urllib.request
from pathlib import Path

from eth_utils.abi import abi_to_signature
from hexbytes import HexBytes
from web3 import Web3

from common import ROOT, Rehearsal, ZERO, ZERO32, WAD, MAX, write, plain, require

HERE = Path(__file__).resolve().parent


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
                     "fiddy_payments", "governance", "boundaries", "asset_capacity", "composed_soak"]:
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
        for getter, expected in [("operatorCollection", self.operators.address), ("activationRegistry", self.activation.address),
                                 ("operatorVault", dependencies["genesisVault"]["address"]), ("routerTimelock", self.timelock.address)]:
            require(self.call(getattr(self.router.functions, getter)()) == expected, f"Router binding {getter}")
        while self.call(self.router.functions.nextOperatorId()) <= self.call(self.router.functions.LAST_OPERATOR_ID()):
            self.tx(self.router.functions.bootstrapOperators(100))
            cursor = self.call(self.router.functions.nextOperatorId())
            if cursor % 500 == 1:
                print(f"Router bootstrap: {cursor - 1}/5555 Operators", flush=True)
        self.tx(self.router.functions.finalizeBootstrap())
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
        self.tx(self.timelock.functions.execute(self.router.address, 0, *[operations[0][0], ZERO32, operations[0][1]]),
                error="TimelockUnexpectedOperationState(bytes32,bytes32)")
        self.advance(86401)
        for data, salt in operations:
            self.tx(self.timelock.functions.execute(self.router.address, 0, data, ZERO32, salt))
        require(self.call(self.router.functions.totalEffectiveWeight()) > 0, "Router has no weight")
        self.tx(self.position.functions.setExternalModule(self.lottery.address, Web3.keccak(text="statics.lottery.fiddy.account.v1"), True))
        for actor in [self.alice, self.bob, self.carol]:
            self.tx(self.position.functions.createPosition(actor), actor)
            self.positions.append(len(self.positions) + 1)
        self.borrower = self.deploy("RehearsalBorrower")
        self.tx(self.borrower.functions.create(self.position.address))
        self.positions.append(self.call(self.borrower.functions.position()))
        self.seed_assets(manifest)
        self.tx(self.lottery.functions.fundFiddyReserve(1000 * WAD), self.alice)
        require(tuple(self.call(self.lottery.functions.fiddyReserve())[3:]) == (False, False, 0, 0), "Unsafe launch conversion defaults")
        self.result("deployment identity", "mainnet dependency hashes, source runtimes and selector routes verified")
        write(self.run / "bindings.json", {"lottery": self.lottery.address, "position": self.position.address,
            "router": self.router.address, "timelock": self.timelock.address, "actors": self.actors,
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
                 "RevenueFacet", "LotteryViewFacet", "FiddyTokenFacet", "FiddyStakingFacet", "FiddyViewFacet"]
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
        data = initializer.functions.initializeWithFiddy(params, bindings)._encode_transaction_data()
        self.tx(self.lottery.functions.diamondCut(cuts, initializer.address, HexBytes(data)))
        require(tuple(self.call(self.lottery.functions.fiddyBindings())) == bindings, "FIDDY binding mismatch")
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
        self.tx(self.lottery.functions.setFiddyConversions(True, True, 10000 * WAD))
        for position, actor, amount in [(1, self.alice, 100 * WAD), (2, self.bob, 70 * WAD)]:
            self.tx(self.lottery.functions.wrapFiddy(position, amount), actor)
            self.tx(self.lottery.functions.stakeFiddy(position, amount), actor)
        self.tx(self.lottery.functions.setFiddyBoostsEnabled(True))
        self.tx(self.lottery.functions.registerFiddyOperator(1, self.operator_id), self.alice)

    def beacon(self, round_id):
        record = self.call(self.lottery.functions.round(round_id))
        beacon_round = record[7]
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
        return record, HexBytes(response["signature"])

    def settle(self, round_id, cached=False):
        record, signature = self.beacon(round_id)
        close = record[5] if record[10] == 2 else record[4]
        timestamp = max(close + 1, self.call(self.drand.functions.roundTime(record[7])))
        now = self.w3.eth.get_block("latest").timestamp
        if now < timestamp:
            self.advance(timestamp - now)
        if cached:
            self.tx(self.drand.functions.postSig(record[7], signature), self.carol)
        self.tx(self.lottery.functions.settleRound(round_id, b"" if cached else signature), self.carol)
        result = self.call(self.lottery.functions.round(round_id))
        require(result[10] == 3 and result[9] < result[8], "Settlement ticket outside sold range")
        require(self.call(self.lottery.functions.ticketOwner(round_id, result[9])) == result[11], "Winner ownership mismatch")
        return result

    def claim_round(self, round_id):
        record = self.call(self.lottery.functions.round(round_id))
        asset, winner, amount = record[0][0], record[11], record[13]
        before = self.call(self.token(asset).functions.balanceOf(winner))
        self.tx(self.lottery.functions.claimWinner(round_id, winner), winner)
        require(self.call(self.token(asset).functions.balanceOf(winner)) - before == amount, "Winner delta mismatch")

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
                self.tx(self.lottery.functions.claimFiddyRevenue(position, asset, actor), actor)
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
            f.isFiddyConsumer(self.router.address), f.fiddyBindings(), f.fiddyReserve(), f.fiddyAccount(1), f.fiddyConfig(version),
            f.fiddyRoundConfig(rid), f.fiddyOperatorAccount(self.operator_id), f.fiddyStaking(), f.fiddyRoundRevenue(rid), f.fiddyRevenueAssets()]
        for asset in self.assets:
            calls += [f.pendingOperatorRevenue(1, asset), f.assetAccounting(asset), f.finalizerCredit(asset, self.carol),
                f.fiddyAsset(asset), f.fiddyCredit(1, asset), f.indexedFiddyRevenue(1, asset)]
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
            f.setFiddyConversions(True, True, MAX), f.setFiddyConsumer(self.carol, True), f.setFiddyBoostsEnabled(False),
            f.initializeFiddy(self.underlying, self.position.address, self.operators.address, self.activation.address),
            f.finalizeProtocol(), f.diamondCut([], ZERO, b"")]
        for fn in privileged:
            self.tx(fn, self.carol, error="NotAuthority(address)", check=self.financial_state)
        self.tx(self.position.functions.approve(self.carol, 1), self.alice)
        for fn in [f.withdrawFiddy(1, 1), f.depositFiddy(1, 1), f.wrapFiddy(1, 1), f.unwrapFiddy(1, 1, self.carol),
                   f.stakeFiddy(1, 1), f.unstakeFiddy(1, 1), f.registerFiddyOperator(1, self.operator_id),
                   f.removeFiddyOperator(1), f.claimFiddyRevenue(1, self.weth, self.carol), f.cleanupFiddyAccount(1)]:
            self.tx(fn, self.carol, error="NotPositionOwner()", check=self.financial_state)
        self.tx(f.protocolMoveFiddy(self.lottery.address, self.carol, 1), self.carol,
                error="OnlyProtocol()", check=self.financial_state)
        self.tx(f.setPaused(True), self.carol, error="NotGuardian(address)")
        self.result("authority and approvals", "NFT approval never grants financial control")

    def locks_and_boosts(self):
        self.stakes()
        f = self.lottery.functions
        version = self.new_config(self.weth)
        rid = self.open(version, 10)
        nonce = self.call(f.fiddyAccount(1))[6]
        self.tx(f.checkpointFiddyAccount(1), self.carol)
        require(self.call(f.fiddyAccount(1))[6] == nonce, "Third party checkpoint changed nonce")
        self.tx(f.unstakeFiddy(1, 1), self.alice, error="StakeLocked(uint256)", check=self.financial_state)
        self.tx(self.operators.functions.transferFrom(self.alice, self.bob, self.operator_id), self.alice)
        self.tx(f.registerFiddyOperator(2, self.operator_id), self.bob)
        require(not self.call(f.fiddyAccount(1))[7], "Stale registration retained")
        require(self.call(f.fiddyAccount(1))[6] == nonce + 1, "Forfeit nonce missing")
        self.tx(self.position.functions.transferFrom(self.bob, self.carol, 2), self.bob)
        self.tx(f.checkpointFiddyAccount(2), self.alice)
        require(self.call(f.fiddyAccount(2))[2] == self.call(f.fiddyAccount(2))[1], "Position sale retained boost")
        self.settle(rid)
        self.claim_round(rid)
        self.advance(86400)
        self.tx(f.wrapFiddy(1, 100 * WAD), self.alice)
        self.tx(f.stakeFiddy(1, 100 * WAD), self.alice)
        start = self.call(f.fiddyAccount(1))[5]
        require(abs(self.w3.eth.get_block("latest").timestamp - start - 43200) <= 2, "Weighted top-up lock mismatch")
        self.tx(f.unstakeFiddy(1, 1), self.alice, error="StakeLocked(uint256)", check=self.financial_state)
        self.advance(43201)
        self.tx(f.unstakeFiddy(1, 200 * WAD), self.alice)
        self.tx(f.removeFiddyOperator(1), self.alice)
        self.tx(f.withdrawFiddy(1, WAD), self.alice)
        self.tx(f.depositFiddy(1, WAD), self.alice)
        for i in [1, 2]:
            actor = self.call(self.position.functions.ownerOf(i))
            account = self.call(f.fiddyAccount(i))
            if account[1]:
                self.tx(f.unstakeFiddy(i, account[1]), actor)
            for asset in self.assets:
                self.tx(f.claimFiddyRevenue(i, asset, actor), actor)
            amount = self.call(f.fiddyAccount(i))[0]
            self.tx(f.unwrapFiddy(i, amount, actor), actor)
            self.tx(f.cleanupFiddyAccount(i), actor)
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
        self.tx(f.claimFiddyRevenue(1, self.hostile.address, self.alice), self.alice, error="Error(string)", check=self.financial_state)
        self.tx(self.hostile.functions.configure(0, ZERO, b""))
        self.claim_round(rid)
        self.tx(f.claimFiddyRevenue(1, self.hostile.address, self.alice), self.alice)
        # Both loan sources fail atomically on the 24-hour stake lock.
        plain_version = self.new_config(self.weth, rewards=None)
        self.tx(f.wrapFiddy(1, WAD), self.alice)
        self.tx(f.withdrawFiddy(1, WAD), self.alice)
        self.tx(f.setFiddyConsumer(self.borrower.address, True))
        self.tx(f.approve(self.borrower.address, WAD), self.alice)
        self.tx(self.token(self.underlying).functions.approve(self.borrower.address, WAD), self.alice)
        for wrap, payment in [(False, self.weth), (True, self.underlying)]:
            v = plain_version if not wrap else self.new_config(self.underlying, rewards=None)
            self.tx(self.borrower.functions.attack(self.lottery.address, payment, v, WAD, wrap), self.alice,
                    error="StakeLocked(uint256)", check=self.financial_state)
        self.result("hostile callbacks and flash funding", "mined reverts with exact financial rollback")

    def fiddy_payments(self):
        self.stakes()
        f = self.lottery.functions
        self.tx(f.wrapFiddy(1, 100 * WAD), self.alice)
        self.tx(f.withdrawFiddy(1, 100 * WAD), self.alice)
        self.tx(f.transfer(self.bob, 1), self.alice, error="TransferRestricted()", check=self.financial_state)
        self.tx(f.createLotteryConfig(self.config(self.lottery.address)), error="OperatorRouterUnavailable(address,address)")
        self.tx(f.setFiddyConsumer(self.router.address, True))
        version = self.new_config(self.lottery.address, rewards=(0, 5000, False))
        rid = self.open(version, 2, position=0)
        self.tx(f.buyTickets(rid, 8), self.alice)
        self.settle(rid)
        self.tx(f.claimWinner(rid, self.bob), self.alice, error="ReceiverRestricted(address)", check=self.financial_state)
        self.claim_round(rid)
        self.tx(f.claimFiddyRevenue(1, self.lottery.address, self.bob), self.alice,
                error="ReceiverRestricted(address)", check=self.financial_state)
        self.tx(f.claimFiddyRevenue(1, self.lottery.address, self.alice), self.alice)
        self.tx(f.setFiddyConsumer(self.router.address, False))
        pending = self.call(f.pendingOperatorRevenue(1, self.lottery.address))
        self.tx(f.flushOperatorRevenue(1, self.lottery.address, pending), self.carol,
                error="OperatorRouterUnavailable(address,address)", check=self.financial_state)
        self.tx(f.setFiddyConsumer(self.router.address, True))
        self.flush()
        # Approved endpoints can redistribute; allowances alone cannot bypass movement policy.
        self.tx(f.setFiddyConsumer(self.bob, True))
        self.tx(f.transfer(self.bob, 100), self.alice)
        self.tx(f.approve(self.carol, 50), self.bob)
        self.tx(f.transferFrom(self.bob, self.carol, 50), self.carol)
        self.result("restricted payment token", "owner payouts, consumer routing and retryable Router delivery")

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
        self.tx(f.stakeFiddy(1, 1), self.alice, error="ProtocolPaused()", check=self.financial_state)
        self.tx(f.setPaused(False), self.bob, error="UnpauseRequiresAuthority(address)")
        self.settle(rid)
        self.claim_round(rid)
        self.tx(f.claimFiddyRevenue(1, self.weth, self.alice), self.alice)
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
        self.tx(f.initializeFiddy(self.underlying, self.position.address, self.operators.address, self.activation.address),
                error="AlreadyInitialized()")
        self.tx(f.wrapFiddy(1, 1), self.alice, error="ConversionDisabled()", check=self.financial_state)
        self.tx(f.setFiddyConversions(True, True, 1))
        self.tx(f.wrapFiddy(1, 2), self.alice, error="WrapCapacityExceeded()", check=self.financial_state)
        self.tx(f.wrapFiddy(1, 1), self.alice)
        self.tx(f.unwrapFiddy(1, 1, self.alice), self.alice)
        self.tx(f.createRewardLotteryConfig(self.config(self.weth), (1, 9000, True)), error="InvalidRewardsConfig()")
        version = self.new_config(self.weth, rewards=(2000 * WAD, 5000, True))
        self.tx(f.setMaxActiveRounds(0))
        self.tx(f.openRoundForPosition(version, 1, 1), self.alice, error="ActiveRoundLimitReached()", check=self.financial_state)
        self.tx(f.setMaxActiveRounds(100))
        self.tx(f.openRound(version, 1), self.alice, error="PositionRequired()", check=self.financial_state)
        rid = self.open(version, 1)
        require(self.call(f.fiddyReserve())[0] == 0, "Inventory exhaustion not reached")
        balance = self.call(f.fiddyAccount(1))[0]
        self.tx(f.buyTicketsForPosition(rid, 1, 1), self.alice)
        require(self.call(f.fiddyAccount(1))[0] == balance, "Unfunded rewards issued")
        self.tx(f.openRoundForPosition(version, 1, 1), self.alice, error="ConfigAlreadyActive(uint64,uint256)", check=self.financial_state)
        self.tx(f.buyTicketsForPosition(rid, 9, 1), self.alice, error="InvalidTicketQuantity()", check=self.financial_state)
        self.tx(f.buyTicketsForPosition(rid, 0, 1), self.alice, error="InvalidTicketQuantity()", check=self.financial_state)
        # Winner-zero and winner-full, tiny-denomination and week-long configurations remain valid.
        for winner in [0, 10000]:
            v = self.new_config(self.hostile.address, rewards=(0, 8000, False), price=1, winner=winner, tip=0)
            r = self.open(v, 10, position=0)
            self.settle(r)
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

    def composed_soak(self):
        self.stakes()
        rng = random.Random(self.environment["seed"])
        f = self.lottery.functions
        versions = [self.new_config(asset) for asset in [self.underlying, self.weth]]
        opened = [self.open(v, 1, i + 1, [self.alice, self.bob][i]) for i, v in enumerate(versions)]
        action_log = []
        for step in range(self.environment["soakSteps"]):
            mode = rng.randrange(6)
            position = rng.choice([1, 2])
            actor = self.call(self.position.functions.ownerOf(position))
            if mode == 0:
                rid = rng.choice(opened)
                r = self.call(f.round(rid))
                if r[10] == 1 and self.w3.eth.get_block("latest").timestamp < r[4] and r[8] < 9:
                    self.tx(f.buyTicketsForPosition(rid, 1, position), actor)
            elif mode == 1:
                self.tx(f.checkpointFiddyAccount(position), self.carol)
            elif mode == 2:
                self.tx(f.claimFiddyRevenue(position, rng.choice(self.assets[:2]), actor), actor)
            elif mode == 3:
                self.tx(f.wrapFiddy(position, rng.randrange(1, 1000)), actor)
            elif mode == 4:
                recipient = self.carol if actor != self.carol else (self.alice if position == 1 else self.bob)
                self.tx(self.position.functions.transferFrom(actor, recipient, position), actor)
            else:
                self.tx(f.setPaused(True), self.guardian)
                self.tx(f.setPaused(False))
            self.reconcile()
            action_log.append({"step": step, "mode": mode, "position": position, "owner": actor})
            if step % 20 == 0:
                print(f"Soak {step+1}/{self.environment['soakSteps']}: exact conservation", flush=True)
        for rid in opened:
            self.settle(rid)
            self.claim_round(rid)
        self.advance(86401)
        for position in [1, 2]:
            actor = self.call(self.position.functions.ownerOf(position))
            amount = self.call(f.fiddyAccount(position))[1]
            self.tx(f.unstakeFiddy(position, amount), actor)
            for asset in self.assets:
                self.tx(f.claimFiddyRevenue(position, asset, actor), actor)
            amount = self.call(f.fiddyAccount(position))[0]
            self.tx(f.unwrapFiddy(position, amount, actor), actor)
            self.tx(f.cleanupFiddyAccount(position), actor)
            require(self.call(self.position.functions.externalLegCount(position)) == 0, "Soak leg remains")
        self.flush()
        require(self.call(f.activeRoundCount()) == 0, "Soak active rounds remain")
        for asset in self.assets:
            require(sum(self.call(f.assetAccounting(asset))) == 0, "Soak liabilities remain")
            require(self.call(f.fiddyAsset(asset))[1] == 0, "Soak staker liability remains")
        write(self.run / "soak-actions.json", action_log)
        self.result("terminal reconciliation", "zero round/claim liabilities; only intentional backed inventory remains")

    def asset_capacity(self):
        self.stakes()
        f = self.lottery.functions
        listed = []
        # Each distinct token has its own real transfer, purchase and revenue index.
        for index in range(64):
            token = self.deploy("RehearsalToken")
            self.tx(token.functions.mint(self.alice, 10000))
            self.tx(token.functions.approve(self.lottery.address, MAX), self.alice)
            version = self.new_config(token.address, rewards=(0, 10000, False), price=1000, operator=0, tip=0)
            rid = self.open(version, 1, position=0)
            listed.append((token, rid))
            require(self.call(f.fiddyAsset(token.address))[1] == 500, "Capacity fixture revenue not booked")
        require(len(self.call(f.fiddyRevenueAssets())) == 64, "Revenue asset count mismatch")
        extra = self.deploy("RehearsalToken")
        before = self.call(f.latestLotteryConfigVersion())
        self.tx(f.createRewardLotteryConfig(self.config(extra.address, operator=0), (0, 10000, False)),
                error="RevenueAssetLimitReached()")
        require(self.call(f.latestLotteryConfigVersion()) == before, "Failed listing leaked config")
        # Already-listed assets still allow new configurations at capacity.
        self.new_config(listed[0][0].address, rewards=(0, 10000, False), operator=0)
        self.tx(self.operators.functions.transferFrom(self.alice, self.bob, self.operator_id), self.alice)
        receipt = self.tx(f.checkpointFiddyAccount(1), self.carol)
        require(receipt.gasUsed < 12_000_000, "Maximum-asset forfeit exceeded transaction budget")
        for token, rid in listed:
            require(self.call(token.functions.balanceOf(self.lottery.address)) ==
                    sum(self.call(f.assetAccounting(token.address))) + self.call(f.fiddyAsset(token.address))[1],
                    "Capacity scenario token liability mismatch")
        self.result("maximum revenue assets", {"assets": 64, "forfeitGas": receipt.gasUsed, "65thRejected": True})

    def coverage_gate(self):
        exceptions = {
            "protocolMoveFiddy(address,address,uint256)": "Authenticated Diamond self-call; direct unauthorized revert plus successful value-moving paths",
            "initializeFiddy(address,address,address,address)": "Already initialized atomically in the installation cut; duplicate and unauthorized reverts",
        }
        abi = {abi_to_signature(a): a for a in self.lottery.abi if a["type"] == "function"}
        missing = []
        report = []
        for row in self.installed.values():
            signature = row["signature"]
            evidence = self.coverage.get(signature, {"view": [], "success": [], "revert": []})
            view = abi[signature]["stateMutability"] in ("view", "pure")
            satisfied = bool(evidence["view"] if view else evidence["success"])
            if not satisfied and signature not in exceptions:
                missing.append(signature)
            report.append({**row, "evidence": evidence, "classification": exceptions.get(signature, "view" if view else "direct transaction")})
        write(self.run / "selector-coverage.json", report)
        require(not missing, "Missing direct selector coverage: " + ", ".join(missing))
        self.result("selector coverage", f"{len(report)} installed selectors classified with execution evidence")
