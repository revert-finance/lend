"""Offline regression tests for token-basis monitoring; no RPC or output files are used."""
import io
import os
import unittest
from contextlib import redirect_stdout
from unittest.mock import mock_open, patch

with patch.dict(os.environ, {"BASE_RPC_URL": "http://unused.invalid"}):
    import feed_roundwalk as monitor


def encoded(*values):
    return "0x" + "".join(f"{value:064x}" for value in values)


class FeedRoundwalkTest(unittest.TestCase):
    def run_monitor(self, multiplier, token_price=100, age=0):
        now = 1_710_000_000
        equity = monitor.EQUITIES[0]

        def rpc(batch):
            results = []
            for request in batch:
                method = request["method"]
                if method == "eth_getBlockByNumber":
                    result = {"timestamp": hex(now)}
                elif method == "eth_call":
                    call = request["params"][0]
                    selector = call["data"][:10]
                    if selector == monitor.SEL["aggregator()"]:
                        result = encoded(123)
                    elif selector == monitor.SEL["multiplier()"]:
                        result = encoded(multiplier)
                    elif selector == monitor.SEL["slot0()"]:
                        # Equal raw units: 100 USD per 8-decimal token against 6-decimal USDC.
                        result = encoded(2 ** 96)
                    elif selector == monitor.SEL["latestRound()"]:
                        result = encoded(1)
                    else:
                        self.assertIn(selector, (
                            monitor.SEL["latestRoundData()"], monitor.SEL["getRoundData(uint80)"]))
                        price = 1 if call["to"] == monitor.USDC_FEED else token_price
                        updated = now if call["to"] == monitor.USDC_FEED else now - age
                        result = encoded(1, price * 10 ** 8, updated, updated, 1)
                else:
                    self.fail(f"Unexpected RPC method: {method}")
                results.append({"id": request["id"], "result": result})
            return results

        with patch.dict(os.environ, {"BLOCK": "0x123"}), \
                patch.object(monitor, "EQUITIES", [equity]), \
                patch.object(monitor, "rpc", side_effect=rpc), \
                patch.object(monitor.os, "makedirs"), \
                patch("builtins.open", mock_open()), \
                patch.object(monitor.json, "dump") as dump, \
                redirect_stdout(io.StringIO()):
            exit_code = 0
            try:
                monitor.main()
            except SystemExit as exc:
                exit_code = exc.code
            return dump.call_args.args[0]["feeds"][0], exit_code

    def test_multiplier_is_informational_not_applied_again(self):
        for multiplier in (10 ** 18, 102 * 10 ** 16, 10 ** 19, 10 ** 17):
            with self.subTest(multiplier=multiplier):
                feed, exit_code = self.run_monitor(multiplier)
                self.assertEqual(feed["tokenAnswer"], 100)
                self.assertEqual(feed["priceBasis"], "token-total-return")
                self.assertEqual(feed["multiplier"], multiplier / 10 ** 18)
                self.assertEqual(feed["divergence"], 0)
                self.assertEqual(exit_code, 0)

    def test_weekend_holiday_and_shared_cutoff(self):
        for age in (24 * 3600, 48 * 3600, 116 * 3600 + 35 * 60, monitor.EQUITY_MAX_FEED_AGE):
            with self.subTest(age=age):
                feed, exit_code = self.run_monitor(10 ** 18, age=age)
                self.assertEqual(feed["oracleState"], "normal")
                self.assertEqual(exit_code, 0)
        feed, exit_code = self.run_monitor(10 ** 18, age=monitor.EQUITY_MAX_FEED_AGE + 1)
        self.assertEqual(feed["oracleState"], "valuation-blackout")
        self.assertEqual(exit_code, 1)

    def test_invalid_timestamp_alerts(self):
        for age in (-1, 1_710_000_000):
            with self.subTest(age=age):
                feed, exit_code = self.run_monitor(10 ** 18, age=age)
                self.assertEqual(feed["oracleState"], "invalid-timestamp")
                self.assertEqual(exit_code, 1)

    def test_real_token_price_divergence_still_alerts(self):
        feed, exit_code = self.run_monitor(10 ** 19, token_price=104)
        self.assertAlmostEqual(feed["divergence"], 0.04)
        self.assertEqual(exit_code, 1)


if __name__ == "__main__":
    unittest.main()
