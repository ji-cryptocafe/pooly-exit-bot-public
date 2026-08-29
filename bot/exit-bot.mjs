#!/usr/bin/env node
/**
 * pooly-exit-bot -- drains a stuck przUSDC (PoolTogether V5 / Moonwell) position
 * the instant the underlying Moonwell mUSDC market has cash again.
 *
 * The bot never decides *how much* to withdraw. It only decides *when to fire*.
 * The amount is computed on-chain inside PoolExitor.grab(), so a tx that lands a
 * block later than intended still takes whatever is actually there.
 *
 * It talks to a single Base RPC endpoint and polls. That is all it needs.
 */
import 'dotenv/config';
import {
  createPublicClient, createWalletClient, http, formatUnits,
  formatEther, parseUnits,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { base } from 'viem/chains';
import { EXITOR_ABI, MTOKEN_ABI, ERC20_ABI } from './abi.mjs';

const DRY = process.argv.includes('--dry-run');

const cfg = {
  exitor:      req('EXITOR_ADDRESS'),
  vault:       process.env.VAULT_ADDRESS || '0x7f5C2b379b88499aC2B997Db583f8079503f25b9',
  mToken:      process.env.MTOKEN_ADDRESS || '0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22',
  rpcHttp:    (process.env.BASE_RPC_URL || 'https://mainnet.base.org').trim(),
  minAssets:   parseUnits(process.env.MIN_ASSETS_USDC || '5', 6),
  prioMinGwei: process.env.PRIORITY_MIN_GWEI || '0.01',
  prioMaxGwei: process.env.PRIORITY_MAX_GWEI || '1.0',
  prioMaxHighGwei: process.env.PRIORITY_MAX_HIGH_GWEI || '3.0',
  highBidUsd:  Number(process.env.HIGH_BID_THRESHOLD_USD || '500'),
  gasUnits:    BigInt(process.env.GAS_UNITS || '600000'), // measured: real grab used 557,587
  // Gas LIMIT is not just a ceiling: the chain reserves limit x maxFeePerGas from the
  // account up front. An inflated limit therefore makes high bids unaffordable even when
  // the real cost is trivial. 800k = 1.43x measured usage.
  gasLimit:    BigInt(process.env.GAS_LIMIT || '800000'),
  maxGasEth:   Number(process.env.MAX_GAS_SPEND_ETH || '0.02'),
  pollMs:      Number(process.env.POLL_MS || '500'),
  heartbeatMs: Number(process.env.HEARTBEAT_MS || '600000'), // proof-of-life every 10 min
  maxGasPct:   Number(process.env.MAX_GAS_PCT || '2'),   // skip if gas > this % of the grab
  ethUsd:      Number(process.env.ETH_USD || '4000'),    // only used for that ratio
  blindMs:     Number(process.env.BLIND_FIRE_MS || '0'), // 0 = off
  simulate:    process.env.SKIP_SIMULATION !== 'true',
};

function req(k) {
  const v = process.env[k];
  if (!v) { console.error(`missing env ${k} (copy .env.example -> .env)`); process.exit(1); }
  return v;
}
const usdc = (v) => `${Number(formatUnits(v, 6)).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 6 })} USDC`;
const ts = () => new Date().toISOString().slice(11, 23);
const log = (...a) => console.log(`[${ts()}]`, ...a);

const transport = http(cfg.rpcHttp, { batch: true, retryCount: 2 });
const pub = createPublicClient({ chain: base, transport });
const account = DRY ? null : privateKeyToAccount(req('BOT_PRIVATE_KEY'));
const wallet = DRY ? null : createWalletClient({ account, chain: base, transport });

let inflight = false;
let gasSpent = 0n;
let recovered = 0n;
let attempts = 0, wins = 0;
let lastBlind = 0;
// Health counters. Without these a silently failing RPC is indistinguishable from an
// idle chain -- both just print nothing.
let polls = 0, readOk = 0, readFail = 0, consecFail = 0, lastBeat = Date.now();
let lastErr = '';
// Fees are refreshed in the background. Fetching them inside fire() adds a full RPC
// round-trip between spotting liquidity and broadcasting.
let baseFeeWei = 5_000_000n;
let gasBalWei = 0n;
async function refreshFees() {
  try {
    const [b, bal] = await Promise.all([
      pub.getBlock({ blockTag: 'latest' }),
      account ? pub.getBalance({ address: account.address }) : Promise.resolve(0n),
    ]);
    if (b.baseFeePerGas) baseFeeWei = b.baseFeePerGas;
    gasBalWei = bal;
  } catch {}
}

// Bid in proportion to what is actually at stake. A flat priority fee is wrong in both
// directions: too timid to win a 1,000 USDC window, and so expensive that a 10 USDC
// window can never clear the efficiency cap. Derive the fee from the MAX_GAS_PCT budget
// for THIS opportunity, then clamp.
function priorityFor(worthUsd) {
  const min = parseUnits(cfg.prioMinGwei, 9);
  // Two-tier ceiling: bid hard only when the window is genuinely worth fighting for.
  // A big window justifies an expensive bid because the fee is a tiny share of it
  // ($7.21 on a 1,000 USDC grab is 0.72%); the same bid on a small window is not worth it.
  const max = parseUnits(
    worthUsd >= cfg.highBidUsd ? cfg.prioMaxHighGwei : cfg.prioMaxGwei, 9);
  if (!worthUsd) return min;
  const budgetWei = BigInt(Math.floor((worthUsd * cfg.maxGasPct / 100 / cfg.ethUsd) * 1e18));
  let prio = budgetWei / cfg.gasUnits - baseFeeWei;
  if (prio < min) prio = min;
  if (prio > max) prio = max;
  return prio;
}

// Suppress identical repeated lines -- a standing opportunity we keep declining used to
// print the same pair of lines every 2s forever.
let lastMsg = '', lastMsgAt = 0, suppressed = 0;
function logOnce(msg) {
  const now = Date.now();
  if (msg === lastMsg && now - lastMsgAt < 60000) { suppressed++; return; }
  if (suppressed && msg !== lastMsg) { log(`(… ${suppressed} identical lines suppressed)`); }
  suppressed = 0; lastMsg = msg; lastMsgAt = now;
  log(msg);
}
// Stale-read detector: a lagging RPC reports liquidity that is already gone.
let lastBlock = 0n, blockStuckSince = Date.now();

async function readState() {
  const [preview, cash, block] = await Promise.all([
    pub.readContract({ address: cfg.exitor, abi: EXITOR_ABI, functionName: 'preview' }),
    pub.readContract({ address: cfg.mToken, abi: MTOKEN_ABI, functionName: 'getCash' }),
    pub.getBlockNumber({ cacheTime: 0 }),
  ]);
  return { avail: preview[0], sharesLeft: preview[1], cash, block };
}

async function fire(reason, avail = 0n, minAssets = cfg.minAssets) {
  if (inflight) return;
  if (Number(formatEther(gasSpent)) >= cfg.maxGasEth) {
    log(`gas cap ${cfg.maxGasEth} ETH reached -- standing down`); process.exit(0);
  }
  inflight = true;
  attempts++;
  try {
    const args = [minAssets];
    const common = { address: cfg.exitor, abi: EXITOR_ABI, functionName: 'grab', args };

    if (DRY) {
      const { result } = await pub.simulateContract({ ...common, account: '0x0000000000000000000000000000000000000001' });
      log(`DRY-RUN would grab ${usdc(result)}  (${reason})`);
      return;
    }

    if (cfg.simulate) {
      // Cheap correctness gate. Skip it (SKIP_SIMULATION=true) to shave a round-trip
      // when you would rather pay for a revert than lose the race.
      try {
        await pub.simulateContract({ ...common, account });
      } catch {
        return; // nothing there this block
      }
    }

    const worthUsd = avail > 0n ? Number(formatUnits(avail, 6)) : 0;
    let prio = priorityFor(worthUsd);

    // Affordability clamp. The node rejects a tx unless the account holds
    // gasLimit * maxFeePerGas, so a bid we cannot reserve is not a bid at all -- it is a
    // silent no-op at exactly the moment a big window is open. Bid what we can actually
    // cover instead of being rejected outright.
    if (gasBalWei > 0n) {
      const affordableGasPrice = (gasBalWei * 90n / 100n) / cfg.gasLimit;
      const floorFee = baseFeeWei * 2n;
      if (floorFee + prio > affordableGasPrice) {
        const reduced = affordableGasPrice > floorFee ? affordableGasPrice - floorFee : 0n;
        if (reduced < parseUnits(cfg.prioMinGwei, 9)) {
          logOnce(`⚠  GAS TOO LOW: balance ${formatEther(gasBalWei)} ETH cannot reserve ${cfg.gasLimit} gas -- TOP UP ${account.address}`);
          return;
        }
        log(`⚠  bid trimmed ${(Number(prio)/1e9).toFixed(3)} -> ${(Number(reduced)/1e9).toFixed(3)} gwei to stay affordable (balance ${formatEther(gasBalWei)} ETH)`);
        prio = reduced;
      }
    }
    const costUsd = Number(formatEther(cfg.gasUnits * (baseFeeWei + prio))) * cfg.ethUsd;

    // Safety net only: with a proportional bid this should essentially never trigger,
    // because the fee was chosen to fit the budget in the first place.
    if (worthUsd > 0 && costUsd > worthUsd * cfg.maxGasPct / 100) {
      logOnce(`holding: even at min bid, gas $${costUsd.toFixed(3)} is ${((costUsd/worthUsd)*100).toFixed(1)}% of ${usdc(avail)} (cap ${cfg.maxGasPct}%)`);
      return;
    }
    const tier = worthUsd >= cfg.highBidUsd ? ' [HIGH-VALUE tier]' : '';
    log(`bidding ${(Number(prio) / 1e9).toFixed(3)} gwei for ${usdc(avail)} (gas ~$${costUsd.toFixed(3)}, ${worthUsd ? ((costUsd/worthUsd)*100).toFixed(2) : '?'}%)${tier}`);

    const fees = { maxFeePerGas: baseFeeWei * 2n };
    const hash = await wallet.writeContract({
      ...common,
      gas: cfg.gasLimit,
      maxPriorityFeePerGas: prio,
      maxFeePerGas: fees.maxFeePerGas + prio,
    });
    log(`sent ${hash}  (${reason})`);

    const rcpt = await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
    gasSpent += rcpt.gasUsed * rcpt.effectiveGasPrice + (rcpt.l1Fee ?? 0n);

    if (rcpt.status === 'success') {
      wins++;
      const ev = rcpt.logs
        .filter((l) => l.address.toLowerCase() === cfg.exitor.toLowerCase())
        .map((l) => { try { return decodeGrabbed(l); } catch { return null; } })
        .find(Boolean);
      if (ev) {
        recovered += ev.assets;
        log(`✅ GRABBED ${usdc(ev.assets)} | total recovered ${usdc(recovered)} | shares left ${usdc(ev.sharesLeft)}`);
        if (ev.sharesLeft === 0n) {
          log(`position fully exited. gas spent ${formatEther(gasSpent)} ETH over ${attempts} attempts.`);
          process.exit(0);
        }
      } else log('✅ tx succeeded (no Grabbed event decoded)');
    } else {
      log(`reverted (no liquidity by inclusion time) -- gas ${formatEther(rcpt.gasUsed * rcpt.effectiveGasPrice)} ETH`);
    }
  } catch (e) {
    logOnce('fire error: ' + String(e.shortMessage || e.message || e).split('\n')[0].slice(0, 150));
  } finally {
    inflight = false;
  }
}

import { decodeEventLog } from 'viem';
function decodeGrabbed(l) {
  const d = decodeEventLog({ abi: EXITOR_ABI, data: l.data, topics: l.topics });
  if (d.eventName !== 'Grabbed') throw new Error('other');
  return d.args;
}

async function onTick(tag) {
  polls++;
  let s;
  try {
    s = await readState();
    readOk++;
    if (consecFail >= 5) log(`✅ RPC recovered after ${consecFail} consecutive failures`);
    consecFail = 0;
  } catch (e) {
    readFail++; consecFail++;
    lastErr = String(e.shortMessage || e.message || e).slice(0, 140);
    // Escalate loudly rather than failing quietly: at 5, then every 200 in a row.
    if (consecFail === 5 || (consecFail > 5 && consecFail % 200 === 0)) {
      log(`⚠  RPC read failing (${consecFail} in a row) -- BOT IS BLIND: ${lastErr}`);
    }
    return;
  } finally {
    if (Date.now() - lastBeat >= cfg.heartbeatMs) {
      lastBeat = Date.now();
      const pct = polls ? ((readOk / polls) * 100).toFixed(1) : '0';
      const st = s ? `available ${usdc(s.avail)} | mUSDC cash ${usdc(s.cash)}` : 'state unavailable';
      log(`heartbeat: ${polls} polls, ${pct}% ok${readFail ? `, ${readFail} failed` : ''} | ${st}`);
    }
  }
  if (s.block !== undefined) {
    if (s.block > lastBlock) { lastBlock = s.block; blockStuckSince = Date.now(); }
    else if (Date.now() - blockStuckSince > 20000) {
      log(`⚠  RPC head stuck at ${lastBlock} for ${((Date.now()-blockStuckSince)/1000).toFixed(0)}s -- reads may be STALE`);
      blockStuckSince = Date.now();
    }
  }
  if (s.sharesLeft === 0n) { log('no shares left -- done.'); process.exit(0); }

  if (s.avail >= cfg.minAssets) {
    if (!inflight) logOnce(`LIQUIDITY: available ${usdc(s.avail)} | mUSDC cash ${usdc(s.cash)}`);
    await fire(tag, s.avail);
  } else if (cfg.blindMs && Date.now() - lastBlind > cfg.blindMs) {
    // Lottery ticket: liquidity that appears and vanishes between our reads is only
    // catchable by already having a tx in flight. A dry grab() reverts for ~158k gas.
    lastBlind = Date.now();
    await fire('blind');
  }
}

async function main() {
  log(`pooly-exit-bot  ${DRY ? '(DRY RUN)' : ''}`);
  // Preflight: read every immutable off-chain-verifiable value and refuse to run against
  // a contract that does not target exactly the expected vault and asset. Never trust the
  // deployment script's console output for this.
  const rd = (fn) => pub.readContract({ address: cfg.exitor, abi: EXITOR_ABI, functionName: fn });
  const [owner, receiver, vaultOnChain, assetOnChain, minRateBps] =
    await Promise.all([rd('OWNER'), rd('RECEIVER'), rd('VAULT'), rd('ASSET'), rd('MIN_RATE_BPS')]);

  const EXPECTED_VAULT = '0x7f5C2b379b88499aC2B997Db583f8079503f25b9';
  const EXPECTED_ASSET = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
  const eq = (a, b) => a.toLowerCase() === b.toLowerCase();
  if (!eq(vaultOnChain, EXPECTED_VAULT) || !eq(assetOnChain, EXPECTED_ASSET)) {
    log(`❌ exitor targets vault=${vaultOnChain} asset=${assetOnChain} -- refusing to run.`);
    process.exit(1);
  }
  const allowance = await pub.readContract({
    address: cfg.vault, abi: ERC20_ABI, functionName: 'allowance', args: [owner, cfg.exitor] });
  const s = await readState();

  log(`exitor    ${cfg.exitor}`);
  log(`owner     ${owner}`);
  log(`receiver  ${receiver}`);
  log(`position  ${usdc(s.sharesLeft)} przUSDC`);
  log(`allowance ${allowance === 0n ? '❌ ZERO -- owner must approve the exitor first!' : '✅ set'}`);
  log(`vault     ${vaultOnChain} ✅ verified`);
  log(`rate floor ${Number(minRateBps) / 100}% of par (immutable -- a stranger cannot loosen it)`);
  log(`threshold ${usdc(cfg.minAssets)} (floor) + gas must stay under ${cfg.maxGasPct}% of the grab`);
  log(`bid ${cfg.prioMinGwei}-${cfg.prioMaxGwei} gwei, up to ${cfg.prioMaxHighGwei} gwei above $${cfg.highBidUsd} | gas cap ${cfg.maxGasEth} ETH`);
  log(`rpc       ${cfg.rpcHttp}`);
  log(`mUSDC cash ${usdc(s.cash)} | available ${usdc(s.avail)}`);
  if (allowance === 0n && !DRY) { log('refusing to start without allowance.'); process.exit(1); }

  // A single RPC, polled. At 500ms this is faster than Base's ~2s block cadence, so it
  // catches liquidity within a block of it appearing without any extra infrastructure.
  await refreshFees();
  setInterval(refreshFees, 5000);
  setInterval(() => onTick('poll'), cfg.pollMs);
  log(`polling every ${cfg.pollMs}ms | heartbeat every ${cfg.heartbeatMs / 60000} min -- waiting for liquidity...`);
}

main().catch((e) => { console.error(e); process.exit(1); });
