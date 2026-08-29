// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PoolExitor.sol";

interface IERC20X {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
interface IMToken {
    function mint(uint256) external returns (uint256);
    function redeemUnderlying(uint256) external returns (uint256);
}

/// A przUSDC that has taken a 50% haircut, i.e. Moonwell socialised its bad debt.
contract LossyVault {
    address public immutable OWNER_;
    uint256 public liquidity;
    error MaxSharesExceeded(uint256 needed, uint256 allowed);
    error MinAssetsNotReached(uint256 got, uint256 want);
    constructor(address o, uint256 liq) { OWNER_ = o; liquidity = liq; }
    function maxWithdraw(address) external view returns (uint256) { return liquidity; }
    function balanceOf(address) external pure returns (uint256) { return 2_806_742_336; }
    function convertToAssets(uint256 s) external pure returns (uint256) { return s / 2; }
    function previewWithdraw(uint256 a) external pure returns (uint256) { return a * 2; }
    function withdraw(uint256 a, address, address, uint256 maxShares) external pure returns (uint256) {
        uint256 needed = a * 2;                       // 50% haircut
        if (needed > maxShares) revert MaxSharesExceeded(needed, maxShares);
        return needed;
    }
    function redeem(uint256 s, address, address, uint256 minAssets) external pure returns (uint256) {
        uint256 got = s / 2;
        if (got < minAssets) revert MinAssetsNotReached(got, minAssets);
        return got;
    }
}

/// Vault whose redeem tries to re-enter the exitor.
contract ReentrantVault {
    PoolExitor public exitor;
    bool public reentryReverted;
    function set(PoolExitor e) external { exitor = e; }
    function maxWithdraw(address) external pure returns (uint256) { return 1_000e6; }
    function balanceOf(address) external pure returns (uint256) { return 1_000e6; }
    function convertToAssets(uint256 s) external pure returns (uint256) { return s; }
    function withdraw(uint256 a, address, address, uint256) external returns (uint256) { _try(); return a; }
    function redeem(uint256 s, address, address, uint256) external returns (uint256) { _try(); return s; }
    function _try() internal {
        try exitor.grab(1) { reentryReverted = false; } catch { reentryReverted = true; }
    }
}

contract AdversarialTest is Test {
    address constant VAULT = 0x7f5C2b379b88499aC2B997Db583f8079503f25b9;
    address constant USDC  = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MUSDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address constant USER  = 0x1111111111111111111111111111111111111111;
    address constant COLD  = address(0xC01D);
    address constant STRANGER = address(0xBEEF);

    PoolExitor exitor;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        exitor = new PoolExitor(USER, COLD, 9_999);
        vm.prank(USER);
        (bool ok,) = VAULT.call(abi.encodeWithSignature("approve(address,uint256)", address(exitor), type(uint256).max));
        require(ok);
    }

    function _supply(uint256 amt) internal {
        address w = address(0xA11CE);
        deal(USDC, w, amt);
        vm.startPrank(w);
        IERC20X(USDC).approve(MUSDC, amt);
        IMToken(MUSDC).mint(amt);
        vm.stopPrank();
    }

    /// Deployment verification: every address the contract can ever touch is fixed.
    function test_09_immutablesAndConstants() public view {
        assertEq(address(exitor.VAULT()), VAULT, "vault is hardcoded");
        assertEq(address(exitor.ASSET()), USDC, "asset is hardcoded");
        assertEq(exitor.OWNER(), USER);
        assertEq(exitor.RECEIVER(), COLD);
        assertEq(exitor.MIN_RATE_BPS(), 9_999);
    }

    function test_10_constructorRejectsBadInput() public {
        vm.expectRevert(PoolExitor.ZeroAddress.selector);
        new PoolExitor(address(0), COLD, 9_999);
        vm.expectRevert(PoolExitor.ZeroAddress.selector);
        new PoolExitor(USER, address(0), 9_999);
        vm.expectRevert(PoolExitor.BadRate.selector);
        new PoolExitor(USER, COLD, 10_001);   // better than par is nonsense
        vm.expectRevert(PoolExitor.BadRate.selector);
        new PoolExitor(USER, COLD, 4_999);    // >50% haircut is never "recovery"
    }

    /// THE GRIEFING VECTOR. grab() is permissionless, so if the slippage floor were a call
    /// parameter, any stranger could force the position out at any rate. Under a socialised
    /// Moonwell loss that realises a real haircut on the owner's behalf.
    function test_11_lossyVault_strangerCannotForceHaircutExit() public {
        vm.etch(VAULT, address(new LossyVault(USER, 1_000e6)).code);

        // A stranger asks for the loosest possible terms.
        vm.prank(STRANGER);
        vm.expectRevert(); // MaxSharesExceeded -- the immutable floor overrides the caller
        exitor.grab(1);

        // Proof this is the floor doing the work: the same call with an unbounded share
        // cap -- which is what `type(uint256).max` gave us before -- goes straight through.
        uint256 wouldHaveBurned = LossyVault(VAULT).withdraw(1_000e6, COLD, USER, type(uint256).max);
        assertEq(wouldHaveBurned, 2_000e6, "old code would burn 2000 shares for 1000 USDC");
    }

    /// The floor is enforced independently of, and can only be tightened by, minAssets.
    function test_12_strangerCannotLowerTheFloor() public {
        _supply(10_000e6); // enough for a full exit -> redeem path
        uint256 shares = 2_806_742_336;
        uint256 expectedFloor = (shares * 9_999) / 10_000;

        // Caller passes minAssets = 1; the contract must still hand the vault its own floor.
        vm.expectCall(
            VAULT,
            abi.encodeWithSignature(
                "redeem(uint256,address,address,uint256)", shares, COLD, USER, expectedFloor
            )
        );
        vm.prank(STRANGER);
        exitor.grab(1);
    }

    /// Reentrancy: no untrusted callback exists in production (VAULT is a constant), but
    /// the guard closes the question rather than arguing about it.
    function test_13_reentrancyBlocked() public {
        ReentrantVault rv = new ReentrantVault();
        vm.etch(VAULT, address(rv).code);
        ReentrantVault(VAULT).set(exitor);
        exitor.grab(1);
        assertTrue(ReentrantVault(VAULT).reentryReverted(), "re-entrant grab must revert");
    }

    /// The contract is a pass-through: funds go vault -> RECEIVER, never resting here.
    /// This is why there is no sweep() and no token parameter anywhere.
    function test_14_exitorNeverHoldsFunds() public {
        _supply(1_500e6);
        exitor.grab(1e6);
        assertEq(IERC20X(USDC).balanceOf(address(exitor)), 0, "no USDC stranded");
        assertEq(IERC20X(VAULT).balanceOf(address(exitor)), 0, "no shares stranded");
        assertGt(IERC20X(USDC).balanceOf(COLD), 1_499e6);
    }

    /// The real production race: liquidity seen at submit time is gone at inclusion time.
    /// Must fail closed -- no shares burned, no funds moved, position intact.
    function test_15_liquidityVanishesBeforeInclusion() public {
        address w = address(0xA11CE);
        _supply(800e6);
        assertEq(exitor.available(), 800e6, "opportunity visible at submit time");

        uint256 sharesBefore = IERC20X(VAULT).balanceOf(USER);
        vm.prank(w);
        IMToken(MUSDC).redeemUnderlying(800e6); // a faster bot takes it first

        vm.expectRevert();
        exitor.grab(1e6);

        assertEq(IERC20X(VAULT).balanceOf(USER), sharesBefore, "position untouched");
        assertEq(IERC20X(USDC).balanceOf(COLD), 0, "nothing moved");
    }

    /// Full exit must land on exactly zero shares, or the bot never terminates.
    /// This is the sole reason the redeem-by-shares branch exists.
    function test_16_fullExitLeavesNoDust() public {
        _supply(9_999_999_997); // deliberately awkward
        exitor.grab(1e6);
        assertEq(IERC20X(VAULT).balanceOf(USER), 0, "exactly zero, not dust");
    }

    /// The second review asked for `maxShares = VAULT.previewWithdraw(amt)`.
    /// That check is a TAUTOLOGY and can never revert: the vault computes the shares it
    /// will burn with previewWithdraw, then compares them against a bound derived from
    /// previewWithdraw at the same block, in the same call. It is `x > x`, always false.
    /// It reads as slippage protection while providing none.
    function test_17_previewWithdrawAsMaxSharesIsATautology() public {
        vm.etch(VAULT, address(new LossyVault(USER, 1_000e6)).code);
        LossyVault lv = LossyVault(VAULT);

        // The "protected" call the review recommends, on a 50%-lossy vault:
        uint256 sharesNeeded = lv.previewWithdraw(1_000e6);
        uint256 burned = lv.withdraw(1_000e6, COLD, USER, sharesNeeded);
        assertEq(burned, 2_000e6, "sails through: 2000 shares burned for 1000 USDC");

        // The immutable par-referenced floor, on the same vault, refuses:
        vm.prank(STRANGER);
        vm.expectRevert();
        exitor.grab(1);
    }
}
