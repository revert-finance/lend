#!/usr/bin/env python3
"""Chainlink round walk for the Coinbase equity feeds (plan WP3 bucket 2 / proposal §2.5).

For each feed: resolve the aggregator behind the proxy, walk `getRoundData` back ROUNDS rounds with
batched JSON-RPC, and report every gap > 12h (weekend, holiday, weekday), the current staleness, and
the live feed-vs-pool divergence (one sample; run from cron overnight to accumulate).

Env: BASE_RPC_URL or ALCHEMY_API_KEY; ROUNDS (default 400); BLOCK (default latest).
Output: results/feed_roundwalk-<block>.json and a summary on stdout. Exit 1 if any feed is stale beyond
maxFeedAge (108000s) or any live divergence exceeds 3%.
"""
import json, math, os, sys, time, urllib.request
from datetime import datetime, timezone, timedelta

RPC = os.environ.get("BASE_RPC_URL") or (
    "https://base-mainnet.g.alchemy.com/v2/" + os.environ["ALCHEMY_API_KEY"])
ROUNDS = int(os.environ.get("ROUNDS", "400"))
MAX_FEED_AGE = 108_000
MAX_DIFFERENCE = 0.03
GAP_THRESHOLD = 12 * 3600
ET = timezone(timedelta(hours=-4))  # EDT; good enough for session labelling

# symbol, token, feed proxy, pool (token0 == USDC, token1 == equity)
EQUITIES = [
    ("AAPLc", "0xb200000000000000000000C2e324d24d7eEcd1fb", "0x787f13dEa48Db0897CbCDD985de77809D837F988", "0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0"),
    ("MSFTc", "0xB200000000000000000000Ab99cFa739E253872B", "0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c", "0x7103eB3c9590d1281f7dc03b2A9EE27C39dF5D54"),
    ("GOOGLc", "0xb2000000000000000000002D0BA3164cc74f58B7", "0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2", "0xB1987CAD1682841b4b641d50E520777eC5Ab5542"),
    ("AMZNc", "0xb200000000000000000000d9192b6B456483C2E8", "0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295", "0xd03Bc8C7F2FAedCe2aac81bF0444AEA08Ea06E9b"),
    ("METAc", "0xb2000000000000000000008bC8786B856E61707C", "0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D", "0xEAF57753BC382E0324a1D43F72E7027705a2273E"),
    ("NVDAc", "0xb20000000000000000000078ee7ce2fE4908108C", "0x04689a41629776563E6822F76f2e57D148d28513", "0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9"),
    ("TSLAc", "0xb2000000000000000000001e800a7f5189430cD0", "0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4", "0x469337fDcc5E8f38e2E4B670B04F57865D13a7BB"),
]
USDC_FEED = "0x7e860098F58bBFC8648a4311b374B1D669a2bc6B"

SEL = {  # function selectors
    "aggregator()": "0x245a7bfc", "latestRound()": "0x668a0f02", "getRoundData(uint80)": "0x9a6fc8f5",
    "latestRoundData()": "0xfeaf968c", "multiplier()": "0x1b3ed722", "slot0()": "0x3850c7bd",
}


def rpc(batch):
    req = urllib.request.Request(RPC, data=json.dumps(batch).encode(), headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        res = json.loads(r.read())
    res.sort(key=lambda x: x["id"])
    return res


def call(to, data, block):
    return {"jsonrpc": "2.0", "id": 0, "method": "eth_call", "params": [{"to": to, "data": data}, block]}


def word(hexdata, i):
    return int(hexdata[2 + 64 * i: 2 + 64 * (i + 1)], 16)


def sword(hexdata, i):
    v = word(hexdata, i)
    return v - (1 << 256) if v >= 1 << 255 else v


def main():
    block_hex = os.environ.get("BLOCK")
    if not block_hex:
        block_hex = rpc([{"jsonrpc": "2.0", "id": 0, "method": "eth_blockNumber", "params": []}])[0]["result"]
    block = int(block_hex, 16)
    blk = rpc([{"jsonrpc": "2.0", "id": 0, "method": "eth_getBlockByNumber", "params": [block_hex, False]}])[0]["result"]
    now = int(blk["timestamp"], 16)

    # phase 1: aggregator + latestRound + live data per feed, multiplier + slot0 per token/pool
    b = []
    for i, (sym, token, feed, pool) in enumerate(EQUITIES):
        b += [call(feed, SEL["aggregator()"], block_hex), call(token, SEL["multiplier()"], block_hex),
              call(pool, SEL["slot0()"], block_hex), call(feed, SEL["latestRoundData()"], block_hex)]
    b.append(call(USDC_FEED, SEL["latestRoundData()"], block_hex))
    for j, q in enumerate(b):
        q["id"] = j
    r1 = rpc(b)
    usdc_rd = r1[-1]["result"]
    usdc_price = word(usdc_rd, 1) / 1e8
    usdc_updated = word(usdc_rd, 3)

    feeds = []
    for i, (sym, token, feed, pool) in enumerate(EQUITIES):
        agg = "0x" + r1[4 * i]["result"][-40:]
        mult = word(r1[4 * i + 1]["result"], 0) / 1e18
        sqrt = word(r1[4 * i + 2]["result"], 0)
        live = r1[4 * i + 3]["result"]
        # pool price: token1 per token0 raw = NVDAc-units per USDC-unit; invert and scale 8/6 decimals
        p_raw = (sqrt / 2 ** 96) ** 2
        pool_usd_per_token = (1 / p_raw) * 1e8 / 1e6 * usdc_price
        feed_usd_per_share = word(live, 1) / 1e8
        feed_usd_per_token = feed_usd_per_share * mult
        divergence = abs(feed_usd_per_token - pool_usd_per_token) / pool_usd_per_token
        feeds.append(dict(symbol=sym, feed=feed, aggregator=agg, multiplier=mult, latestRoundId=word(live, 0),
                          shareAnswer=feed_usd_per_share, tokenAnswer=feed_usd_per_token, updatedAt=word(live, 3),
                          ageSeconds=now - word(live, 3), poolUsdPerToken=pool_usd_per_token, divergence=divergence))

    # phase 2: latestRound on each aggregator, then getRoundData back ROUNDS rounds in batches
    b = [call(f["aggregator"], SEL["latestRound()"], block_hex) for f in feeds]
    for j, q in enumerate(b):
        q["id"] = j
    latest = [word(x["result"], 0) for x in rpc(b)]
    for f, lr in zip(feeds, latest):
        rounds = []
        ids = list(range(max(1, lr - ROUNDS + 1), lr + 1))
        for k in range(0, len(ids), 100):
            chunk = ids[k:k + 100]
            b = [call(f["aggregator"], SEL["getRoundData(uint80)"] + hex(rid)[2:].rjust(64, "0"), block_hex) for rid in chunk]
            for j, q in enumerate(b):
                q["id"] = j
            for rid, x in zip(chunk, rpc(b)):
                if "result" in x and len(x["result"]) >= 2 + 64 * 5:
                    rounds.append((rid, word(x["result"], 1) / 1e8, word(x["result"], 3)))
        rounds.sort()
        gaps = []
        for (rid0, a0, t0), (rid1, a1, t1) in zip(rounds, rounds[1:]):
            if t1 - t0 > GAP_THRESHOLD:
                d0 = datetime.fromtimestamp(t0, ET)
                d1 = datetime.fromtimestamp(t1, ET)
                kind = "weekend" if d0.weekday() == 4 and d1.weekday() == 6 else ("long-weekend" if (t1 - t0) > 60 * 3600 else "weekday")
                gaps.append(dict(fromRound=rid0, toRound=rid1, hours=round((t1 - t0) / 3600, 2), kind=kind,
                                 start=d0.strftime("%a %Y-%m-%d %H:%M ET"), end=d1.strftime("%a %Y-%m-%d %H:%M ET"),
                                 answerBefore=a0, answerAfter=a1, stepPct=round((a1 / a0 - 1) * 100, 3)))
        f["roundsWalked"] = len(rounds)
        f["oldestRound"] = datetime.fromtimestamp(rounds[0][2], ET).strftime("%Y-%m-%d %H:%M ET") if rounds else None
        f["gapsOver12h"] = gaps
        f["maxWeekendGapHours"] = max([g["hours"] for g in gaps if g["kind"] != "weekday"], default=0)
        f["maxWeekdayGapHours"] = max([g["hours"] for g in gaps if g["kind"] == "weekday"], default=0)
        f["maxAbsReopenStepPct"] = max([abs(g["stepPct"]) for g in gaps], default=0)

    out = dict(block=block, timestamp=now, usdcPrice=usdc_price, usdcFeedAgeSeconds=now - usdc_updated,
               maxFeedAge=MAX_FEED_AGE, maxDifference=MAX_DIFFERENCE, feeds=feeds)
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"feed_roundwalk-{block}.json")
    with open(path, "w") as fh:
        json.dump(out, fh, indent=1)

    fail = False
    print(f"block {block}  {datetime.fromtimestamp(now, ET).strftime('%a %Y-%m-%d %H:%M ET')}  USDC {usdc_price:.4f} (age {now - usdc_updated}s)")
    print(f"{'feed':7} {'age':>7} {'share$':>10} {'mult':>12} {'token$':>10} {'pool$':>10} {'div%':>6} {'rounds':>6} {'wknd h':>7} {'wkday h':>8} {'step%':>6}")
    for f in feeds:
        stale = f["ageSeconds"] > MAX_FEED_AGE
        div_bad = f["divergence"] > MAX_DIFFERENCE
        fail |= stale or div_bad
        print(f"{f['symbol']:7} {f['ageSeconds']:>7} {f['shareAnswer']:>10.2f} {f['multiplier']:>12.9f} {f['tokenAnswer']:>10.2f} "
              f"{f['poolUsdPerToken']:>10.2f} {100 * f['divergence']:>6.2f} {f['roundsWalked']:>6} {f['maxWeekendGapHours']:>7.1f} "
              f"{f['maxWeekdayGapHours']:>8.1f} {f['maxAbsReopenStepPct']:>6.2f}{'  STALE' if stale else ''}{'  DIVERGED' if div_bad else ''}")
    print(f"written {path}")
    if fail:
        print("ALERT: stale feed or divergence above tolerance")
        sys.exit(1)
    print("OK")


if __name__ == "__main__":
    main()
