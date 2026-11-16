// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IERC721 } from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import { IBonanzaActivation } from "../interfaces/IBonanzaProtocol.sol";
import { IStaticsExternalModules } from "../interfaces/IStaticsExternalModules.sol";
import { LibBonanzaStorage } from "./LibBonanzaStorage.sol";
import { BonanzaBindings, BonanzaConfig, BonanzaAccount } from "../shared/BonanzaTypes.sol";
import { BonanzaErrors } from "../shared/BonanzaErrors.sol";

library LibBonanza {
    bytes32 internal constant MODULE = keccak256("statics.lottery.fiddy.account.v1");
    event BonanzaParticipation(
        uint256 indexed roundId,
        uint256 indexed positionId,
        uint256 requested,
        uint256 issued,
        uint256 shortfall
    );
    event BonanzaAccountAttached(uint256 indexed positionId);
    event BonanzaInitialized(
        address underlying, address positionNFT, address operators, address registry
    );

    /// @dev One-time binding. Callers enforce Diamond authority.
    function initialize(BonanzaBindings memory bindings) internal {
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        if (s.underlying != address(0)) revert BonanzaErrors.AlreadyInitialized();
        if (
            bindings.underlying.code.length == 0 || bindings.positionNFT.code.length == 0
                || bindings.operators.code.length == 0 || bindings.registry.code.length == 0
                || bindings.underlying == address(this)
                || IBonanzaActivation(bindings.registry).genesisCollection() != bindings.operators
                || !IStaticsExternalModules(bindings.positionNFT)
                    .supportsInterface(type(IStaticsExternalModules).interfaceId)
        ) revert BonanzaErrors.InvalidBinding();
        s.underlying = bindings.underlying;
        s.positionNFT = bindings.positionNFT;
        s.operators = bindings.operators;
        s.registry = bindings.registry;
        emit BonanzaInitialized(
            bindings.underlying, bindings.positionNFT, bindings.operators, bindings.registry
        );
    }

    function enforceInitialized() internal view {
        if (LibBonanzaStorage.state().underlying == address(0)) {
            revert BonanzaErrors.NotInitialized();
        }
    }

    function enforceOwner(uint256 id) internal view {
        enforceInitialized();
        if (IERC721(LibBonanzaStorage.state().positionNFT).ownerOf(id) != msg.sender) {
            revert BonanzaErrors.NotPositionOwner();
        }
    }

    function attach(uint256 id) internal {
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        if (!s.accounts[id].attached) {
            s.accounts[id].attached = true;
            IStaticsExternalModules(s.positionNFT).attachExternalAccountLeg(id, MODULE, bytes32(id));
            emit BonanzaAccountAttached(id);
        }
    }

    /// @dev Third-party checkpoints that only book revenue must not call this, or anyone could
    /// cancel orders conditioned on the nonce.
    function touch(uint256 id) internal {
        ++LibBonanzaStorage.state().accounts[id].nonce;
    }

    function creditBalance(uint256 id, uint256 amount) internal {
        attach(id);
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        s.accounts[id].balance += amount;
        s.custodyTotal += amount;
        touch(id);
    }

    function debitBalance(uint256 id, uint256 amount) internal {
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        BonanzaAccount storage a = s.accounts[id];
        if (amount > a.balance - a.staked) revert BonanzaErrors.InsufficientBonanza();
        a.balance -= amount;
        s.custodyTotal -= amount;
        touch(id);
    }

    function issue(uint256 roundId, uint256 id, uint256 quantity) internal {
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        BonanzaConfig storage config = s.rounds[roundId];
        if (!config.participation) return;
        if (id == 0) revert BonanzaErrors.PositionRequired();
        enforceOwner(id);
        uint256 requested = uint256(config.unitsPerTicket) * quantity;
        uint256 issued = requested < s.inventory ? requested : s.inventory;
        if (issued != 0) {
            creditBalance(id, issued);
            s.inventory -= issued;
        }
        emit BonanzaParticipation(roundId, id, requested, issued, requested - issued);
    }

    function extraReserved(address asset) internal view returns (uint256 amount) {
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        amount = s.assets[asset].reserved;
        if (asset == s.underlying) amount += s.allocatedBacking;
        if (asset == address(this)) amount += s.inventory + s.custodyTotal;
    }
}
