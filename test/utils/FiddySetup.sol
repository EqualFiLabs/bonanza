// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { ERC721 } from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import { IStaticsExternalModules } from "../../src/interfaces/IStaticsExternalModules.sol";
import { FiddyStakingFacet } from "../../src/facets/FiddyStakingFacet.sol";
import { FiddyTokenFacet } from "../../src/facets/FiddyTokenFacet.sol";
import { FiddyViewFacet } from "../../src/facets/FiddyViewFacet.sol";
import { FiddySelectors } from "../../src/libraries/FiddySelectors.sol";
import { LotteryFacet } from "../../src/facets/LotteryFacet.sol";
import { GovernanceFacet } from "../../src/facets/GovernanceFacet.sol";
import { ILottery } from "../../src/interfaces/ILottery.sol";
import { IGovernance } from "../../src/interfaces/IGovernance.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { FacetCut } from "../../src/shared/DiamondTypes.sol";
import { LotteryIntegrationSetup } from "./LotteryIntegrationSetup.sol";

contract FiddyPositions is ERC721 {
    uint256 public transferHead;
    bool public ready = true;
    bool public rejectAttach;
    mapping(uint256 => uint256) public legs;
    mapping(address => bool) public module;
    mapping(uint256 => mapping(address => bool)) public attached;
    mapping(uint256 => IStaticsExternalModules.TransferChange) internal changes;
    mapping(address => mapping(uint256 => IStaticsExternalModules.TransferState)) internal states;
    constructor() ERC721("Positions", "PNFT") { }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setModule(address who) external {
        module[who] = true;
    }

    function setReady(bool value) external {
        ready = value;
    }

    function setRejectAttach(bool value) external {
        rejectAttach = value;
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IStaticsExternalModules).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function attachExternalAccountLeg(uint256 id, bytes32, bytes32) external returns (bytes32) {
        require(module[msg.sender] && !rejectAttach && !attached[id][msg.sender]);
        ownerOf(id);
        attached[id][msg.sender] = true;
        ++legs[id];
        return bytes32(id);
    }

    function detachExternalAccountLeg(uint256 id, bytes32, bytes32) external {
        require(attached[id][msg.sender]);
        attached[id][msg.sender] = false;
        --legs[id];
    }

    function close(uint256 id) external {
        require(ownerOf(id) == msg.sender && legs[id] == 0);
        _burn(id);
    }

    function record(address collection, uint256 id) public {
        // Unit fixture only: actual-source integration authenticates the registry path.
        IStaticsExternalModules.TransferState storage state = states[collection][id];
        ++state.nonce;
        state.transferredAt = uint64(block.timestamp);
        state.lastSequence = ++transferHead;
        changes[transferHead] = IStaticsExternalModules.TransferChange(
            collection, state.nonce, state.transferredAt, id
        );
    }

    function transferState(address collection, uint256 id)
        external
        view
        returns (IStaticsExternalModules.TransferState memory)
    {
        return states[collection][id];
    }

    function historyCoverage(address)
        external
        view
        returns (IStaticsExternalModules.HistoryCoverage memory)
    {
        return IStaticsExternalModules.HistoryCoverage(0, 0, ready);
    }

    function transferChanges(uint256 afterSequence, uint256 limit)
        external
        view
        returns (IStaticsExternalModules.TransferChange[] memory result, uint256 next)
    {
        next = afterSequence + limit;
        if (next > transferHead) next = transferHead;
        result = new IStaticsExternalModules.TransferChange[](next - afterSequence);
        for (uint256 i; afterSequence < next; ++i) {
            result[i] = changes[++afterSequence];
        }
    }

    function _update(address to, uint256 id, address auth)
        internal
        override
        returns (address from)
    {
        from = super._update(to, id, auth);
        if (from != address(0) && to != address(0) && from != to) record(address(this), id);
    }
}

contract FiddyOperators is ERC721 {
    FiddyPositions public core;
    mapping(uint256 => uint16) public multiplierBps;
    address public activeConsumer;

    constructor(FiddyPositions core_) ERC721("Operators", "OP") {
        core = core_;
        activeConsumer = address(core_);
    }

    function genesisCollection() external view returns (address) {
        return address(this);
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
        multiplierBps[id] = 10_000;
    }

    function activate(uint256 id, uint16 multiplier) external {
        require(ownerOf(id) == msg.sender);
        multiplierBps[id] = multiplier;
    }

    function setConsumer(address consumer) external {
        activeConsumer = consumer;
    }

    function _update(address to, uint256 id, address auth)
        internal
        override
        returns (address from)
    {
        from = super._update(to, id, auth);
        if (from != address(0) && to != address(0) && from != to) {
            multiplierBps[id] = 10_000;
            core.record(address(this), id);
        }
    }
}

abstract contract FiddySetup is LotteryIntegrationSetup {
    FiddyPositions internal positions;
    FiddyOperators internal operators;
    FiddyStakingFacet internal staking;
    FiddyTokenFacet internal fiddy;
    FiddyViewFacet internal fiddyView;

    function setUp() public virtual override {
        super.setUp();
        positions = new FiddyPositions();
        operators = new FiddyOperators(positions);
        positions.mint(alice, 1);
        positions.mint(bob, 2);
        operators.mint(alice, 1);
        operators.mint(bob, 2);
        FacetCut[] memory cuts = new FacetCut[](5);
        cuts[0] = _cut(address(new FiddyTokenFacet()), FiddySelectors.token());
        cuts[1] = _cut(address(new FiddyViewFacet()), FiddySelectors.views());
        bytes4[] memory purchaseSelectors = new bytes4[](2);
        purchaseSelectors[0] = ILottery.openRoundForPosition.selector;
        purchaseSelectors[1] = ILottery.buyTicketsForPosition.selector;
        cuts[2] = _cut(address(new LotteryFacet()), purchaseSelectors);
        bytes4[] memory configSelectors = new bytes4[](1);
        configSelectors[0] = IGovernance.createRewardLotteryConfig.selector;
        cuts[3] = _cut(address(new GovernanceFacet()), configSelectors);
        cuts[4] = _cut(address(new FiddyStakingFacet()), FiddySelectors.staking());
        vm.prank(authority);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
        staking = FiddyStakingFacet(address(diamond));
        fiddy = FiddyTokenFacet(address(diamond));
        fiddyView = FiddyViewFacet(address(diamond));
        positions.setModule(address(diamond));
        _initializeFiddy();
        vm.prank(alice);
        tokenA.approve(address(diamond), type(uint256).max);
    }

    function _initializeFiddy() internal virtual {
        vm.prank(authority);
        fiddy.initializeFiddy(
            address(tokenA), address(positions), address(operators), address(operators)
        );
    }

    function _wrap(uint256 id, address owner, uint256 amount) internal {
        vm.prank(authority);
        fiddy.setFiddyConversions(true, false, type(uint128).max);
        vm.prank(owner);
        fiddy.wrapFiddy(id, amount);
    }
}
