# Deploying, for someone who has never deployed anything

**🇬🇧 English · 🇩🇪 [Deutsch](DEPLOY.md)**

**Your secure machine installs nothing.** It only ever opens a browser and clicks one button.
Everything else runs from the dev machine with a throwaway key that can never touch your position.

| Machine | Role | Needs installed |
|---|---|---|
| **Secure machine** (holds `0xYOUR_WALLET`) | Signs exactly ONE transaction, ever: the `approve`. | Nothing. A browser + your wallet extension. |
| **Dev machine** (this repo) | Deploys the contract, runs the bot. | Already set up. |
| **Throwaway key** (created below) | Pays gas for the deploy and the bot. | — |

The throwaway key is *only* a gas payer. It is never named inside the contract, and the
contract can only ever send funds to the immutable `RECEIVER`. If it were stolen tomorrow,
the attacker gets whatever ETH is left on it and nothing else.

---

## Costs (measured, Base at 0.005 gwei)

| | gas | cost @ $4000/ETH |
|---|---|---|
| deploy the contract | 557,372 | **$0.011** |
| your `approve` | ~46,000 | **$0.001** |
| each successful grab | ~900,000 | **$0.018** |
| each failed attempt | ~158,000 | **$0.003** |

Budget ~0.003 ETH on the throwaway key. That is over a thousand attempts.

---

## Step 1 — create the throwaway key (dev machine)

**Do not use MetaMask for this.** The bot needs a raw private key sitting in a plaintext file,
and every MetaMask account is derived from your seed phrase. Exporting one doesn't leak the
seed, but it puts a key from your main wallet family into a hot file for no reason. This
generates a mathematically independent key instead:

```bash
cd pooly-exit-bot-public
./newkey.sh
```

It writes the key straight into `.env` (chmod 600) and prints **only the address**. The
private key is never displayed, so it never lands in your terminal scrollback or any
transcript. Do not run bare `cast wallet new` — that prints the key to the screen.

The same key is used for both the deploy and the bot; both jobs are just "pay gas".

Then open `.env` and fill in the rest:

```
BASE_RPC_URL=https://mainnet.base.org
OWNER_ADDRESS=0xYOUR_WALLET_ADDRESS
RECEIVER_ADDRESS=0xYOUR_WALLET_ADDRESS
MIN_RATE_BPS=9999
```

(Leave `DEPLOYER_PRIVATE_KEY` / `BOT_PRIVATE_KEY` alone — `newkey.sh` already set them.)

### What this key can and cannot do

- **Can:** pay gas, deploy the contract, call `grab()`.
- **Cannot:** touch your przUSDC, redirect the USDC, or change anything about the contract.
  It is never named inside the contract. If it were stolen tomorrow the attacker gets the
  leftover gas money and nothing else.

MetaMask's only involvement in this whole process is Step 2 (sending it gas) and Step 5
(the approve).

### Choosing RECEIVER — this is immutable, get it right

- **Same as OWNER** (`0xYOUR_WALLET`): the recovered USDC simply lands back in the wallet it
  came from. Simplest, nothing new to manage.
- **A hardware wallet**: better if you consider `0xYOUR_WALLET` exposed at all.

It cannot be changed after deployment. Changing it means deploying again and re-approving.

## Step 2 — fund the throwaway key (secure machine, browser)

In MetaMask, send **0.003 ETH** to the address `newkey.sh` printed.
Make sure the network is **Base**, not Ethereum mainnet.

## Step 3 — deploy (dev machine)

```bash
./deploy.sh
```

It shows you every value, simulates without spending, waits for you to type `YES`, deploys,
then verifies the source on Basescan so you can read it in a browser. It ends by printing
your contract address and the exact instructions for Step 4.

## Step 4 — verify before you trust it (secure machine, browser)

Open `https://basescan.org/address/<YOUR_EXITOR>#readContract` and confirm **all five**:

```
VAULT        = 0x7f5C2b379b88499aC2B997Db583f8079503f25b9
ASSET        = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
OWNER        = 0xYOUR_WALLET_ADDRESS
RECEIVER     = <what you chose>
MIN_RATE_BPS = 9999
```

**If any value differs, stop. Do not approve.** This is the whole security check — once these
five are right, the contract provably cannot send your money anywhere else.

## Step 5 — approve (secure machine, browser)

Go to:

```
https://basescan.org/address/0x7f5C2b379b88499aC2B997Db583f8079503f25b9#writeContract
```

- Click **Connect to Web3** and connect `0xYOUR_WALLET`.
- Find **approve**, and enter:
  - `spender` = your exitor address
  - `amount` = `<your exact przUSDC balance, written with no decimal point>`
- Click **Write** and confirm in your wallet.

przUSDC has 6 decimals, so drop the decimal point: a balance shown as `1000.000000 przUSDC`
is entered as `1000000000`. Read your exact balance from your wallet or Basescan.
**Approve exactly this, not unlimited.** It is all the bot ever needs, and it caps the
blast radius at the position you are already trying to rescue.

To cancel later, repeat with `amount = 0`.

## Step 6 — run the bot (dev machine)

```bash
npm run watch    # dry run: reports what it would do, sends nothing
```

Confirm it prints `allowance ✅ set` and `vault … ✅ verified`. Then:

```bash
npm run bot
```

Leave it running. It exits by itself the moment the position hits zero.

To keep it alive after you close the terminal:

```bash
nohup npm run bot > bot.log 2>&1 &
tail -f bot.log
```

Stop it with `pkill -f exit-bot`.

---

## What you will see

Idle (the normal state — could be days):

```
[12:00:00] mUSDC cash 0.000001 USDC | available 0.00 USDC
[12:00:00] polling every 500ms -- waiting for liquidity...
```

When liquidity appears:

```
[14:23:11] LIQUIDITY: available 800.00 USDC | mUSDC cash 800.000001 USDC -> firing
[14:23:11] ✅ GRABBED 800.00 USDC | total recovered 800.00 USDC | shares left <remaining> USDC
```

`reverted (no liquidity by inclusion time)` means someone beat you to it. Costs ~$0.003.
If you see it repeatedly, raise `PRIORITY_GWEI` in `.env` and restart.

---

## When does it actually fire?

Two gates, both must pass. There is **no upper limit** -- it always takes everything
available, capped only by your remaining position.

1. **`MIN_ASSETS_USDC`** (default `5`) -- a hard floor in dollars.
2. **`MAX_GAS_PCT`** (default `2`) -- gas must stay under 2% of what the grab recovers.
   This is the gate that matters if Base fees ever spike; the fixed floor alone would
   quietly stop making sense.

Worst-case gas to fully exit a **$1,000** position, if *every* fill were exactly this size.
It scales linearly — double the position and you double the grabs and the total gas, but the
**% of position stays the same**:

| avg fill | grabs (per $1k) | total gas (per $1k) | % of position |
|---|---|---|---|
| $1 | 1000 | $18.00 | 1.80% |
| $5 | 200 | $3.60 | 0.36% |
| $10 | 100 | $1.80 | 0.18% |
| $25 | 40 | $0.72 | 0.07% |
| $100 | 10 | $0.18 | 0.02% |

`5` is a good default. Raising the floor does **not** get you bigger fills -- it just means
small ones go to somebody else, and with ~13.16M USDC of competing claims the small fills
are the ones you are most likely to actually win. Lower it to `1` if you would rather
grind out 1.8% in gas than risk not exiting at all.

---

## If something goes wrong

| Symptom | Fix |
|---|---|
| `allowance ❌ ZERO` | Step 5 didn't land. Check the tx on Basescan. |
| `refusing to run` on startup | On-chain VAULT/ASSET don't match. Do **not** approve. Redeploy. |
| `insufficient funds` | Throwaway key is out of ETH. Send it more. |
| Repeated reverts | Someone is faster. Raise `PRIORITY_GWEI` in `.env` and restart. |
| Want to stop everything | `pkill -f exit-bot`, then `approve(exitor, 0)` on Basescan. |
