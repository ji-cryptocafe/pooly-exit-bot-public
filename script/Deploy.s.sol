// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PoolExitor.sol";

/// Separation of duties -- three distinct keys, none of which can take the position:
///   OWNER    : the wallet that already holds the przUSDC. Signs ONE approve, ever.
///              This should be your normal/cold wallet. It does NOT need to be hot.
///   RECEIVER : where recovered USDC lands. Immutable. Can be a different cold wallet.
///   DEPLOYER : pays for this deployment and nothing else.
///   (the bot key, elsewhere, pays gas only and is never referenced by the contract)
contract Deploy is Script {
    function run() external {
        address owner    = vm.envAddress("OWNER_ADDRESS");    // wallet currently HOLDING the przUSDC
        address receiver = vm.envAddress("RECEIVER_ADDRESS"); // wallet that RECEIVES recovered USDC
        uint256 minRate  = vm.envOr("MIN_RATE_BPS", uint256(9_999));

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        PoolExitor e = new PoolExitor(owner, receiver, minRate);
        vm.stopBroadcast();

        console2.log("PoolExitor:", address(e));
        console2.log("");
        console2.log("VERIFY THESE ON-CHAIN BEFORE APPROVING (do not trust this output):");
        console2.log("  cast call <EXITOR> 'VAULT()(address)'        --rpc-url $BASE_RPC_URL");
        console2.log("  cast call <EXITOR> 'ASSET()(address)'        --rpc-url $BASE_RPC_URL");
        console2.log("  cast call <EXITOR> 'OWNER()(address)'        --rpc-url $BASE_RPC_URL");
        console2.log("  cast call <EXITOR> 'RECEIVER()(address)'     --rpc-url $BASE_RPC_URL");
        console2.log("  cast call <EXITOR> 'MIN_RATE_BPS()(uint256)' --rpc-url $BASE_RPC_URL");
    }
}
