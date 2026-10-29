#!/usr/bin/env python3
"""Verify the replacement factory using its exact compilation metadata. Never signs transactions."""
import copy
import json
import os
from pathlib import Path
import subprocess
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def compiler_input(artifact):
    # The factory embeds holder creation code. Preserve ALL compiler remappings:
    # filtering them changes embedded metadata and produces a bytecode mismatch.
    metadata = artifact['metadata']
    settings = copy.deepcopy(metadata['settings'])
    settings.pop('compilationTarget')
    return {
        'language': metadata['language'],
        'sources': {path: {'content': (ROOT / path).read_text()} for path in metadata['sources']},
        'settings': settings,
    }


def main():
    key = os.environ.get('ETHERSCAN_API_KEY')
    if not key:
        raise SystemExit('Set ETHERSCAN_API_KEY before verification.')
    record = json.loads((ROOT / 'broadcast/DeployPoolsideFactory.s.sol/8453/run-latest.json').read_text())
    creations = [t for t in record['transactions'] if t.get('transactionType') in ('CREATE', 'CREATE2')]
    if len(creations) != 1 or creations[0]['contractName'] != 'PoolsideFactory':
        raise SystemExit('Expected exactly one factory deployment.')
    tx = creations[0]
    if not tx.get('hash') or int(tx['transaction']['chainId'], 16) != 8453:
        raise SystemExit('Expected a broadcast Base deployment record.')
    receipt = next((r for r in record['receipts'] if r['transactionHash'] == tx['hash']), None)
    if receipt is None or int(receipt['status'], 16) != 1:
        raise SystemExit('Factory deployment receipt is missing or unsuccessful.')
    artifact = json.loads((ROOT / 'out/PoolsideFactory.sol/PoolsideFactory.json').read_text())
    args = subprocess.check_output([
        'cast', 'abi-encode', 'constructor(address,address,address,address)', *tx['arguments']
    ], text=True).strip()[2:]
    bytecode = artifact['bytecode']['object'].removeprefix('0x')
    if tx['transaction']['input'].removeprefix('0x').lower() != (bytecode + args).lower():
        raise SystemExit('Local artifact differs from the broadcast initcode; restore the deployed build.')
    address = tx['contractAddress']
    payload = {
        'apikey': key, 'module': 'contract', 'action': 'verifysourcecode',
        'contractaddress': address, 'sourceCode': json.dumps(compiler_input(artifact)),
        'codeformat': 'solidity-standard-json-input',
        'contractname': 'src/poolside/PoolsideFactory.sol:PoolsideFactory',
        'compilerversion': 'v' + artifact['metadata']['compiler']['version'],
        'constructorArguements': args,
    }
    request = urllib.request.Request('https://api.etherscan.io/v2/api?chainid=8453',
                                     data=urllib.parse.urlencode(payload).encode())
    with urllib.request.urlopen(request, timeout=120) as response:
        result = json.load(response)
    if result['status'] != '1':
        if 'already verified' not in result['result'].lower():
            raise SystemExit(result['result'])
    else:
        subprocess.run(['forge', 'verify-check', result['result'], '--chain', '8453'], cwd=ROOT, check=True)
    print('Verified PoolsideFactory:', 'https://basescan.org/address/' + address + '#code')


if __name__ == '__main__':
    main()
