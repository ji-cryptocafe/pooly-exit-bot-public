# pooly-exit-bot — technical notes

> New here? Start with the plain-English **[README](README.en.md)** and the step-by-step
> **[DEPLOY](DEPLOY.en.md)** guide (or the German **[README](README.md)** / **[DEPLOY](DEPLOY.md)**).
> This file is the deep dive: the diagnosis, the design decisions, and how every claim was tested.

Opportunistic exit from a stuck **przUSDC** (PoolTogether V5 "Prize USDC - Moonwell") position on Base.

Position: `0xYOUR_WALLET_ADDRESS` — **your stuck przUSDC balance**

---

## Diagnosis (measured on Base at block ~50,558,241)

The pool is a three-layer stack:

```
przUSDC  0x7f5C2b379b88499aC2B997Db583f8079503f25b9   PrizeVault, 1,333,419 USDC of deposits
  └─ wmUSDC  0xbc8dD54d1AE1B738b40FfddCCEe1428B178fA80B   ERC4626-Wrapped Moonwell USDC
       └─ mUSDC  0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22   Moonwell USDC market
```

Measured state:

| | |
|---|---|
| `mUSDC.getCash()` | **1 wei** (0.000001 USDC) |
| `mUSDC` total supplied | ~13,159,000 USDC |
| `mUSDC` total borrows | ~13,184,939 USDC |
| `yieldVault.maxRedeem(przUSDC)` | 0 |
| `przUSDC.maxWithdraw(you)` | 0 |

A `withdraw` today reverts with `0xc3096099` + arg `14` — Compound error code 14,
`TOKEN_INSUFFICIENT_CASH`. The market is at 100% utilisation.

**The pool is not the bottleneck — the Moonwell market is.** This matters for the bot design:

- Watching only przUSDC deposits (the basescan tokentxns page) is the *wrong trigger*. Pool
  deposits are a minor liquidity source.
- The real trigger is `mUSDC.getCash()` rising, which happens on **any** USDC supply *or
  loan repayment* on Moonwell. With 13.18M USDC borrowed, repayments are by far the biggest
  and most frequent source.
- This bot triggers on the actual constraint, so it catches both.

Solvency note: `totalPreciseAssets` (1,334,527) > `totalDebt` (1,333,419). The vault is **not**
lossy — shares still convert 1:1. This is a *liquidity* problem, not a *solvency* haircut.
`previewWithdraw(1e6) == 1e6`.

---

## Design

### Why a contract, not just a bot calling `withdraw()`

The withdrawable amount is set by third-party liquidity and changes every block. Any amount
your bot reads off-chain is already stale when the tx lands:

- liquidity fell -> your tx **reverts** and you get nothing
- liquidity rose -> you **leave money behind**

`PoolExitor.grab(minAssets)` reads `maxWithdraw` and executes in the *same transaction*.

### Security model

- `VAULT` and `ASSET` are **compile-time constants**. Nothing about the target is caller-,
  deployer-, or governance-supplied, so a fat-fingered deploy cannot point it elsewhere.
- `OWNER`, `RECEIVER`, `MIN_RATE_BPS` are **immutable**, fixed at construction.
- There is **no** `call`, `delegatecall`, setter, owner role, sweep, or token parameter
  anywhere. The only external calls the contract can make are to the one hardcoded vault.
- `grab()` is therefore permissionless *by construction*: the sole state change it can cause
  is OWNER's position -> RECEIVER, at no worse than `MIN_RATE_BPS`. A stranger calling it
  just pays your gas.

**You do not need a hot wallet.** Leave the przUSDC where it is, sign one `approve`, point
`RECEIVER` at a cold address. The bot key is gas-only and can never touch the position.

### `MIN_RATE_BPS` is immutable on purpose

This is the slippage floor, and it is deliberately **not** a call parameter. `grab()` is
permissionless, so a caller-supplied floor would let any stranger force the position out at
an arbitrarily bad rate. That matters precisely because the premise here is a compromised
lending market: if Moonwell socialises bad debt, przUSDC becomes lossy and an unbounded exit
would realise that loss on your behalf. Changing the floor requires a redeploy -- a
deliberate act by the owner. See `test_11` / `test_12`.

`9999` = accept at most 0.01% below par: enough to absorb ERC-4626 share rounding, not
enough to absorb a real haircut.

### No retry ladder

An earlier version stepped 100% -> 99.99% -> 99.9% -> 99% on failure. Measured over 40
boundary scenarios across both liquidity routes (`test/LadderNecessity.t.sol`),
`withdraw(maxWithdraw(owner))` **never once failed** -- PoolTogether's `maxWithdraw` already
rounds down conservatively. A fallback that never fires is not resilience, it is a place for
bugs to hide. Removed.

The full-exit `redeem`-by-shares branch stays, for one measured reason: withdrawing by asset
amount rounds shares up and can strand a wei, which would keep the bot running forever
against an empty position (`test_16`).

---

## Verification

`forge test` -- 18 tests, all against **live Base state** at fork time.

**Function** (`test/PoolExitor.t.sol`)

```
test_01 currentlyStuck          position is real (your full balance) and maxWithdraw == 0
test_02 grabRevertsWhenDry      no-op when there is no cash
test_03 partialExitFromMoonwellSupply   500 supplied to Moonwell -> 500 recovered
test_04 partialExitFromPoolDeposit      1000 deposited to pool   -> 999.999999 recovered
test_05 fullExit                10k windfall -> whole position out, 0 shares left
test_06 incrementalDrain        8 x 400 windfalls -> fully drained
test_07 thresholdEnforced       minAssets enforced on-chain
test_08 permissionlessButSafe   stranger's call still sends funds to RECEIVER
```

**Adversarial** (`test/Adversarial.t.sol`)

```
test_09 immutablesAndConstants          every reachable address is fixed
test_10 constructorRejectsBadInput      zero addrs and nonsense rates revert at deploy
test_11 lossyVault_strangerCannotForce...  50%-lossy vault: stranger's grab(1) REVERTS
test_12 strangerCannotLowerTheFloor     expectCall proves the immutable floor reaches the vault
test_13 reentrancyBlocked               re-entrant grab reverts
test_14 exitorNeverHoldsFunds           0 USDC and 0 shares stranded (why there is no sweep)
test_15 liquidityVanishesBeforeInclusion  faster bot takes it first -> fails closed, position intact
test_16 fullExitLeavesNoDust            lands on exactly 0 shares
test_17 previewWithdrawAsMaxSharesIsATautology   see below
```

**Ladder necessity** (`test/LadderNecessity.t.sol`): 40 scenarios, 0 failures of the naive path.

**Live integration** (anvil fork, bot + contract together, end to end):

```
GRABBED 800.00 USDC    | shares left …          <- 3rd-party pool deposit
GRABBED 900.00 USDC    | shares left …          <- 3rd-party Moonwell supply
GRABBED (final chunk)  | shares left 0.00
position fully exited. gas spent 0.0000743 ETH over 3 attempts. exitor holds 0.
```

---

## Response to external review

Adopted:

| Item | Status |
|---|---|
| Delete `sweep()` | Done. Contract is a pass-through; `test_14` proves nothing is ever stranded. |
| Hardcode VAULT/USDC as constants | Done. Constructor now takes only `owner, receiver, minRateBps`. |
| Constructor validation | Done -- zero-address and rate-sanity checks (`test_10`). |
| Drop the retry ladder | Done, on evidence: 0/40 failures of the naive path. |
| Adversarial fork tests | Done -- 9 of them. |
| Verify immutables before approving | Done -- `Deploy.s.sol` prints the exact `cast` commands, and the **bot refuses to start** unless the on-chain `VAULT`/`ASSET` match. |
| OWNER is the cold wallet, not the bot | Fixed the misleading comment in `Deploy.s.sol`. |
| Reentrancy guard | Added. Not strictly needed (VAULT is a constant, no untrusted callback exists) but it is 2.9k gas and ends the argument. |

Declined, with reasons:

**`maxShares = VAULT.previewWithdraw(amt)`** -- this was the review's headline fix. It is a
**tautology that can never revert**: the vault computes the shares it will burn with
`previewWithdraw`, then compares them against a bound derived from `previewWithdraw` at the
same block in the same call. It is `x > x`. `test_17` demonstrates it letting a 50%-lossy
vault burn 2,000 shares for 1,000 USDC while the immutable par-referenced floor refuses the
same call. Real slippage protection needs an **external** reference; the vault's own current
quote is not one.

**Remove the unused `ASSET`** -- kept. It is a `constant`, so it costs no storage and no
deploy gas, and the bot reads it during preflight as on-chain deployment verification.

Also worth noting: the review's items on "trigger on `maxWithdraw`, not Moonwell cash",
"use the native `minAssets` overload", "don't blind-fire every 30s", and "start with
simulation on" were all already the behaviour in the code -- they were inferred from prose,
not from the source. `mUSDC.getCash()` has only ever been a log line.

The one genuinely new **security** finding did not come from either review directly: because
`grab()` is permissionless, a *caller-supplied* slippage bound is a griefing vector -- any
stranger could force a haircut exit. That is what `MIN_RATE_BPS` being immutable fixes.

---

## Runbook

```bash
cd pooly-exit-bot-public
cp .env.example .env      # fill it in
forge test                # re-verify against current chain state
```

**1. Deploy** (`OWNER` = wallet holding przUSDC, `RECEIVER` = where USDC should land):

```bash
forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --broadcast
```

**2. Approve, once, from the wallet holding the shares.** This is the only tx that wallet ever signs:

```bash
cast send 0x7f5C2b379b88499aC2B997Db583f8079503f25b9 \
  "approve(address,uint256)" <EXITOR> \
  0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  --rpc-url $BASE_RPC_URL --private-key <OWNER_KEY>
```

**3. Fund the bot key** with ~0.01 ETH on Base for gas. Nothing else.

**4. Dry run**, then go live:

```bash
npm run watch    # --dry-run: reports what it would grab, sends nothing
npm run bot
```

The bot exits by itself once the position hits zero shares.

### Tuning

| var | effect |
|---|---|
| `MIN_ASSETS_USDC` | Don't fire below this. `5` is sane; lower it if you'd rather nibble. |
| `PRIORITY_GWEI` | The race is decided here. Start `0.05`; raise if you see reverts. |
| `SKIP_SIMULATION=true` | Drops a pre-flight `eth_call` round-trip. Wins more races, pays for more reverts (~158k gas each, well under a cent). |
| `BLIND_FIRE_MS` | Fire unconditionally every N ms. Catches liquidity that appears *and vanishes* between two reads. `30000` ≈ $9/day at current Base fees. |

---

## Honest expectations

- **You are racing ~13.16M USDC of other claims** on the same cash — every Moonwell USDC
  supplier, not just pool participants. A position this size is a tiny fraction of that.
- That smallness is an **advantage**: you fill from windfalls too small to matter to anyone
  else, and `test_06` shows the position drains incrementally across many small hits. You do
  not need one big exit.
- **Other people are running the same play.** Some will have faster infrastructure.
  Raising `PRIORITY_GWEI` is the main lever you have to stay competitive.
- **This does not recover anything if Moonwell's bad debt is never repaid.** If borrowers are
  underwater and never repay, cash never returns and no bot helps. Watch the Moonwell
  governance/recovery process in parallel — that, not this bot, decides whether the money
  exists at all.
- A secondary option worth pricing separately: selling przUSDC on-chain at a discount, if
  anyone is bidding. That is an instant exit at a known loss versus this bot's slow exit at par.
