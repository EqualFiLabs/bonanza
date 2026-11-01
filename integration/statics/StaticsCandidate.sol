// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {GenesisPositionIntegrationTest} from "pinned-statics/test/genesis/GenesisPositionIntegration.t.sol";
import {ExternalModuleFacet} from "pinned-statics/src/facets/ExternalModuleFacet.sol";
import {StaticsSelectors} from "pinned-statics/src/libraries/StaticsSelectors.sol";
import {IDiamondCut} from "pinned-statics/src/interfaces/IDiamondCut.sol";
import {IStaticsExternalModules} from "pinned-statics/src/interfaces/IStaticsExternalModules.sol";

/// @notice Actual pinned Statics contracts compiled with their own compiler policy.
/// Test-only creation fixture; launch funding uses the upstream local fixture.
contract StaticsCandidate is GenesisPositionIntegrationTest {
    function _installDefaultLiquidityManager() internal pure override returns (bool) {
        return false;
    }

    function _deployPoolManager() internal override returns (IPoolManager) {
        return IPoolManager(deployCode("out-statics/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
    }

    function create()
        external
        returns (address core, address operators, address registry, address statics, uint256 id)
    {
        setUp();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            address(new ExternalModuleFacet()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.externalModules()
        );
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
        id = _createPosition(alice);
        _buyGenesis(alice, 1);
        _activate(alice, 1, 4);
        stakingAsset.mint(alice, 200 ether);
        return (address(diamond), address(genesis), address(activationRegistry), address(stakingAsset), id);
    }

    function approveModule(address consumer) external {
        IStaticsExternalModules(address(diamond))
            .setExternalModule(consumer, keccak256("statics.lottery.fiddy.account.v1"), true);
    }
}
