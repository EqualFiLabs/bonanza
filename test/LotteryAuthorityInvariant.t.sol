// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { StaticsLotteryDiamond } from "../src/StaticsLotteryDiamond.sol";
import { DiamondCutFacet } from "../src/facets/DiamondCutFacet.sol";
import { GovernanceFacet } from "../src/facets/GovernanceFacet.sol";
import { IGovernance } from "../src/interfaces/IGovernance.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { GovernanceSelectors } from "../src/libraries/GovernanceSelectors.sol";
import { Errors } from "../src/shared/Errors.sol";
import { FacetCut, FacetCutAction } from "../src/shared/DiamondTypes.sol";

contract AuthorityTransferHandler is Test {
    IGovernance public immutable governance;
    address public current;
    address public pending;
    bool public finalized;
    uint256 public acceptances;
    address[4] private actors;

    constructor(IGovernance governance_, address initial) {
        governance = governance_;
        current = initial;
        actors = [initial, makeAddr("nominee-a"), makeAddr("nominee-b"), makeAddr("nominee-c")];
    }

    function nominate(uint256 seed) external {
        address next = actors[seed % actors.length];
        vm.prank(current);
        governance.nominateAuthority(next);
        pending = next;
    }

    function cancel() external {
        if (pending == address(0)) vm.expectRevert(Errors.NoPendingAuthority.selector);
        vm.prank(current);
        governance.cancelAuthorityTransfer();
        pending = address(0);
    }

    function accept(uint256 seed) external {
        address caller = actors[seed % actors.length];
        bool valid = caller == pending;
        if (!valid) {
            vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingAuthority.selector, caller));
        }
        vm.prank(caller);
        governance.acceptAuthority();
        if (valid) {
            current = caller;
            pending = address(0);
            ++acceptances;
        }
    }

    function finalize() external {
        if (finalized) vm.expectRevert(Errors.AlreadyFinalized.selector);
        vm.prank(current);
        governance.finalizeProtocol();
        finalized = true;
    }

    function administer(uint256 seed) external {
        address caller = actors[seed % actors.length];
        if (caller != current) {
            vm.expectRevert(abi.encodeWithSelector(Errors.NotAuthority.selector, caller));
        }
        vm.prank(caller);
        governance.setMaxActiveRounds(uint16(seed % 100));
    }

    function attemptCut() external {
        FacetCut[] memory empty = new FacetCut[](0);
        if (finalized) vm.expectRevert(Errors.CutsDisabled.selector);
        vm.prank(current);
        IDiamondCut(address(governance)).diamondCut(empty, address(0), "");
    }
}

contract LotteryAuthorityInvariantTest is StdInvariant, Test {
    IGovernance internal governance;
    AuthorityTransferHandler internal handler;

    function setUp() public {
        address initial = makeAddr("bootstrap");
        StaticsLotteryDiamond diamond =
            new StaticsLotteryDiamond(initial, address(new DiamondCutFacet()));
        FacetCut[] memory cuts = new FacetCut[](1);
        cuts[0] =
            FacetCut(address(new GovernanceFacet()), FacetCutAction.Add, GovernanceSelectors.all());
        vm.prank(initial);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
        governance = IGovernance(address(diamond));
        handler = new AuthorityTransferHandler(governance, initial);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.nominate.selector;
        selectors[1] = handler.cancel.selector;
        selectors[2] = handler.accept.selector;
        selectors[3] = handler.finalize.selector;
        selectors[4] = handler.administer.selector;
        selectors[5] = handler.attemptCut.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantAuthorityAndPendingMatchModel() public view {
        assertEq(governance.authority(), handler.current());
        assertEq(governance.pendingAuthority(), handler.pending());
        assertTrue(governance.authority() != address(0));
        assertTrue(governance.authority() != address(governance));
        assertEq(governance.protocolFinalized(), handler.finalized());
    }

    function testPostFinalizationSequenceHasSuccessfulHandover() public {
        handler.finalize();
        handler.nominate(1);
        handler.accept(1);
        handler.nominate(2);
        handler.cancel();
        handler.accept(2);
        handler.nominate(3);
        handler.accept(3);
        handler.attemptCut();
        assertEq(handler.acceptances(), 2);
        invariantAuthorityAndPendingMatchModel();
    }
}
