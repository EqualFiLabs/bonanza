// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { FiddySetup } from "./utils/FiddySetup.sol";
import { LotteryFacet } from "../src/facets/LotteryFacet.sol";
import { SettlementFacet } from "../src/facets/SettlementFacet.sol";
import { GovernanceFacet } from "../src/facets/GovernanceFacet.sol";
import { RevenueFacet } from "../src/facets/RevenueFacet.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { FacetCut, FacetCutAction } from "../src/shared/DiamondTypes.sol";
import { Round } from "../src/shared/Types.sol";

contract FiddyUpgradeTest is FiddySetup {
    uint256 internal occupiedRound;
    bytes32 internal snapshot;

    function _initializeFiddy() internal override {
        FacetCut[] memory cuts = new FacetCut[](4);
        cuts[0] = FacetCut(
            vm.deployCode("out-legacy/LotteryFacet.sol/LotteryFacet.json"),
            FacetCutAction.Replace,
            _lotterySelectors()
        );
        cuts[1] = FacetCut(
            vm.deployCode("out-legacy/SettlementFacet.sol/SettlementFacet.json"),
            FacetCutAction.Replace,
            _settlementSelectors()
        );
        cuts[2] = FacetCut(
            vm.deployCode("out-legacy/GovernanceFacet.sol/GovernanceFacet.json"),
            FacetCutAction.Replace,
            _governanceSelectors()
        );
        cuts[3] = FacetCut(
            vm.deployCode("out-legacy/RevenueFacet.sol/RevenueFacet.json"),
            FacetCutAction.Replace,
            _revenueSelectors()
        );
        vm.prank(authority);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
        vm.prank(alice);
        occupiedRound = lottery.openRound(1, 4);
        snapshot = keccak256(abi.encode(stateView.round(occupiedRound)));
        super._initializeFiddy();
    }

    function testActualLegacyRoundSurvivesFacetUpgradeAndNewInitialization() public {
        assertEq(keccak256(abi.encode(stateView.round(occupiedRound))), snapshot);
        FacetCut[] memory cuts = new FacetCut[](4);
        cuts[0] = FacetCut(address(new LotteryFacet()), FacetCutAction.Replace, _lotterySelectors());
        cuts[1] = FacetCut(
            address(new SettlementFacet()), FacetCutAction.Replace, _settlementSelectors()
        );
        cuts[2] = FacetCut(
            address(new GovernanceFacet()), FacetCutAction.Replace, _governanceSelectors()
        );
        cuts[3] = FacetCut(address(new RevenueFacet()), FacetCutAction.Replace, _revenueSelectors());
        vm.prank(authority);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
        assertEq(keccak256(abi.encode(stateView.round(occupiedRound))), snapshot);
        assertEq(fiddyView.fiddyRoundConfig(occupiedRound).stakerProtocolBps, 0);
        vm.prank(bob);
        lottery.buyTickets(occupiedRound, 6);
        _prepareProof(occupiedRound, hex"1234");
        vm.prank(finalizer);
        settlement.settleRound(occupiedRound, hex"1234");
        Round memory settled = stateView.round(occupiedRound);
        vm.prank(settled.winner);
        assertEq(claims.claimWinner(occupiedRound, settled.winner), 80);
        assertEq(revenue.flushOperatorRevenue(1, address(tokenA), 10), 10);
        assertEq(revenue.flushTreasury(address(tokenA), 7), 7);
        vm.prank(finalizer);
        assertEq(claims.claimFinalizerTips(address(tokenA), finalizer), 3);
        assertEq(tokenA.balanceOf(address(diamond)), 0);
        assertEq(stateView.activeRoundCount(), 0);
    }
}
