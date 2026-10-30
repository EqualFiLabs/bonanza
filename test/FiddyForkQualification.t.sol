// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { FiddySetup } from "./utils/FiddySetup.sol";
import { IStaticsCandidate } from "./FiddyStaticsIntegration.t.sol";
import { IERC721 } from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import { IStaticsExternalModules } from "../src/interfaces/IStaticsExternalModules.sol";

contract FiddyForkQualificationTest is FiddySetup {
    uint256 internal positionId;
    IStaticsExternalModules internal core;
    IERC721 internal liveOperators;

    function setUp() public override {
        string memory rpc = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 101_439_372);
        uint256 timestamp = block.timestamp;
        super.setUp();
        vm.warp(timestamp);
    }

    function _initializeFiddy() internal override {
        IStaticsCandidate fixture = IStaticsCandidate(
            vm.deployCode("out-statics/StaticsForkCandidate.sol/StaticsForkCandidate.json")
        );
        (address position, address ops, address registry_, address underlying, uint256 id) =
            fixture.create();
        core = IStaticsExternalModules(position);
        liveOperators = IERC721(ops);
        positionId = id;
        fixture.approveModule(address(diamond));
        vm.prank(authority);
        fiddy.initializeFiddy(underlying, position, ops, registry_);
    }

    function testForkActualOperatorSaleRevokesRegistration() public {
        assertEq(block.number, 26_303_058); // L1 NUMBER at pinned L2 block 101439372
        vm.prank(authority);
        staking.setFiddyBoostsEnabled(true);
        address owner = liveOperators.ownerOf(3);
        vm.prank(owner);
        staking.registerFiddyOperator(positionId, 3);
        assertTrue(fiddyView.fiddyAccount(positionId).registered);
        assertEq(fiddyView.fiddyOperatorAccount(3), positionId);
        assertEq(core.externalLegCount(positionId), 1);
        vm.prank(owner);
        liveOperators.transferFrom(owner, alice, 3);
        staking.checkpointFiddyAccount(positionId);
        assertFalse(fiddyView.fiddyAccount(positionId).registered);
        assertEq(fiddyView.fiddyOperatorAccount(3), 0);
        vm.prank(owner);
        staking.cleanupFiddyAccount(positionId);
        assertEq(core.externalLegCount(positionId), 0);
    }
}
