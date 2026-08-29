// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PoolExitor.sol";

/// A przUSDC whose share:asset rate is dialled to an arbitrary bps of par.
/// rate/liquidity/shares are immutable so they survive vm.etch (immutables live in code).
contract RateVault {
    uint256 public immutable RATE;   // assets per share, bps of par
    uint256 public immutable LIQ;    // withdrawable ceiling
    uint256 public immutable SHARES;
    error MaxSharesExceeded(uint256 needed, uint256 allowed);
    error MinAssetsNotReached(uint256 got, uint256 want);
    constructor(uint256 r, uint256 l, uint256 sh) { RATE = r; LIQ = l; SHARES = sh; }
    function maxWithdraw(address) external view returns (uint256) {
        uint256 ownerAssets = (SHARES * RATE) / 10_000;
        return ownerAssets < LIQ ? ownerAssets : LIQ;
    }
    function balanceOf(address) external view returns (uint256) { return SHARES; }
    function convertToAssets(uint256 s) external view returns (uint256) { return (s * RATE) / 10_000; }
    function previewWithdraw(uint256 a) public view returns (uint256) {
        return (a * 10_000 + RATE - 1) / RATE;               // shares rounded UP
    }
    function withdraw(uint256 a, address, address, uint256 maxShares) external view returns (uint256) {
        uint256 need = previewWithdraw(a);
        if (need > maxShares) revert MaxSharesExceeded(need, maxShares);
        return need;
    }
    function redeem(uint256 s, address, address, uint256 minAssets) external view returns (uint256) {
        uint256 got = (s * RATE) / 10_000;
        if (got < minAssets) revert MinAssetsNotReached(got, minAssets);
        return got;
    }
}

contract RateFloorTest is Test {
    address constant VAULT = 0x7f5C2b379b88499aC2B997Db583f8079503f25b9;
    address constant USER  = 0x1111111111111111111111111111111111111111;
    address constant COLD  = address(0xC01D);
    uint256 constant SHARES = 2_806_742_336;

    PoolExitor exitor;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        exitor = new PoolExitor(USER, COLD, 9_999);   // floor = 99.99% of par
    }

    function _etch(uint256 rate, uint256 liq) internal {
        vm.etch(VAULT, address(new RateVault(rate, liq, SHARES)).code);
    }

    // ---- review item 12: the floor rejects a loss, on BOTH paths ----

    function test_18_rateFloor_partialPath() public {
        _etch(9_998, 1_000e6);                       // 0.02% below par, liquidity-limited
        vm.expectRevert(); exitor.grab(1);

        _etch(9_999, 1_000e6);                       // exactly at the floor
        assertEq(exitor.grab(1), 1_000e6, "at-floor partial must clear");

        _etch(10_000, 1_000e6);                      // par
        assertEq(exitor.grab(1), 1_000e6, "par partial must clear");
    }

    function test_19_rateFloor_fullPath() public {
        uint256 big = 10_000e6;                      // liquidity > whole position -> redeem path
        _etch(9_998, big);
        vm.expectRevert(); exitor.grab(1);

        _etch(9_999, big);
        assertGt(exitor.grab(1), 0, "at-floor full exit must clear");

        _etch(10_000, big);
        assertEq(exitor.grab(1), SHARES, "par full exit returns par");
    }

    /// A deeper haircut is refused on both paths, regardless of what the caller asks for.
    function test_20_deepHaircutRefusedFromAnyCaller() public {
        _etch(5_000, 1_000e6);                       // 50% loss
        vm.prank(address(0xBEEF));
        vm.expectRevert(); exitor.grab(1);

        _etch(5_000, 10_000e6);
        vm.prank(address(0xBEEF));
        vm.expectRevert(); exitor.grab(1);
    }

    // ---- review item 13: exact boundary arithmetic ----

    /// The reviewer proposed:  if (requiredShares * MIN_RATE_BPS < max * BPS) revert;
    /// That comparison is INVERTED. It rejects healthy exits and permits lossy ones.
    function test_21_reviewersConditionIsInverted() public pure {
        uint256 BPS = 10_000;
        uint256 MIN = 9_999;

        // Healthy: 1000 USDC out for 1000 shares (par).
        uint256 maxA = 1_000e6;
        uint256 reqPar = 1_000e6;
        assertTrue(reqPar * MIN < maxA * BPS, "reviewer's form fires on a PAR exit -> would revert it");

        // Lossy: 1000 USDC out for 2000 shares (50% haircut).
        uint256 reqLossy = 2_000e6;
        assertFalse(reqLossy * MIN < maxA * BPS, "reviewer's form stays silent on a 50% HAIRCUT -> permits it");

        // Correct direction (what the contract does): refuse when shares demanded are too many.
        assertFalse(reqPar * MIN > maxA * BPS, "correct form permits par");
        assertTrue(reqLossy * MIN > maxA * BPS, "correct form refuses the haircut");
    }

    /// The reviewer worried that `(max * BPS) / MIN_RATE_BPS` loses precision versus
    /// cross-multiplication. For integer share counts the two are exactly equivalent --
    /// `n <= floor(x)` iff `n <= x`. Proven over the input space rather than asserted.
    function testFuzz_22_divisionAndCrossMultiplyAgree(uint96 maxA, uint96 shares, uint16 rate) public pure {
        vm.assume(rate >= 5_000 && rate <= 10_000);
        vm.assume(maxA > 0);
        bool crossMul = uint256(shares) * rate > uint256(maxA) * 10_000;
        bool division = uint256(shares) > (uint256(maxA) * 10_000) / rate;
        assertEq(crossMul, division, "the two formulations must never disagree");
    }
}
