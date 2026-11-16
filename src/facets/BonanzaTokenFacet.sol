// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {
    ERC20Upgradeable
} from "openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import {
    IERC20Metadata
} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { LibBonanzaStorage } from "../libraries/LibBonanzaStorage.sol";
import { LibBonanzaMovement } from "../libraries/LibBonanzaMovement.sol";
import { LibBonanza } from "../libraries/LibBonanza.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibReentrancy } from "../libraries/LibReentrancy.sol";
import { LibLotteryStorage } from "../libraries/LibLotteryStorage.sol";
import { LibExactToken } from "../libraries/LibExactToken.sol";
import { BonanzaBindings } from "../shared/BonanzaTypes.sol";
import { BonanzaErrors } from "../shared/BonanzaErrors.sol";
import { Errors } from "../shared/Errors.sol";

contract BonanzaTokenFacet is ERC20Upgradeable {
    event BonanzaConsumerSet(address indexed consumer, bool allowed);
    event BonanzaReserveFunded(address indexed funder, uint256 amount);
    event BonanzaConversionsSet(bool wrapEnabled, bool unwrapEnabled, uint256 wrapCap);
    event BonanzaDeposited(uint256 indexed positionId, address indexed sender, uint256 amount);
    event BonanzaWithdrawn(uint256 indexed positionId, address indexed receiver, uint256 amount);
    event BonanzaWrapped(uint256 indexed positionId, uint256 amount);
    event BonanzaUnwrapped(uint256 indexed positionId, address indexed receiver, uint256 amount);

    constructor() {
        _disableInitializers();
    }
    modifier guarded() {
        LibReentrancy.enter();
        _;
        LibReentrancy.exit();
    }
    modifier onlyProtocol() {
        if (msg.sender != address(this)) revert BonanzaErrors.OnlyProtocol();
        _;
    }

    function name() public pure override returns (string memory) {
        return "Bonanza";
    }

    function symbol() public pure override returns (string memory) {
        return "BONANZA";
    }

    function decimals() public view override returns (uint8) {
        return IERC20Metadata(LibBonanzaStorage.state().underlying).decimals();
    }

    function initializeBonanza(
        address underlying_,
        address positionNFT_,
        address operators_,
        address registry_
    ) external guarded {
        LibDiamond.enforceAuthority();
        LibBonanza.initialize(BonanzaBindings(underlying_, positionNFT_, operators_, registry_));
    }

    function setBonanzaConsumer(address consumer, bool allowed) external {
        LibDiamond.enforceAuthority();
        if (consumer == address(0) || consumer == address(this)) revert Errors.InvalidAddress();
        LibBonanzaStorage.state().consumers[consumer] = allowed;
        emit BonanzaConsumerSet(consumer, allowed);
    }

    function isBonanzaConsumer(address consumer) external view returns (bool) {
        return LibBonanzaStorage.state().consumers[consumer];
    }

    function setBonanzaConversions(bool wrap_, bool unwrap_, uint256 cap) external {
        LibDiamond.enforceAuthority();
        LibBonanza.enforceInitialized();
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        s.wrapEnabled = wrap_;
        s.unwrapEnabled = unwrap_;
        s.wrapCap = cap;
        emit BonanzaConversionsSet(wrap_, unwrap_, cap);
    }

    function fundBonanzaReserve(uint256 amount) external guarded {
        LibBonanza.enforceInitialized();
        _positive(amount);
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        s.inventory += amount;
        s.allocatedBacking += amount;
        LibExactToken.pullExact(s.underlying, msg.sender, amount);
        _mint(address(this), amount);
        emit BonanzaReserveFunded(msg.sender, amount);
    }

    function depositBonanza(uint256 id, uint256 amount) external guarded {
        LibBonanza.enforceOwner(id);
        _positive(amount);
        LibBonanza.creditBalance(id, amount);
        _spendAllowance(msg.sender, address(this), amount);
        _move(msg.sender, address(this), amount);
        emit BonanzaDeposited(id, msg.sender, amount);
    }

    /// @notice Withdraw unstaked account BONANZA to the PositionNFT owner, who is the caller.
    function withdrawBonanza(uint256 id, uint256 amount) external guarded {
        LibBonanza.enforceOwner(id);
        _positive(amount);
        LibBonanza.debitBalance(id, amount);
        _move(address(this), msg.sender, amount);
        emit BonanzaWithdrawn(id, msg.sender, amount);
    }

    function wrapBonanza(uint256 id, uint256 amount) external guarded {
        LibBonanza.enforceOwner(id);
        _positive(amount);
        if (LibLotteryStorage.governanceStorage().paused) revert Errors.ProtocolPaused();
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        if (!s.wrapEnabled) revert BonanzaErrors.ConversionDisabled();
        if (s.wrapOutstanding > s.wrapCap || amount > s.wrapCap - s.wrapOutstanding) {
            revert BonanzaErrors.WrapCapacityExceeded();
        }
        s.wrapOutstanding += amount;
        s.allocatedBacking += amount;
        LibBonanza.creditBalance(id, amount);
        LibExactToken.pullExact(s.underlying, msg.sender, amount);
        _mint(address(this), amount);
        emit BonanzaWrapped(id, amount);
    }

    function unwrapBonanza(uint256 id, uint256 amount, address receiver) external guarded {
        LibBonanza.enforceOwner(id);
        _positive(amount);
        _receiver(receiver);
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        if (!s.unwrapEnabled) revert BonanzaErrors.ConversionDisabled();
        LibBonanza.debitBalance(id, amount);
        s.allocatedBacking -= amount;
        s.wrapOutstanding -= amount < s.wrapOutstanding ? amount : s.wrapOutstanding;
        _burn(address(this), amount);
        LibExactToken.pushExact(s.underlying, receiver, amount);
        emit BonanzaUnwrapped(id, receiver, amount);
    }

    function protocolMoveBonanza(address from, address to, uint256 amount) external onlyProtocol {
        if (from != address(this)) _spendAllowance(from, address(this), amount);
        _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private {
        LibBonanzaMovement.authorize(from, to, amount);
        _transfer(from, to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            if (
                !LibBonanzaMovement.consume(from, to, amount)
                    && (from == address(this)
                        || to == address(this)
                        || (!LibBonanzaStorage.state().consumers[from]
                            && !LibBonanzaStorage.state().consumers[to]))
            ) {
                revert BonanzaErrors.TransferRestricted();
            }
        }
        super._update(from, to, amount);
    }

    function _positive(uint256 amount) private pure {
        if (amount == 0) revert Errors.ZeroAmount();
    }

    function _receiver(address receiver) private view {
        if (receiver == address(0) || receiver == address(this)) revert Errors.InvalidAddress();
    }
}
