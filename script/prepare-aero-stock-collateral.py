#!/usr/bin/env python3
"""Prepare/recheck stock collateral with deployed TWAP feed adapters. Read-only unless --broadcast.

No contracts are deployed. The config is deliberately pinned to the existing Base vault.
"""
import argparse
import json
import os
import re
from pathlib import Path
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ZERO = '0x' + '0' * 40


def encode(signature, *args):
    return subprocess.check_output(['cast', 'calldata', signature, *map(str, args)], text=True).strip()


def words(raw):
    return [int(raw[i:i + 64], 16) for i in range(2, len(raw), 64)]


def address(raw):
    return '0x' + raw[-40:].lower()


def string(raw):
    data = bytes.fromhex(raw[2:])
    offset = int.from_bytes(data[:32], 'big')
    size = int.from_bytes(data[offset:offset + 32], 'big')
    return data[offset + 32:offset + 32 + size].decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--adapters', type=Path, required=True,
                        help='Reviewed JSON mapping NVDAc/TSLAc/GOOGLc to deployed StockTwapFeed addresses')
    parser.add_argument('--broadcast', action='store_true')
    parser.add_argument('--account', help='Local Foundry keystore; required for EOA broadcast')
    args = parser.parse_args()
    if args.broadcast and not args.account:
        parser.error('--broadcast requires --account; Safe owners use the generated batch')
    config = json.loads((ROOT / 'config/aero-stock-collateral.json').read_text())
    adapters = json.loads(args.adapters.read_text())
    if not isinstance(adapters, dict) or set(adapters) != {a['symbol'] for a in config['assets']}:
        raise SystemExit('Adapters must map exactly the three configured stock symbols to addresses.')
    if not all(isinstance(a, str) and re.fullmatch(r'0x[0-9a-fA-F]{40}', a) for a in adapters.values()):
        raise SystemExit('Malformed adapter address.')
    adapters = {symbol: value.lower() for symbol, value in adapters.items()}
    if len(set(adapters.values())) != 3 or ZERO in adapters.values():
        raise SystemExit('Three distinct deployed adapters are required.')
    addresses = [config[k] for k in ['vault', 'oracle', 'npm', 'factory', 'safe', 'deployer']]
    addresses += [config['usdc'], config['usdcFeed']]
    addresses += [a[k] for a in config['assets'] for k in ['token', 'feed', 'pool']]
    if not all(re.fullmatch(r'0x[0-9a-f]{40}', a) for a in addresses):
        raise SystemExit('Malformed address in reviewed configuration.')
    rpc_url = os.environ.get('BASE_RPC_URL')
    if not rpc_url and os.environ.get('ALCHEMY_API_KEY'):
        rpc_url = 'https://base-mainnet.g.alchemy.com/v2/' + os.environ['ALCHEMY_API_KEY']
    if not rpc_url:
        raise SystemExit('Set BASE_RPC_URL or ALCHEMY_API_KEY.')

    def rpc(method, params):
        request = urllib.request.Request(rpc_url, json.dumps({
            'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params
        }).encode(), {'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                result = json.load(response)
        except Exception:
            raise SystemExit('RPC request failed; no transaction sent by this request.') from None
        if 'error' in result:
            raise SystemExit(f'RPC {method} failed; check the selected chain/state.')
        return result['result']

    def require(condition, reason):
        if not condition:
            raise SystemExit(reason)

    require(int(rpc('eth_chainId', []), 16) == 8453 == config['chainId'], 'Expected Base mainnet.')
    block = rpc('eth_blockNumber', [])
    timestamp = int(rpc('eth_getBlockByNumber', [block, False])['timestamp'], 16)

    def read(target, signature, *values):
        return rpc('eth_call', [{'to': target, 'data': encode(signature, *values)}, block])

    vault, oracle = config['vault'], config['oracle']
    for target in [vault, oracle, config['npm'], config['factory']]:
        require(rpc('eth_getCode', [target, block]) != '0x', 'Missing deployment code: ' + target)
    for target, signature, expected in [
        (vault, 'oracle()', oracle), (vault, 'nonfungiblePositionManager()', config['npm']),
        (oracle, 'nonfungiblePositionManager()', config['npm']), (oracle, 'factory()', config['factory']),
        (oracle, 'referenceToken()', '0x4200000000000000000000000000000000000006'),
        (oracle, 'chainlinkReferenceToken()', ZERO),
    ]:
        require(address(read(target, signature)) == expected, 'Unexpected deployment binding: ' + signature)
    require(words(read(oracle, 'maxPoolPriceDifference()')) == [200], 'Expected unchanged 2% pool guard.')
    owners = {target: address(read(target, 'owner()')) for target in [oracle, vault]}
    require(all(o in [config['deployer'], config['safe']] for o in owners.values()), 'Unexpected configuration owner.')
    require(0 < config['collateralFactorBps'] <= 5000, 'Review collateral factors above 50% separately.')
    require(0 < config['collateralValueLimitBps'] <= 500, 'Review exposure above 5% per stock separately.')
    require(config['maxFeedAge'] == 86400, 'Review feed-age changes separately.')
    require(config['maxUsdcFeedAge'] == 86400 and config['twapSeconds'] == 60
            and config['maxDifferenceBps'] == 200, 'Review TWAP policy changes separately.')
    require(words(read(config['usdc'], 'decimals()')) == [6], 'Adapter requires 6-decimal USDC.')
    usdc_config = words(read(oracle, 'feedConfigs(address)', config['usdc']))
    require(usdc_config[0] == int(config['usdcFeed'], 16)
            and usdc_config[1] == config['maxUsdcFeedAge'], 'USDC oracle configuration changed.')
    cf = config['collateralFactorBps'] * 2**32 // 10000
    cap = config['collateralValueLimitBps'] * 2**32 // 10000
    oracle_calls, vault_calls = [], []
    feed_state = []
    for asset in config['assets']:
        token, feed = asset['token'], asset['feed']
        # B20 token metadata is native on Base: code.length is not a valid token-existence check.
        require(string(read(token, 'symbol()')) == asset['symbol'], 'Unexpected stock token symbol.')
        require(words(read(token, 'decimals()')) == [8], 'Unexpected stock decimals.')
        require(rpc('eth_getCode', [feed, block]) != '0x', 'Missing feed code.')
        require(string(read(feed, 'description()')) == asset['feedDescription'], 'Incorrect issuer/24-7 feed.')
        require(words(read(feed, 'decimals()')) == [8], 'Unexpected feed decimals.')
        round_id, answer, _, updated_at, _ = words(read(feed, 'latestRoundData()'))
        require(0 < answer < 2**255 and 0 < updated_at <= timestamp, 'Invalid feed round.')
        require(timestamp - updated_at <= config['maxFeedAge'], 'Stale stock feed: ' + asset['symbol'])
        adapter = adapters[asset['symbol']]
        require(rpc('eth_getCode', [adapter, block]) != '0x', 'Missing adapter code.')
        for getter, expected in [('stock', token), ('usdc', config['usdc']), ('stockFeed', feed),
                                 ('usdcFeed', config['usdcFeed']), ('pool', asset['pool'])]:
            require(address(read(adapter, getter + '()')) == expected, 'Incorrect adapter binding: ' + getter)
        for getter, expected in [('decimals', 8), ('maxStockAge', config['maxFeedAge']),
                                 ('maxUsdcAge', config['maxUsdcFeedAge']), ('twapSeconds', config['twapSeconds']),
                                 ('maxDifferenceBps', config['maxDifferenceBps'])]:
            require(words(read(adapter, getter + '()')) == [expected], 'Incorrect adapter setting: ' + getter)
        spacing = words(read(asset['pool'], 'tickSpacing()'))[0]
        require(address(read(config['factory'], 'getPool(address,address,int24)', token, config['usdc'], spacing))
                == asset['pool'], 'TWAP pool does not resolve from Aero factory.')
        require(read(adapter, 'latestRoundData()') == read(feed, 'latestRoundData()'),
                'Adapter must pass TWAP validation and preserve the underlying stock round.')
        feed_state.append(dict(symbol=asset['symbol'], adapter=adapter, roundId=str(round_id),
                               answer=str(answer), updatedAt=updated_at))
        current = words(read(oracle, 'feedConfigs(address)', token))
        desired = [int(adapter, 16), config['maxFeedAge'], 8, 8, 0, 0, 0, 3, 0]
        require(current[7] == 0 or current == desired, 'Existing stock oracle differs; review before overwriting.')
        if current != desired:
            oracle_calls.append(dict(to=oracle, value='0', data=encode(
                'setTokenConfig(address,address,uint32,address,uint32,uint8,uint16)',
                token, adapter, config['maxFeedAge'], ZERO, 0, 3, 0), symbol=asset['symbol'], stage='oracle'))
        old_cf, old_cap, _ = words(read(vault, 'tokenConfigs(address)', token))
        require((old_cf == 0 and old_cap == 0) or (old_cf == cf and old_cap == cap),
                'Existing stock risk settings differ; review before overwriting.')
        if (old_cf, old_cap) != (cf, cap):
            vault_calls.append(dict(to=vault, value='0', data=encode(
                'setTokenConfig(address,uint32,uint32)', token, cf, cap), symbol=asset['symbol'], stage='collateral'))
    calls = oracle_calls + vault_calls  # Every oracle first, collateral activation last.
    # Execute each actual setter as an eth_call on Base, including native B20 metadata reads.
    for call in calls:
        rpc('eth_call', [{'from': owners[call['to']], 'to': call['to'], 'data': call['data']}, block])
    args.out.mkdir(parents=True, exist_ok=True)
    plan = dict(chainId=8453, block=int(block, 16), timestamp=timestamp, config=config, adapters=adapters,
                owners=owners, feeds=feed_state, transactions=calls)
    (args.out / 'plan.json').write_text(json.dumps(plan, indent=2) + '\n')
    safe_path = args.out / 'safe-batch.json'
    # Do not leave an old actionable batch behind when current ownership no longer matches.
    if safe_path.exists():
        safe_path.unlink()
    if all(o == config['safe'] for o in owners.values()):
        batch = dict(version='1.0', chainId='8453', createdAt=int(time.time() * 1000),
                     meta=dict(name='Aero stock collateral', createdFromSafeAddress=config['safe']),
                     transactions=[{k: c[k] for k in ['to', 'value', 'data']} for c in calls])
        safe_path.write_text(json.dumps(batch, indent=2) + '\n')
    print(f'Base block {int(block, 16)}: {len(calls)} configuration calls; all setter simulations passed.')
    print(f'Collateral factor {cf}/2^32; exposure cap {cap}/2^32 of lender assets per token.')
    print(f'Plan: {args.out / "plan.json"}')
    if not args.broadcast or not calls:
        return
    require(all(o == config['deployer'] for o in owners.values()), 'Use the Safe batch after ownership acceptance.')
    # All static preflight and RPC simulations have completed before asking the user to unlock a keystore.
    signer = subprocess.check_output(['cast', 'wallet', 'address', '--account', args.account], text=True).strip().lower()
    require(signer == config['deployer'], 'Keystore is not the current configuration owner.')
    for call in calls:
        # Stop if ownership changes between transactions. On failure, rerun prepare to skip completed settings.
        current_owner = address(rpc('eth_call', [{'to': call['to'], 'data': encode('owner()')}, 'latest']))
        require(current_owner == signer, 'Ownership changed; re-prepare the proposal.')
        env = dict(os.environ, ETH_RPC_URL=rpc_url)
        result = subprocess.run(['cast', 'send', call['to'], call['data'], '--account', args.account,
                                 '--from', signer, '--chain', '8453', '--gas-limit', '500000', '--json'],
                                env=env, text=True, capture_output=True)
        if result.returncode:
            # Raw provider output can contain credentials. Only report a safe status.
            raise SystemExit('Send/receipt failed. Inspect chain state and rerun prepare before retrying; earlier calls may have succeeded.')
        try:
            receipt = json.loads(result.stdout)
            receipt = receipt.get('data', receipt)
            status = receipt['status']
            status = int(status, 0) if isinstance(status, str) else int(status)
            require(status == 1, 'Transaction reverted; inspect receipts and rerun preparation.')
        except (ValueError, TypeError, KeyError, AttributeError):
            raise SystemExit('Could not confirm receipt status; inspect chain state before retrying.') from None
        print('Confirmed:', call['stage'], call['symbol'], receipt.get('transactionHash', ''))
    print('Configuration sent. Run this command again without --broadcast to verify zero remaining calls.')


if __name__ == '__main__':
    main()
