// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { BonanzaRevenueSetup } from "./BonanzaStaking.t.sol";
import { BonanzaAccount, BonanzaAsset, BonanzaCredit } from "../src/shared/BonanzaTypes.sol";
import { BonanzaConfig } from "../src/shared/BonanzaTypes.sol";
import { AssetAccounting } from "../src/shared/Types.sol";
import { LibBonanzaStaking } from "../src/libraries/LibBonanzaStaking.sol";

contract BonanzaStatefulTest is BonanzaRevenueSetup {
    uint256 internal constant RAY = 1e27;

    function setUp() public override {
        super.setUp();
        tokenA.mint(alice, 1e30);
        tokenA.mint(bob, 1e30);
        tokenB.mint(alice, 1e30);
        tokenB.mint(bob, 1e30);
        _start();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = this.act.selector;
        targetSelector(FuzzSelector(address(this), selectors));
        targetContract(address(this));
    }

    function act(uint256 seed) external {
        uint256 id = 1 + seed % 2;
        address owner = positions.ownerOf(id);
        BonanzaAccount memory a = bonanzaView.bonanzaAccount(id);
        uint256 mode = (seed >> 16) % 14;
        if (mode == 0) {
            _settle(seed % 2 == 0 ? address(tokenA) : address(tokenB), seed % 3 == 0);
        } else if (mode == 1 && a.balance > a.staked) {
            vm.prank(owner);
            staking.stakeBonanza(id, 1 + seed % (a.balance - a.staked));
        } else if (
            mode == 2 && a.staked > 0
                && block.timestamp >= a.stakeStart + LibBonanzaStaking.STAKE_LOCK
        ) {
            vm.prank(owner);
            staking.unstakeBonanza(id, 1 + seed % a.staked);
        } else if (mode == 3) {
            _wrap(id, owner, 1 + seed % 1000);
        } else if (mode == 4) {
            vm.prank(owner);
            positions.transferFrom(owner, owner == alice ? bob : alice, id);
        } else if (mode == 5) {
            vm.prank(owner);
            staking.claimBonanzaRevenue(
                id, seed % 2 == 0 ? address(tokenA) : address(tokenB), owner
            );
        } else if (mode == 6 && a.balance > a.staked) {
            uint256 amount = 1 + seed % (a.balance - a.staked);
            vm.prank(owner);
            bonanza.withdrawBonanza(id, amount);
            vm.prank(owner);
            bonanza.approve(address(diamond), amount);
            vm.prank(owner);
            bonanza.depositBonanza(id, amount);
        } else if (mode == 7) {
            vm.prank(owner);
            bonanza.fundBonanzaReserve(1 + seed % 1000);
        } else if (mode == 8) {
            _participate(id, owner, seed % 100 + 1);
        } else if (mode == 9) {
            staking.checkpointBonanzaAccount(id);
        } else if (mode == 10) {
            skip(seed % 2 days);
        } else if (mode == 11) {
            uint256 operatorId = 1 + (seed >> 32) % 2;
            address holder = operators.ownerOf(operatorId);
            vm.prank(holder);
            operators.transferFrom(holder, holder == alice ? bob : alice, operatorId);
        } else if (mode == 12) {
            _register(id, owner, seed);
        } else if (mode == 13) {
            vm.prank(owner);
            staking.removeBonanzaOperator(id);
        }
    }

    /// @dev Activation only rises, as in the Genesis registry; occupied valid boosts may revert.
    function _register(uint256 id, address owner, uint256 seed) internal {
        uint256 operatorId = 1 + (seed >> 32) % 2;
        if (operators.ownerOf(operatorId) != owner) return;
        uint256 current = operators.multiplierBps(operatorId);
        vm.prank(owner);
        operators.activate(operatorId, uint16(current + (seed >> 40) % (12_501 - current)));
        vm.prank(owner);
        try staking.registerBonanzaOperator(id, operatorId) { } catch { }
    }

    function _participate(uint256 id, address owner, uint256 rate) internal {
        vm.startPrank(authority);
        uint64 version = governance.createRewardLotteryConfig(
            _config(address(tokenB), 100, 10, 10, 1 days, 0),
            BonanzaConfig(uint96(rate), 5000, true)
        );
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
        vm.prank(owner);
        uint256 roundId = lottery.openRoundForPosition(version, 10, id);
        _settleRound(roundId);
    }

    function invariantBackingCustodyAndEveryAssetConserved() public view {
        (uint256 inventory, uint256 backing, uint256 custody,,,,) = bonanzaView.bonanzaReserve();
        assertEq(bonanza.totalSupply(), backing);
        assertEq(bonanza.balanceOf(address(diamond)), inventory + custody);
        BonanzaAccount memory a = bonanzaView.bonanzaAccount(1);
        BonanzaAccount memory b = bonanzaView.bonanzaAccount(2);
        assertEq(custody, a.balance + b.balance);
        (uint256 totalWeight,,) = bonanzaView.bonanzaStaking();
        assertEq(totalWeight, a.weight + b.weight);
        assertLe(a.staked, a.balance);
        assertLe(b.staked, b.balance);
        assertEq(tokenA.balanceOf(address(diamond)), _owed(address(tokenA)) + backing);
        assertEq(tokenB.balanceOf(address(diamond)), _owed(address(tokenB)));
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
        _entitlement(address(tokenA));
        _entitlement(address(tokenB));
        _registrations();
    }

    function _registrations() internal view {
        for (uint256 id = 1; id <= 2; ++id) {
            BonanzaAccount memory a = bonanzaView.bonanzaAccount(id);
            if (a.registered) assertEq(bonanzaView.bonanzaOperatorAccount(a.operatorId), id);
            else assertEq(a.weight, a.staked);
            uint256 occupant = bonanzaView.bonanzaOperatorAccount(id);
            if (occupant != 0) assertEq(bonanzaView.bonanzaAccount(occupant).operatorId, id);
        }
    }

    /// @dev Reserved revenue equals claimable, retained fractions and unbooked accrual of every
    /// account plus global dust; the whole-unit claims alone can never exceed it.
    function _entitlement(address asset) internal view {
        BonanzaAsset memory book = bonanzaView.bonanzaAsset(asset);
        uint256 scaled = book.dustRay;
        uint256 claims;
        for (uint256 id = 1; id <= 2; ++id) {
            BonanzaCredit memory c = bonanzaView.bonanzaCredit(id, asset);
            uint256 accrual = bonanzaView.bonanzaAccount(id).weight * (book.indexRay - c.paidIndex);
            scaled += c.claimable * RAY + c.remainderRay + accrual;
            claims += c.claimable + (c.remainderRay + accrual) / RAY;
        }
        assertEq(book.reserved * RAY, scaled);
        assertLe(claims, book.reserved);
    }

    function _owed(address asset) internal view returns (uint256) {
        AssetAccounting memory a = stateView.assetAccounting(asset);
        return a.activeRoundEscrow + a.winnerLiability + a.refundLiability + a.finalizerLiability
            + a.pendingOperatorRevenueTotal + a.treasuryAvailable
            + bonanzaView.bonanzaAsset(asset).reserved;
    }
}
