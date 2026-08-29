# pooly-exit-bot

A small bot that automatically rescues money stuck in a **przUSDC** position
(PoolTogether V5 "Prize USDC – Moonwell") on the Base network.

If your withdraw button just reverts and your funds feel frozen, this is for you.

---

## What's going on (in plain English)

Your USDC is deposited in a savings pool. That pool lends the money out to a
lending market (Moonwell). Right now **almost everyone has borrowed and nobody
has repaid**, so there is no cash sitting in the market to pay you back. That's
why "withdraw" fails — the money isn't gone, it's just *unavailable this second*.

Cash briefly reappears whenever **someone repays a loan or adds new funds** — but
it vanishes again in seconds because other people are waiting for it too.

**This bot watches the market around the clock and grabs your share the instant
cash appears** — faster than you could ever do by hand. It keeps nibbling away,
a little at a time, until your whole position is out.

---

## Is my money safe? (yes — here's why)

You never hand your funds or your main wallet's password to anything.

- You sign **one** approval, once, from the wallet that holds the money.
- That approval lets a tiny, purpose-built contract move **only your stuck
  position**, and **only** to an address you choose (your own wallet, or a cold
  wallet). It physically cannot send your money anywhere else, and it cannot be
  changed after setup.
- The bot itself runs on a **separate throwaway key** that only ever pays gas
  fees. If someone stole that key tomorrow, all they'd get is a few dollars of
  leftover gas — never your position.

The full security reasoning is in **[TECHNICAL.md](TECHNICAL.md)**.

---

## What you'll need

- A computer (Mac, Windows, or Linux) you can leave running.
- The wallet (e.g. MetaMask) that holds the stuck przUSDC.
- About **0.01 ETH on the Base network** for gas — a few dollars.
- 20–30 minutes, once.

You do **not** need to be a programmer. The detailed guide holds your hand
through every command.

---

## How to do it — the short version

Each step below links to the exact commands in **[DEPLOY.md](DEPLOY.md)**.
Follow that guide top to bottom; this list is just the map.

1. **Get the code onto your computer.**
   ```bash
   git clone https://github.com/ji-cryptocafe/pooly-exit-bot-public.git
   cd pooly-exit-bot-public
   npm install
   ```

2. **Create a throwaway "gas" key.** One command (`./newkey.sh`) makes a brand-new
   key that can only pay fees. Your real wallet is never involved. → *DEPLOY Step 1*

3. **Fill in the settings.** Copy `.env.example` to `.env` and paste in your wallet
   address and the network endpoint (a working default is already provided).
   → *DEPLOY Step 1*

4. **Send a few dollars of ETH** (on Base) to the throwaway key so it can pay gas.
   → *DEPLOY Step 2*

5. **Deploy the little rescue contract** with `./deploy.sh`. It shows you every
   value and waits for you to type `YES` before spending anything. → *DEPLOY Step 3*

6. **Double-check it, then approve once** from your real wallet, in your browser on
   Basescan. This is the only time your main wallet signs anything. → *DEPLOY Steps 4–5*

7. **Start the bot** with `npm run bot` and leave it running. It reports what it's
   doing, and **shuts itself off automatically** the moment your position is fully
   recovered. → *DEPLOY Step 6*

> Tip: run `npm run watch` first — a safe "dry run" that shows what the bot *would*
> do without sending any transaction.

---

## Will it definitely work?

It gets your money out **as soon as the market has cash to pay you** — and it will
beat almost anyone doing it manually. But be realistic:

- If borrowers **never** repay, cash never returns, and no bot on earth can help.
  That part is out of everyone's hands.
- Other people run similar bots. You can spend a little more on gas priority to win
  more often (see the tuning notes in [DEPLOY.md](DEPLOY.md)).

This is a tool, not financial advice. Read what it does, verify the contract before
you approve it, and use it at your own risk.

---

## The three docs

| File | For |
|---|---|
| **README.md** (this file) | What it is and the big picture. |
| **[DEPLOY.md](DEPLOY.md)** | The exact, click-by-click walkthrough. Start here to actually run it. |
| **[TECHNICAL.md](TECHNICAL.md)** | The deep dive: the diagnosis, the design, and how every claim was tested. |
