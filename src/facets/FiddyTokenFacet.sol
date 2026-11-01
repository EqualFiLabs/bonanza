// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {
    ERC20Upgradeable
} from "openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import {
    IERC20Metadata
} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { LibFiddyStorage } from "../libraries/LibFiddyStorage.sol";
import { LibFiddyMovement } from "../libraries/LibFiddyMovement.sol";
import { LibFiddy } from "../libraries/LibFiddy.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibReentrancy } from "../libraries/LibReentrancy.sol";
import { LibLotteryStorage } from "../libraries/LibLotteryStorage.sol";
import { LibExactToken } from "../libraries/LibExactToken.sol";
import { FiddyBindings } from "../shared/FiddyTypes.sol";
import { FiddyErrors } from "../shared/FiddyErrors.sol";
import { Errors } from "../shared/Errors.sol";

contract FiddyTokenFacet is ERC20Upgradeable {
    event FiddyConsumerSet(address indexed consumer, bool allowed);
    event FiddyReserveFunded(address indexed funder, uint256 amount);
    event FiddyConversionsSet(bool wrapEnabled, bool unwrapEnabled, uint256 wrapCap);
    event FiddyDeposited(uint256 indexed positionId, address indexed sender, uint256 amount);
    event FiddyWithdrawn(uint256 indexed positionId, address indexed receiver, uint256 amount);
    event FiddyWrapped(uint256 indexed positionId, uint256 amount);
    event FiddyUnwrapped(uint256 indexed positionId, address indexed receiver, uint256 amount);

    constructor() {
        _disableInitializers();
    }
    modifier guarded() {
        LibReentrancy.enter();
        _;
        LibReentrancy.exit();
    }
    modifier onlyProtocol() {
        if (msg.sender != address(this)) revert FiddyErrors.OnlyProtocol();
        _;
    }

    function name() public pure override returns (string memory) {
        return "FIDDY";
    }

    function symbol() public pure override returns (string memory) {
        return "FIDDY";
    }

    function decimals() public view override returns (uint8) {
        return IERC20Metadata(LibFiddyStorage.state().underlying).decimals();
    }

    function initializeFiddy(
        address underlying_,
        address positionNFT_,
        address operators_,
        address registry_
    ) external guarded {
        LibDiamond.enforceAuthority();
        LibFiddy.initialize(FiddyBindings(underlying_, positionNFT_, operators_, registry_));
    }

    function setFiddyConsumer(address consumer, bool allowed) external {
        LibDiamond.enforceAuthority();
        if (consumer == address(0) || consumer == address(this)) revert Errors.InvalidAddress();
        LibFiddyStorage.state().consumers[consumer] = allowed;
        emit FiddyConsumerSet(consumer, allowed);
    }

    function isFiddyConsumer(address consumer) external view returns (bool) {
        return LibFiddyStorage.state().consumers[consumer];
    }

    function setFiddyConversions(bool wrap_, bool unwrap_, uint256 cap) external {
        LibDiamond.enforceAuthority();
        LibFiddy.enforceInitialized();
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        s.wrapEnabled = wrap_;
        s.unwrapEnabled = unwrap_;
        s.wrapCap = cap;
        emit FiddyConversionsSet(wrap_, unwrap_, cap);
    }

    function fundFiddyReserve(uint256 amount) external guarded {
        LibFiddy.enforceInitialized();
        _positive(amount);
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        s.inventory += amount;
        s.allocatedBacking += amount;
        LibExactToken.pullExact(s.underlying, msg.sender, amount);
        _mint(address(this), amount);
        emit FiddyReserveFunded(msg.sender, amount);
    }

    function depositFiddy(uint256 id, uint256 amount) external guarded {
        LibFiddy.enforceOwner(id);
        _positive(amount);
        LibFiddy.creditBalance(id, amount);
        _spendAllowance(msg.sender, address(this), amount);
        _move(msg.sender, address(this), amount);
        emit FiddyDeposited(id, msg.sender, amount);
    }

    /// @notice Withdraw unstaked account FIDDY to the PositionNFT owner, who is the caller.
    function withdrawFiddy(uint256 id, uint256 amount) external guarded {
        LibFiddy.enforceOwner(id);
        _positive(amount);
        LibFiddy.debitBalance(id, amount);
        _move(address(this), msg.sender, amount);
        emit FiddyWithdrawn(id, msg.sender, amount);
    }

    function wrapFiddy(uint256 id, uint256 amount) external guarded {
        LibFiddy.enforceOwner(id);
        _positive(amount);
        if (LibLotteryStorage.governanceStorage().paused) revert Errors.ProtocolPaused();
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        if (!s.wrapEnabled) revert FiddyErrors.ConversionDisabled();
        if (s.wrapOutstanding > s.wrapCap || amount > s.wrapCap - s.wrapOutstanding) {
            revert FiddyErrors.WrapCapacityExceeded();
        }
        s.wrapOutstanding += amount;
        s.allocatedBacking += amount;
        LibFiddy.creditBalance(id, amount);
        LibExactToken.pullExact(s.underlying, msg.sender, amount);
        _mint(address(this), amount);
        emit FiddyWrapped(id, amount);
    }

    function unwrapFiddy(uint256 id, uint256 amount, address receiver) external guarded {
        LibFiddy.enforceOwner(id);
        _positive(amount);
        _receiver(receiver);
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        if (!s.unwrapEnabled) revert FiddyErrors.ConversionDisabled();
        LibFiddy.debitBalance(id, amount);
        s.allocatedBacking -= amount;
        s.wrapOutstanding -= amount < s.wrapOutstanding ? amount : s.wrapOutstanding;
        _burn(address(this), amount);
        LibExactToken.pushExact(s.underlying, receiver, amount);
        emit FiddyUnwrapped(id, receiver, amount);
    }

    function protocolMoveFiddy(address from, address to, uint256 amount) external onlyProtocol {
        if (from != address(this)) _spendAllowance(from, address(this), amount);
        _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private {
        LibFiddyMovement.authorize(from, to, amount);
        _transfer(from, to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            if (
                !LibFiddyMovement.consume(from, to, amount)
                    && (from == address(this)
                        || to == address(this)
                        || (!LibFiddyStorage.state().consumers[from]
                            && !LibFiddyStorage.state().consumers[to]))
            ) {
                revert FiddyErrors.TransferRestricted();
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
