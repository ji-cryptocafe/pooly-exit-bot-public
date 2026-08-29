// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "../src/PoolExitor.sol";
interface IERC20X { function approve(address,uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }
interface IMToken { function mint(uint256) external returns (uint256); }

/// What gas limit is actually safe? Measure the real grab() call on both paths.
contract GasLimitTest is Test {
    address constant VAULT=0x7f5C2b379b88499aC2B997Db583f8079503f25b9;
    address constant USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MUSDC=0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address constant USER=0x1111111111111111111111111111111111111111;
    PoolExitor e;
    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        e = new PoolExitor(USER, USER, 9_999);
        vm.prank(USER);
        (bool ok,) = VAULT.call(abi.encodeWithSignature("approve(address,uint256)", address(e), type(uint256).max));
        require(ok);
    }
    function _supply(uint256 a) internal {
        address w=address(0xA11CE); deal(USDC,w,a); vm.startPrank(w);
        IERC20X(USDC).approve(MUSDC,a); IMToken(MUSDC).mint(a); vm.stopPrank();
    }
    function test_gasOfEachPath() public {
        uint256 pos = IERC20X(VAULT).balanceOf(USER);
        emit log_named_uint("position", pos);

        _supply(500e6);                       // partial-withdraw path
        uint256 g0 = gasleft(); e.grab(1e6); uint256 gPartial = g0 - gasleft();
        emit log_named_uint("grab() gas  PARTIAL withdraw", gPartial);

        _supply(10_000e6);                    // full redeem path
        g0 = gasleft(); e.grab(1e6); uint256 gFull = g0 - gasleft();
        emit log_named_uint("grab() gas  FULL redeem", gFull);
        emit log_named_uint("worst path + 21k intrinsic", (gPartial > gFull ? gPartial : gFull) + 21000);
    }
}
