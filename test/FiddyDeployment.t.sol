// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {
    IERC20Metadata
} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { DeployLottery } from "../script/DeployLottery.s.sol";
import { FiddyTokenFacet } from "../src/facets/FiddyTokenFacet.sol";
import { FiddyViewFacet } from "../src/facets/FiddyViewFacet.sol";
import { IGovernance } from "../src/interfaces/IGovernance.sol";
import { LibFiddy } from "../src/libraries/LibFiddy.sol";
import { Errors } from "../src/shared/Errors.sol";
import { FiddyErrors } from "../src/shared/FiddyErrors.sol";
import { ConfiguredDrandRegistry, IntegrationEndpoint } from "./utils/LotteryIntegrationSetup.sol";
import { FiddyOperators, FiddyPositions } from "./utils/FiddySetup.sol";

contract DeploymentDecimalsToken is ERC20 {
    uint8 internal immutable tokenDecimals;

    constructor(uint8 decimals_) ERC20("Token", "TKN") {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }
}

contract DeploymentActivationRegistry {
    address public immutable genesisCollection;

    constructor(address collection) {
        genesisCollection = collection;
    }
}

contract DeploymentHarness is DeployLottery {
    function deploy(address operatorFeeRouter, address positionNFT)
        external
        returns (Deployment memory)
    {
        return _deploy(address(this), operatorFeeRouter, positionNFT);
    }

    function initializeAgain(address diamond) external {
        FiddyTokenFacet(diamond)
            .initializeFiddy(STATICS, address(1), OPERATOR_COLLECTION, ACTIVATION_REGISTRY);
    }

    function pinned() external pure returns (address, address, address, address, address) {
        return (STATICS, WETH, DRAND_REGISTRY, OPERATOR_COLLECTION, ACTIVATION_REGISTRY);
    }
}

/// @notice Runs the deployment script's cut and initializer against local stand-ins etched at
/// its pinned dependency addresses. STATICS uses 6 decimals to prove FIDDY reads it.
contract FiddyDeploymentTest is Test {
    DeploymentHarness internal harness;
    FiddyPositions internal positions;
    IntegrationEndpoint internal router;

    function setUp() public {
        harness = new DeploymentHarness();
        (
            address statics,
            address weth,
            address drandRegistry,
            address operators,
            address activationRegistry
        ) = harness.pinned();
        vm.etch(statics, address(new DeploymentDecimalsToken(6)).code);
        vm.etch(weth, address(new DeploymentDecimalsToken(18)).code);
        vm.etch(drandRegistry, address(new ConfiguredDrandRegistry()).code);
        vm.etch(operators, address(new DeploymentDecimalsToken(0)).code);
        vm.etch(activationRegistry, address(new DeploymentActivationRegistry(operators)).code);
        positions = new FiddyPositions();
        router = new IntegrationEndpoint();
    }

    function testFreshDeploymentInitializesFiddyInTheCutTransaction() public {
        vm.recordLogs();
        DeployLottery.Deployment memory deployment =
            harness.deploy(address(router), address(positions));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Both the base configuration and FIDDY bindings were written by the single cut call.
        assertEq(_count(logs, deployment.diamond, IGovernance.LotteryConfigCreated.selector), 2);
        assertEq(_count(logs, deployment.diamond, LibFiddy.FiddyInitialized.selector), 1);

        assertEq(IERC20Metadata(deployment.diamond).decimals(), 6);
        assertEq(IERC20Metadata(deployment.diamond).name(), "FIDDY");
        (address statics,,, address operators, address activationRegistry) = harness.pinned();
        (address underlying, address positionNFT, address boundOperators, address registry) =
            FiddyViewFacet(deployment.diamond).fiddyBindings();
        assertEq(underlying, statics);
        assertEq(positionNFT, address(positions));
        assertEq(boundOperators, operators);
        assertEq(registry, activationRegistry);

        vm.expectRevert(FiddyErrors.AlreadyInitialized.selector);
        harness.initializeAgain(deployment.diamond);
    }

    function testDeploymentRejectsAPositionNftWithoutTheModuleInterface() public {
        address plainNft = address(new FiddyOperators(positions));
        bytes memory reason = abi.encodeWithSelector(FiddyErrors.InvalidBinding.selector);
        vm.expectRevert(abi.encodeWithSelector(Errors.InitializationFailed.selector, reason));
        harness.deploy(address(router), plainNft);
    }

    function _count(Vm.Log[] memory logs, address emitter, bytes32 topic)
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == emitter && logs[i].topics.length != 0
                    && logs[i].topics[0] == topic
            ) ++count;
        }
    }
}
