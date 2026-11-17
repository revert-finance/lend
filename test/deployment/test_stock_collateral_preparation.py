"""Regression tests for stale actionable output after a failed preparation run."""
import copy
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('prepare_stock', ROOT / 'script/prepare-aero-stock-collateral.py')
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)


class StaleOutputTest(unittest.TestCase):
    def test_failed_preflight_removes_previous_calldata(self):
        config = json.loads((ROOT / 'config/aero-stock-collateral.json').read_text())
        for failure in ['invalid_json', 'missing_signer', 'rpc_failure', 'unexpected_owner']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp)
                outputs = [out / 'safe-batch.json', out / 'plan.json']
                for path in outputs:
                    path.write_text('{"transactions": [{"data": "old calldata"}]}')
                unrelated = out / 'notes.txt'
                unrelated.write_text('keep me')
                adapters = out / 'adapters.json'
                adapters.write_text('invalid' if failure == 'invalid_json' else json.dumps({
                    asset['symbol']: '0x' + f'{index + 1:040x}'
                    for index, asset in enumerate(config['assets'])
                }))
                argv = ['prepare', '--adapters', str(adapters), '--out', str(out)]
                if failure == 'missing_signer':
                    argv += ['--broadcast']
                seen_owner = []

                def response(request, **kwargs):
                    if failure == 'rpc_failure':
                        raise OSError('offline')
                    call = json.loads(request.data)
                    method, params = call['method'], call['params']
                    if method == 'eth_chainId':
                        result = hex(8453)
                    elif method == 'eth_blockNumber':
                        result = '0x1'
                    elif method == 'eth_getBlockByNumber':
                        result = {'timestamp': '0x1'}
                    elif method == 'eth_getCode':
                        result = '0x01'
                    elif method == 'eth_call':
                        signature = params[0]['data']
                        bindings = {'oracle()': config['oracle'], 'nonfungiblePositionManager()': config['npm'],
                                    'factory()': config['factory'], 'referenceToken()':
                                    '0x4200000000000000000000000000000000000006',
                                    'chainlinkReferenceToken()': PREPARE.ZERO, 'owner()': PREPARE.ZERO}
                        if signature == 'owner()':
                            seen_owner.append(params[0]['to'])
                        value = 200 if signature == 'maxPoolPriceDifference()' else int(bindings[signature], 16)
                        result = '0x' + f'{value:064x}'
                    else:
                        self.fail('Unexpected RPC: ' + method)
                    return io.BytesIO(json.dumps({'result': result}).encode())

                with patch('sys.argv', argv), patch.dict('os.environ', {'BASE_RPC_URL': 'http://example.invalid'}, clear=True), \
                     patch.object(PREPARE, 'encode', side_effect=lambda signature, *args: signature), \
                     patch.object(PREPARE.urllib.request, 'urlopen', side_effect=response), \
                     patch.object(PREPARE.subprocess, 'run') as send, contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises((SystemExit, json.JSONDecodeError)) as caught:
                        PREPARE.main()
                    if failure == 'unexpected_owner':
                        self.assertEqual(str(caught.exception), 'Unexpected configuration owner.')
                        self.assertEqual(len(seen_owner), 2)
                    send.assert_not_called()
                for path in outputs:
                    self.assertFalse(path.exists(), f'Stale {path.name} survived {failure}')
                self.assertEqual(unrelated.read_text(), 'keep me')
                self.assertTrue(adapters.exists())


class ExposurePolicyTest(unittest.TestCase):
    def setUp(self):
        self.config = json.loads((ROOT / 'config/aero-stock-collateral.json').read_text())

    def test_reviewed_per_stock_limits_round_down(self):
        self.assertEqual(PREPARE.exposure_caps(self.config),
                         {'NVDAc': 429496729, 'TSLAc': 214748364, 'GOOGLc': 429496729})

    def test_rejects_unreviewed_and_malformed_limits(self):
        for index, too_high in [(0, 1001), (1, 501), (2, 1001)]:
            for value in [too_high, 0, -1, True, 500.5, None]:
                with self.subTest(index=index, value=value):
                    config = copy.deepcopy(self.config)
                    config['assets'][index]['collateralValueLimitBps'] = value
                    with self.assertRaises(SystemExit):
                        PREPARE.exposure_caps(config)

    def test_rejects_duplicate_or_missing_stock(self):
        self.config['assets'][2] = self.config['assets'][0]
        with self.assertRaises(SystemExit):
            PREPARE.exposure_caps(self.config)


if __name__ == '__main__':
    unittest.main()
