// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { LibLotteryConfig } from "../src/libraries/LibLotteryConfig.sol";
import { Errors } from "../src/shared/Errors.sol";
import { IntegrationConfig, LotteryConfig, RoundConfigSnapshot } from "../src/shared/Types.sol";

contract ConfigurationEndpoint { }

contract LotteryConfigHarness {
    function validateLottery(LotteryConfig memory config) external view {
        LibLotteryConfig.validate(config);
    }

    function validateIntegration(IntegrationConfig memory config) external view {
        LibLotteryConfig.validate(config);
    }

    function snapshot(LotteryConfig memory config)
        external
        pure
        returns (RoundConfigSnapshot memory)
    {
        return LibLotteryConfig.snapshot(config);
    }
}

contract LotteryConfigTest is Test {
    LotteryConfigHarness internal harness;
    ConfigurationEndpoint internal token;
    ConfigurationEndpoint internal registry;
    ConfigurationEndpoint internal router;

    function setUp() public {
        harness = new LotteryConfigHarness();
        token = new ConfigurationEndpoint();
        registry = new ConfigurationEndpoint();
        router = new ConfigurationEndpoint();
    }

    function test_AcceptsBoundaryValuesAndZeroSemantics() public view {
        LotteryConfig memory config = _validConfig();
        config.randomnessDelay = 0;
        config.maxTicketsPerPurchase = 0;
        config.winnerBps = 0;
        config.operatorProtocolBps = 0;
        config.finalizerTip = 0;
        harness.validateLottery(config);

        config.maxTicketsPerPurchase = config.ticketCount;
        config.winnerBps = 10_000;
        config.operatorProtocolBps = 10_000;
        harness.validateLottery(config);
    }

    function test_RejectsInvalidTokenPriceCountAndDuration() public {
        LotteryConfig memory config = _validConfig();
        config.paymentToken = address(0);
        vm.expectRevert(Errors.InvalidAddress.selector);
        harness.validateLottery(config);

        config = _validConfig();
        address account = makeAddr("account without code");
        config.paymentToken = account;
        vm.expectRevert(abi.encodeWithSelector(Errors.NoCode.selector, account));
        harness.validateLottery(config);

        config = _validConfig();
        config.ticketPrice = 0;
        vm.expectRevert(Errors.InvalidConfig.selector);
        harness.validateLottery(config);

        config = _validConfig();
        config.ticketCount = 0;
        vm.expectRevert(Errors.InvalidConfig.selector);
        harness.validateLottery(config);

        config = _validConfig();
        config.salesDuration = 0;
        vm.expectRevert(Errors.InvalidConfig.selector);
        harness.validateLottery(config);
    }

    function test_RejectsInvalidBpsAndPurchaseLimit() public {
        LotteryConfig memory config = _validConfig();
        config.winnerBps = 10_001;
        vm.expectRevert(Errors.InvalidConfig.selector);
        harness.validateLottery(config);

        config = _validConfig();
        config.operatorProtocolBps = 10_001;
        vm.expectRevert(Errors.InvalidConfig.selector);
        harness.validateLottery(config);

        config = _validConfig();
        config.maxTicketsPerPurchase = config.ticketCount + 1;
        vm.expectRevert(Errors.InvalidConfig.selector);
        harness.validateLottery(config);
    }

    function test_RequiresContractIntegrationEndpoints() public {
        harness.validateIntegration(IntegrationConfig(address(registry), address(router)));

        vm.expectRevert(Errors.InvalidAddress.selector);
        harness.validateIntegration(IntegrationConfig(address(0), address(router)));

        address account = makeAddr("router without code");
        vm.expectRevert(abi.encodeWithSelector(Errors.NoCode.selector, account));
        harness.validateIntegration(IntegrationConfig(address(registry), account));
    }

    function test_SnapshotCopiesEveryRoundParameter() public view {
        LotteryConfig memory config = _validConfig();
        RoundConfigSnapshot memory result = harness.snapshot(config);

        assertEq(result.paymentToken, config.paymentToken);
        assertEq(result.ticketPrice, config.ticketPrice);
        assertEq(result.ticketCount, config.ticketCount);
        assertEq(result.salesDuration, config.salesDuration);
        assertEq(result.randomnessDelay, config.randomnessDelay);
        assertEq(result.maxTicketsPerPurchase, config.maxTicketsPerPurchase);
        assertEq(result.winnerBps, config.winnerBps);
        assertEq(result.operatorProtocolBps, config.operatorProtocolBps);
        assertEq(result.finalizerTip, config.finalizerTip);
    }

    function _validConfig() private view returns (LotteryConfig memory) {
        return LotteryConfig({
            paymentToken: address(token),
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
}
