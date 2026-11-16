// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {
    TimelockController
} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";
import { LegacyGovernanceFacet } from "./fixtures/LegacyGovernanceFacet.sol";
import { GovernanceFacet } from "../src/facets/GovernanceFacet.sol";
import { DiamondLoupeFacet } from "../src/facets/DiamondLoupeFacet.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { IGovernance } from "../src/interfaces/IGovernance.sol";
import { ILotteryView } from "../src/interfaces/ILotteryView.sol";
import { BonanzaViewFacet } from "../src/facets/BonanzaViewFacet.sol";
import { GovernanceSelectors } from "../src/libraries/GovernanceSelectors.sol";
import { BonanzaConfig } from "../src/shared/BonanzaTypes.sol";
import { IntegrationConfig, LotteryConfig, Round } from "../src/shared/Types.sol";
import { Errors } from "../src/shared/Errors.sol";
import { Facet, FacetCut, FacetCutAction } from "../src/shared/DiamondTypes.sol";
import { PrepareAuthorityTransferUpgrade } from "../script/PrepareAuthorityTransferUpgrade.s.sol";
import { BonanzaSetup } from "./utils/BonanzaSetup.sol";

contract AuthorityExecutor {
    address private immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function execute(address target, bytes calldata data) external {
        require(msg.sender == owner);
        (bool success, bytes memory reason) = target.call(data);
        if (!success) {
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
    }
}

contract LotteryAuthorityTransferTest is BonanzaSetup {
    function testNominationReplacementCancellationAndEvents() public {
        assertEq(governance.authority(), authority);
        assertEq(governance.pendingAuthority(), address(0));
        vm.expectEmit(true, true, false, true, address(diamond));
        emit IGovernance.AuthorityTransferNominated(authority, alice);
        vm.prank(authority);
        governance.nominateAuthority(alice);
        assertEq(governance.authority(), authority);
        assertEq(governance.pendingAuthority(), alice);
        vm.prank(authority);
        governance.setMaxActiveRounds(3);
        vm.prank(authority);
        governance.nominateAuthority(bob);
        _rejectAccept(alice);
        assertEq(governance.pendingAuthority(), bob);
        vm.expectEmit(true, true, false, true, address(diamond));
        emit IGovernance.AuthorityTransferCancelled(authority, bob);
        vm.prank(authority);
        governance.cancelAuthorityTransfer();
        assertEq(governance.authority(), authority);
        assertEq(governance.pendingAuthority(), address(0));
        _rejectAccept(bob);
        vm.expectRevert(Errors.NoPendingAuthority.selector);
        vm.prank(authority);
        governance.cancelAuthorityTransfer();
    }

    function testRejectsUnauthorizedAndInvalidNominations() public {
        vm.prank(authority);
        governance.nominateAuthority(alice);
        for (uint256 i; i < 2; ++i) {
            address caller = i == 0 ? alice : bob;
            vm.expectRevert(abi.encodeWithSelector(Errors.NotAuthority.selector, caller));
            vm.prank(caller);
            governance.nominateAuthority(bob);
            vm.expectRevert(abi.encodeWithSelector(Errors.NotAuthority.selector, caller));
            vm.prank(caller);
            governance.cancelAuthorityTransfer();
            vm.expectRevert(abi.encodeWithSelector(Errors.NotAuthority.selector, caller));
            vm.prank(caller);
            governance.setMaxActiveRounds(1);
        }
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(authority);
        governance.nominateAuthority(address(0));
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(authority);
        governance.nominateAuthority(address(diamond));
        assertEq(governance.pendingAuthority(), alice);
        _rejectAccept(authority);
        _rejectAccept(bob);
    }

    function testAcceptancePreservesFinancialStateAndMovesEveryAuthorityCheck() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        staking.stakeBonanza(1, 50);
        uint256 roundId = _sellOutRoundA();
        _prepareProof(roundId, hex"1234");
        settlement.settleRound(roundId, hex"1234");
        vm.prank(bob);
        uint256 openId = lottery.openRound(2, 1);
        bytes32 finances = _financialState(roundId, openId);
        vm.prank(authority);
        governance.nominateAuthority(alice);
        vm.expectEmit(true, true, false, true, address(diamond));
        emit IGovernance.AuthorityTransferred(authority, alice);
        vm.prank(alice);
        governance.acceptAuthority();
        assertEq(governance.authority(), alice);
        assertEq(governance.pendingAuthority(), address(0));
        assertEq(_financialState(roundId, openId), finances);
        assertEq(governance.guardian(), guardian);
        assertEq(governance.treasuryRecipient(), treasury);
        _rejectAccept(alice);
        _assertOldAuthorityRejected();
        vm.startPrank(alice);
        governance.setMaxActiveRounds(8);
        bonanza.setBonanzaConsumer(bob, true);
        staking.setBonanzaBoostsEnabled(true);
        vm.stopPrank();
        _claimRecordedWinner(roundId);
    }

    function testHandoverWorksWhilePausedAndAfterFinalization() public {
        vm.startPrank(authority);
        governance.setPaused(true);
        governance.nominateAuthority(alice);
        governance.finalizeProtocol();
        vm.stopPrank();
        vm.prank(alice);
        governance.acceptAuthority();
        vm.startPrank(alice);
        governance.nominateAuthority(bob);
        governance.cancelAuthorityTransfer();
        governance.nominateAuthority(bob);
        vm.stopPrank();
        vm.prank(bob);
        governance.acceptAuthority();
        vm.prank(bob);
        governance.setPaused(false);
        vm.prank(bob);
        governance.setMaxActiveRounds(4);
        assertEq(governance.authority(), bob);
        assertTrue(governance.protocolFinalized());
        FacetCut[] memory empty = new FacetCut[](0);
        vm.expectRevert(Errors.CutsDisabled.selector);
        vm.prank(bob);
        IDiamondCut(address(diamond)).diamondCut(empty, address(0), "");
        vm.expectRevert(Errors.AlreadyFinalized.selector);
        vm.prank(bob);
        governance.finalizeProtocol();
    }

    function testFormerAuthorityRetainsOnlyItsSeparateGuardianRole() public {
        vm.startPrank(authority);
        governance.setGuardian(authority);
        governance.nominateAuthority(alice);
        vm.stopPrank();
        vm.prank(alice);
        governance.acceptAuthority();
        vm.prank(authority);
        governance.setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnpauseRequiresAuthority.selector, authority));
        vm.prank(authority);
        governance.setPaused(false);
        vm.prank(alice);
        governance.setPaused(false);
        assertEq(governance.guardian(), authority);
    }

    function testExecutorAcceptsWithoutReceiverCallback() public {
        AuthorityExecutor executor = new AuthorityExecutor(address(this));
        vm.prank(authority);
        governance.nominateAuthority(address(executor));
        _rejectAccept(address(this));
        executor.execute(address(diamond), abi.encodeCall(IGovernance.acceptAuthority, ()));
        assertEq(governance.authority(), address(executor));
        executor.execute(address(diamond), abi.encodeCall(IGovernance.setMaxActiveRounds, (9)));
        executor.execute(address(diamond), abi.encodeCall(IGovernance.nominateAuthority, (bob)));
        vm.prank(bob);
        governance.acceptAuthority();
        vm.expectRevert(abi.encodeWithSelector(Errors.NotAuthority.selector, address(executor)));
        executor.execute(address(diamond), abi.encodeCall(IGovernance.setMaxActiveRounds, (1)));
    }

    function testTimelockAcceptanceAndNominationUseItsExistingDelay() public {
        address[] memory actors = new address[](1);
        actors[0] = address(this);
        TimelockController timelock = new TimelockController(1 days, actors, actors, address(0));
        vm.prank(authority);
        governance.nominateAuthority(address(timelock));
        bytes memory accept = abi.encodeCall(IGovernance.acceptAuthority, ());
        timelock.schedule(address(diamond), 0, accept, bytes32(0), bytes32(0), 1 days);
        vm.expectRevert();
        timelock.execute(address(diamond), 0, accept, bytes32(0), bytes32(0));
        assertEq(governance.authority(), authority);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        timelock.execute(address(diamond), 0, accept, bytes32(0), bytes32(0));
        assertEq(governance.authority(), address(timelock));
        bytes memory nominate = abi.encodeCall(IGovernance.nominateAuthority, (bob));
        timelock.schedule(address(diamond), 0, nominate, bytes32(0), bytes32(uint256(1)), 1 days);
        vm.expectRevert();
        timelock.execute(address(diamond), 0, nominate, bytes32(0), bytes32(uint256(1)));
        assertEq(governance.pendingAuthority(), address(0));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        timelock.execute(address(diamond), 0, nominate, bytes32(0), bytes32(uint256(1)));
        vm.prank(bob);
        governance.acceptAuthority();
        vm.prank(bob);
        governance.setMaxActiveRounds(3);
        assertEq(governance.authority(), bob);
    }

    function testUpgradePreservesLegacyStorageFinancialStateAndOtherRoutes() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        staking.stakeBonanza(1, 40);
        uint256 sold = _sellOutRoundA();
        vm.prank(bob);
        uint256 open = lottery.openRound(2, 1);
        bytes32 finances = _financialState(sold, open);
        _installLegacyGovernanceSurface();
        bytes32 slot = keccak256("statics.lottery.diamond.storage.v1");
        bytes32 legacyAuthorityAndLatch = vm.load(address(diamond), bytes32(uint256(slot) + 3));
        assertEq(address(uint160(uint256(legacyAuthorityAndLatch))), authority);
        assertEq(uint256(legacyAuthorityAndLatch) >> 160, 0);
        assertEq(vm.load(address(diamond), bytes32(uint256(slot) + 4)), bytes32(0));
        bytes32 otherRoutes = _otherRoutesHash();
        address replacement = address(new GovernanceFacet());
        bytes memory upgrade =
            new PrepareAuthorityTransferUpgrade().prepare(address(diamond), replacement);
        vm.prank(authority);
        (bool ok,) = address(diamond).call(upgrade);
        assertTrue(ok);
        assertEq(vm.load(address(diamond), bytes32(uint256(slot) + 3)), legacyAuthorityAndLatch);
        assertEq(governance.authority(), authority);
        assertEq(governance.pendingAuthority(), address(0));
        _assertGovernanceRoutes(replacement);
        assertEq(_otherRoutesHash(), otherRoutes);
        assertEq(_financialState(sold, open), finances);
        vm.prank(authority);
        governance.nominateAuthority(alice);
        assertEq(
            vm.load(address(diamond), bytes32(uint256(slot) + 4)), bytes32(uint256(uint160(alice)))
        );
        vm.prank(alice);
        governance.acceptAuthority();
        assertEq(_financialState(sold, open), finances);
        _prepareProof(sold, hex"1234");
        settlement.settleRound(sold, hex"1234");
        _claimRecordedWinner(sold);
    }

    function testUpgradePreparationRejectsFinalizedAndInvalidTargets() public {
        PrepareAuthorityTransferUpgrade builder = new PrepareAuthorityTransferUpgrade();
        vm.expectRevert(Errors.InvalidAddress.selector);
        builder.prepare(address(diamond), alice);
        vm.prank(authority);
        governance.finalizeProtocol();
        GovernanceFacet replacement = new GovernanceFacet();
        vm.expectRevert(Errors.CutsDisabled.selector);
        builder.prepare(address(diamond), address(replacement));
    }

    function testUpgradePreparationRejectsSplitAndPreinstalledRoutes() public {
        _installLegacyGovernanceSurface();
        address replacement = address(new GovernanceFacet());
        PrepareAuthorityTransferUpgrade builder = new PrepareAuthorityTransferUpgrade();
        bytes4 selector = IGovernance.setMaxActiveRounds.selector;
        address current = IDiamondLoupe(address(diamond)).facetAddress(selector);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        FacetCut[] memory cuts = new FacetCut[](1);
        cuts[0] = FacetCut(replacement, FacetCutAction.Replace, selectors);
        vm.prank(authority);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
        vm.expectRevert(
            abi.encodeWithSelector(
                PrepareAuthorityTransferUpgrade.UnexpectedGovernanceRoute.selector,
                selector,
                current,
                replacement
            )
        );
        builder.prepare(address(diamond), replacement);
        cuts[0] = FacetCut(current, FacetCutAction.Replace, selectors);
        vm.prank(authority);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
        selectors[0] = IGovernance.authority.selector;
        cuts[0] = FacetCut(replacement, FacetCutAction.Add, selectors);
        vm.prank(authority);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
        vm.expectRevert(
            abi.encodeWithSelector(
                PrepareAuthorityTransferUpgrade.UnexpectedGovernanceRoute.selector,
                selectors[0],
                address(0),
                replacement
            )
        );
        builder.prepare(address(diamond), replacement);
    }

    function testFuzzNomineeCannotAcceptAfterCancellation(address nominee) public {
        if (nominee == address(0) || nominee == address(diamond)) nominee = alice;
        vm.prank(authority);
        governance.nominateAuthority(nominee);
        vm.prank(authority);
        governance.cancelAuthorityTransfer();
        _rejectAccept(nominee);
        assertEq(governance.authority(), authority);
        assertEq(governance.pendingAuthority(), address(0));
    }

    function _installLegacyGovernanceSurface() private {
        bytes4[] memory views = new bytes4[](4);
        views[0] = IDiamondLoupe.facets.selector;
        views[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        views[2] = IDiamondLoupe.facetAddresses.selector;
        views[3] = IDiamondLoupe.facetAddress.selector;
        FacetCut[] memory oldSurface = new FacetCut[](3);
        oldSurface[0] = FacetCut(
            address(new LegacyGovernanceFacet()),
            FacetCutAction.Replace,
            GovernanceSelectors.existing()
        );
        oldSurface[1] = FacetCut(address(0), FacetCutAction.Remove, GovernanceSelectors.handover());
        oldSurface[2] = FacetCut(address(new DiamondLoupeFacet()), FacetCutAction.Add, views);
        vm.prank(authority);
        IDiamondCut(address(diamond)).diamondCut(oldSurface, address(0), "");
    }

    function _otherRoutesHash() private view returns (bytes32) {
        Facet[] memory facets = IDiamondLoupe(address(diamond)).facets();
        bytes4[] memory governanceRoutes = GovernanceSelectors.all();
        bytes32 digest;
        uint256 count;
        for (uint256 i; i < facets.length; ++i) {
            for (uint256 j; j < facets[i].functionSelectors.length; ++j) {
                bytes4 selector = facets[i].functionSelectors[j];
                bool excluded;
                for (uint256 k; k < governanceRoutes.length; ++k) {
                    if (selector == governanceRoutes[k]) excluded = true;
                }
                if (!excluded) {
                    digest ^= keccak256(abi.encode(selector, facets[i].facetAddress));
                    ++count;
                }
            }
        }
        return keccak256(abi.encode(digest, count));
    }

    function _assertGovernanceRoutes(address replacement) private view {
        bytes4[] memory selectors = GovernanceSelectors.all();
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(IDiamondLoupe(address(diamond)).facetAddress(selectors[i]), replacement);
        }
    }

    function _assertOldAuthorityRejected() private {
        bytes[] memory calls = new bytes[](15);
        calls[0] = abi.encodeCall(IGovernance.setMaxActiveRounds, (1));
        calls[1] = abi.encodeCall(IGovernance.setGuardian, (bob));
        calls[2] = abi.encodeCall(IGovernance.setTreasuryRecipient, (bob));
        calls[3] = abi.encodeCall(IGovernance.setLotteryConfigEnabled, (1, false));
        calls[4] = abi.encodeCall(IGovernance.nominateAuthority, (bob));
        calls[5] = abi.encodeCall(IGovernance.cancelAuthorityTransfer, ());
        calls[6] = abi.encodeCall(IGovernance.finalizeProtocol, ());
        calls[7] = abi.encodeCall(bonanza.setBonanzaConsumer, (bob, true));
        calls[8] = abi.encodeCall(bonanza.setBonanzaConversions, (true, true, 100));
        calls[9] = abi.encodeCall(staking.setBonanzaBoostsEnabled, (true));
        (IntegrationConfig memory integration,) = governance.integrationConfig();
        calls[10] = abi.encodeCall(IGovernance.setIntegrationConfig, (integration));
        FacetCut[] memory empty = new FacetCut[](0);
        calls[11] = abi.encodeCall(IDiamondCut.diamondCut, (empty, address(0), bytes("")));
        (LotteryConfig memory config,) = stateView.lotteryConfig(1);
        BonanzaConfig memory rewards;
        calls[12] = abi.encodeCall(IGovernance.createLotteryConfig, (config));
        calls[13] = abi.encodeCall(IGovernance.createRewardLotteryConfig, (config, rewards));
        calls[14] = abi.encodeCall(
            bonanza.initializeBonanza,
            (address(tokenA), address(positions), address(operators), address(operators))
        );
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(authority);
            (bool ok, bytes memory reason) = address(diamond).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(Errors.NotAuthority.selector, authority));
        }
    }

    function _rejectAccept(address caller) private {
        vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingAuthority.selector, caller));
        vm.prank(caller);
        governance.acceptAuthority();
    }

    function _financialState(uint256 first, uint256 second) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _read(abi.encodeCall(ILotteryView.round, (first))),
                _read(abi.encodeCall(ILotteryView.round, (second))),
                _read(abi.encodeCall(ILotteryView.assetAccounting, (address(tokenA)))),
                _read(abi.encodeCall(ILotteryView.assetAccounting, (address(tokenB)))),
                _read(abi.encodeCall(BonanzaViewFacet.bonanzaReserve, ())),
                _read(abi.encodeCall(BonanzaViewFacet.bonanzaAccount, (1))),
                _read(abi.encodeCall(BonanzaViewFacet.bonanzaStaking, ())),
                tokenA.balanceOf(address(diamond)),
                tokenB.balanceOf(address(diamond))
            )
        );
    }

    function _claimRecordedWinner(uint256 roundId) private {
        Round memory round = stateView.round(roundId);
        uint256 beforeBalance = tokenA.balanceOf(round.winner);
        vm.prank(round.winner);
        claims.claimWinner(roundId, round.winner);
        assertEq(tokenA.balanceOf(round.winner) - beforeBalance, round.winnerClaimable);
    }

    function _read(bytes memory data) private view returns (bytes32) {
        (bool ok, bytes memory result) = address(diamond).staticcall(data);
        require(ok);
        return keccak256(result);
    }
}
