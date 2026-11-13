// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { BonanzaTokenFacet } from "../src/facets/BonanzaTokenFacet.sol";
import { BonanzaStakingFacet } from "../src/facets/BonanzaStakingFacet.sol";
import { BonanzaViewFacet } from "../src/facets/BonanzaViewFacet.sol";
import { BonanzaSelectors } from "../src/libraries/BonanzaSelectors.sol";
import { Script } from "forge-std/Script.sol";

import { StaticsLotteryDiamond } from "../src/StaticsLotteryDiamond.sol";
import { ClaimsFacet } from "../src/facets/ClaimsFacet.sol";
import { DiamondCutFacet } from "../src/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../src/facets/DiamondLoupeFacet.sol";
import { GovernanceFacet } from "../src/facets/GovernanceFacet.sol";
import { LotteryFacet } from "../src/facets/LotteryFacet.sol";
import { LotteryViewFacet } from "../src/facets/LotteryViewFacet.sol";
import { RevenueFacet } from "../src/facets/RevenueFacet.sol";
import { SettlementFacet } from "../src/facets/SettlementFacet.sol";
import { LotteryInit } from "../src/initializers/LotteryInit.sol";
import { IClaims } from "../src/interfaces/IClaims.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { IGovernance } from "../src/interfaces/IGovernance.sol";
import { ILottery } from "../src/interfaces/ILottery.sol";
import { ILotteryView } from "../src/interfaces/ILotteryView.sol";
import { IOperatorFeeRouter } from "../src/interfaces/IOperatorFeeRouter.sol";
import { IRevenue } from "../src/interfaces/IRevenue.sol";
import { ISettlement } from "../src/interfaces/ISettlement.sol";
import { FacetCut, FacetCutAction } from "../src/shared/DiamondTypes.sol";
import { BonanzaBindings } from "../src/shared/BonanzaTypes.sol";
import { IntegrationConfig, LotteryConfig } from "../src/shared/Types.sol";

interface IConfiguredOperatorFeeRouter is IOperatorFeeRouter {
    function operatorCollection() external view returns (address);
    function activationRegistry() external view returns (address);
    function operatorVault() external view returns (address);
    function routerTimelock() external view returns (address);
}

/// @notice Deterministic Robinhood Testnet deployment for the disposable release rehearsal.
contract DeployLottery is Script {
    uint256 internal constant ROBINHOOD_TESTNET_CHAIN_ID = 46_630;
    address internal constant EXPECTED_DEPLOYER = 0x6Ae2aD9905FEDC8270b828294D4b9CEC7CBBE316;

    address internal constant DRAND_REGISTRY = 0x61388A94B429A04cAC0357485c12F68f706d7b57;
    address internal constant WETH = 0x33e4191705c386532ba27cBF171Db86919200B94;
    address internal constant STATICS = 0xb6Cc79B2d892798d8e469A1efBF0713Fc2e51f86;
    address internal constant OPERATOR_COLLECTION = 0x6c9197347161FC140a209175849d443FeaAF509c;
    address internal constant ACTIVATION_REGISTRY = 0x8cE462A801726FA030e06264f3423Be2Ae8d6414;
    address internal constant OPERATOR_VAULT = 0x8D3a32ddF8bD529EC847457eC79620D2870FFdc4;

    bytes32 internal constant DRAND_REGISTRY_CODEHASH =
        0xde08fa453cee52a32750e6ff4f736d28b2a4378494cc699e62d27eb44164c1fc;
    bytes32 internal constant WETH_CODEHASH =
        0x55f8ac53c64450f01880d8249fc5cb0c69c064e4bcb097ea80a02fff40485a7c;
    bytes32 internal constant STATICS_CODEHASH =
        0xe548428d65bf2a8cee29a63e8dfaaeda0b4d44294d80f67f7626e1da8b89be69;

    uint16 internal constant MAX_ACTIVE_ROUNDS = 100;
    uint32 internal constant TICKET_COUNT = 5;
    uint32 internal constant SALES_DURATION = 120;
    uint32 internal constant RANDOMNESS_DELAY = 6;
    uint16 internal constant WINNER_BPS = 5000;
    // Operators receive 40% of the remaining 50%, or 20% of gross receipts.
    uint16 internal constant OPERATOR_PROTOCOL_BPS = 4000;

    uint96 internal constant WETH_TICKET_PRICE = 0.000_01 ether;
    uint96 internal constant WETH_FINALIZER_TIP = 0.000_001 ether;
    uint96 internal constant STATICS_TICKET_PRICE = 1 ether;
    uint96 internal constant STATICS_FINALIZER_TIP = 0.1 ether;

    struct Deployment {
        address diamond;
        address cutFacet;
        address loupeFacet;
        address governanceFacet;
        address lotteryFacet;
        address settlementFacet;
        address claimsFacet;
        address revenueFacet;
        address viewFacet;
        address initializer;
        address bonanzaTokenFacet;
        address bonanzaStakingFacet;
        address bonanzaViewFacet;
    }

    error DependencyCodeHashMismatch(address dependency, bytes32 expected, bytes32 actual);
    error OperatorRouterConfigurationMismatch();
    error OperatorRouterNotReady();
    error UnexpectedDeployer(address actual);
    error WrongChain(uint256 actual);

    function run() external returns (Deployment memory deployment) {
        if (block.chainid != ROBINHOOD_TESTNET_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 deployerKey = vm.envUint("LOTTERY_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        if (deployer != EXPECTED_DEPLOYER) revert UnexpectedDeployer(deployer);

        address operatorFeeRouter = vm.envAddress("LOTTERY_OPERATOR_FEE_ROUTER");
        // The Statics PositionNFT that implements the external account module interface. BONANZA
        // initialization verifies its code and interface in the same transaction as the cut.
        address positionNFT = vm.envAddress("LOTTERY_BONANZA_POSITION_NFT");
        _validateDependencies(operatorFeeRouter);

        vm.startBroadcast(deployerKey);
        deployment = _deploy(deployer, operatorFeeRouter, positionNFT);
        vm.stopBroadcast();
    }

    function _deploy(address authority, address operatorFeeRouter, address positionNFT)
        internal
        returns (Deployment memory deployment)
    {
        deployment.cutFacet = address(new DiamondCutFacet());
        deployment.diamond = address(new StaticsLotteryDiamond(authority, deployment.cutFacet));
        deployment.loupeFacet = address(new DiamondLoupeFacet());
        deployment.governanceFacet = address(new GovernanceFacet());
        deployment.lotteryFacet = address(new LotteryFacet());
        deployment.settlementFacet = address(new SettlementFacet());
        deployment.claimsFacet = address(new ClaimsFacet());
        deployment.revenueFacet = address(new RevenueFacet());
        deployment.viewFacet = address(new LotteryViewFacet());
        deployment.initializer = address(new LotteryInit());
        deployment.bonanzaTokenFacet = address(new BonanzaTokenFacet());
        deployment.bonanzaStakingFacet = address(new BonanzaStakingFacet());
        deployment.bonanzaViewFacet = address(new BonanzaViewFacet());

        _initializeDiamond(deployment, authority, operatorFeeRouter, positionNFT);
    }

    function _initializeDiamond(
        Deployment memory deployment,
        address authority,
        address operatorFeeRouter,
        address positionNFT
    ) internal {
        FacetCut[] memory cuts = new FacetCut[](10);
        cuts[0] = _cut(deployment.loupeFacet, _loupeSelectors());
        cuts[1] = _cut(deployment.governanceFacet, _governanceSelectors());
        cuts[2] = _cut(deployment.lotteryFacet, _lotterySelectors());
        cuts[3] = _cut(deployment.settlementFacet, _settlementSelectors());
        cuts[4] = _cut(deployment.claimsFacet, _claimsSelectors());
        cuts[5] = _cut(deployment.revenueFacet, _revenueSelectors());
        cuts[6] = _cut(deployment.viewFacet, _viewSelectors());

        cuts[7] = _cut(deployment.bonanzaTokenFacet, BonanzaSelectors.token());
        cuts[8] = _cut(deployment.bonanzaStakingFacet, BonanzaSelectors.staking());
        cuts[9] = _cut(deployment.bonanzaViewFacet, BonanzaSelectors.views());

        LotteryConfig[] memory configs = new LotteryConfig[](2);
        configs[0] = _lotteryConfig(WETH, WETH_TICKET_PRICE, WETH_FINALIZER_TIP);
        configs[1] = _lotteryConfig(STATICS, STATICS_TICKET_PRICE, STATICS_FINALIZER_TIP);
        LotteryInit.InitParams memory params = LotteryInit.InitParams({
            authority: authority,
            guardian: authority,
            treasuryRecipient: authority,
            maxActiveRounds: MAX_ACTIVE_ROUNDS,
            integration: IntegrationConfig(DRAND_REGISTRY, operatorFeeRouter),
            lotteryConfigs: configs
        });

        BonanzaBindings memory bonanza =
            BonanzaBindings(STATICS, positionNFT, OPERATOR_COLLECTION, ACTIVATION_REGISTRY);
        IDiamondCut(deployment.diamond)
            .diamondCut(
                cuts,
                deployment.initializer,
                abi.encodeCall(LotteryInit.initializeWithBonanza, (params, bonanza))
            );
    }

    function _validateDependencies(address operatorFeeRouter) internal view {
        _requireCodeHash(DRAND_REGISTRY, DRAND_REGISTRY_CODEHASH);
        _requireCodeHash(WETH, WETH_CODEHASH);
        _requireCodeHash(STATICS, STATICS_CODEHASH);

        IConfiguredOperatorFeeRouter router = IConfiguredOperatorFeeRouter(operatorFeeRouter);
        if (
            operatorFeeRouter.code.length == 0 || router.operatorCollection() != OPERATOR_COLLECTION
                || router.activationRegistry() != ACTIVATION_REGISTRY
                || router.operatorVault() != OPERATOR_VAULT
                || router.routerTimelock().code.length == 0
        ) {
            revert OperatorRouterConfigurationMismatch();
        }
        if (
            !router.bootstrapFinalized() || router.totalEffectiveWeight() == 0
                || !router.isRewardAsset(WETH) || !router.rewardAssetEnabled(WETH)
                || !router.isRewardAsset(STATICS) || !router.rewardAssetEnabled(STATICS)
        ) {
            revert OperatorRouterNotReady();
        }
    }

    function _requireCodeHash(address dependency, bytes32 expected) internal view {
        bytes32 actual = dependency.codehash;
        if (actual != expected) {
            revert DependencyCodeHashMismatch(dependency, expected, actual);
        }
    }

    function _lotteryConfig(address paymentToken, uint96 ticketPrice, uint96 finalizerTip)
        internal
        pure
        returns (LotteryConfig memory)
    {
        return LotteryConfig({
            paymentToken: paymentToken,
            ticketPrice: ticketPrice,
            ticketCount: TICKET_COUNT,
            salesDuration: SALES_DURATION,
            randomnessDelay: RANDOMNESS_DELAY,
            maxTicketsPerPurchase: TICKET_COUNT,
            winnerBps: WINNER_BPS,
            operatorProtocolBps: OPERATOR_PROTOCOL_BPS,
            recipientBps: 0,
            recipient: address(0),
            finalizerTip: finalizerTip
        });
    }

    function _cut(address facet, bytes4[] memory selectors)
        internal
        pure
        returns (FacetCut memory)
    {
        return FacetCut(facet, FacetCutAction.Add, selectors);
    }

    function _loupeSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IDiamondLoupe.facets.selector;
        selectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        selectors[2] = IDiamondLoupe.facetAddresses.selector;
        selectors[3] = IDiamondLoupe.facetAddress.selector;
    }

    function _governanceSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](14);
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
        selectors[13] = IGovernance.createRewardLotteryConfig.selector;
    }

    function _lotterySelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[2] = ILottery.openRoundForPosition.selector;
        selectors[3] = ILottery.buyTicketsForPosition.selector;
        selectors[0] = ILottery.openRound.selector;
        selectors[1] = ILottery.buyTickets.selector;
    }

    function _settlementSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = ISettlement.settleRound.selector;
    }

    function _claimsSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IClaims.claimWinner.selector;
        selectors[1] = IClaims.claimFinalizerTips.selector;
    }

    function _revenueSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = IRevenue.flushOperatorRevenue.selector;
        selectors[1] = IRevenue.flushTreasury.selector;
        selectors[2] = IRevenue.availableTokenSurplus.selector;
        selectors[3] = IRevenue.absorbTokenSurplus.selector;
        selectors[4] = IRevenue.flushNativeSurplus.selector;
        selectors[5] = IRevenue.flushRecipientRevenue.selector;
        selectors[6] = IRevenue.claimRecipientRevenue.selector;
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
}
