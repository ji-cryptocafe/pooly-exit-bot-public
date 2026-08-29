# The Vault That Ate Itself

### A nine-hour on-chain recovery, told straight

> **Source material for video content.** Every number here is measured, not estimated.
> Personal identifiers — wallets, contract addresses, transaction hashes, API keys — have
> been stripped. Public protocol addresses and market-wide statistics are intact, because
> they're the story.

---

## COLD OPEN

A lending market on Base has **one wei** of cash in it. Not one dollar. One millionth of a dollar.

Thirteen million USDC has been borrowed out of it. Roughly thirteen million was supplied. The difference between those two numbers is the entire problem, and about 2,800 USDC of one person's money is trapped on the wrong side of it.

The withdraw button doesn't work. It reverts with error code `14`.

What follows is what it took to get that money out, and what we found when we looked at who kept feeding the machine.

---

# ACT I — THE DIAGNOSIS

## The stack

The money wasn't in one place. It was in three, nested:

```
przUSDC   "Prize USDC - Moonwell"      PoolTogether V5 prize vault
   └─ wmUSDC   ERC4626-Wrapped Moonwell USDC
        └─ mUSDC    Moonwell USDC lending market
```

You deposit into the top. It flows to the bottom. To get out, the bottom has to have cash.

Measured state at the start:

| | |
|---|---|
| `mUSDC.getCash()` | **1 wei** (0.000001 USDC) |
| total supplied | ~13,159,000 USDC |
| total borrows | ~13,184,939 USDC |
| utilization | **100.2%** |
| `yieldVault.maxRedeem(prizeVault)` | 0 |
| `przUSDC.maxWithdraw(user)` | 0 |

A withdrawal attempt reverted with selector `0xc3096099` and argument `14`.

Compound error code 14 is `TOKEN_INSUFFICIENT_CASH`.

The market wasn't broken. It was *empty*.

## The first wrong instinct

The obvious plan is to watch the pool's page on the block explorer, see a deposit arrive, and race to withdraw.

That plan is wrong, and understanding why is the whole key.

The prize vault is not the bottleneck. The **Moonwell market underneath it** is. And liquidity reaches that market by three routes:

1. Someone deposits into the prize pool
2. Someone supplies USDC directly to Moonwell
3. **Someone repays a loan** ← with 13.18M borrowed, by far the biggest and most frequent

Watching only the pool means watching the smallest of the three doors.

## One important piece of good news

```
totalPreciseAssets  1,334,527
totalDebt           1,333,419
previewWithdraw(1e6) = 1e6
```

Assets exceeded debt. Shares still converted 1:1. This was a **liquidity** problem, not a solvency haircut. The money was all still there — it just wasn't reachable.

That distinction decides whether you're patient or panicking.

---

# ACT II — BUILDING THE WEAPON

## Why a bot alone can't do this

The naive approach: bot reads how much is withdrawable, bot sends a withdrawal for that amount.

This fails in both directions:

- Liquidity **fell** between reading and landing → transaction reverts, you get nothing
- Liquidity **rose** between reading and landing → you leave money behind

In a race decided at the block boundary, any number read off-chain is already a lie by the time your transaction executes.

So the amount has to be computed **inside the transaction itself**. That means a contract.

```solidity
function grab(uint256 minAssets) external returns (uint256) {
    uint256 max = available();                    // read at execution time
    if (max == 0 || max < minAssets) revert NothingToGrab(max, minAssets);
    ...
}
```

## The security model that made it safe

The contract was built so that the wallet holding the funds **signs exactly one transaction, ever** — a single approval — and then is never needed again. No hot wallet. No private key in a file that can touch the position.

- Target vault and asset: **compile-time constants**. Not caller-supplied, not deployer-supplied.
- Owner, receiver, slippage floor: **immutable**, fixed at deployment.
- No `call`, no `delegatecall`, no setter, no admin role, no sweep function.

The consequence: `grab()` could be made **permissionless**. Anyone can call it. The only thing it can possibly do is move the owner's position to the owner's own predetermined address. A stranger calling it just pays your gas for you.

## Three security reviews, and what they actually caught

The contract went through three external reviews. This is where it gets interesting, because the reviews were *useful* and *wrong* in roughly equal measure.

### Review finding: "the retry ladder is unjustified complexity"

The first version had a fallback: try to withdraw 100% of the available amount, and if that fails due to rounding, try 99.99%, then 99.9%, then 99%.

Rather than argue, we tested it. **40 boundary scenarios** across both liquidity routes — prime numbers, exact-position amounts, off-by-one-wei amounts.

```
scenarios tested: 40
100%-rung failures: 0
```

Never failed. Not once. PoolTogether already rounds its own limit down conservatively, so the fallback was dead code — a place for bugs to hide, dressed as resilience.

**Deleted.** The reviewer was right, and the evidence was better than the argument.

### Review finding: "delete the sweep function"

Also right, though not for the stated reason. There was no exploit — but the contract is a pass-through and never holds tokens, so a rescue function for stranded funds protected against nothing while adding an arbitrary external call. Deleted, and a test added proving zero tokens are ever stranded.

### Review finding that was flatly wrong

The headline recommendation of the third review was to bound share slippage like this:

```solidity
if (requiredShares * MIN_RATE_BPS < max * BPS) revert;
```

That comparison is **inverted**. Run the numbers at par — a perfectly healthy withdrawal:

```
requiredShares * 9999 = 9.999e12
max * 10000           = 1.0e13
9.999e12 < 1e13  →  TRUE  →  reverts a healthy exit
```

And on a 50% haircut — the exact scenario the check exists to prevent:

```
2.0e13 < 1e13  →  FALSE  →  sails straight through
```

It rejects good exits and permits catastrophic ones. A test was written to demonstrate both directions rather than assert it.

An earlier version of the same review had recommended passing `previewWithdraw(amount)` as the slippage bound. That one is a **tautology that can never revert** — the vault computes the shares it will burn with `previewWithdraw`, then compares them against a bound derived from `previewWithdraw`, in the same call, at the same block. It is `x > x`. It reads like protection and provides none.

**Lesson for the video:** security review output is not automatically security. Two of three headline recommendations across these reviews would have made the contract worse. The way to tell the difference is to run the code.

## The bug nobody flagged

Chasing one of those recommendations surfaced something real that no reviewer named.

`grab()` was permissionless — good. But the slippage floor was a **call parameter**. Meaning any stranger could call `grab(1)` and force the entire position out at *any* exchange rate.

Harmless while the vault sits at par. Catastrophic the moment a lending market socializes bad debt — which is precisely the situation this whole exercise exists inside.

Fix: the floor became **immutable**, set at deployment, overriding whatever the caller asks for. Changing it requires a redeploy — a deliberate act by the owner.

Final test count: **24 tests**, all against live chain state.

---

# ACT III — FIRST CONTACT

Contract deployed. Cost: **$0.011**. One approval signed from the cold wallet, for the exact share balance — not unlimited.

The bot went live and sat quiet.

## 09:37 — the first window, and the first loss

```
09:37:45.246  LIQUIDITY: available 1,000.67 USDC -> firing
09:37:46.029  sent
09:37:46.174  reverted (no liquidity by inclusion time)
```

Nothing recovered.

The failed transaction burned exactly 156,458 gas — the signature of the cheap early-revert path. Translation: by the time the transaction executed, the available amount was already zero.

Two things were wrong, and both were embarrassing.

**783 milliseconds** elapsed between spotting the liquidity and broadcasting. That was a pre-flight simulation call and a gas-price fetch, both round-trips.

Worse: the bot kept reporting liquidity *after* the transaction had already reverted for lack of it. The RPC endpoint was serving **stale state**. We were firing at ghosts.

## The RPC audit

Twenty-eight public Base endpoints were benchmarked — not on advertised latency, but against the bot's actual workload, from the actual machine, sampled **concurrently** so that "staleness" meant something.

(The first attempt sampled them sequentially, which made early endpoints look stale purely because the chain advanced during the test. That run was thrown out.)

Results:

| endpoint class | outcome |
|---|---|
| usable (100% reliable, 0 blocks behind) | **13 of 28** |
| hard-dead (`429`, `402`, `403`, `ENOTFOUND`, HTML instead of JSON) | 15 |
| **the endpoint we had been using** | **40% reliability, rate-limited** |

Half the public RPC infrastructure people casually depend on is either dead or lying.

Fast, correct endpoints came in at 27–52ms. Switched, added a websocket, cached gas prices in the background, dropped the pre-flight simulation.

## 09:46 — first blood

Nine minutes later:

```
✅ GRABBED ~1,013 USDC
```

First attempt after the fix. About 36% of the position, recovered in a single transaction.

---

# ACT IV — THE HUNT FOR A BETTER TRIGGER

## Can we see transactions before they're mined?

The dream: watch the mempool, see a deposit *before* it lands, and be in the same block instead of always reacting one block late.

Tested it properly. Subscribed to pending transactions — unfiltered, every transaction on the chain — for **60 seconds**.

```
alchemy_pendingTransactions  ALL      → 0 events in 60s
newPendingTransactions       standard → 0 events in 60s
```

Dead on Base. The sequencer's mempool is private; no provider can show you pending transactions.

That zero is only trustworthy because a control was run first: a subscription to a busy contract's logs returned **801 events in 12 seconds**. The harness could detect a positive. The zero was real.

**Silver lining for the story:** nobody can front-run on this chain either. The playing field is flat.

## The trigger that did work

Every route that restores liquidity — pool deposit, direct supply, loan repayment — bottoms out as **one USDC transfer into the lending market**.

One log subscription covers all three. It fires only on the real signal, and the amount rides in the payload — so the bot can broadcast without a preceding read at all.

```
⚡ USDC -> Moonwell: 5,000.00 USDC -> firing without waiting for a read
```

---

# ACT V — THE CATASTROPHE

## 12:59 — 5,753 USDC arrives, and we can't touch it

The single largest window of the day. **5,753.80 USDC** — several times more than needed to close the entire remaining position in one shot.

The bot saw it in **6 milliseconds**.

Then, roughly twenty times in a row:

```
fire error: The total cost (gas * gas fee + value) of executing this
transaction exceeds the balance of the account.
```

Every attempt was rejected **locally**. Not one of them reached the chain. The window opened, stayed open for seconds, and closed.

## The arithmetic of the failure

The transaction specified a gas limit of 1,500,000 — chosen carelessly, and **2.7× the real usage of 557,587**.

Ethereum reserves `gasLimit × maxFeePerGas` from the account up front, even though only actual gas is ever spent:

```
reserve required = 1,500,000 × 3.01 gwei = 0.004515 ETH
account balance                          = 0.003997 ETH   → REJECTED
actual cost had it run                   = 0.001678 ETH
```

**Blocked from reserving 0.0045 ETH in order to spend 0.0017 ETH.**

And the cruelest detail: this bug had been dormant for hours. It only triggered because the priority fee had been raised earlier that day to bid more aggressively. *The optimization armed the bug.*

Fix: gas limit dropped to 800,000 — measured on a fork across both code paths (partial withdraw 448,814; full exit 313,733 — the full exit is *cheaper*). Plus an affordability clamp that trims the bid to what the account can actually reserve, because a reduced bid beats no bid.

---

# ACT VI — THE QUESTION THAT FLIPPED EVERYTHING

At this point the working assumption was: *we keep losing races, so we must be getting outbid.*

That assumption was never tested. So we tested it — by pulling every single exit from the pool over 11 hours and reading what the winners actually paid.

**93 exits.** Here's what they bid:

| | priority fee | gas limit |
|---|---|---|
| rival minimum | 0.0000 gwei | 464,971 |
| **rival median** | **0.0010 gwei** | 620,616 |
| rival maximum | 0.5000 gwei | 1,685,440 |
| **us** | **3.0000 gwei** | 800,000 |

The largest exit in the dataset — **9,376 USDC** — went through at **0.001 gwei**.

We were bidding **3,000× the median and 6× the highest bid ever recorded on this pool.**

## We were never losing on price

Two distinct competing bots were visible in the data — one paying a flat 0.5 gwei with a fixed 620,616 gas limit, another cycling 0.05–0.3 gwei with a 1,350,000 limit. Everyone else was ordinary users at 0.001 gwei.

We were outbidding all of them by three orders of magnitude and *still* losing. Which proves price was never the constraint.

Every loss had been an **execution failure**:

- the stale RPC serving phantom liquidity
- the gas-reserve rejection that never broadcast at all

One more check settled it. If winners were bundling their exit **atomically** into the same block as the liquidity, we'd be structurally locked out and no amount of money would help. They weren't:

```
exit landed 0 blocks after injection:  1
exit landed 1 block  after injection:  3
exit landed 3 blocks after injection:  1
```

They were reacting, exactly like us. It was winnable — cheaply.

The bid came **down**, from 3.0 gwei to 1.0 gwei. Still double the most aggressive rival ever seen, at a third of the cost, and — critically — the smaller reserve allowed **four concurrent attempts instead of one**.

---

# ACT VII — THE KILL

Two minutes after the bid was lowered:

```
14:19:25  ⚡ USDC -> Moonwell: 5,000.00 USDC
14:19:25  bidding 1.000 gwei (gas $2.41 = 0.05% of the grab) [HIGH-VALUE tier]
14:19:27  ✅ GRABBED ~1,610 USDC | shares left 0.00
```

**Position closed.** The bot detected zero remaining shares and shut itself down.

## The audit

Not trusting the bot's own counter, every withdrawal was reconstructed from chain events:

| withdrawal | assets | shares burned | rate |
|---|---|---|---|
| 1 | ~1,013 | ~1,013 | 1.000000 |
| 2 | ~20 | ~20 | 1.000000 |
| 3 | ~163 | ~163 | 1.000000 |
| 4 | ~1,610 | ~1,610 | 1.000000 |
| **total** | **~2,806** | **~2,806** | **1.000000** |

**Recovered at exact par. Zero loss.** The slippage floor permitted up to ~0.28 USDC of shortfall. None was used.

**Total gas to recover ~$2,800: about $7.** Roughly 0.25%.

---

# ACT VIII — THE TWIST

The money got out. But one question remained, and it turned out to be the most interesting part of the whole day:

**Who kept putting USDC *into* a market nobody could withdraw from?**

Compound-style markets emit a *different event for each intent*, so this isn't guesswork. Over 22 hours:

| intent | events | volume | share |
|---|---|---|---|
| **`Mint` — supplying** | **416** | **2,395,734 USDC** | **93%** |
| `RepayBorrow` | 112 | 184,616 USDC | 7% |
| `LiquidateBorrow` | **1** | 0.11 USDC | ~0% |

Ninety-three percent of the money flowing into a drained market was people **supplying more**.

## Why anyone would do that

```
utilization      100.204%
supply APR        87.69%     (~140% APY compounded)
borrow APR        97.24%
normal rate    ≈ 3-8%        →  roughly 18× normal
```

The empty market *mechanically manufactures* a spectacular yield. Drain a lending pool and its own interest rate model starts screaming come and get it.

That rate is the bait. And the trap is that the same emptiness which creates the yield is what stops you leaving.

## Who took the bait

Every top supplier was a **contract**. All 224 bytes. Nearly all sharing an identical codehash — meaning one factory, not independent actors.

Following the proxy's implementation slot led to a verified contract:

```
ERC20MoonwellMorphoStrategy
  "splits deposits between Moonwell core market and Moonwell Vaults"
  registry: IMamoStrategyRegistry
```

**Mamo** — an automated yield product. Each depositor gets their own strategy proxy; four checked instances had four distinct human owners.

So: real people's money, but **the allocation decision was made by an automated strategy, not by a human evaluating whether the exit door works.** A bot sees 87% APR and routes capital in. That is its entire job.

The deposit amounts confirm it. Not `100000` or `50000`, the round numbers a human types. Instead: `840621.678333`, `221930.718783`, `136193.402306` — computed full-balance transfers. Machine amounts.

## The number that should end the video

**325 of 332 suppliers never withdrew a single dollar. They are holding 2,347,613 USDC inside the trap.**

New borrows during the same window: **zero**. Nobody could borrow — there was no cash to borrow.

Because every dollar those strategies supplied was consumed almost instantly by the exit queue of people trying to get *out*.

Which means, plainly: **the automated yield strategies funded our escape.** Their capital walked in the front door and straight out the back, into the hands of whoever was watching that market most closely.

They are now standing exactly where we were standing at the start of this story. Earning 87% on paper. Unable to withdraw a cent.

---

# EPILOGUE — THE HONEST CAVEAT

What is verifiable: 100.2% utilization, ~13.18M in outstanding borrows, one wei of cash, and zero new borrowing.

What is **not** verified: why. Whether that debt is bad debt or an unwind that eventually repays is a different investigation. If borrowers repay, those 325 suppliers collect an extraordinary yield and look like geniuses. If they don't, that 2.35M is the story's real casualty.

That question was not settled here, and pretending otherwise would be the one dishonest thing in an otherwise fully measured account.

---

# THE SCOREBOARD

| | |
|---|---|
| Amount trapped | ~2,800 USDC |
| Time to full recovery | ~9 hours |
| Recovery rate | **100%, exact par, zero loss** |
| Total gas spent | ~$7 (≈0.25%) |
| Successful grabs | 4 |
| Windows lost to bugs | 2 (one worth 5,753 USDC) |
| Contract bugs found in review | 3 real, 2 reviewer suggestions rejected as wrong |
| Tests written | 24, all against live chain state |
| Public RPCs tested / usable | 28 / 13 |
| Competing exit bots identified | 2 |
| Rival median bid | 0.001 gwei |
| Our peak bid (later cut) | 3.0 gwei |
| USDC supplied into the trap (22h) | 2,395,734 |
| Suppliers still stuck | **325 of 332** |
| Value still trapped | **2,347,613 USDC** |
| Advertised APR on that trapped money | **87.69%** |

---

## FIVE LESSONS WORTH NARRATING

1. **The bottleneck is rarely where the interface says it is.** The pool page was the wrong thing to watch. Three layers down was the real constraint.
2. **A number read off-chain is already a lie.** In a race, only on-chain computation is true.
3. **Optimizations arm latent bugs.** Raising the bid was correct — and it detonated a dormant gas-limit mistake that cost the largest window of the day.
4. **Test the assumption before tuning against it.** Everyone "knew" we were being outbid. We were outbidding the field 3,000-to-1 and losing to our own bugs.
5. **A high yield is a description of a problem, not a reward.** 87% APR wasn't generosity. It was the sound of an empty room.
