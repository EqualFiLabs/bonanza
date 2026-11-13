// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { BonanzaSetup } from "./utils/BonanzaSetup.sol";
import { IERC721 } from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import { IERC165 } from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IStaticsExternalModules } from "../src/interfaces/IStaticsExternalModules.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { BonanzaConfig } from "../src/shared/BonanzaTypes.sol";
import { Round } from "../src/shared/Types.sol";
import { BonanzaErrors } from "../src/shared/BonanzaErrors.sol";
import { IBonanzaActivation } from "../src/interfaces/IBonanzaProtocol.sol";

interface IStaticsCandidate {
    function create() external returns (address, address, address, address, uint256);
    function approveModule(address consumer) external;
    function setModuleEnabled(address consumer, bool enabled) external;
}

interface IGenesisLinks {
    function linkGenesis(uint256 id, uint256 operatorId) external;
    function unlinkGenesis(uint256 id, uint256 operatorId) external;
}

interface IPositionClosure {
    function closePosition(uint256 id) external;
}

/// @notice Executes actual 0.8.33 Statics artifacts against the 0.8.30 Bonanza candidate.
contract BonanzaStaticsIntegrationTest is BonanzaSetup {
    IStaticsCandidate internal candidate;
    IStaticsExternalModules internal core;
    IERC721 internal actualOperators;
    IERC20 internal statics;
    uint256 internal positionId;
    address internal activation;

    function _initializeBonanza() internal override {
        candidate = IStaticsCandidate(
            vm.deployCode("out-statics/StaticsCandidate.sol/StaticsCandidate.json")
        );
        (address position, address ops, address registry_, address underlying, uint256 id) =
            candidate.create();
        core = IStaticsExternalModules(position);
        actualOperators = IERC721(ops);
        statics = IERC20(underlying);
        activation = registry_;
        positionId = id;
        candidate.approveModule(address(diamond));
        vm.prank(authority);
        bonanza.initializeBonanza(underlying, position, ops, registry_);
    }

    function testActualCandidateSupportsOnlyReducedExternalInterface() public view {
        bytes4 reduced = type(IStaticsExternalModules).interfaceId;
        assertTrue(IERC165(address(core)).supportsInterface(reduced));
        bytes4[4] memory removed = [
            bytes4(keccak256("transferHead()")),
            bytes4(keccak256("transferState(address,uint256)")),
            bytes4(keccak256("transferChanges(uint256,uint256)")),
            bytes4(keccak256("historyCoverage(address)"))
        ];
        bytes4 previous = reduced;
        for (uint256 i; i < removed.length; ++i) {
            previous ^= removed[i];
            assertEq(IDiamondLoupe(address(core)).facetAddress(removed[i]), address(0));
        }
        assertFalse(IERC165(address(core)).supportsInterface(previous));
    }

    function testActualCandidateAttachmentRollbackAndDisabledCleanup() public {
        vm.prank(authority);
        bonanza.setBonanzaConversions(true, false, 100 ether);
        candidate.setModuleEnabled(address(diamond), false);
        uint256 beforeBalance = statics.balanceOf(alice);
        vm.startPrank(alice);
        statics.approve(address(diamond), 100 ether);
        vm.expectRevert();
        bonanza.wrapBonanza(positionId, 100 ether);
        vm.stopPrank();
        assertEq(statics.balanceOf(alice), beforeBalance);
        assertEq(statics.balanceOf(address(diamond)), 0);
        assertEq(bonanza.totalSupply(), 0);
        assertEq(bonanzaView.bonanzaAccount(positionId).balance, 0);
        assertFalse(bonanzaView.bonanzaAccount(positionId).attached);
        assertEq(core.externalLegCount(positionId), 0);
        candidate.setModuleEnabled(address(diamond), true);
        vm.startPrank(alice);
        bonanza.wrapBonanza(positionId, 100 ether);
        IERC721(address(core)).approve(bob, positionId);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(BonanzaErrors.NotPositionOwner.selector);
        bonanza.withdrawBonanza(positionId, 1);
        candidate.setModuleEnabled(address(diamond), false);
        vm.startPrank(alice);
        vm.expectRevert();
        IPositionClosure(address(core)).closePosition(positionId);
        bonanza.withdrawBonanza(positionId, 100 ether);
        staking.cleanupBonanzaAccount(positionId);
        assertEq(core.externalLegCount(positionId), 0);
        IPositionClosure(address(core)).closePosition(positionId);
        vm.stopPrank();
    }

    function testActualCandidateLifecycleBoostResetAndPositionSale() public {
        vm.prank(authority);
        bonanza.setBonanzaConversions(true, false, 100 ether);
        vm.startPrank(alice);
        statics.approve(address(diamond), 100 ether);
        bonanza.wrapBonanza(positionId, 100 ether);
        vm.stopPrank();
        assertEq(core.externalLegCount(positionId), 1);
        vm.prank(authority);
        staking.setBonanzaBoostsEnabled(true);
        vm.prank(alice);
        staking.stakeBonanza(positionId, 100 ether);
        vm.prank(alice);
        staking.registerBonanzaOperator(positionId, 1);
        assertEq(bonanzaView.bonanzaAccount(positionId).weight, 125 ether);
        vm.prank(alice);
        IGenesisLinks(address(core)).linkGenesis(positionId, 1);
        assertEq(bonanzaView.bonanzaAccount(positionId).weight, 125 ether);
        vm.prank(alice);
        IGenesisLinks(address(core)).unlinkGenesis(positionId, 1);
        assertEq(bonanzaView.bonanzaAccount(positionId).weight, 125 ether);
        vm.prank(alice);
        statics.approve(address(diamond), type(uint256).max);
        vm.prank(alice);
        bonanza.fundBonanzaReserve(2 ether);
        uint256 soldOut = _fundedRound(address(tokenB), false);
        uint256 deadline = _fundedRound(address(statics), true);
        // An actual Genesis round trip resets the activation tier, so the boost is forfeited even
        // though Alice owns both NFTs again. With no other stake the excess goes to Treasury.
        vm.prank(alice);
        actualOperators.transferFrom(alice, bob, 1);
        vm.prank(bob);
        actualOperators.transferFrom(bob, alice, 1);
        assertEq(IBonanzaActivation(activation).multiplierBps(1), 10_000);
        uint256 treasuryB = stateView.assetAccounting(address(tokenB)).treasuryAvailable;
        staking.checkpointBonanzaAccount(positionId);
        assertFalse(bonanzaView.bonanzaAccount(positionId).registered);
        assertEq(bonanzaView.bonanzaAccount(positionId).weight, 100 ether);
        assertEq(bonanzaView.bonanzaOperatorAccount(1), 0);
        assertEq(bonanzaView.bonanzaCredit(positionId, address(tokenB)).claimable, 80);
        assertEq(bonanzaView.bonanzaCredit(positionId, address(statics)).claimable, 40);
        assertEq(stateView.assetAccounting(address(tokenB)).treasuryAvailable, treasuryB + 20);
        vm.prank(alice);
        IERC721(address(core)).transferFrom(alice, bob, positionId);
        vm.prank(alice);
        vm.expectRevert(BonanzaErrors.NotPositionOwner.selector);
        bonanza.withdrawBonanza(positionId, 1);
        vm.prank(bob);
        staking.unstakeBonanza(positionId, 100 ether);
        vm.prank(bob);
        assertEq(staking.claimBonanzaRevenue(positionId, address(tokenB), bob), 80);
        vm.prank(bob);
        assertEq(staking.claimBonanzaRevenue(positionId, address(statics), bob), 40);
        vm.prank(bob);
        bonanza.withdrawBonanza(positionId, 102 ether);
        Round memory round = stateView.round(soldOut);
        vm.prank(round.winner);
        claims.claimWinner(soldOut, round.winner);
        round = stateView.round(deadline);
        vm.prank(round.winner);
        claims.claimWinner(deadline, round.winner);
        vm.prank(bob);
        staking.cleanupBonanzaAccount(positionId);
        assertEq(core.externalLegCount(positionId), 0);
        vm.prank(bob);
        IPositionClosure(address(core)).closePosition(positionId);
    }

    function _fundedRound(address asset, bool deadline) internal returns (uint256 id) {
        router.setAsset(asset, true, true);
        vm.startPrank(authority);
        uint64 version = governance.createRewardLotteryConfig(
            _config(asset, 100, 10, 10, 1 days, 0), BonanzaConfig(1 ether, 5000, true)
        );
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
        vm.prank(alice);
        id = lottery.openRoundForPosition(version, deadline ? 5 : 10, positionId);
        bytes memory proof = abi.encode(id);
        _prepareProof(id, proof);
        vm.prank(finalizer);
        settlement.settleRound(id, proof);
    }
}
