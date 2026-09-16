#!/usr/bin/env python3
"""B20 role-holder enumeration from RoleGranted/RoleRevoked logs (plan WP1.3).

Role holders are not enumerable through view calls on the native token, so this replays the
AccessControl events since deployment for every equity and reports the current holders per role,
whether each holder is a contract or an EOA, and grants/revokes over the window.
Env: BASE_RPC_URL or ALCHEMY_API_KEY; FROM_BLOCK (default 0x2d00000, before the 2026-08-24 launch).
Output: results/roles_from_logs-<block>.json ; exit 1 if any role holder changed since LAST (a
previous results file passed via env) - intended as a poller.
"""
import json, os, sys, urllib.request

RPC = os.environ.get("BASE_RPC_URL") or ("https://base-mainnet.g.alchemy.com/v2/" + os.environ["ALCHEMY_API_KEY"])
FROM_BLOCK = os.environ.get("FROM_BLOCK", "0x2d00000")
ROLE_GRANTED = "0x2f8788117e7eff1d82e926ec794901d17c78024a50270940304540a733656f0d"
ROLE_REVOKED = "0xf6391f5c32d9c69d2a47ea670b442974b53935d1edc7fd64eb21e047a839171b"
ROLE_NAMES = {
    "0x" + "0" * 64: "DEFAULT_ADMIN_ROLE",
    "0x154c00819833dac601ee5ddded6fda79d9d8b506b911b3dbd54cdb95fe6c3686": "MINT_ROLE",
    "0xe97b137254058bd94f28d2f3eb79e2d34074ffb488d042e3bc958e0a57d2fa22": "BURN_ROLE",
    "0x3469b8b0d89e9604f8510ed143f74a8336d22955d4f83e23bf53d9414e27f432": "SEIZE_ROLE",
    "0x139c2898040ef16910dc9f44dc697df79363da767d8bc92f2e310312b816e46d": "PAUSE_ROLE",
    "0x265b220c5a8891efdd9e1b1b7fa72f257bd5169f8d87e319cf3dad6ff52b94ae": "UNPAUSE_ROLE",
    "0x6bd6b5318a46e5fff572d5e4258a20774aab40cc35ac7680654b9081fcc82f80": "METADATA_ROLE",
    "0x97667070c54ef182b0f5858b034beac1b6f3089aa2d3188bb1e8929f4fa9b929": "OPERATOR_ROLE",
}
EQUITIES = [
    ("AAPLc", "0xb200000000000000000000C2e324d24d7eEcd1fb"), ("MSFTc", "0xB200000000000000000000Ab99cFa739E253872B"),
    ("GOOGLc", "0xb2000000000000000000002D0BA3164cc74f58B7"), ("AMZNc", "0xb200000000000000000000d9192b6B456483C2E8"),
    ("METAc", "0xb2000000000000000000008bC8786B856E61707C"), ("NVDAc", "0xb20000000000000000000078ee7ce2fE4908108C"),
    ("TSLAc", "0xb2000000000000000000001e800a7f5189430cD0"),
]


def rpc(method, params, i=0):
    req = urllib.request.Request(RPC, data=json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}).encode(),
                                 headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        res = json.loads(r.read())
    if "error" in res:
        raise RuntimeError(res["error"])
    return res["result"]


def addr(topic):
    return "0x" + topic[-40:]


def main():
    block_hex = rpc("eth_blockNumber", [])
    block = int(block_hex, 16)
    code_cache = {}

    def has_code(a):
        if a not in code_cache:
            code_cache[a] = len(rpc("eth_getCode", [a, block_hex])) > 2
        return code_cache[a]

    tokens = []
    for sym, token in EQUITIES:
        events = []
        for topic, kind in ((ROLE_GRANTED, "grant"), (ROLE_REVOKED, "revoke")):
            logs = rpc("eth_getLogs", [{"address": token, "topics": [topic], "fromBlock": FROM_BLOCK, "toBlock": block_hex}])
            for lg in logs:
                events.append(dict(kind=kind, block=int(lg["blockNumber"], 16), logIndex=int(lg["logIndex"], 16),
                                   role=lg["topics"][1], account=addr(lg["topics"][2]), sender=addr(lg["topics"][3]),
                                   tx=lg["transactionHash"]))
        events.sort(key=lambda e: (e["block"], e["logIndex"]))
        holders = {}
        for e in events:
            s = holders.setdefault(e["role"], set())
            (s.add if e["kind"] == "grant" else s.discard)(e["account"])
        roles = {}
        for role, accs in holders.items():
            roles[ROLE_NAMES.get(role, role)] = [dict(account=a, hasCode=has_code(a)) for a in sorted(accs)]
        tokens.append(dict(symbol=sym, token=token, events=len(events), roles=roles,
                           history=[dict(e, role=ROLE_NAMES.get(e["role"], e["role"])) for e in events]))

    out = dict(block=block, fromBlock=FROM_BLOCK, tokens=tokens)
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"roles_from_logs-{block}.json")
    json.dump(out, open(path, "w"), indent=1)

    print(f"block {block}")
    for t in tokens:
        print(f"{t['symbol']} ({t['events']} events)")
        for role, accs in sorted(t["roles"].items()):
            print(f"  {role:20} " + ", ".join(f"{a['account']}{' (contract)' if a['hasCode'] else ' (EOA)'}" for a in accs))
    # cross-token summary: distinct holders per role
    print("distinct holders across all seven:")
    agg = {}
    for t in tokens:
        for role, accs in t["roles"].items():
            for a in accs:
                agg.setdefault(role, {})[a["account"]] = a["hasCode"]
    for role, m in sorted(agg.items()):
        print(f"  {role:20} " + ", ".join(f"{a}{' (contract)' if c else ' (EOA)'}" for a, c in sorted(m.items())))

    last = os.environ.get("LAST")
    if last:
        prev = json.load(open(last))
        prev_roles = {t["token"]: {r: sorted(a["account"] for a in accs) for r, accs in t["roles"].items()} for t in prev["tokens"]}
        cur_roles = {t["token"]: {r: sorted(a["account"] for a in accs) for r, accs in t["roles"].items()} for t in tokens}
        if prev_roles != cur_roles:
            print("ALERT: role holders changed since", last)
            sys.exit(1)
    print(f"written {path}")


if __name__ == "__main__":
    main()
