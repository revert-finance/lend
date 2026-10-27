#!/usr/bin/env python3
"""Build ownership/activation Safe files from a completed Foundry broadcast (never from predictions).

Uses only Python's standard library and cast. Does not sign, submit or execute transactions.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

SAFE = '0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9'
DEPLOYER = '0x83681C14770b44361e21Faf91D8325423365eA5C'
NPM = '0x4857DB576eE0e45F10525eC59527BfD10beeC60b'
OWNABLE = ['V3Oracle', 'V3Vault', 'GaugeManager', 'V3Utils', 'LeverageTransformer', 'AutoRangeAndCompound', 'AutoExit']
REQUIRED = OWNABLE + ['InterestRateModel', 'FlashloanLiquidator']

def calldata(signature, *args):
    return subprocess.check_output(['cast', 'calldata', signature, *map(str, args)], text=True).strip()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('broadcast', type=Path)
    parser.add_argument('--recovery-broadcast', type=Path, help='Completed configuration-only recovery for the known reserve-factor gas failure')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--ownership-only', action='store_true', help='Generate ownership acceptance only; no borrowing activation file')
    mode.add_argument('--debt-cap-usdc', type=int, help='Explicit whole-USDC activation cap')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.debt_cap_usdc is not None and not 0 < args.debt_cap_usdc <= 1_000_000:
        raise SystemExit('Choose an activation cap between 1 and 1,000,000 USDC; review larger caps separately.')
    if args.ownership_only and (args.out/'safe-activate-borrowing.json').exists():
        raise SystemExit('Use a separate output directory for ownership-only handoff; an activation file already exists here.')
    rpc_url = os.environ['BASE_RPC_URL']
    def rpc(method, params):
        req = urllib.request.Request(rpc_url, json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(), {'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                result = json.load(response)
        except Exception:
            raise SystemExit('RPC request failed; check Base RPC access. No output generated.') from None
        if 'error' in result:
            raise SystemExit('RPC returned an error. No output generated.')
        return result['result']
    if int(rpc('eth_chainId', []),16) != 8453:
        raise SystemExit('Expected Base chain 8453.')
    # Compare one coherent live snapshot, not a mixture of blocks while ownership/configuration changes.
    block = rpc('eth_blockNumber', [])
    def read(address, signature, *args):
        return rpc('eth_call', [{'to':address, 'data':calldata(signature, *args)}, block])
    def address_word(raw):
        return '0x'+raw[-40:]
    def require_address(address, signature, expected, *args):
        if address_word(read(address, signature, *args)).lower() != expected.lower():
            raise SystemExit(f'Unexpected {signature} on {address}.')
    data = json.loads(args.broadcast.read_text())
    txs = data['transactions']
    if args.recovery_broadcast:
        # Preserve the original failure evidence. Accept only the exact unsatisfied suffix replayed successfully.
        failed_hash = '0x9293cc9f4a176da7b63894686db1018369f892d688eac52881f96593b4c2995a'
        if len(txs) != 47 or txs[34].get('hash') != failed_hash or any(t.get('hash') for t in txs[35:]):
            raise SystemExit('Recovery does not match the known partial deployment.')
        failed_receipt = rpc('eth_getTransactionReceipt', [failed_hash])
        if not failed_receipt or int(failed_receipt['status'],16) != 0:
            raise SystemExit('Expected original failed reserve-factor transaction.')
        recovered = json.loads(args.recovery_broadcast.read_text())['transactions']
        if len(recovered) != 13:
            raise SystemExit('Expected exactly 13 recovery configuration calls.')
        for expected, actual in zip(txs[34:], recovered):
            original_call = expected['transaction']
            replay = actual['transaction']
            if actual.get('transactionType') != 'CALL' or any(
                str(original_call.get(key, '')).lower() != str(replay.get(key, '')).lower()
                for key in ('from','to','input','value','chainId')
            ):
                raise SystemExit('Recovery call differs from the original configuration sequence.')
        txs = txs[:34] + recovered
    # Check every actual receipt, including the configuration/nomination transactions.
    for tx in txs:
        if not tx.get('hash'):
            raise SystemExit('Missing transaction hash: this is not a completed broadcast.')
        receipt = rpc('eth_getTransactionReceipt', [tx['hash']])
        if receipt is None or int(receipt['status'],16) != 1:
            raise SystemExit('Pending or failed transaction. Resolve the partial deployment before handoff.')
    addresses = {}
    for tx in txs:
        if tx.get('transactionType') in ('CREATE','CREATE2') and tx.get('contractName') in REQUIRED:
            name = tx['contractName']
            if name in addresses:
                raise SystemExit(f'Ambiguous deployment: more than one {name}.')
            receipt = rpc('eth_getTransactionReceipt', [tx['hash']])
            address = receipt.get('contractAddress')
            if not address or address.lower() != tx['contractAddress'].lower():
                raise SystemExit('Deployment address/receipt mismatch.')
            addresses[name] = address
    if set(addresses) != set(REQUIRED):
        raise SystemExit('Broadcast does not contain all nine required contracts.')
    for name,address in addresses.items():
        if rpc('eth_getCode',[address,block]) == '0x':
            raise SystemExit(f'Missing deployed code: {name}.')
    require_address(addresses['V3Vault'],'gaugeManager()',addresses['GaugeManager'])
    require_address(addresses['GaugeManager'],'vault()',addresses['V3Vault'])
    require_address(addresses['V3Vault'],'oracle()',addresses['V3Oracle'])
    require_address(addresses['V3Vault'],'interestRateModel()',addresses['InterestRateModel'])
    require_address(addresses['GaugeManager'],'compoundModeSource()',addresses['AutoRangeAndCompound'])
    require_address(addresses['InterestRateModel'],'owner()',SAFE)
    for name in REQUIRED:
        if name != 'InterestRateModel': require_address(addresses[name],'nonfungiblePositionManager()',NPM)
    withdrawer = '0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82'
    operator = '0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF'
    for name in ['GaugeManager','AutoRangeAndCompound','AutoExit']:
        require_address(addresses[name],'withdrawer()',withdrawer)
    for name in ['AutoRangeAndCompound','AutoExit']:
        if int(read(addresses[name],'operators(address)',operator),16) != 1:
            raise SystemExit(f'Operator not authorized on {name}.')
    for name in ['V3Utils','LeverageTransformer','AutoRangeAndCompound']:
        if int(read(addresses['V3Vault'],'transformerAllowList(address)',addresses[name]),16) != 1:
            raise SystemExit(f'Vault transformer not enabled: {name}.')
        if int(read(addresses[name],'vaults(address)',addresses['V3Vault']),16) != 1:
            raise SystemExit(f'Fresh vault not enabled on {name}.')
    for signature, expected in [('minLoanSize()',1_000_000),('globalLendLimit()',1_000_000_000_000),('dailyLendIncreaseLimitMin()',100_000_000_000),('dailyDebtIncreaseLimitMin()',100_000_000_000),('reserveFactorX32()',429496729),('reserveProtectionFactorX32()',214748364)]:
        if int(read(addresses['V3Vault'],signature),16) != expected:
            raise SystemExit(f'Vault configuration differs: {signature}.')
    for token, factor in [('0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',3650722201),('0x4200000000000000000000000000000000000006',3328599654),('0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf',3328599654)]:
        config = read(addresses['V3Vault'],'tokenConfigs(address)',token)
        if int(config[2:66],16) != factor or int(config[66:130],16) != 2**32-1:
            raise SystemExit(f'Collateral configuration differs: {token}.')
    # Must match DeployAeroProtocol.s.sol. Receipts prove past calls, not the current owner-set state.
    zero = '0x' + '0' * 40
    weth = '0x4200000000000000000000000000000000000006'
    usdc = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'
    cbbtc = '0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf'
    factory = '0x9CB220581b91b0C83223012FE69688b92aD07a76'
    weth_usdc = '0x4a7af46bc8abc00048c6c7920a1488daf568366c'
    cbbtc_weth = '0xbb5507daae822ba89c4da61bbfdf4b49a1666bac'
    oracle = addresses['V3Oracle']
    manager = addresses['GaugeManager']
    require_address(addresses['V3Vault'],'asset()',usdc)
    for name in REQUIRED:
        if name != 'InterestRateModel': require_address(addresses[name],'factory()',factory)
    require_address(oracle,'referenceToken()',weth)
    require_address(oracle,'chainlinkReferenceToken()',zero)
    require_address(oracle,'sequencerUptimeFeed()','0xBCF85224fc0756B9Fa45aA7892530B47e10b6433')
    require_address(oracle,'emergencyAdmin()',zero)
    require_address(addresses['V3Vault'],'emergencyAdmin()',zero)
    require_address(manager,'aeroToken()','0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee')
    require_address(manager,'rootEmissionsHandler()','0x8C37F30F3c8fd48bEddb14086fa5148291D422C3')
    # Full public feed tuple: feed, max age, feed/token decimals, TWAP seconds, pool, token order, mode, deviation.
    feeds = {
        weth: ('0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70',3600,8,18,0,zero,0,3,0),
        usdc: ('0x7e860098F58bBFC8648a4311b374B1D669a2bc6B',86400,8,6,60,weth_usdc,0,1,200),
        cbbtc: ('0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D',86400,8,8,60,cbbtc_weth,0,1,200),
    }
    for token, expected in feeds.items():
        raw = read(oracle,'feedConfigs(address)',token)[2:]
        actual = [int(raw[i:i+64],16) for i in range(0,len(raw),64)]
        expected = [int(v,16) if isinstance(v,str) else v for v in expected]
        if actual != expected: raise SystemExit(f'Oracle feed configuration differs: {token}.')
    gauges = {
        weth_usdc: '0x46a9dca72d78366571be583aa69c1dc16e6889fb',
        '0x2a430bebd2082d8e05d56d64dede8944279bbc24': '0x14018f5afaeca44bb49d5036267d836723b57c91',
        cbbtc_weth: '0x5b14d6d194e49330647eb4717010ade1b1b3f8b5',
        '0xec3c3755b9ded4a2960ef50c9b48c1694ce274c2': '0xabb3fb6659e05847631896cb87a6d1b8bc0c6d8c',
        '0x42609aa1e58c5dd7e5a012dc74118fff975f0eac': '0x74a30b3357121a822adb91a539f4b11b5fb7cb3f',
        '0x784e539f15ca2d19449a6311c5dab6cf37d8f1ba': '0x4262b2d1415345b98e656a56c2f12cdbb1118539',
    }
    for pool, gauge in gauges.items():
        require_address(manager,'poolToGauge(address)',gauge,pool)
        require_address(pool,'gauge()',gauge)
    routes = {usdc:'0xd0acf293547457fb4fe9ee32ca93e89497626816', weth:'0xc85d5cb72d1aad6f152a8decad228ae4a59ac9b3', cbbtc:'0xe6a7317df4a9a7540663b99a07d1e019caa8afa4'}
    for token, pool in routes.items(): require_address(manager,'rewardBasePools(address)',pool,token)
    for name in ['GaugeManager','V3Utils','LeverageTransformer','AutoRangeAndCompound','AutoExit','FlashloanLiquidator']:
        require_address(addresses[name],'universalRouter()','0x6fF5693b99212Da76ad316178A184AB56D299b43')
        require_address(addresses[name],'zeroxAllowanceHolder()','0x0000000000001fF3684f28c67538d4D072C22734')
    values = [(oracle,'maxPoolPriceDifference()',200), (oracle,'referenceTokenDecimals()',18),
              (manager,'totalRewardX64()',2**64//20),
              (addresses['AutoRangeAndCompound'],'totalRewardX64()',2**64//20),
              (addresses['AutoRangeAndCompound'],'simpleRewardX64()',2**64//10),
              (addresses['AutoRangeAndCompound'],'stakeChangeCooldownBlocks()',0)]
    for name in ['AutoRangeAndCompound','AutoExit']:
        values += [(addresses[name],'TWAPSeconds()',60),(addresses[name],'maxTWAPTickDifference()',100)]
    for signature, expected in [('baseRatePerSecondX64()',0),('multiplierPerSecondX64()',(2**64*13//100)//31557600),('jumpMultiplierPerSecondX64()',(2**64*3)//31557600),('kinkX64()',2**64*90//100)]:
        values.append((addresses['InterestRateModel'],signature,expected))
    for address, signature, expected in values:
        if int(read(address,signature),16) != expected:
            raise SystemExit(f'Configuration differs: {signature} on {address}.')
    if int(read(addresses['V3Vault'],'globalDebtLimit()'),16) != 0:
        raise SystemExit('Vault debt cap is already nonzero. Review activation separately.')
    pending = []
    for name in OWNABLE:
        address = addresses[name]
        owner = address_word(read(address,'owner()'))
        if owner.lower() == SAFE.lower(): continue
        if owner.lower() != DEPLOYER.lower(): raise SystemExit(f'Unexpected owner: {name}.')
        require_address(address,'pendingOwner()',SAFE)
        pending.append({'to':address,'value':'0','data':calldata('acceptOwnership()'),'contractMethod':None,'contractInputsValues':None})
    def batch(name,transactions):
        return {'version':'1.0','chainId':'8453','createdAt':int(time.time()*1000),'meta':{'name':name,'description':'Fresh Aero deployment; review against pinned source and runbook.','txBuilderVersion':'1.18.0','createdFromSafeAddress':SAFE},'transactions':transactions}
    files = [('addresses.json',addresses),('safe-accept-ownership.json',batch('Aero: accept ownership',pending))]
    if not args.ownership_only:
        activation = {'to':addresses['V3Vault'],'value':'0','data':calldata('setLimits(uint256,uint256,uint256,uint256,uint256)',1_000_000,1_000_000_000_000,args.debt_cap_usdc*1_000_000,100_000_000_000,100_000_000_000),'contractMethod':None,'contractInputsValues':None}
        files.append(('safe-activate-borrowing.json',batch('Aero: activate borrowing AFTER final checks',[activation])))
    args.out.mkdir(parents=True,exist_ok=True)
    for name,value in files:
        (args.out/name).write_text(json.dumps(value,indent=2)+'\n')
    print(f'Validated receipts and expected deployment configuration at Base block {int(block,16)}. Wrote {len(files)} files in {args.out}.')
    if args.ownership_only:
        print('Ownership acceptance only. No borrowing activation file generated.')
    else:
        print('Do not execute activation until ownership acceptance, source verification, audit and operational readiness checks pass.')

if __name__ == '__main__': main()
