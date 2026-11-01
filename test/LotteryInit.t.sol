// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import { StaticsLotteryDiamond } from "../src/StaticsLotteryDiamond.sol";
import { DiamondCutFacet } from "../src/facets/DiamondCutFacet.sol";
import { GovernanceFacet } from "../src/facets/GovernanceFacet.sol";
import { LotteryViewFacet } from "../src/facets/LotteryViewFacet.sol";
import { RevenueFacet } from "../src/facets/RevenueFacet.sol";
import { LotteryInit } from "../src/initializers/LotteryInit.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IGovernance } from "../src/interfaces/IGovernance.sol";
import { ILotteryView } from "../src/interfaces/ILotteryView.sol";
import { IRevenue } from "../src/interfaces/IRevenue.sol";
import { FacetCut, FacetCutAction } from "../src/shared/DiamondTypes.sol";
import { Errors } from "../src/shared/Errors.sol";
import { IntegrationConfig, LotteryConfig } from "../src/shared/Types.sol";

contract InitialPaymentToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) { }
}

contract InitialIntegrationEndpoint { }

contract LotteryInitTest is Test {
    address internal authority = makeAddr("authority");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");

    StaticsLotteryDiamond internal diamond;
    LotteryInit internal initializer;
    GovernanceFacet internal governanceFacet;
    LotteryViewFacet internal viewFacet;
    RevenueFacet internal revenueFacet;
    InitialPaymentToken internal tokenA;
    InitialPaymentToken internal tokenB;
    InitialIntegrationEndpoint internal registry;
    InitialIntegrationEndpoint internal router;

    function setUp() public {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        diamond = new StaticsLotteryDiamond(authority, address(cutFacet));
        initializer = new LotteryInit();
        governanceFacet = new GovernanceFacet();
        viewFacet = new LotteryViewFacet();
        revenueFacet = new RevenueFacet();
        tokenA = new InitialPaymentToken("Payment A", "PAYA");
        tokenB = new InitialPaymentToken("Payment B", "PAYB");
        registry = new InitialIntegrationEndpoint();
        router = new InitialIntegrationEndpoint();
    }

    function test_InitializesCompleteConfigurationAtomically() public {
        vm.recordLogs();
        _initialize(_validParams());

        ILotteryView stateView = ILotteryView(address(diamond));
        IGovernance governance = IGovernance(address(diamond));
        IRevenue revenue = IRevenue(address(diamond));

        assertEq(stateView.latestLotteryConfigVersion(), 2);
        assertEq(stateView.maxActiveRounds(), 2);
        assertEq(stateView.activeRoundCount(), 0);
        assertEq(governance.guardian(), guardian);
        assertEq(governance.treasuryRecipient(), treasury);
        assertFalse(governance.paused());

        (IntegrationConfig memory integration, uint64 integrationVersion) =
            stateView.currentIntegration();
        assertEq(integrationVersion, 1);
        assertEq(integration.drandRegistry, address(registry));
        assertEq(integration.operatorFeeRouter, address(router));

        (LotteryConfig memory configA, bool enabledA) = stateView.lotteryConfig(1);
        (LotteryConfig memory configB, bool enabledB) = stateView.lotteryConfig(2);
        assertEq(configA.paymentToken, address(tokenA));
        assertEq(configA.ticketPrice, 1 ether);
        assertEq(configB.paymentToken, address(tokenB));
        assertEq(configB.ticketPrice, 2 ether);
        assertTrue(enabledA);
        assertTrue(enabledB);
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countTopic(logs, IGovernance.IntegrationConfigUpdated.selector), 1);
        assertEq(_countTopic(logs, IGovernance.GuardianUpdated.selector), 1);
        assertEq(_countTopic(logs, IGovernance.TreasuryRecipientUpdated.selector), 1);
        assertEq(_countTopic(logs, IGovernance.MaxActiveRoundsUpdated.selector), 1);
        assertEq(_countTopic(logs, IGovernance.LotteryConfigCreated.selector), 2);
        assertEq(_countTopic(logs, IGovernance.LotteryConfigEnabled.selector), 2);
    }

    function test_RejectsRepeatedInitialization() public {
        LotteryInit.InitParams memory params = _validParams();
        _initialize(params);

        bytes memory reason = abi.encodeWithSelector(Errors.AlreadyInitialized.selector);
        vm.expectRevert(abi.encodeWithSelector(Errors.InitializationFailed.selector, reason));
        FacetCut[] memory cuts = new FacetCut[](0);
        vm.prank(authority);
        IDiamondCut(address(diamond))
            .diamondCut(
                cuts, address(initializer), abi.encodeCall(LotteryInit.initialize, (params))
            );
    }

    function test_RejectsAuthorityMismatch() public {
        LotteryInit.InitParams memory params = _validParams();
        params.authority = makeAddr("different authority");
        bytes memory reason = abi.encodeWithSelector(
            Errors.AuthorityMismatch.selector, authority, params.authority
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.InitializationFailed.selector, reason));
        _initialize(params);
    }

    function test_RejectsMissingInitialConfiguration() public {
        LotteryInit.InitParams memory params = _validParams();
        params.lotteryConfigs = new LotteryConfig[](0);
        bytes memory reason = abi.encodeWithSelector(Errors.EmptyLotteryConfigurations.selector);

        vm.expectRevert(abi.encodeWithSelector(Errors.InitializationFailed.selector, reason));
        _initialize(params);
    }

    function test_InvalidLaterConfigurationRollsBackAndCanRetry() public {
        LotteryInit.InitParams memory invalidParams = _validParams();
        invalidParams.lotteryConfigs[1].ticketPrice = 0;
        bytes memory reason = abi.encodeWithSelector(Errors.InvalidConfig.selector);

        vm.expectRevert(abi.encodeWithSelector(Errors.InitializationFailed.selector, reason));
        _initialize(invalidParams);

        _initialize(_validParams());
        assertEq(ILotteryView(address(diamond)).latestLotteryConfigVersion(), 2);
    }

    function test_RejectsEndpointWithoutCode() public {
        LotteryInit.InitParams memory params = _validParams();
        params.integration.operatorFeeRouter = makeAddr("empty router");
        bytes memory reason =
            abi.encodeWithSelector(Errors.NoCode.selector, params.integration.operatorFeeRouter);

        vm.expectRevert(abi.encodeWithSelector(Errors.InitializationFailed.selector, reason));
        _initialize(params);
    }

    function test_RejectsInvalidInitialRoles() public {
        LotteryInit.InitParams memory params = _validParams();
        params.guardian = address(0);
        bytes memory reason = abi.encodeWithSelector(Errors.InvalidAddress.selector);

        vm.expectRevert(abi.encodeWithSelector(Errors.InitializationFailed.selector, reason));
        _initialize(params);
    }

    function test_RejectsFiddyPricedOperatorShareWithoutConsumerRouter() public {
        LotteryInit.InitParams memory params = _validParams();
        params.lotteryConfigs[1].paymentToken = address(diamond);
        bytes memory reason = abi.encodeWithSelector(
            Errors.OperatorRouterUnavailable.selector, address(router), address(diamond)
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.InitializationFailed.selector, reason));
        _initialize(params);

        params.lotteryConfigs[1].operatorProtocolBps = 0;
        _initialize(params);
        assertEq(ILotteryView(address(diamond)).latestLotteryConfigVersion(), 2);
    }

    function _initialize(LotteryInit.InitParams memory params) internal {
        FacetCut[] memory cuts = new FacetCut[](3);
        cuts[0] = _cut(address(governanceFacet), _governanceSelectors());
        cuts[1] = _cut(address(viewFacet), _viewSelectors());
        cuts[2] = _cut(address(revenueFacet), _revenueSelectors());

        vm.prank(authority);
        IDiamondCut(address(diamond))
            .diamondCut(
                cuts, address(initializer), abi.encodeCall(LotteryInit.initialize, (params))
            );
    }

    function _validParams() internal view returns (LotteryInit.InitParams memory params) {
        LotteryConfig[] memory configs = new LotteryConfig[](2);
        configs[0] = _config(address(tokenA), 1 ether);
        configs[1] = _config(address(tokenB), 2 ether);
        params = LotteryInit.InitParams({
            authority: authority,
            guardian: guardian,
            treasuryRecipient: treasury,
            maxActiveRounds: 2,
            integration: IntegrationConfig(address(registry), address(router)),
            lotteryConfigs: configs
        });
    }

    function _config(address token, uint96 price) internal pure returns (LotteryConfig memory) {
        return LotteryConfig({
            paymentToken: token,
            ticketPrice: price,
            ticketCount: 10,
            salesDuration: 1 days,
            randomnessDelay: 30,
            maxTicketsPerPurchase: 10,
            winnerBps: 8000,
            operatorProtocolBps: 5000,
            finalizerTip: price / 100
        });
    }

    function _cut(address facet, bytes4[] memory selectors)
        internal
        pure
        returns (FacetCut memory)
    {
        return FacetCut(facet, FacetCutAction.Add, selectors);
    }

    function _governanceSelectors() internal pure returns (bytes4[] memory selectors) {
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

    function _viewSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](16);
        selectors[0] = ILotteryView.latestLotteryConfigVersion.selector;
        selectors[1] = ILotteryView.latestRoundId.selector;
        selectors[2] = ILotteryView.round.selector;
        selectors[3] = ILotteryView.roundConfig.selector;
        selectors[4] = ILotteryView.ticketOwner.selector;
        selectors[5] = ILotteryView.purchaseEntryCount.selector;
        selectors[6] = ILotteryView.purchaseEntry.selector;
        selectors[7] = ILotteryView.lotteryConfig.selector;
        selectors[8] = ILotteryView.currentIntegration.selector;
        selectors[9] = ILotteryView.integrationAt.selector;
        selectors[10] = ILotteryView.activeRoundCount.selector;
        selectors[11] = ILotteryView.maxActiveRounds.selector;
        selectors[12] = ILotteryView.pendingOperatorRevenue.selector;
        selectors[13] = ILotteryView.assetAccounting.selector;
        selectors[14] = ILotteryView.finalizerCredit.selector;
        selectors[15] = ILotteryView.activeRoundForConfig.selector;
    }

    function _revenueSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IRevenue.flushOperatorRevenue.selector;
        selectors[1] = IRevenue.flushTreasury.selector;
        selectors[2] = IRevenue.availableTokenSurplus.selector;
        selectors[3] = IRevenue.absorbTokenSurplus.selector;
        selectors[4] = IRevenue.flushNativeSurplus.selector;
    }

    function _countTopic(Vm.Log[] memory logs, bytes32 topic)
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) {
                ++count;
            }
        }
    }
}
