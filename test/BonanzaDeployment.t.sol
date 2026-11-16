// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IERC165 } from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import { IStaticsExternalModules } from "../src/interfaces/IStaticsExternalModules.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {
    IERC20Metadata
} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { DeployLottery } from "../script/DeployLottery.s.sol";
import { BonanzaTokenFacet } from "../src/facets/BonanzaTokenFacet.sol";
import { BonanzaViewFacet } from "../src/facets/BonanzaViewFacet.sol";
import { IGovernance } from "../src/interfaces/IGovernance.sol";
import { LibBonanza } from "../src/libraries/LibBonanza.sol";
import { Errors } from "../src/shared/Errors.sol";
import { BonanzaErrors } from "../src/shared/BonanzaErrors.sol";
import { ConfiguredDrandRegistry, IntegrationEndpoint } from "./utils/LotteryIntegrationSetup.sol";
import { BonanzaOperators, BonanzaPositions } from "./utils/BonanzaSetup.sol";

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
        BonanzaTokenFacet(diamond)
            .initializeBonanza(STATICS, address(1), OPERATOR_COLLECTION, ACTIVATION_REGISTRY);
    }

    function pinned() external pure returns (address, address, address, address, address) {
        return (STATICS, WETH, DRAND_REGISTRY, OPERATOR_COLLECTION, ACTIVATION_REGISTRY);
    }
}

/// @notice Runs the deployment script's cut and initializer against local stand-ins etched at
/// its pinned dependency addresses. STATICS uses 6 decimals to prove BONANZA reads it.
contract BonanzaDeploymentTest is Test {
    DeploymentHarness internal harness;
    BonanzaPositions internal positions;
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
        positions = new BonanzaPositions();
        router = new IntegrationEndpoint();
    }

    function testFreshDeploymentInitializesBonanzaInTheCutTransaction() public {
        vm.recordLogs();
        DeployLottery.Deployment memory deployment =
            harness.deploy(address(router), address(positions));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Both the base configuration and BONANZA bindings were written by the single cut call.
        assertEq(_count(logs, deployment.diamond, IGovernance.LotteryConfigCreated.selector), 2);
        assertEq(_count(logs, deployment.diamond, LibBonanza.BonanzaInitialized.selector), 1);

        assertEq(IERC20Metadata(deployment.diamond).decimals(), 6);
        assertEq(IERC20Metadata(deployment.diamond).name(), "Bonanza");
        assertEq(IERC20Metadata(deployment.diamond).symbol(), "BONANZA");
        (address statics,,, address operators, address activationRegistry) = harness.pinned();
        (address underlying, address positionNFT, address boundOperators, address registry) =
            BonanzaViewFacet(deployment.diamond).bonanzaBindings();
        assertEq(underlying, statics);
        assertEq(positionNFT, address(positions));
        assertEq(boundOperators, operators);
        assertEq(registry, activationRegistry);

        vm.expectRevert(BonanzaErrors.AlreadyInitialized.selector);
        harness.initializeAgain(deployment.diamond);
    }

    function testDeploymentRejectsOnlyThePreviousModuleInterface() public {
        bytes4 reduced = type(IStaticsExternalModules).interfaceId;
        bytes4 previous = reduced ^ bytes4(keccak256("transferHead()"))
            ^ bytes4(keccak256("transferState(address,uint256)"))
            ^ bytes4(keccak256("transferChanges(uint256,uint256)"))
            ^ bytes4(keccak256("historyCoverage(address)"));
        vm.mockCall(
            address(positions),
            abi.encodeCall(IERC165.supportsInterface, (previous)),
            abi.encode(true)
        );
        vm.mockCall(
            address(positions),
            abi.encodeCall(IERC165.supportsInterface, (reduced)),
            abi.encode(false)
        );
        bytes memory reason = abi.encodeWithSelector(BonanzaErrors.InvalidBinding.selector);
        vm.expectRevert(abi.encodeWithSelector(Errors.InitializationFailed.selector, reason));
        harness.deploy(address(router), address(positions));
    }

    function testDeploymentRejectsAPositionNftWithoutTheModuleInterface() public {
        address plainNft = address(new BonanzaOperators(positions));
        bytes memory reason = abi.encodeWithSelector(BonanzaErrors.InvalidBinding.selector);
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
