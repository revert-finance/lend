#!/usr/bin/env python3
"""Verify the saved deployment, never a dry-run prediction. Does not sign transactions."""
import json
import os
from pathlib import Path
import subprocess

chain = int(os.environ['AERO_CHAIN_ID'])
if chain not in (1, 4663):
    raise SystemExit('Unsupported chain')
record = json.loads(Path(f'broadcast/DeployAeroV3UtilsMultichain.s.sol/{chain}/run-latest.json').read_text())
creations = [tx for tx in record['transactions'] if tx.get('transactionType') == 'CREATE' and tx.get('contractName') == 'V3Utils']
if len(creations) != 1 or not creations[0].get('hash'):
    raise SystemExit('Expected one broadcast V3Utils creation')
tx = creations[0]
if int(tx['transaction']['chainId'], 16) != chain:
    raise SystemExit('Wrong deployment chain')
receipt = subprocess.run(['cast', 'receipt', tx['hash'], '--rpc-url', os.environ['AERO_RPC_URL'], '--json'], text=True, capture_output=True)
if receipt.returncode:
    raise SystemExit('Could not read deployment receipt; check RPC')
r = json.loads(receipt.stdout)
if int(str(r['status']), 0) != 1 or r['contractAddress'].lower() != tx['contractAddress'].lower():
    raise SystemExit('Deployment failed or address differs')
artifact = json.loads(Path('out/V3Utils.sol/V3Utils.json').read_text())
encoded = subprocess.check_output(['cast', 'abi-encode', 'constructor(address,address,address)', *tx['arguments']], text=True).strip()
command = ['forge', 'verify-contract', tx['contractAddress'], 'src/transformers/V3Utils.sol:V3Utils', '--chain', str(chain), '--compiler-version', artifact['metadata']['compiler']['version'], '--constructor-args', encoded, '--watch']
if chain == 4663:
    command += ['--verifier', 'blockscout', '--verifier-url', 'https://robinhoodchain.blockscout.com/api?']
elif not os.environ.get('ETHERSCAN_API_KEY'):
    raise SystemExit('Set ETHERSCAN_API_KEY')
secrets = [os.environ.get(k) for k in ['ALCHEMY_API_KEY', 'ETHERSCAN_API_KEY', 'AERO_RPC_URL'] if os.environ.get(k)]
p = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
for line in p.stdout:
    for secret in secrets:
        line = line.replace(secret, '[REDACTED]')
    print(line, end='', flush=True)
raise SystemExit(p.wait())
