// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;
import {Test} from "forge-std/Test.sol";
import {IERC173} from "pinned-statics/src/interfaces/IERC173.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IDiamondCut} from "pinned-statics/src/interfaces/IDiamondCut.sol";
import {IStaticsPosition} from "pinned-statics/src/interfaces/IStaticsPosition.sol";
import {IStaticsExternalModules} from "pinned-statics/src/interfaces/IStaticsExternalModules.sol";
import {IStaticsGenesisIntegration} from "pinned-statics/src/interfaces/IStaticsGenesisIntegration.sol";
import {IStaticsGenesis} from "pinned-statics/src/interfaces/IStaticsGenesis.sol";
import {IStaticsFeeReceiver} from "pinned-statics/src/interfaces/IStaticsFeeReceiver.sol";
import {IGenesisLaunchDistributor} from "pinned-statics/src/interfaces/IGenesisLaunchDistributor.sol";
import {IGenesisActivationRegistry} from "pinned-statics/src/interfaces/IGenesisActivationRegistry.sol";
import {GenesisNFTFacet} from "pinned-statics/src/facets/GenesisNFTFacet.sol";
import {ExternalModuleFacet} from "pinned-statics/src/facets/ExternalModuleFacet.sol";
import {StaticsGenesisIntegrationInit} from "pinned-statics/src/diamond/StaticsGenesisIntegrationInit.sol";
import {LibGenesisIntegration} from "pinned-statics/src/libraries/LibGenesisIntegration.sol";
import {StaticsSelectors} from "pinned-statics/src/libraries/StaticsSelectors.sol";
import {StaticsTestDeployer} from "pinned-statics/test/helpers/StaticsTestBase.sol";

/// @notice Local-fork governance impersonation; never broadcasts a transaction.
contract StaticsForkCandidate is Test {
    IStaticsExternalModules private core;

    function create() external returns (address position, address nft, address registry, address token, uint256 id) {
        assertEq(block.chainid, 4663);
        // Robinhood NUMBER exposes the pinned header's L1 block number.
        assertEq(block.number, 26303058);
        string memory manifest = vm.readFile("lib/statics/deployments/robinhood-mainnet-genesis.json");
        nft = _binding(manifest, "operatorsNft");
        registry = _binding(manifest, "activationRegistry");
        token = _binding(manifest, "staticsToken");
        address receiver = _binding(manifest, "feeReceiver");
        address vault = _binding(manifest, "genesisVault");
        address predecessor = _binding(manifest, "launchDistributor");
        position = address(
            new StaticsTestDeployer()
                .deploy(address(this), address(0x1234), vm.parseJsonAddress(manifest, ".roles.treasury"), token)
        );
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut(
            address(new GenesisNFTFacet()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.genesisNFT()
        );
        cuts[1] = IDiamondCut.FacetCut(
            address(new ExternalModuleFacet()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.externalModules()
        );
        StaticsGenesisIntegrationInit init = new StaticsGenesisIntegrationInit();
        LibGenesisIntegration.InitArgs memory args = LibGenesisIntegration.InitArgs(
            nft, vault, registry, receiver, token, IStaticsFeeReceiver(receiver).numeraire(), 4000
        );
        IDiamondCut(position)
            .diamondCut(cuts, address(init), abi.encodeCall(StaticsGenesisIntegrationInit.initialize, (args)));
        vm.prank(IERC173(nft).owner());
        IStaticsGenesis(nft).bindProtocol(position);
        core = IStaticsExternalModules(position);
        assertFalse(core.historyCoverage(nft).ready);
        IStaticsGenesisIntegration integration = IStaticsGenesisIntegration(position);
        vm.prank(IERC173(receiver).owner());
        IStaticsFeeReceiver(receiver).proposeDistributor(position);
        integration.acceptGenesisDistributorRole();
        if (!IGenesisLaunchDistributor(predecessor).finalized()) {
            vm.prank(IERC173(predecessor).owner());
            IGenesisLaunchDistributor(predecessor).finalizeLaunchRewards();
        }
        vm.prank(IERC173(registry).owner());
        IGenesisActivationRegistry(registry).proposeConsumer(position);
        integration.acceptGenesisConsumerRole();
        assertTrue(core.historyCoverage(nft).ready);
        assertEq(IGenesisActivationRegistry(registry).activeConsumer(), position);
        address owner = IERC721(nft).ownerOf(3);
        vm.prank(owner);
        id = IStaticsPosition(position).createPosition(owner);
    }

    function approveModule(address consumer) external {
        core.setExternalModule(consumer, keccak256("statics.lottery.fiddy.account.v1"), true);
    }

    function _binding(string memory manifest, string memory key) private view returns (address target) {
        string memory base = string.concat(".contracts.", key);
        target = vm.parseJsonAddress(manifest, string.concat(base, ".address"));
        assertEq(target.codehash, vm.parseJsonBytes32(manifest, string.concat(base, ".runtimeCodeHash")));
    }
}
