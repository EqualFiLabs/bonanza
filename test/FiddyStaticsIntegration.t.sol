// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { FiddySetup } from "./utils/FiddySetup.sol";
import { IERC721 } from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IStaticsExternalModules } from "../src/interfaces/IStaticsExternalModules.sol";
import { FiddyConfig } from "../src/shared/FiddyTypes.sol";
import { Round } from "../src/shared/Types.sol";
import { FiddyErrors } from "../src/shared/FiddyErrors.sol";
import { IFiddyActivation } from "../src/interfaces/IFiddyProtocol.sol";

interface IStaticsCandidate {
    function create() external returns (address, address, address, address, uint256);
    function approveModule(address consumer) external;
}

interface IGenesisLinks {
    function linkGenesis(uint256 id, uint256 operatorId) external;
    function unlinkGenesis(uint256 id, uint256 operatorId) external;
}

interface IPositionClosure {
    function closePosition(uint256 id) external;
}

/// @notice Executes actual 0.8.33 Statics artifacts against the 0.8.30 Fiddy candidate.
contract FiddyStaticsIntegrationTest is FiddySetup {
    IStaticsCandidate internal candidate;
    IStaticsExternalModules internal core;
    IERC721 internal actualOperators;
    IERC20 internal statics;
    uint256 internal positionId;
    address internal activation;

    function _initializeFiddy() internal override {
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
        fiddy.initializeFiddy(underlying, position, ops, registry_);
    }

    function testActualCandidateLifecycleBoostResetAndPositionSale() public {
        vm.prank(authority);
        fiddy.setFiddyConversions(true, false, 100 ether);
        vm.startPrank(alice);
        statics.approve(address(diamond), 100 ether);
        fiddy.wrapFiddy(positionId, 100 ether);
        vm.stopPrank();
        assertEq(core.externalLegCount(positionId), 1);
        vm.prank(authority);
        staking.setFiddyBoostsEnabled(true);
        vm.prank(alice);
        staking.stakeFiddy(positionId, 100 ether);
        vm.prank(alice);
        staking.registerFiddyOperator(positionId, 1);
        assertEq(fiddyView.fiddyAccount(positionId).weight, 125 ether);
        vm.prank(alice);
        IGenesisLinks(address(core)).linkGenesis(positionId, 1);
        assertEq(fiddyView.fiddyAccount(positionId).weight, 125 ether);
        vm.prank(alice);
        IGenesisLinks(address(core)).unlinkGenesis(positionId, 1);
        assertEq(fiddyView.fiddyAccount(positionId).weight, 125 ether);
        vm.prank(alice);
        statics.approve(address(diamond), type(uint256).max);
        vm.prank(alice);
        fiddy.fundFiddyReserve(2 ether);
        uint256 soldOut = _fundedRound(address(tokenB), false);
        uint256 deadline = _fundedRound(address(statics), true);
        // An actual Genesis round trip resets the activation tier, so the boost is forfeited even
        // though Alice owns both NFTs again. With no other stake the excess goes to Treasury.
        vm.prank(alice);
        actualOperators.transferFrom(alice, bob, 1);
        vm.prank(bob);
        actualOperators.transferFrom(bob, alice, 1);
        assertEq(IFiddyActivation(activation).multiplierBps(1), 10_000);
        uint256 treasuryB = stateView.assetAccounting(address(tokenB)).treasuryAvailable;
        staking.checkpointFiddyAccount(positionId);
        assertFalse(fiddyView.fiddyAccount(positionId).registered);
        assertEq(fiddyView.fiddyAccount(positionId).weight, 100 ether);
        assertEq(fiddyView.fiddyOperatorAccount(1), 0);
        assertEq(fiddyView.fiddyCredit(positionId, address(tokenB)).claimable, 80);
        assertEq(fiddyView.fiddyCredit(positionId, address(statics)).claimable, 40);
        assertEq(stateView.assetAccounting(address(tokenB)).treasuryAvailable, treasuryB + 20);
        vm.prank(alice);
        IERC721(address(core)).transferFrom(alice, bob, positionId);
        vm.prank(alice);
        vm.expectRevert(FiddyErrors.NotPositionOwner.selector);
        fiddy.withdrawFiddy(positionId, 1, alice);
        vm.prank(bob);
        staking.unstakeFiddy(positionId, 100 ether);
        vm.prank(bob);
        assertEq(staking.claimFiddyRevenue(positionId, address(tokenB), bob), 80);
        vm.prank(bob);
        assertEq(staking.claimFiddyRevenue(positionId, address(statics), bob), 40);
        vm.prank(bob);
        fiddy.withdrawFiddy(positionId, 102 ether, bob);
        Round memory round = stateView.round(soldOut);
        vm.prank(round.winner);
        claims.claimWinner(soldOut, round.winner);
        round = stateView.round(deadline);
        vm.prank(round.winner);
        claims.claimWinner(deadline, round.winner);
        vm.prank(bob);
        staking.cleanupFiddyAccount(positionId);
        assertEq(core.externalLegCount(positionId), 0);
        vm.prank(bob);
        IPositionClosure(address(core)).closePosition(positionId);
    }

    function _fundedRound(address asset, bool deadline) internal returns (uint256 id) {
        router.setAsset(asset, true, true);
        vm.startPrank(authority);
        uint64 version = governance.createRewardLotteryConfig(
            _config(asset, 100, 10, 10, 1 days, 0), FiddyConfig(1 ether, 5000, true)
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
