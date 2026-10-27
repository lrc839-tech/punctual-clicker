import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer
from urllib.request import Request, urlopen

from server import CalibrationState, clock_estimate, make_handler, match_target


class CalibrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = CalibrationState(Path(self.temp.name) / "report.json")

    def tearDown(self):
        self.temp.cleanup()

    def test_symmetric_clock_offset(self):
        value = clock_estimate(1000, 1105, 1107, 1012)
        self.assertEqual(value["offsetMs"], 100)
        self.assertEqual(value["rttMs"], 10)
        self.assertEqual(value["uncertaintyEstimateMs"], 5)

    def test_no_latency_without_actual_send(self):
        self.state.set_plan({"runId": "a", "targetsMs": [1000], "compensationMs": 5})
        result = self.state.ingest_samples({"runId": "a", "samples": [{"index": 1, "receivedMacMs": 1002}]})
        self.assertIsNone(result["medianLatencyMs"])
        self.assertEqual(result["p50ErrorMs"], 2)
        self.assertEqual(result["estimatedMedianLatencyMs"], 7)

    def test_matching_and_deduplication(self):
        self.state.set_plan({"runId": "a", "targetsMs": [1000, 1500]})
        row = {"index": 1, "receivedMacMs": 1002}
        self.state.ingest_samples({"runId": "a", "samples": [row, row]})
        result = self.state.ingest_sends({"runId": "a", "events": [{"index": 1, "sentUpMs": 990}]})
        self.assertEqual(result["sampleCount"], 1)
        self.assertEqual(result["medianLatencyMs"], 12)
        self.assertEqual(result["p95AbsErrorMs"], 2)
        self.assertEqual(json.loads(self.state.report_path.read_text())["samples"][0]["latencyMs"], 12)

    def test_unknown_latency_requires_single_anchor(self):
        self.assertEqual(match_target(1240, [1000]), 1)
        self.assertIsNone(match_target(1240, [1000, 1500]))
        self.assertIsNone(match_target(5000, [1000]))

    def test_missing_first_event_does_not_shift_indexes(self):
        targets = [1000, 1500, 2000]
        # 240ms baseline is larger than a naive 150ms matching window.
        self.assertEqual(match_target(1740, targets, expected_latency_ms=240), 2)
        self.assertEqual(match_target(2240, targets, consumed={2}, expected_latency_ms=240), 3)

    def test_compensation_and_stray_matching(self):
        targets = [1000, 1500, 2000]
        self.assertEqual(match_target(1502, targets, compensation_ms=240, expected_latency_ms=240), 2)
        self.assertIsNone(match_target(1290, targets, expected_latency_ms=0))
        self.assertIsNone(match_target(1502, targets, consumed={2}, expected_latency_ms=0))

    def test_summary_counts_stray_missing_and_clock(self):
        self.state.set_plan({"runId": "a", "targetsMs": [1000, 1500], "expectedLatencyMs": 240})
        result = self.state.ingest_samples({"runId": "a", "samples": [{"index": 2, "receivedMacMs": 1740}],
                                           "straySamples": [{"receivedMacMs": 1400}],
                                           "clock": {"rttMs": 6, "uncertaintyEstimateMs": 3}})
        self.assertEqual(result["missingCount"], 1)
        self.assertEqual(result["strayCount"], 1)
        self.assertEqual(result["clockUncertaintyEstimateMs"], 3)
        self.assertEqual(result["clockRttMs"], 6)

    def test_clock_freshness(self):
        self.state.set_plan({"runId": "fresh", "targetsMs": [1000]})
        self.state.ingest_samples({"runId": "fresh", "samples": [],
                                   "clock": {"calibratedAtMacMs": time.time() * 1000 - 5000}})
        self.assertTrue(self.state.summary()["clockFresh"])
        self.state.clock["calibratedAtMacMs"] = time.time() * 1000 - 61000
        self.assertFalse(self.state.summary()["clockFresh"])

    def test_invalid_plan_and_stale_samples(self):
        with self.assertRaises(ValueError):
            self.state.set_plan({"runId": "a", "targetsMs": [2, 1]})
        self.state.set_plan({"runId": "a", "targetsMs": [1000]})
        with self.assertRaises(ValueError):
            self.state.ingest_samples({"runId": "b", "samples": []})
        with self.assertRaises(ValueError):
            self.state.ingest_samples({"runId": "a", "samples": [{"index": 2, "receivedMacMs": 1}]})

    def test_http_endpoints(self):
        service = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.state))
        thread = threading.Thread(target=service.serve_forever, daemon=True)
        thread.start()
        base = "http://127.0.0.1:%d" % service.server_port
        try:
            with urlopen(base + "/time") as response:
                clock = json.load(response)
            self.assertGreaterEqual(clock["sendMs"], clock["receiveMs"])
            body = json.dumps({"runId": "http", "targetsMs": [1000]}).encode()
            with urlopen(Request(base + "/test-plan", data=body, headers={"Content-Type": "application/json"})) as response:
                self.assertEqual(json.load(response)["runId"], "http")
            with urlopen(base + "/") as response:
                self.assertIn("校时 20 轮", response.read().decode())
        finally:
            service.shutdown()
            service.server_close()


if __name__ == "__main__":
    unittest.main()
