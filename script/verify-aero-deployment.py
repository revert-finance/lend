#!/usr/bin/env python3
"""Verify deployed sources from Foundry records. Never broadcasts or signs transactions."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    if not os.environ.get('ETHERSCAN_API_KEY'):
        raise SystemExit('Set ETHERSCAN_API_KEY before verification.')
    record = json.loads((ROOT/'broadcast/DeployAeroProtocol.s.sol/8453/run-latest.json').read_text())
    creations = [t for t in record['transactions'] if t.get('transactionType') in ('CREATE','CREATE2')]
    if len(creations) != 10:
        raise SystemExit('Expected nine contracts and VaultLib in the production deployment record.')
    secrets = [os.environ.get(k) for k in ('ETHERSCAN_API_KEY','ALCHEMY_API_KEY','BASE_RPC_URL') if os.environ.get(k)]
    failures = []
    for tx in creations:
        name, address = tx['contractName'], tx['contractAddress']
        if not tx.get('hash') or int(tx['transaction']['chainId'],16) != 8453:
            raise SystemExit('Expected broadcast Base deployment records.')
        artifact = json.loads((ROOT/'out'/(name+'.sol')/(name+'.json')).read_text())
        target = artifact['metadata']['settings']['compilationTarget']
        source = next(p for p,n in target.items() if n == name)
        constructor = next((a for a in artifact['abi'] if a['type']=='constructor'), {'inputs':[]})
        signature = 'constructor('+','.join(i['type'] for i in constructor['inputs'])+')'
        args = tx.get('arguments') or []
        if len(args) != len(constructor['inputs']):
            raise SystemExit('Constructor arguments do not match the saved artifact.')
        command = ['forge','verify-contract',address,source+':'+name,'--chain','8453','--watch',
                   '--compiler-version',artifact['metadata']['compiler']['version']]
        if args:
            encoded = subprocess.check_output(['cast','abi-encode',signature,*args],text=True).strip()
            command += ['--constructor-args',encoded]
        # Foundry linked this deployment after compilation. Preserve the original empty
        # compiler libraries setting; Etherscan resolves the deployed link references.
        print('Verifying',name,address,flush=True)
        process = subprocess.Popen(command,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        for line in process.stdout:
            for secret in secrets:
                line = line.replace(secret,'[REDACTED]')
            print(line,end='',flush=True)
        if process.wait():
            failures.append(name)
    if failures:
        raise SystemExit('Verification remains incomplete for: '+', '.join(failures))
    print('Verified all nine contracts and VaultLib.',flush=True)

if __name__ == '__main__':
    main()
