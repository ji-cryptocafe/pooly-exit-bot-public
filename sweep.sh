#!/usr/bin/env bash
# Sweeps the gas key's remaining ETH back to OWNER_ADDRESS.
# The private key never leaves .env and is never printed. MetaMask is not involved.
# Usage:  ./sweep.sh            -> preview only, sends nothing
#         ./sweep.sh --send     -> actually broadcast
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a
RPC="${BASE_RPC_URL%%,*}"
TO="${1:-$OWNER_ADDRESS}"; [ "$TO" = "--send" ] && TO="$OWNER_ADDRESS"

FROM=$(cast wallet address --private-key "$BOT_PRIVATE_KEY")
BAL=$(cast balance "$FROM" --rpc-url "$RPC")

# A plain transfer is 21000 gas, but Base also charges an L1 data fee that is not part of
# the gas price. Reserve generously rather than have the send rejected for 1 wei.
BASEFEE=$(cast base-fee --rpc-url "$RPC")
RESERVE=$(python3 -c "print(int(21000 * ($BASEFEE*2 + 1_000_000) + 3_000_000_000_000))")
SEND=$(python3 -c "print(max(0, $BAL - $RESERVE))")

echo "─────────────────────────────────────────────────────"
echo "  from     : $FROM  (gas key)"
echo "  to       : $TO"
echo "  balance  : $(cast from-wei $BAL) ETH"
echo "  reserve  : $(cast from-wei $RESERVE) ETH   (21k gas + Base L1 data fee)"
echo "  SENDING  : $(cast from-wei $SEND) ETH"
echo "─────────────────────────────────────────────────────"
[ "$SEND" -gt 0 ] || { echo "nothing to sweep"; exit 0; }

if [ "${1:-}" != "--send" ] && [ "${2:-}" != "--send" ]; then
  echo "preview only. re-run with --send to broadcast."; exit 0
fi

TX=$(cast send "$TO" --value "$SEND" --private-key "$BOT_PRIVATE_KEY" --rpc-url "$RPC" --json | python3 -c "import sys,json;print(json.load(sys.stdin)['transactionHash'])")
echo "  sent: $TX"
sleep 4
echo "  status : $(cast receipt "$TX" status --rpc-url "$RPC" 2>/dev/null || echo pending)"
echo "  gas key: $(cast from-wei $(cast balance "$FROM" --rpc-url "$RPC")) ETH remaining"
echo "  wallet : $(cast from-wei $(cast balance "$TO" --rpc-url "$RPC")) ETH"
