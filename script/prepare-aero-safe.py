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
    parser.add_argument('--debt-cap-usdc', required=True, type=int, help='Explicit whole-USDC activation cap')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if not 0 < args.debt_cap_usdc <= 1_000_000:
        raise SystemExit('Choose an activation cap between 1 and 1,000,000 USDC; review larger caps separately.')
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
    def read(address, signature, *args):
        return rpc('eth_call', [{'to':address, 'data':calldata(signature, *args)}, 'latest'])
    def address_word(raw):
        return '0x'+raw[-40:]
    def require_address(address, signature, expected):
        if address_word(read(address, signature)).lower() != expected.lower():
            raise SystemExit(f'Unexpected {signature} on {address}.')
    data = json.loads(args.broadcast.read_text())
    txs = data['transactions']
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
        if rpc('eth_getCode',[address,'latest']) == '0x':
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
    activation = {'to':addresses['V3Vault'],'value':'0','data':calldata('setLimits(uint256,uint256,uint256,uint256,uint256)',1_000_000,1_000_000_000_000,args.debt_cap_usdc*1_000_000,100_000_000_000,100_000_000_000),'contractMethod':None,'contractInputsValues':None}
    args.out.mkdir(parents=True,exist_ok=True)
    for name,value in [('addresses.json',addresses),('safe-accept-ownership.json',batch('Aero: accept ownership',pending)),('safe-activate-borrowing.json',batch('Aero: activate borrowing AFTER final checks',[activation]))]:
        (args.out/name).write_text(json.dumps(value,indent=2)+'\n')
    print(f'Validated all broadcast receipts and deployment bindings. Wrote three files in {args.out}.')
    print('Do not execute activation until ownership acceptance, source verification, audit and operational readiness checks pass.')

if __name__ == '__main__': main()
