#!/usr/bin/env bash
# Generates a fresh gas-only key and writes it straight into .env.
# The private key is NEVER printed to the terminal -- only the address is shown.
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || cp .env.example .env

if grep -qE '^(DEPLOYER|BOT)_PRIVATE_KEY=0x[a-fA-F0-9]{64}$' .env; then
  echo "⚠  .env already contains a real key."
  echo "   Existing address: $(cast wallet address --private-key "$(grep -m1 '^BOT_PRIVATE_KEY=' .env | cut -d= -f2)")"
  read -r -p "   Overwrite it? Any funds on it become unreachable. Type YES: " C
  [ "$C" = "YES" ] || { echo "kept the existing key."; exit 0; }
fi

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
cast wallet new --json > "$TMP"

ADDR=$(python3 -c "import json;print(json.load(open('$TMP'))[0]['address'])")

# Substitute the key into .env via python so it never passes through the shell or the screen.
python3 - "$TMP" <<'PY'
import json, re, sys
pk = json.load(open(sys.argv[1]))[0]['private_key']
if not pk.startswith('0x'):
    pk = '0x' + pk
env = open('.env').read()
for var in ('DEPLOYER_PRIVATE_KEY', 'BOT_PRIVATE_KEY'):
    if re.search(rf'^{var}=.*$', env, re.M):
        env = re.sub(rf'^{var}=.*$', f'{var}={pk}', env, flags=re.M)
    else:
        env += f'\n{var}={pk}\n'
open('.env', 'w').write(env)
PY

chmod 600 .env
echo
echo "✅ new gas-only key written to .env (private key never displayed)"
echo
echo "   ADDRESS: $ADDR"
echo
echo "   NEXT: send this address 0.003 ETH — on the BASE network, not Ethereum mainnet."
echo "         It only ever pays gas. It cannot touch your przUSDC position."
