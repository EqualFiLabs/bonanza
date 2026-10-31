// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IERC721 } from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import { IFiddyActivation } from "../interfaces/IFiddyProtocol.sol";
import { IStaticsExternalModules } from "../interfaces/IStaticsExternalModules.sol";
import { LibFiddyStorage } from "./LibFiddyStorage.sol";
import { FiddyBindings, FiddyConfig, FiddyAccount } from "../shared/FiddyTypes.sol";
import { FiddyErrors } from "../shared/FiddyErrors.sol";

library LibFiddy {
    bytes32 internal constant MODULE = keccak256("statics.lottery.fiddy.account.v1");
    event FiddyParticipation(
        uint256 indexed roundId,
        uint256 indexed positionId,
        uint256 requested,
        uint256 issued,
        uint256 shortfall
    );
    event FiddyAccountAttached(uint256 indexed positionId);
    event FiddyInitialized(
        address underlying, address positionNFT, address operators, address registry
    );

    /// @dev One-time binding. Callers enforce Diamond authority.
    function initialize(FiddyBindings memory bindings) internal {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        if (s.underlying != address(0)) revert FiddyErrors.AlreadyInitialized();
        if (
            bindings.underlying.code.length == 0 || bindings.positionNFT.code.length == 0
                || bindings.operators.code.length == 0 || bindings.registry.code.length == 0
                || bindings.underlying == address(this)
                || IFiddyActivation(bindings.registry).genesisCollection() != bindings.operators
                || !IStaticsExternalModules(bindings.positionNFT)
                    .supportsInterface(type(IStaticsExternalModules).interfaceId)
        ) revert FiddyErrors.InvalidBinding();
        s.underlying = bindings.underlying;
        s.positionNFT = bindings.positionNFT;
        s.operators = bindings.operators;
        s.registry = bindings.registry;
        emit FiddyInitialized(
            bindings.underlying, bindings.positionNFT, bindings.operators, bindings.registry
        );
    }

    function enforceInitialized() internal view {
        if (LibFiddyStorage.state().underlying == address(0)) revert FiddyErrors.NotInitialized();
    }

    function enforceOwner(uint256 id) internal view {
        enforceInitialized();
        if (IERC721(LibFiddyStorage.state().positionNFT).ownerOf(id) != msg.sender) {
            revert FiddyErrors.NotPositionOwner();
        }
    }

    function attach(uint256 id) internal {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        if (!s.accounts[id].attached) {
            s.accounts[id].attached = true;
            IStaticsExternalModules(s.positionNFT).attachExternalAccountLeg(id, MODULE, bytes32(id));
            emit FiddyAccountAttached(id);
        }
    }

    /// @dev Third-party checkpoints that only book revenue must not call this, or anyone could
    /// cancel orders conditioned on the nonce.
    function touch(uint256 id) internal {
        ++LibFiddyStorage.state().accounts[id].nonce;
    }

    function creditBalance(uint256 id, uint256 amount) internal {
        attach(id);
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        s.accounts[id].balance += amount;
        s.custodyTotal += amount;
        touch(id);
    }

    function debitBalance(uint256 id, uint256 amount) internal {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        FiddyAccount storage a = s.accounts[id];
        if (amount > a.balance - a.staked) revert FiddyErrors.InsufficientFiddy();
        a.balance -= amount;
        s.custodyTotal -= amount;
        touch(id);
    }

    function issue(uint256 roundId, uint256 id, uint256 quantity) internal {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        FiddyConfig storage config = s.rounds[roundId];
        if (!config.participation) return;
        if (id == 0) revert FiddyErrors.PositionRequired();
        enforceOwner(id);
        uint256 requested = uint256(config.unitsPerTicket) * quantity;
        uint256 issued = requested < s.inventory ? requested : s.inventory;
        if (issued != 0) {
            creditBalance(id, issued);
            s.inventory -= issued;
        }
        emit FiddyParticipation(roundId, id, requested, issued, requested - issued);
    }

    function extraReserved(address asset) internal view returns (uint256 amount) {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        amount = s.assets[asset].reserved;
        if (asset == s.underlying) amount += s.allocatedBacking;
        if (asset == address(this)) amount += s.inventory + s.custodyTotal;
    }
}
