// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { StaticsLotteryDiamond } from "../src/StaticsLotteryDiamond.sol";
import { DiamondCutFacet } from "../src/facets/DiamondCutFacet.sol";
import { GovernanceFacet } from "../src/facets/GovernanceFacet.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IGovernance } from "../src/interfaces/IGovernance.sol";
import { LibLotteryStorage } from "../src/libraries/LibLotteryStorage.sol";
import { Errors } from "../src/shared/Errors.sol";
import { FacetCut, FacetCutAction } from "../src/shared/DiamondTypes.sol";
import { IntegrationConfig, LotteryConfig } from "../src/shared/Types.sol";

contract GovernanceEndpoint { }

contract GovernanceStateFacet {
    function lotteryConfigAt(uint64 version)
        external
        view
        returns (LotteryConfig memory config, bool enabled)
    {
        LibLotteryStorage.GameStorage storage gs = LibLotteryStorage.gameStorage();
        return (gs.configs[version], gs.configEnabled[version]);
    }

    function integrationAt(uint64 version) external view returns (IntegrationConfig memory) {
        return LibLotteryStorage.integrationStorage().integrations[version];
    }

    function maxActiveRounds() external view returns (uint16) {
        return LibLotteryStorage.gameStorage().maxActiveRounds;
    }

    function nextConfigVersion() external view returns (uint64) {
        return LibLotteryStorage.gameStorage().nextConfigVersion;
    }

    function currentIntegrationVersion() external view returns (uint64) {
        return LibLotteryStorage.integrationStorage().currentVersion;
    }
}

contract LotteryGovernanceTest is Test {
    address internal authority = makeAddr("authority");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal outsider = makeAddr("outsider");

    StaticsLotteryDiamond internal diamond;
    DiamondCutFacet internal cutFacet;
    IGovernance internal governance;
    GovernanceStateFacet internal stateView;
    GovernanceEndpoint internal token;
    GovernanceEndpoint internal registry;
    GovernanceEndpoint internal router;

    function setUp() public {
        cutFacet = new DiamondCutFacet();
        diamond = new StaticsLotteryDiamond(authority, address(cutFacet));
        GovernanceFacet governanceFacet = new GovernanceFacet();
        GovernanceStateFacet stateFacet = new GovernanceStateFacet();
        token = new GovernanceEndpoint();
        registry = new GovernanceEndpoint();
        router = new GovernanceEndpoint();

        FacetCut[] memory cuts = new FacetCut[](2);
        cuts[0] = _cut(address(governanceFacet), _governanceSelectors());
        cuts[1] = _cut(address(stateFacet), _stateSelectors());

        vm.prank(authority);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
        governance = IGovernance(address(diamond));
        stateView = GovernanceStateFacet(address(diamond));
    }

    function test_CreatesImmutableConfigsWithIndependentEnabledState() public {
        LotteryConfig memory first = _config(address(token));
        vm.prank(authority);
        uint64 firstVersion = governance.createLotteryConfig(first);
        assertEq(firstVersion, 1);
        _assertConfig(1, first, false);

        vm.prank(authority);
        governance.setLotteryConfigEnabled(firstVersion, true);
        _assertConfig(1, first, true);

        GovernanceEndpoint secondToken = new GovernanceEndpoint();
        LotteryConfig memory second = _config(address(secondToken));
        second.ticketPrice = 25 ether;
        vm.prank(authority);
        uint64 secondVersion = governance.createLotteryConfig(second);

        assertEq(secondVersion, 2);
        _assertConfig(1, first, true);
        _assertConfig(2, second, false);
        assertEq(stateView.nextConfigVersion(), 2);
    }

    function test_RejectsEnabledStateForMissingConfig() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ConfigNotFound.selector, 0));
        vm.prank(authority);
        governance.setLotteryConfigEnabled(0, true);

        vm.expectRevert(abi.encodeWithSelector(Errors.ConfigNotFound.selector, 1));
        vm.prank(authority);
        governance.setLotteryConfigEnabled(1, true);
    }

    function test_VersionsIntegrationsWithoutRewritingHistory() public {
        IntegrationConfig memory first = IntegrationConfig(address(registry), address(router));
        vm.prank(authority);
        governance.setIntegrationConfig(first);

        (IntegrationConfig memory current, uint64 version) = governance.integrationConfig();
        assertEq(version, 1);
        _assertIntegration(current, first);

        GovernanceEndpoint secondRegistry = new GovernanceEndpoint();
        GovernanceEndpoint secondRouter = new GovernanceEndpoint();
        IntegrationConfig memory second =
            IntegrationConfig(address(secondRegistry), address(secondRouter));
        vm.prank(authority);
        governance.setIntegrationConfig(second);

        (current, version) = governance.integrationConfig();
        assertEq(version, 2);
        _assertIntegration(current, second);
        _assertIntegration(stateView.integrationAt(1), first);
        assertEq(stateView.currentIntegrationVersion(), 2);
    }

    function test_AllowsZeroToDisableFutureRoundOpening() public {
        vm.prank(authority);
        governance.setMaxActiveRounds(12);
        assertEq(stateView.maxActiveRounds(), 12);

        vm.prank(authority);
        governance.setMaxActiveRounds(0);
        assertEq(stateView.maxActiveRounds(), 0);
    }

    function test_RestrictsTreasuryRecipientAndGuardianPausePowers() public {
        vm.prank(authority);
        governance.setTreasuryRecipient(treasury);
        assertEq(governance.treasuryRecipient(), treasury);

        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(authority);
        governance.setTreasuryRecipient(address(0));

        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(authority);
        governance.setTreasuryRecipient(address(diamond));

        vm.prank(authority);
        governance.setGuardian(guardian);
        assertEq(governance.guardian(), guardian);

        vm.expectRevert(abi.encodeWithSelector(Errors.NotGuardian.selector, outsider));
        vm.prank(outsider);
        governance.setPaused(true);

        vm.prank(guardian);
        governance.setPaused(true);
        assertTrue(governance.paused());

        vm.expectRevert(abi.encodeWithSelector(Errors.UnpauseRequiresAuthority.selector, guardian));
        vm.prank(guardian);
        governance.setPaused(false);

        vm.prank(authority);
        governance.setPaused(false);
        assertFalse(governance.paused());
    }

    function test_RequiresAuthorityForEveryPrivilegedMutation() public {
        bytes memory unauthorized = abi.encodeWithSelector(Errors.NotAuthority.selector, outsider);

        vm.expectRevert(unauthorized);
        vm.prank(outsider);
        governance.createLotteryConfig(_config(address(token)));

        vm.expectRevert(unauthorized);
        vm.prank(outsider);
        governance.setLotteryConfigEnabled(1, true);

        vm.expectRevert(unauthorized);
        vm.prank(outsider);
        governance.setMaxActiveRounds(1);

        vm.expectRevert(unauthorized);
        vm.prank(outsider);
        governance.setIntegrationConfig(IntegrationConfig(address(registry), address(router)));

        vm.expectRevert(unauthorized);
        vm.prank(outsider);
        governance.setTreasuryRecipient(treasury);

        vm.expectRevert(unauthorized);
        vm.prank(outsider);
        governance.setGuardian(guardian);

        vm.expectRevert(unauthorized);
        vm.prank(outsider);
        governance.finalizeProtocol();
    }

    function test_FinalizationDisablesCutsButPreservesParameterGovernance() public {
        vm.prank(authority);
        governance.finalizeProtocol();
        assertTrue(governance.protocolFinalized());

        FacetCut[] memory cuts = new FacetCut[](0);
        vm.expectRevert(Errors.CutsDisabled.selector);
        vm.prank(authority);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        vm.prank(authority);
        assertEq(governance.createLotteryConfig(_config(address(token))), 1);
        vm.prank(authority);
        governance.setMaxActiveRounds(5);
        assertEq(stateView.maxActiveRounds(), 5);

        vm.expectRevert(Errors.AlreadyFinalized.selector);
        vm.prank(authority);
        governance.finalizeProtocol();
    }

    function _config(address paymentToken) private pure returns (LotteryConfig memory) {
        return LotteryConfig({
            paymentToken: paymentToken,
            ticketPrice: 10 ether,
            ticketCount: 100,
            salesDuration: 1 days,
            randomnessDelay: 30,
            maxTicketsPerPurchase: 10,
            winnerBps: 8000,
            operatorProtocolBps: 5000,
            recipientBps: 0,
            recipient: address(0),
            finalizerTip: 1 ether
        });
    }

    function _assertConfig(uint64 version, LotteryConfig memory expected, bool enabled)
        private
        view
    {
        (LotteryConfig memory actual, bool actualEnabled) = stateView.lotteryConfigAt(version);
        assertEq(actual.paymentToken, expected.paymentToken);
        assertEq(actual.ticketPrice, expected.ticketPrice);
        assertEq(actual.ticketCount, expected.ticketCount);
        assertEq(actual.salesDuration, expected.salesDuration);
        assertEq(actual.randomnessDelay, expected.randomnessDelay);
        assertEq(actual.maxTicketsPerPurchase, expected.maxTicketsPerPurchase);
        assertEq(actual.winnerBps, expected.winnerBps);
        assertEq(actual.operatorProtocolBps, expected.operatorProtocolBps);
        assertEq(actual.finalizerTip, expected.finalizerTip);
        assertEq(actualEnabled, enabled);
    }

    function _assertIntegration(IntegrationConfig memory actual, IntegrationConfig memory expected)
        private
        pure
    {
        assertEq(actual.drandRegistry, expected.drandRegistry);
        assertEq(actual.operatorFeeRouter, expected.operatorFeeRouter);
    }

    function _cut(address facet, bytes4[] memory selectors) private pure returns (FacetCut memory) {
        return FacetCut(facet, FacetCutAction.Add, selectors);
    }

    function _governanceSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](13);
        selectors[0] = IGovernance.createLotteryConfig.selector;
        selectors[1] = IGovernance.setLotteryConfigEnabled.selector;
        selectors[2] = IGovernance.setMaxActiveRounds.selector;
        selectors[3] = IGovernance.integrationConfig.selector;
        selectors[4] = IGovernance.setIntegrationConfig.selector;
        selectors[5] = IGovernance.setTreasuryRecipient.selector;
        selectors[6] = IGovernance.setGuardian.selector;
        selectors[7] = IGovernance.setPaused.selector;
        selectors[8] = IGovernance.paused.selector;
        selectors[9] = IGovernance.guardian.selector;
        selectors[10] = IGovernance.treasuryRecipient.selector;
        selectors[11] = IGovernance.protocolFinalized.selector;
        selectors[12] = IGovernance.finalizeProtocol.selector;
    }

    function _stateSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = GovernanceStateFacet.lotteryConfigAt.selector;
        selectors[1] = GovernanceStateFacet.integrationAt.selector;
        selectors[2] = GovernanceStateFacet.maxActiveRounds.selector;
        selectors[3] = GovernanceStateFacet.nextConfigVersion.selector;
        selectors[4] = GovernanceStateFacet.currentIntegrationVersion.selector;
    }
}
