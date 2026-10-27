#!/usr/bin/env python3
"""Integration regression for prepare-aero-safe.py against an already deployed LOCAL Anvil fork.

Never uses a public RPC. Mutates fork contracts, then restores every case via snapshots.
Usage: python3 test/deployment/aero_safe_handoff.py --broadcast <local run-latest.json>
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
DEPLOYER = '0x83681C14770b44361e21Faf91D8325423365eA5C'
SAFE = '0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9'
ZERO = '0x' + '0' * 40
USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'
WETH = '0x4200000000000000000000000000000000000006'
CBBTC = '0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--broadcast', type=Path, required=True)
    parser.add_argument('--rpc-url', default='http://127.0.0.1:28544')
    args = parser.parse_args()
    url = urlparse(args.rpc_url)
    assert url.scheme == 'http' and url.hostname == '127.0.0.1', 'LOCAL Anvil only'

    def rpc(method, params):
        request = urllib.request.Request(args.rpc_url, json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(), {'Content-Type':'application/json'})
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
        assert 'error' not in result, result.get('error')
        return result['result']

    assert 'anvil' in rpc('web3_clientVersion', []).lower(), 'LOCAL Anvil only'
    for actor in [DEPLOYER, SAFE]:
        rpc('anvil_impersonateAccount', [actor])
        rpc('anvil_setBalance', [actor, hex(10*10**18)])
    records = json.loads(args.broadcast.read_text())
    addresses = {t['contractName']:t['contractAddress'] for t in records['transactions'] if t.get('transactionType') == 'CREATE'}

    def send(name, signature, *values, actor=DEPLOYER):
        data = subprocess.check_output(['cast','calldata',signature,*map(str,values)],text=True).strip()
        tx = rpc('eth_sendTransaction', [{'from':actor,'to':addresses[name],'data':data,'gas':'0x100000'}])
        for _ in range(100):
            receipt = rpc('eth_getTransactionReceipt', [tx])
            if receipt:
                assert int(receipt['status'],16) == 1, (name, signature)
                return
            time.sleep(0.05)
        raise AssertionError('Local transaction receipt timeout')

    def check(label, mutate=None, expected_error=None, expected_acceptances=7, ownership_only=False):
        snapshot = rpc('evm_snapshot', [])
        try:
            if mutate:
                mutate()
            with tempfile.TemporaryDirectory() as directory:
                output = Path(directory)/'handoff'
                mode = ['--ownership-only'] if ownership_only else ['--debt-cap-usdc','1000000']
                result = subprocess.run(['python3',str(ROOT/'script/prepare-aero-safe.py'),str(args.broadcast.resolve()),*mode,'--out',str(output)],env=dict(os.environ,BASE_RPC_URL=args.rpc_url),text=True,capture_output=True,cwd=ROOT)
                if expected_error:
                    assert result.returncode != 0 and expected_error in result.stderr, (label,result.stdout,result.stderr)
                    assert not output.exists(), f'{label}: wrote Safe files despite configuration mismatch'
                else:
                    assert result.returncode == 0, (label,result.stdout,result.stderr)
                    acceptance = json.loads((output/'safe-accept-ownership.json').read_text())
                    assert len(acceptance['transactions']) == expected_acceptances
                    if ownership_only:
                        assert {p.name for p in output.iterdir()} == {'addresses.json','safe-accept-ownership.json'}
                        assert all(t['data'] == '0x79ba5097' and t['value'] == '0' for t in acceptance['transactions'])
                    else:
                        assert len(json.loads((output/'safe-activate-borrowing.json').read_text())['transactions']) == 1
            print('PASS', label, flush=True)
        finally:
            assert rpc('evm_revert', [snapshot])

    check('unchanged deployment accepts all seven nominations')
    check('ownership-only emits seven acceptances and no activation', ownership_only=True)
    check('partial Safe acceptance', lambda:send('V3Oracle','acceptOwnership()',actor=SAFE), expected_acceptances=6)
    owned = ['V3Oracle','V3Vault','GaugeManager','V3Utils','LeverageTransformer','AutoRangeAndCompound','AutoExit']
    check('configuration recheck after all acceptances', lambda:[send(n,'acceptOwnership()',actor=SAFE) for n in owned], expected_acceptances=0)
    check('ownership-only recheck after all acceptances', lambda:[send(n,'acceptOwnership()',actor=SAFE) for n in owned], expected_acceptances=0, ownership_only=True)

    feed_configs = {
        WETH: ['0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70',3600,ZERO,0,3,0],
        USDC: ['0x7e860098F58bBFC8648a4311b374B1D669a2bc6B',86400,'0x4a7af46bc8abc00048c6c7920a1488daf568366c',60,1,200],
        CBBTC: ['0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D',86400,'0xbb5507daae822ba89c4da61bbfdf4b49a1666bac',60,1,200],
    }
    signature = 'setTokenConfig(address,address,uint32,address,uint32,uint8,uint16)'
    for token, config in feed_configs.items():
        changed = list(config); changed[1] += 1
        check('changed feed age '+token, lambda t=token,c=changed:send('V3Oracle',signature,t,*c), 'Oracle feed configuration differs')
    for label,index,value in [('feed address',0,feed_configs[WETH][0]),('reference pool',2,'0x2a430bebd2082d8e05d56d64dede8944279bbc24'),('TWAP period',3,61),('oracle mode',4,3),('deviation bound',5,201)]:
        changed = list(feed_configs[USDC]); changed[index] = value
        check('changed '+label, lambda c=changed:send('V3Oracle',signature,USDC,*c), 'Oracle feed configuration differs')
    check('changed global price bound',lambda:send('V3Oracle','setMaxPoolPriceDifference(uint16)',201),'maxPoolPriceDifference()')
    check('removed sequencer check',lambda:send('V3Oracle','setSequencerUptimeFeed(address)',ZERO),'sequencerUptimeFeed()')
    for name in ['V3Oracle','V3Vault']:
        check('changed emergency admin '+name,lambda n=name:send(n,'setEmergencyAdmin(address)',DEPLOYER),'emergencyAdmin()')
    for token in [USDC,WETH,CBBTC]:
        check('removed reward route '+token,lambda t=token:send('GaugeManager','setRewardBasePool(address,address)',t,ZERO),'rewardBasePools(address)')
    check('replaced reward route',lambda:send('GaugeManager','setRewardBasePool(address,address)',USDC,'0x422df9aa896e883c9cdcbad309c0785b7364a1cf'),'rewardBasePools(address)')

    # Fault injection only: setGauge rejects arbitrary replacements without matching upstream pool bindings.
    # Alter each stored assignment directly to prove the handoff reads the mapping, not just old receipts.
    layout = json.loads(subprocess.check_output(['forge','inspect','GaugeManager','storageLayout','--json'],cwd=ROOT,text=True))
    slot = next(v['slot'] for v in layout['storage'] if v['label']=='poolToGauge')
    bindings = json.loads((ROOT/'docs/deployment/base-aero-bindings-53136369.json').read_text())
    pools = [p['address'] for p in bindings['pools'] if p['pair'] in ['WETH/USDC','cbBTC/WETH','cbBTC/USDC'] and int(p['gauge'],16)]
    assert len(pools)==6
    for pool in pools:
        key = subprocess.check_output(['cast','index','address',pool,slot],text=True).strip()
        check('corrupted gauge assignment '+pool,lambda k=key:rpc('anvil_setStorageAt',[addresses['GaugeManager'],k,'0x'+'0'*64]),'poolToGauge(address)')
    check('changed IRM kink',lambda:send('InterestRateModel','setValues(uint256,uint256,uint256,uint256)',0,2**64*13//100,2**64*3,2**64*80//100,actor=SAFE),'kinkX64()')
    check('changed compound fees',lambda:send('AutoRangeAndCompound','setAutoCompoundRewards(uint64,uint64)',2**64//100,2**64//10),'totalRewardX64()')
    check('changed staking cooldown',lambda:send('AutoRangeAndCompound','setStakeChangeCooldown(uint32)',10),'stakeChangeCooldownBlocks()')
    for name in ['AutoRangeAndCompound','AutoExit']:
        check('changed automation TWAP '+name,lambda n=name:send(n,'setTWAPConfig(uint16,uint32)',99,60),'maxTWAPTickDifference()')
    check('restored deployment still generates handoff')


if __name__ == '__main__':
    main()
