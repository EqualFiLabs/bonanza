// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { BonanzaRevenueSetup } from "./BonanzaStaking.t.sol";
import { IntegrationToken } from "./utils/LotteryIntegrationSetup.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract HostileBonanzaPayment is ERC20 {
    uint256 public mode;
    address public target;
    bytes public callback;
    bool public blocked;
    constructor() ERC20("Hostile", "HOST") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(uint256 mode_, address target_, bytes calldata callback_) external {
        mode = mode_;
        target = target_;
        callback = callback_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (mode == 3 && to == target) revert("recipient blocked");
        super._update(from, to, amount);
        if (from != address(0) && to != address(0)) {
            if (mode == 1 && amount > 0) super._update(to, address(0), 1);
            if (mode == 2) {
                (bool ok,) = target.call(callback);
                blocked = !ok;
            }
        }
    }
}

contract BonanzaAdversarialTest is BonanzaRevenueSetup {
    function testClaimFailuresRollbackAndReentrancyCannotDoubleSpend() public {
        _start();
        HostileBonanzaPayment asset = new HostileBonanzaPayment();
        asset.mint(alice, 10_000);
        router.setAsset(address(asset), true, true);
        vm.prank(alice);
        asset.approve(address(diamond), type(uint256).max);
        _settle(address(asset), false);
        (uint256 earned,) = staking.indexedBonanzaRevenue(1, address(asset));
        uint256 reserved = bonanzaView.bonanzaAsset(address(asset)).reserved;
        for (uint256 mode = 1; mode <= 3; mode += 2) {
            asset.configure(mode, alice, "");
            vm.prank(alice);
            vm.expectRevert();
            staking.claimBonanzaRevenue(1, address(asset), alice);
            (uint256 unchanged,) = staking.indexedBonanzaRevenue(1, address(asset));
            assertEq(unchanged, earned);
            assertEq(bonanzaView.bonanzaAsset(address(asset)).reserved, reserved);
        }
        asset.configure(
            2,
            address(diamond),
            abi.encodeCall(staking.claimBonanzaRevenue, (1, address(asset), alice))
        );
        vm.prank(alice);
        assertEq(staking.claimBonanzaRevenue(1, address(asset), alice), earned);
        assertTrue(asset.blocked());
        vm.prank(alice);
        assertEq(staking.claimBonanzaRevenue(1, address(asset), alice), 0);
    }

    function testLateEntrantCannotClaimPastRevenue() public {
        _wrap(1, alice, 100);
        _wrap(2, bob, 100);
        vm.prank(alice);
        staking.stakeBonanza(1, 100);
        _settle(address(tokenB), false);
        vm.prank(bob);
        staking.stakeBonanza(2, 100);
        (uint256 past,) = staking.indexedBonanzaRevenue(2, address(tokenB));
        assertEq(past, 0);
        vm.prank(bob);
        assertEq(staking.claimBonanzaRevenue(2, address(tokenB), bob), 0);
        _settle(address(tokenB), false);
        (uint256 current,) = staking.indexedBonanzaRevenue(2, address(tokenB));
        assertEq(current, 50);
        (uint256 first,) = staking.indexedBonanzaRevenue(1, address(tokenB));
        assertEq(first, 150);
    }
}

contract BonanzaHostileReserveTest is BonanzaRevenueSetup {
    HostileBonanzaPayment internal hostile;

    function _initializeBonanza() internal override {
        hostile = new HostileBonanzaPayment();
        // Deliberately hostile STATICS stand-in, only for exact-transfer rejection tests.
        tokenA = IntegrationToken(address(hostile));
        hostile.mint(alice, 1000);
        super._initializeBonanza();
    }

    function testInexactReserveFundingWrapAndUnwrapRollback() public {
        hostile.configure(1, address(0), "");
        vm.prank(alice);
        vm.expectRevert();
        bonanza.fundBonanzaReserve(100);
        (uint256 inventory, uint256 backing,,,,,) = bonanzaView.bonanzaReserve();
        assertEq(inventory, 0);
        assertEq(backing, 0);
        vm.prank(authority);
        bonanza.setBonanzaConversions(true, true, 100);
        vm.prank(alice);
        vm.expectRevert();
        bonanza.wrapBonanza(1, 100);
        assertEq(bonanza.totalSupply(), 0);
        assertEq(positions.legs(1), 0);
        hostile.configure(0, address(0), "");
        vm.prank(alice);
        bonanza.wrapBonanza(1, 100);
        hostile.configure(1, address(0), "");
        vm.prank(alice);
        vm.expectRevert();
        bonanza.unwrapBonanza(1, 100, alice);
        assertEq(bonanza.totalSupply(), 100);
        assertEq(bonanzaView.bonanzaAccount(1).balance, 100);
        assertEq(hostile.balanceOf(address(diamond)), 100);
    }
}
