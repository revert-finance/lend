#!/usr/bin/env python3
"""Stressed-exit model for the Coinbase equity pools (plan WP5).

For every MinUnstake token/USDC pool (token0 == USDC, token1 == equity):
  1. read slot0, liquidity, fee and the initialized ticks above spot from the tick bitmap;
  2. for each underlying shock s in SHOCKS, move the price to spot*(1-s) by crossing ticks (the
     LP map is assumed unchanged - nobody rebalances inside a weekend gap);
  3. sell the liquidator's inventory - cap x (1 + max penalty) worth of equity at the post-shock
     price - through the remaining liquidity with the pool fee, exact Uniswap v3 math;
  4. report USDC recovered vs notional, price impact, and the largest sale that still recovers
     RECOVERY_FLOOR of notional (binary search) = the liquidity-consistent cap for that shock.

Reproducible from a pinned block: BLOCK=0x... ; two runs at different blocks should agree within
the stated tolerance (plan WP5 acceptance). Output: results/tickwalk_exit-<block>.json.
Env: BASE_RPC_URL or ALCHEMY_API_KEY; BLOCK; LENT (USDC lent base, default 2_000_000);
     PILOT (1 = half-size pilot caps, default 1); RECOVERY_FLOOR (default 0.90).
"""
import json, math, os, sys, urllib.request

RPC = os.environ.get("BASE_RPC_URL") or ("https://base-mainnet.g.alchemy.com/v2/" + os.environ["ALCHEMY_API_KEY"])
LENT = float(os.environ.get("LENT", "2000000"))
PILOT = os.environ.get("PILOT", "1") == "1"
RECOVERY_FLOOR = float(os.environ.get("RECOVERY_FLOOR", "0.90"))
SHOCKS = [0.0, 0.10, 0.20, 0.30, 0.40]
MAX_PENALTY = 0.10
TICK_RANGE_UP = 14_000  # ~4x price: covers a 40% shock (+5108 ticks) plus the sale impact
Q96 = 2 ** 96

# symbol, token, pool, full cap factor (fraction of lent); pilot = half
EQUITIES = [
    ("AAPLc", "0xb200000000000000000000C2e324d24d7eEcd1fb", "0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0", 0.08),
    ("MSFTc", "0xB200000000000000000000Ab99cFa739E253872B", "0x7103eB3c9590d1281f7dc03b2A9EE27C39dF5D54", 0.05),
    ("GOOGLc", "0xb2000000000000000000002D0BA3164cc74f58B7", "0xB1987CAD1682841b4b641d50E520777eC5Ab5542", 0.12),
    ("AMZNc", "0xb200000000000000000000d9192b6B456483C2E8", "0xd03Bc8C7F2FAedCe2aac81bF0444AEA08Ea06E9b", 0.04),
    ("METAc", "0xb2000000000000000000008bC8786B856E61707C", "0xEAF57753BC382E0324a1D43F72E7027705a2273E", 0.09),
    ("NVDAc", "0xb20000000000000000000078ee7ce2fE4908108C", "0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9", 0.07),
    ("TSLAc", "0xb2000000000000000000001e800a7f5189430cD0", "0x469337fDcc5E8f38e2E4B670B04F57865D13a7BB", 0.03),
]
USDC_FEED = "0x7e860098F58bBFC8648a4311b374B1D669a2bc6B"
SEL = {"slot0()": "0x3850c7bd", "liquidity()": "0x1a686502", "fee()": "0xddca3f43", "tickSpacing()": "0xd0c93a7c",
       "tickBitmap(int16)": "0x5339c296", "ticks(int24)": "0xf30dba93", "latestRoundData()": "0xfeaf968c"}


def rpc(batch):
    req = urllib.request.Request(RPC, data=json.dumps(batch).encode(), headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=90) as r:
        res = json.loads(r.read())
    res.sort(key=lambda x: x["id"])
    return res


def enc_int(v, bits=256):
    return hex(v % (1 << bits))[2:].rjust(64, "0")


def call(to, data, block, i=0):
    return {"jsonrpc": "2.0", "id": i, "method": "eth_call", "params": [{"to": to, "data": data}, block]}


def word(h, i):
    return int(h[2 + 64 * i: 2 + 64 * (i + 1)], 16)


def sword(h, i):
    v = word(h, i)
    return v - (1 << 256) if v >= 1 << 255 else v


def sqrt_at_tick(t):
    return math.sqrt(1.0001 ** t) * Q96


def load_pool(pool, block_hex):
    r = rpc([call(pool, SEL["slot0()"], block_hex, 0), call(pool, SEL["liquidity()"], block_hex, 1),
             call(pool, SEL["fee()"], block_hex, 2), call(pool, SEL["tickSpacing()"], block_hex, 3)])
    slot0 = r[0]["result"]
    sqrt_p, tick = word(slot0, 0), sword(slot0, 1)
    liq = word(r[1]["result"], 0)
    fee = word(r[2]["result"], 0) if "result" in r[2] else 500
    spacing = sword(r[3]["result"], 0)
    # bitmap words from the current tick up to TICK_RANGE_UP (price rises when equity is sold)
    lo_word = (tick // spacing) >> 8
    hi_word = ((tick + TICK_RANGE_UP) // spacing) >> 8
    words = list(range(lo_word, hi_word + 1))
    r = rpc([call(pool, SEL["tickBitmap(int16)"] + enc_int(w), block_hex, i) for i, w in enumerate(words)])
    init_ticks = []
    for w, x in zip(words, r):
        bm = word(x["result"], 0)
        for bit in range(256):
            if bm >> bit & 1:
                init_ticks.append(((w << 8) + bit) * spacing)
    init_ticks = sorted(t for t in init_ticks if t > tick)
    nets = {}
    for k in range(0, len(init_ticks), 100):
        chunk = init_ticks[k:k + 100]
        r = rpc([call(pool, SEL["ticks(int24)"] + enc_int(t), block_hex, i) for i, t in enumerate(chunk)])
        for t, x in zip(chunk, r):
            nets[t] = sword(x["result"], 1)  # liquidityNet
    return dict(sqrtP=sqrt_p, tick=tick, liquidity=liq, fee=fee, spacing=spacing, ticks=init_ticks, nets=nets)


def cross_to_price(state, target_sqrt):
    """Move the price up to target_sqrt without trading (post-gap arbitrage), tracking liquidity."""
    sqrt_p, liq = state["sqrtP"], state["liquidity"]
    idx = 0
    ticks = state["ticks"]
    while idx < len(ticks) and sqrt_at_tick(ticks[idx]) <= target_sqrt:
        liq += state["nets"][ticks[idx]]
        idx += 1
    return target_sqrt, max(liq, 0), idx


def sell_equity(state, start_sqrt, start_liq, start_idx, amount1_in):
    """Exact-in sale of token1 (equity) for token0 (USDC): price moves up through initialized ticks."""
    fee_mult = 1 - state["fee"] / 1e6
    remaining = amount1_in * fee_mult
    sqrt_p, liq, idx = start_sqrt, start_liq, start_idx
    out0 = 0.0
    ticks = state["ticks"]
    while remaining > 0:
        if liq <= 0:
            if idx >= len(ticks):
                break  # ran out of liquidity: rest of the inventory is unsellable in this pool
            sqrt_p = sqrt_at_tick(ticks[idx])
            liq += state["nets"][ticks[idx]]
            idx += 1
            continue
        next_sqrt = sqrt_at_tick(ticks[idx]) if idx < len(ticks) else sqrt_p * 4
        dy_to_next = liq * (next_sqrt - sqrt_p) / Q96
        if remaining >= dy_to_next and idx < len(ticks):
            out0 += liq * (Q96 / sqrt_p - Q96 / next_sqrt)
            remaining -= dy_to_next
            sqrt_p = next_sqrt
            liq += state["nets"][ticks[idx]]
            idx += 1
        else:
            new_sqrt = sqrt_p + remaining * Q96 / liq
            out0 += liq * (Q96 / sqrt_p - Q96 / new_sqrt)
            sqrt_p = new_sqrt
            remaining = 0
    return out0, sqrt_p


def usd_per_token(sqrt_p, usdc_usd):
    # price token1/token0 raw; invert; 8 vs 6 decimals
    p_raw = (sqrt_p / Q96) ** 2
    return (1 / p_raw) * 1e8 / 1e6 * usdc_usd


def main():
    block_hex = os.environ.get("BLOCK") or rpc([{"jsonrpc": "2.0", "id": 0, "method": "eth_blockNumber", "params": []}])[0]["result"]
    block = int(block_hex, 16)
    usdc_usd = word(rpc([call(USDC_FEED, SEL["latestRoundData()"], block_hex)])[0]["result"], 1) / 1e8
    results = []
    for sym, token, pool, full_factor in EQUITIES:
        st = load_pool(pool, block_hex)
        factor = full_factor / 2 if PILOT else full_factor
        cap_usd = LENT * factor
        spot = usd_per_token(st["sqrtP"], usdc_usd)
        row = dict(symbol=sym, pool=pool, spotUsd=spot, tick=st["tick"], liquidity=st["liquidity"], fee=st["fee"],
                   initializedTicksAbove=len(st["ticks"]), capUsd=cap_usd, scenarios=[])
        for s in SHOCKS:
            post_price = spot * (1 - s)
            target_sqrt = st["sqrtP"] / math.sqrt(1 - s) if s else st["sqrtP"]
            sq, liq, idx = cross_to_price(st, target_sqrt)
            notional = cap_usd * (1 + MAX_PENALTY)
            amount1 = notional / post_price * 1e8  # raw equity units
            out0, end_sqrt = sell_equity(st, sq, liq, idx, amount1)
            recovered = out0 / 1e6 * usdc_usd
            end_price = usd_per_token(end_sqrt, usdc_usd)
            # liquidity-consistent sale: largest notional recovering >= RECOVERY_FLOOR
            lo, hi = 0.0, notional * 8
            for _ in range(40):
                mid = (lo + hi) / 2
                o, _e = sell_equity(st, sq, liq, idx, mid / post_price * 1e8)
                if o / 1e6 * usdc_usd >= RECOVERY_FLOOR * mid:
                    lo = mid
                else:
                    hi = mid
            row["scenarios"].append(dict(shock=s, postShockUsd=post_price, liquidityAtStart=liq, saleNotionalUsd=notional,
                                         recoveredUsd=recovered, recoveryPct=recovered / notional if notional else 0,
                                         endPriceUsd=end_price, priceImpactPct=end_price / post_price - 1,
                                         maxSaleAtFloorUsd=lo, impliedCapAtFloorUsd=lo / (1 + MAX_PENALTY)))
        results.append(row)

    out = dict(block=block, usdcUsd=usdc_usd, lentUsd=LENT, pilot=PILOT, recoveryFloor=RECOVERY_FLOOR, maxPenalty=MAX_PENALTY,
               shocks=SHOCKS, pools=results)
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"tickwalk_exit-{block}.json")
    json.dump(out, open(path, "w"), indent=1)

    print(f"block {block}  lent ${LENT:,.0f}  {'pilot' if PILOT else 'full'} caps  sale = cap x {1 + MAX_PENALTY}  floor {RECOVERY_FLOOR:.0%}")
    print(f"{'pool':7} {'spot$':>8} {'cap$':>9} | " + " | ".join(f"{'-' + str(int(s * 100)) + '%':>5} rec% impact% cap@floor$" for s in SHOCKS[1:]))
    totals = {s: [0.0, 0.0] for s in SHOCKS}
    for r in results:
        cells = []
        for sc in r["scenarios"]:
            totals[sc["shock"]][0] += sc["saleNotionalUsd"]
            totals[sc["shock"]][1] += sc["recoveredUsd"]
            if sc["shock"] == 0:
                continue
            cells.append(f"{100 * sc['recoveryPct']:>10.1f} {100 * sc['priceImpactPct']:>7.1f} {sc['impliedCapAtFloorUsd']:>10,.0f}")
        print(f"{r['symbol']:7} {r['spotUsd']:>8.2f} {r['capUsd']:>9,.0f} | " + " | ".join(cells))
    at_spot = [sc for r in results for sc in r["scenarios"] if sc["shock"] == 0]
    print(f"at spot (no shock): recovery {100 * sum(x['recoveredUsd'] for x in at_spot) / sum(x['saleNotionalUsd'] for x in at_spot):.1f}% "
          f"across all seven, worst impact {100 * max(x['priceImpactPct'] for x in at_spot):.2f}%")
    for s in SHOCKS[1:]:
        n, rec = totals[s]
        print(f"correlated seven-name liquidation after -{int(s * 100)}%: sell ${n:,.0f} -> recover ${rec:,.0f} ({100 * rec / n:.1f}%)")
    print(f"written {path}")


if __name__ == "__main__":
    main()
