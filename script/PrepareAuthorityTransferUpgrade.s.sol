// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { IGovernance } from "../src/interfaces/IGovernance.sol";
import { GovernanceSelectors } from "../src/libraries/GovernanceSelectors.sol";
import { FacetCut, FacetCutAction } from "../src/shared/DiamondTypes.sol";
import { Errors } from "../src/shared/Errors.sol";

/// @notice Prepares calldata only. Deployment, verification and execution are separate operations.
contract PrepareAuthorityTransferUpgrade is Script {
    error UnexpectedGovernanceRoute(bytes4 selector, address expected, address actual);

    function run() external view returns (bytes memory) {
        return prepare(vm.envAddress("LOTTERY_DIAMOND"), vm.envAddress("LOTTERY_GOVERNANCE_FACET"));
    }

    function prepare(address diamond, address replacement) public view returns (bytes memory) {
        if (diamond.code.length == 0 || replacement.code.length == 0 || diamond == replacement) {
            revert Errors.InvalidAddress();
        }
        if (IGovernance(diamond).protocolFinalized()) revert Errors.CutsDisabled();
        bytes4[] memory previous = GovernanceSelectors.existing();
        bytes4[] memory added = GovernanceSelectors.handover();
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address current = loupe.facetAddress(previous[0]);
        if (current == address(0) || current == replacement) revert Errors.InvalidAddress();
        for (uint256 i; i < previous.length; ++i) {
            _expectRoute(loupe, previous[i], current);
        }
        for (uint256 i; i < added.length; ++i) {
            _expectRoute(loupe, added[i], address(0));
        }

        FacetCut[] memory cuts = new FacetCut[](2);
        cuts[0] = FacetCut(replacement, FacetCutAction.Replace, previous);
        cuts[1] = FacetCut(replacement, FacetCutAction.Add, added);
        return abi.encodeCall(IDiamondCut.diamondCut, (cuts, address(0), bytes("")));
    }

    function _expectRoute(IDiamondLoupe loupe, bytes4 selector, address expected) private view {
        address actual = loupe.facetAddress(selector);
        if (actual != expected) revert UnexpectedGovernanceRoute(selector, expected, actual);
    }
}
