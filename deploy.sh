#!/usr/bin/env bash
# Guided deployment. Simulates first, asks before spending, verifies on Basescan.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "❌ no .env -- copy .env.example to .env and fill it in"; exit 1; }
set -a; source .env; set +a

: "${BASE_RPC_URL:?}"; : "${OWNER_ADDRESS:?}"; : "${RECEIVER_ADDRESS:?}"
: "${DEPLOYER_PRIVATE_KEY:?}"; MIN_RATE_BPS="${MIN_RATE_BPS:-9999}"
RPC="${BASE_RPC_URL%%,*}"
VAULT=0x7f5C2b379b88499aC2B997Db583f8079503f25b9

DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
BAL=$(cast balance "$DEPLOYER" --rpc-url "$RPC")

echo "──────────────────────────────────────────────────────────────"
echo " ABOUT TO DEPLOY PoolExitor TO BASE MAINNET"
echo "──────────────────────────────────────────────────────────────"
echo "  OWNER (holds przUSDC, signs the approve) : $OWNER_ADDRESS"
echo "  RECEIVER (gets the recovered USDC)       : $RECEIVER_ADDRESS   << IMMUTABLE"
echo "  MIN_RATE_BPS (slippage floor)            : $MIN_RATE_BPS       << IMMUTABLE"
echo "  deployer (pays gas only)                 : $DEPLOYER"
echo "  deployer balance                         : $(cast from-wei "$BAL") ETH"
echo
echo "  position at OWNER: $(cast call $VAULT 'balanceOf(address)(uint256)' "$OWNER_ADDRESS" --rpc-url "$RPC") przUSDC (6 decimals)"
echo "──────────────────────────────────────────────────────────────"

if [ "$BAL" = "0" ]; then echo "❌ deployer has no ETH on Base. Send it ~0.002 ETH first."; exit 1; fi

echo "Step 1/3: simulating (no transaction sent)..."
forge script script/Deploy.s.sol --rpc-url "$RPC" >/dev/null 2>&1 && echo "  ✅ simulation OK" || { echo "  ❌ simulation failed"; exit 1; }

echo
read -r -p "Type YES to broadcast for real: " CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "aborted."; exit 1; }

echo "Step 2/3: deploying..."
forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast 2>&1 | tee /tmp/deploy.out
EXITOR=$(grep -oE "PoolExitor: 0x[a-fA-F0-9]{40}" /tmp/deploy.out | tail -1 | awk '{print $2}')
[ -n "$EXITOR" ] || { echo "❌ could not parse deployed address; check /tmp/deploy.out"; exit 1; }

echo
echo "Step 3/3: verifying source on Basescan (so you can read it in a browser)..."
forge verify-contract "$EXITOR" src/PoolExitor.sol:PoolExitor \
  --chain-id 8453 --watch \
  --constructor-args "$(cast abi-encode 'constructor(address,address,uint256)' "$OWNER_ADDRESS" "$RECEIVER_ADDRESS" "$MIN_RATE_BPS")" \
  --etherscan-api-key "${ETHERSCAN_API_KEY:-}" 2>&1 | tail -5 || echo "  ⚠ verification failed -- not fatal, but you lose the browser Read/Write tabs"

sed -i '' "s|^EXITOR_ADDRESS=.*|EXITOR_ADDRESS=$EXITOR|" .env 2>/dev/null || echo "EXITOR_ADDRESS=$EXITOR" >> .env

echo
echo "══════════════════════════════════════════════════════════════"
echo " DEPLOYED: $EXITOR"
echo " https://basescan.org/address/$EXITOR#readContract"
echo
echo " ON YOUR SECURE MACHINE, IN A BROWSER:"
echo " 1. Open the link above. Under 'Read Contract' confirm ALL of:"
echo "      VAULT        = 0x7f5C2b379b88499aC2B997Db583f8079503f25b9"
echo "      ASSET        = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
echo "      OWNER        = $OWNER_ADDRESS"
echo "      RECEIVER     = $RECEIVER_ADDRESS"
echo "      MIN_RATE_BPS = $MIN_RATE_BPS"
echo "    If ANY value differs, STOP. Do not approve."
echo
echo " 2. Then go to:"
echo "      https://basescan.org/address/$VAULT#writeContract"
echo "    Connect your wallet ($OWNER_ADDRESS), find 'approve', and enter:"
echo "      spender = $EXITOR"
echo "      value   = $(cast call $VAULT 'balanceOf(address)(uint256)' "$OWNER_ADDRESS" --rpc-url "$RPC" | awk '{print $1}')"
echo "    (that is your exact share balance -- not unlimited)"
echo
echo " 3. Back here:  npm run watch     (dry run, sends nothing)"
echo "                npm run bot       (live)"
echo "══════════════════════════════════════════════════════════════"
