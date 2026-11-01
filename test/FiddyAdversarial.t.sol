// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { FiddyRevenueSetup } from "./FiddyStaking.t.sol";
import { IntegrationToken } from "./utils/LotteryIntegrationSetup.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract HostileFiddyPayment is ERC20 {
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

contract FiddyAdversarialTest is FiddyRevenueSetup {
    function testClaimFailuresRollbackAndReentrancyCannotDoubleSpend() public {
        _start();
        HostileFiddyPayment asset = new HostileFiddyPayment();
        asset.mint(alice, 10_000);
        router.setAsset(address(asset), true, true);
        vm.prank(alice);
        asset.approve(address(diamond), type(uint256).max);
        _settle(address(asset), false);
        (uint256 earned,) = staking.indexedFiddyRevenue(1, address(asset));
        uint256 reserved = fiddyView.fiddyAsset(address(asset)).reserved;
        for (uint256 mode = 1; mode <= 3; mode += 2) {
            asset.configure(mode, alice, "");
            vm.prank(alice);
            vm.expectRevert();
            staking.claimFiddyRevenue(1, address(asset), alice);
            (uint256 unchanged,) = staking.indexedFiddyRevenue(1, address(asset));
            assertEq(unchanged, earned);
            assertEq(fiddyView.fiddyAsset(address(asset)).reserved, reserved);
        }
        asset.configure(
            2,
            address(diamond),
            abi.encodeCall(staking.claimFiddyRevenue, (1, address(asset), alice))
        );
        vm.prank(alice);
        assertEq(staking.claimFiddyRevenue(1, address(asset), alice), earned);
        assertTrue(asset.blocked());
        vm.prank(alice);
        assertEq(staking.claimFiddyRevenue(1, address(asset), alice), 0);
    }

    function testLateEntrantCannotClaimPastRevenue() public {
        _wrap(1, alice, 100);
        _wrap(2, bob, 100);
        vm.prank(alice);
        staking.stakeFiddy(1, 100);
        _settle(address(tokenB), false);
        vm.prank(bob);
        staking.stakeFiddy(2, 100);
        (uint256 past,) = staking.indexedFiddyRevenue(2, address(tokenB));
        assertEq(past, 0);
        vm.prank(bob);
        assertEq(staking.claimFiddyRevenue(2, address(tokenB), bob), 0);
        _settle(address(tokenB), false);
        (uint256 current,) = staking.indexedFiddyRevenue(2, address(tokenB));
        assertEq(current, 50);
        (uint256 first,) = staking.indexedFiddyRevenue(1, address(tokenB));
        assertEq(first, 150);
    }
}

contract FiddyHostileReserveTest is FiddyRevenueSetup {
    HostileFiddyPayment internal hostile;

    function _initializeFiddy() internal override {
        hostile = new HostileFiddyPayment();
        // Deliberately hostile STATICS stand-in, only for exact-transfer rejection tests.
        tokenA = IntegrationToken(address(hostile));
        hostile.mint(alice, 1000);
        super._initializeFiddy();
    }

    function testInexactReserveFundingWrapAndUnwrapRollback() public {
        hostile.configure(1, address(0), "");
        vm.prank(alice);
        vm.expectRevert();
        fiddy.fundFiddyReserve(100);
        (uint256 inventory, uint256 backing,,,,,) = fiddyView.fiddyReserve();
        assertEq(inventory, 0);
        assertEq(backing, 0);
        vm.prank(authority);
        fiddy.setFiddyConversions(true, true, 100);
        vm.prank(alice);
        vm.expectRevert();
        fiddy.wrapFiddy(1, 100);
        assertEq(fiddy.totalSupply(), 0);
        assertEq(positions.legs(1), 0);
        hostile.configure(0, address(0), "");
        vm.prank(alice);
        fiddy.wrapFiddy(1, 100);
        hostile.configure(1, address(0), "");
        vm.prank(alice);
        vm.expectRevert();
        fiddy.unwrapFiddy(1, 100, alice);
        assertEq(fiddy.totalSupply(), 100);
        assertEq(fiddyView.fiddyAccount(1).balance, 100);
        assertEq(hostile.balanceOf(address(diamond)), 100);
    }
}
