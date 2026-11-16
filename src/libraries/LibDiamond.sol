// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IDiamondCut } from "../interfaces/IDiamondCut.sol";
import { Errors } from "../shared/Errors.sol";
import { FacetCut, FacetCutAction } from "../shared/DiamondTypes.sol";

library LibDiamond {
    bytes32 internal constant DIAMOND_STORAGE_SLOT =
        keccak256("statics.lottery.diamond.storage.v1");

    struct SelectorData {
        address facet;
        uint256 selectorPosition;
    }

    struct FacetData {
        bytes4[] selectors;
        uint256 facetPosition;
    }

    struct DiamondStorage {
        mapping(bytes4 => SelectorData) selectorData;
        mapping(address => FacetData) facetData;
        address[] facetAddresses;
        address authority;
        bool cutsDisabled;
        // Append-only: preserve the authority and finalization flag offsets.
        address pendingAuthority;
    }

    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 slot = DIAMOND_STORAGE_SLOT;
        assembly ("memory-safe") {
            ds.slot := slot
        }
    }

    function initializeAuthority(address authority_) internal {
        if (authority_ == address(0)) revert Errors.InvalidAddress();
        diamondStorage().authority = authority_;
    }

    function authority() internal view returns (address) {
        return diamondStorage().authority;
    }

    function enforceAuthority() internal view {
        if (msg.sender != diamondStorage().authority) revert Errors.NotAuthority(msg.sender);
    }

    function cutsDisabled() internal view returns (bool) {
        return diamondStorage().cutsDisabled;
    }

    function disableCuts() internal {
        DiamondStorage storage ds = diamondStorage();
        if (ds.cutsDisabled) revert Errors.AlreadyFinalized();
        ds.cutsDisabled = true;
    }

    function diamondCut(FacetCut[] memory cuts, address init, bytes memory data) internal {
        DiamondStorage storage ds = diamondStorage();

        for (uint256 i; i < cuts.length; ++i) {
            bytes4[] memory selectors = cuts[i].functionSelectors;
            if (selectors.length == 0) revert Errors.EmptySelectors();

            FacetCutAction action = cuts[i].action;
            if (action == FacetCutAction.Add) {
                _add(ds, cuts[i].facetAddress, selectors);
            } else if (action == FacetCutAction.Replace) {
                _replace(ds, cuts[i].facetAddress, selectors);
            } else if (action == FacetCutAction.Remove) {
                _remove(ds, cuts[i].facetAddress, selectors);
            } else {
                revert Errors.InvalidFacetAction(uint8(action));
            }
        }

        emit IDiamondCut.DiamondCut(cuts, init, data);
        _initialize(init, data);
    }

    function _add(DiamondStorage storage ds, address facet, bytes4[] memory selectors) private {
        _enforceHasCode(facet);
        FacetData storage facetData = ds.facetData[facet];

        if (facetData.selectors.length == 0) {
            facetData.facetPosition = ds.facetAddresses.length;
            ds.facetAddresses.push(facet);
        }

        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = selectors[i];
            if (ds.selectorData[selector].facet != address(0)) {
                revert Errors.SelectorAlreadyExists(selector);
            }
            ds.selectorData[selector] = SelectorData(facet, facetData.selectors.length);
            facetData.selectors.push(selector);
        }
    }

    function _replace(DiamondStorage storage ds, address facet, bytes4[] memory selectors) private {
        _enforceHasCode(facet);
        FacetData storage newFacetData = ds.facetData[facet];

        if (newFacetData.selectors.length == 0) {
            newFacetData.facetPosition = ds.facetAddresses.length;
            ds.facetAddresses.push(facet);
        }

        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = selectors[i];
            address oldFacet = ds.selectorData[selector].facet;
            if (oldFacet == address(0)) revert Errors.SelectorDoesNotExist(selector);
            if (oldFacet == facet) revert Errors.SelectorUnchanged(selector);

            _removeSelector(ds, oldFacet, selector);
            ds.selectorData[selector] = SelectorData(facet, newFacetData.selectors.length);
            newFacetData.selectors.push(selector);
        }
    }

    function _remove(DiamondStorage storage ds, address facet, bytes4[] memory selectors) private {
        if (facet != address(0)) revert Errors.InvalidAddress();

        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = selectors[i];
            address oldFacet = ds.selectorData[selector].facet;
            if (oldFacet == address(0)) revert Errors.SelectorDoesNotExist(selector);

            _removeSelector(ds, oldFacet, selector);
            delete ds.selectorData[selector];
        }
    }

    function _removeSelector(DiamondStorage storage ds, address facet, bytes4 selector) private {
        FacetData storage facetData = ds.facetData[facet];
        uint256 position = ds.selectorData[selector].selectorPosition;
        uint256 lastPosition = facetData.selectors.length - 1;

        if (position != lastPosition) {
            bytes4 movedSelector = facetData.selectors[lastPosition];
            facetData.selectors[position] = movedSelector;
            ds.selectorData[movedSelector].selectorPosition = position;
        }
        facetData.selectors.pop();

        if (facetData.selectors.length != 0) return;

        uint256 facetPosition = facetData.facetPosition;
        uint256 lastFacetPosition = ds.facetAddresses.length - 1;
        if (facetPosition != lastFacetPosition) {
            address movedFacet = ds.facetAddresses[lastFacetPosition];
            ds.facetAddresses[facetPosition] = movedFacet;
            ds.facetData[movedFacet].facetPosition = facetPosition;
        }
        ds.facetAddresses.pop();
        delete ds.facetData[facet];
    }

    function _initialize(address init, bytes memory data) private {
        if (init == address(0)) {
            if (data.length != 0) revert Errors.UnexpectedInitializationData();
            return;
        }
        if (data.length == 0) revert Errors.EmptyInitializationData();

        _enforceHasCode(init);
        (bool success, bytes memory reason) = init.delegatecall(data);
        if (!success) revert Errors.InitializationFailed(reason);
    }

    function _enforceHasCode(address target) private view {
        if (target.code.length == 0) revert Errors.NoCode(target);
    }
}
