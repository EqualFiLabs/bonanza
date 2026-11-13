// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { ERC721 } from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import { IStaticsExternalModules } from "../../src/interfaces/IStaticsExternalModules.sol";
import { BonanzaStakingFacet } from "../../src/facets/BonanzaStakingFacet.sol";
import { BonanzaTokenFacet } from "../../src/facets/BonanzaTokenFacet.sol";
import { BonanzaViewFacet } from "../../src/facets/BonanzaViewFacet.sol";
import { BonanzaSelectors } from "../../src/libraries/BonanzaSelectors.sol";
import { LotteryFacet } from "../../src/facets/LotteryFacet.sol";
import { GovernanceFacet } from "../../src/facets/GovernanceFacet.sol";
import { ILottery } from "../../src/interfaces/ILottery.sol";
import { IGovernance } from "../../src/interfaces/IGovernance.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { FacetCut } from "../../src/shared/DiamondTypes.sol";
import { LotteryIntegrationSetup } from "./LotteryIntegrationSetup.sol";

contract BonanzaPositions is ERC721 {
    bool public rejectAttach;
    mapping(uint256 => uint256) public legs;
    mapping(address => bool) public module;
    mapping(uint256 => mapping(address => bool)) public attached;
    constructor() ERC721("Positions", "PNFT") { }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setModule(address who) external {
        module[who] = true;
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
}

contract BonanzaOperators is ERC721 {
    BonanzaPositions public core;
    mapping(uint256 => uint16) public multiplierBps;
    address public activeConsumer;

    constructor(BonanzaPositions core_) ERC721("Operators", "OP") {
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
        }
    }
}

abstract contract BonanzaSetup is LotteryIntegrationSetup {
    BonanzaPositions internal positions;
    BonanzaOperators internal operators;
    BonanzaStakingFacet internal staking;
    BonanzaTokenFacet internal bonanza;
    BonanzaViewFacet internal bonanzaView;

    function setUp() public virtual override {
        super.setUp();
        positions = new BonanzaPositions();
        operators = new BonanzaOperators(positions);
        positions.mint(alice, 1);
        positions.mint(bob, 2);
        operators.mint(alice, 1);
        operators.mint(bob, 2);
        FacetCut[] memory cuts = new FacetCut[](5);
        cuts[0] = _cut(address(new BonanzaTokenFacet()), BonanzaSelectors.token());
        cuts[1] = _cut(address(new BonanzaViewFacet()), BonanzaSelectors.views());
        bytes4[] memory purchaseSelectors = new bytes4[](2);
        purchaseSelectors[0] = ILottery.openRoundForPosition.selector;
        purchaseSelectors[1] = ILottery.buyTicketsForPosition.selector;
        cuts[2] = _cut(address(new LotteryFacet()), purchaseSelectors);
        bytes4[] memory configSelectors = new bytes4[](1);
        configSelectors[0] = IGovernance.createRewardLotteryConfig.selector;
        cuts[3] = _cut(address(new GovernanceFacet()), configSelectors);
        cuts[4] = _cut(address(new BonanzaStakingFacet()), BonanzaSelectors.staking());
        vm.prank(authority);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
        staking = BonanzaStakingFacet(address(diamond));
        bonanza = BonanzaTokenFacet(address(diamond));
        bonanzaView = BonanzaViewFacet(address(diamond));
        positions.setModule(address(diamond));
        _initializeBonanza();
        vm.prank(alice);
        tokenA.approve(address(diamond), type(uint256).max);
    }

    function _initializeBonanza() internal virtual {
        vm.prank(authority);
        bonanza.initializeBonanza(
            address(tokenA), address(positions), address(operators), address(operators)
        );
    }

    function _wrap(uint256 id, address owner, uint256 amount) internal {
        vm.prank(authority);
        bonanza.setBonanzaConversions(true, false, type(uint128).max);
        vm.prank(owner);
        bonanza.wrapBonanza(id, amount);
    }
}
