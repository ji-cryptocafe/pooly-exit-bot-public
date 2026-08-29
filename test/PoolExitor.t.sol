// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PoolExitor.sol";

interface IERC20X {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IMToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function getCash() external view returns (uint256);
}

interface IVaultFull is IPrizeVault {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function approve(address, uint256) external returns (bool);
    function totalDebt() external view returns (uint256);
}

contract PoolExitorTest is Test {
    address constant VAULT    = 0x7f5C2b379b88499aC2B997Db583f8079503f25b9; // przUSDC
    address constant USDC     = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MUSDC    = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22; // Moonwell mUSDC
    address constant USER     = 0x1111111111111111111111111111111111111111; // the position
    address constant COLD     = address(0xC01D);

    PoolExitor exitor;
    IVaultFull v = IVaultFull(VAULT);

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        exitor = new PoolExitor(USER, COLD, 9_999);
        // The one and only tx the share-holding wallet ever signs.
        vm.prank(USER);
        v.approve(address(exitor), type(uint256).max);
    }

    function _whaleSuppliesToMoonwell(uint256 amt) internal {
        address whale = address(0xA11CE);
        deal(USDC, whale, amt);
        vm.startPrank(whale);
        IERC20X(USDC).approve(MUSDC, amt);
        assertEq(IMToken(MUSDC).mint(amt), 0, "moonwell mint failed");
        vm.stopPrank();
    }

    function _whaleDepositsToPool(uint256 amt) internal {
        address whale = address(0xDEB0);
        deal(USDC, whale, amt);
        vm.startPrank(whale);
        IERC20X(USDC).approve(VAULT, amt);
        v.deposit(amt, whale);
        vm.stopPrank();
    }

    /// Baseline: the position is real, and it is currently stuck.
    function test_01_currentlyStuck() public view {
        uint256 shares = v.balanceOf(USER);
        console2.log("shares (przUSDC):", shares);
        console2.log("mUSDC getCash():  ", IMToken(MUSDC).getCash());
        console2.log("maxWithdraw:      ", v.maxWithdraw(USER));
        assertGt(shares, 0, "USER should hold a stuck przUSDC position");
        assertEq(v.maxWithdraw(USER), 0, "expected zero liquidity");
    }

    function test_02_grabRevertsWhenDry() public {
        vm.expectRevert();
        exitor.grab(1e6);
    }

    /// Someone repays/supplies USDC on Moonwell -> cash appears -> we take it.
    function test_03_partialExitFromMoonwellSupply() public {
        _whaleSuppliesToMoonwell(500e6);
        uint256 avail = exitor.available();
        console2.log("available after 500 USDC supply:", avail);
        assertGt(avail, 499e6);

        uint256 before = IERC20X(USDC).balanceOf(COLD);
        uint256 got = exitor.grab(100e6);
        uint256 delta = IERC20X(USDC).balanceOf(COLD) - before;

        console2.log("grabbed:", got, "delta to cold:", delta);
        assertEq(delta, got, "receiver must get exactly what grab reports");
        assertGt(delta, 499e6, "should have taken ~all 500");
        assertGt(v.balanceOf(USER), 0, "partial exit leaves a remainder");
    }

    /// Another user deposits into the prize pool itself -> that is our exit liquidity.
    function test_04_partialExitFromPoolDeposit() public {
        _whaleDepositsToPool(1_000e6);
        uint256 avail = exitor.available();
        console2.log("available after 1000 USDC pool deposit:", avail);
        assertGt(avail, 999e6);

        uint256 got = exitor.grab(1e6);
        assertGt(IERC20X(USDC).balanceOf(COLD), 999e6);
        console2.log("grabbed:", got, "shares left:", v.balanceOf(USER));
    }

    /// Enough liquidity for the whole position -> full exit, zero shares left.
    function test_05_fullExit() public {
        _whaleSuppliesToMoonwell(10_000e6);
        uint256 got = exitor.grab(1e6);
        console2.log("full exit grabbed:", got);
        assertEq(v.balanceOf(USER), 0, "position fully closed");
        assertGt(IERC20X(USDC).balanceOf(COLD), 0, "recovered position lands in the cold wallet");
    }

    /// Repeated small windfalls are drained incrementally until the position is empty.
    function test_06_incrementalDrain() public {
        uint256 rounds;
        while (v.balanceOf(USER) > 0 && rounds < 10) {
            _whaleSuppliesToMoonwell(400e6);
            exitor.grab(1e6);
            rounds++;
        }
        console2.log("rounds:", rounds, "recovered:", IERC20X(USDC).balanceOf(COLD));
        assertEq(v.balanceOf(USER), 0);
        assertGe(IERC20X(USDC).balanceOf(COLD), 2_800e6);
    }

    /// The threshold is enforced on-chain, at execution time.
    function test_07_thresholdEnforced() public {
        _whaleSuppliesToMoonwell(50e6);
        vm.expectRevert();
        exitor.grab(500e6); // want >=500, only ~50 there -> no tx, no wasted position
        exitor.grab(10e6);  // lower bar clears
        assertGt(IERC20X(USDC).balanceOf(COLD), 49e6);
    }

    /// grab() is permissionless but can only ever move USER -> COLD.
    function test_08_permissionlessButSafe() public {
        _whaleSuppliesToMoonwell(600e6);
        address caller = address(0xBAD);
        // NB: low vanity addresses hold real dust on Base -- assert on the delta, not the balance.
        uint256 callerBefore = IERC20X(USDC).balanceOf(caller);
        vm.prank(caller);
        exitor.grab(1e6);
        assertGt(IERC20X(USDC).balanceOf(COLD), 599e6, "funds go to RECEIVER regardless of caller");
        assertEq(IERC20X(USDC).balanceOf(caller), callerBefore, "caller gains nothing");
    }
}
