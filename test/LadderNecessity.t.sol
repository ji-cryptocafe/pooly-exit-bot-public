// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PoolExitor.sol";

interface IERC20X {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IMToken { function mint(uint256) external returns (uint256); }
interface IVaultFull is IPrizeVault {
    function deposit(uint256, address) external returns (uint256);
    function approve(address, uint256) external returns (bool);
    function previewWithdraw(uint256) external view returns (uint256);
}

/// Does the naive `withdraw(maxWithdraw(owner))` ever revert on the real contracts?
/// If it never does, the descending ladder in PoolExitor is dead complexity and should go.
contract LadderNecessityTest is Test {
    address constant VAULT = 0x7f5C2b379b88499aC2B997Db583f8079503f25b9;
    address constant USDC  = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MUSDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address constant USER  = 0x1111111111111111111111111111111111111111;
    address constant COLD  = address(0xC01D);
    IVaultFull v = IVaultFull(VAULT);

    function setUp() public { vm.createSelectFork(vm.envString("BASE_RPC_URL")); }

    function _supply(uint256 amt) internal {
        address w = address(0xA11CE);
        deal(USDC, w, amt);
        vm.startPrank(w);
        IERC20X(USDC).approve(MUSDC, amt);
        IMToken(MUSDC).mint(amt);
        vm.stopPrank();
    }

    function _poolDeposit(uint256 amt) internal {
        address w = address(0xDEB0);
        deal(USDC, w, amt);
        vm.startPrank(w);
        IERC20X(USDC).approve(VAULT, amt);
        v.deposit(amt, w);
        vm.stopPrank();
    }

    function test_ladder_isItEverNeeded() public {
        // Awkward, prime-ish and boundary amounts on both liquidity routes.
        uint256[20] memory amts = [
            uint256(1), 3, 999, 1e6 - 1, 1e6, 1e6 + 1, 7_777_777, 123_456_789,
            999_999_999, 1e9, 1e9 + 1, 1_500_000_003, 2_806_742_335, 2_806_742_336,
            2_806_742_337, 2_999_999_999, 3e9, 13_000_000_001, 5e9 + 7, 10e9
        ];
        uint256 rung0Fail;
        uint256 tested;

        for (uint256 route = 0; route < 2; ++route) {
            for (uint256 i = 0; i < amts.length; ++i) {
                uint256 snap = vm.snapshotState();
                if (route == 0) _supply(amts[i]); else _poolDeposit(amts[i]);

                uint256 max = v.maxWithdraw(USER);
                if (max > 0) {
                    tested++;
                    vm.prank(USER);
                    try v.withdraw(max, COLD, USER, type(uint256).max) returns (uint256) {
                        // rung 0 cleared
                    } catch {
                        rung0Fail++;
                        emit log_named_uint("rung-0 FAILED at liquidity", amts[i]);
                        emit log_named_uint("  route (0=moonwell,1=pool)", route);
                        emit log_named_uint("  maxWithdraw", max);
                        emit log_named_uint("  previewWithdraw(max)", v.previewWithdraw(max));
                        emit log_named_uint("  shares held", v.balanceOf(USER));
                    }
                }
                vm.revertToState(snap);
            }
        }
        emit log_named_uint("scenarios tested", tested);
        emit log_named_uint("rung-0 (100%) failures", rung0Fail);
    }
}
