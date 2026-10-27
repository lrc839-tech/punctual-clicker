#!/usr/bin/env python3
"""Local-only Safari/iPhone Mirroring timing calibration. Python stdlib only."""
from __future__ import annotations

import argparse
import ipaddress
import json
import math
from pathlib import Path
import socket
import statistics
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
DEFAULT_REPORT = ROOT.parent / "Reports" / "phone-calibration.json"
MAX_BODY = 2 * 1024 * 1024


def epoch_ms():
    return time.time_ns() / 1_000_000


def finite_number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{name} 必须是有限数值")
    return float(value)


def percentile(values, p):
    ordered = sorted(values)
    if not ordered:
        return None
    pos = (len(ordered) - 1) * p
    lo, hi = math.floor(pos), math.ceil(pos)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (pos - lo)


def clock_estimate(client_send, server_receive, server_send, client_receive):
    """NTP-style midpoint estimate; asymmetry means RTT/2 is not a guarantee."""
    values = [finite_number(v, "clock timestamp") for v in
              (client_send, server_receive, server_send, client_receive)]
    t0, t1, t2, t3 = values
    rtt = max(0.0, (t3 - t0) - (t2 - t1))
    return {"offsetMs": ((t1 - t0) + (t2 - t3)) / 2,
            "rttMs": rtt, "uncertaintyEstimateMs": rtt / 2}


def match_target(received_ms, targets, consumed=(), compensation_ms=0, expected_latency_ms=None):
    """Match known-latency runs; an unknown periodic phase is intentionally refused."""
    available = [(i + 1, target) for i, target in enumerate(targets) if i + 1 not in consumed]
    if not available:
        return None
    if expected_latency_ms is None:
        # A single-click baseline is the only unambiguous anchor without a prior.
        if len(targets) != 1:
            return None
        idx, target = available[0]
        delta = received_ms - (target - compensation_ms)
        return idx if -100 <= delta <= 3000 else None
    adjusted = received_ms - (expected_latency_ms - compensation_ms)
    idx, target = min(available, key=lambda row: abs(adjusted - row[1]))
    gaps = [b - a for a, b in zip(targets, targets[1:])]
    tolerance = min(min(gaps) * .45, 150) if gaps else 150
    return idx if abs(adjusted - target) <= tolerance else None


class CalibrationState:
    def __init__(self, report_path=DEFAULT_REPORT):
        self.report_path = Path(report_path)
        self.lock = threading.RLock()
        self.plan = {"runId": "", "targetsMs": [], "compensationMs": 0,
                     "label": "尚未收到测试计划"}
        self.samples = {}
        self.stray_samples = []
        self.send_events = {}
        self.clock = {}

    def set_plan(self, body):
        run_id = body.get("runId")
        targets = body.get("targetsMs")
        if not isinstance(run_id, str) or not run_id or len(run_id) > 128:
            raise ValueError("runId 需要是非空字符串，最长128字符")
        if not isinstance(targets, list) or not 1 <= len(targets) <= 10000:
            raise ValueError("targetsMs 需要包含1到10000个目标时间")
        targets = [finite_number(x, "targetMs") for x in targets]
        if any(b <= a for a, b in zip(targets, targets[1:])):
            raise ValueError("目标时间必须严格递增")
        comp = finite_number(body.get("compensationMs", 0), "compensationMs")
        latency = body.get("expectedLatencyMs")
        if latency is not None:
            latency = finite_number(latency, "expectedLatencyMs")
        with self.lock:
            self.plan = {"runId": run_id, "targetsMs": targets, "compensationMs": comp,
                         "expectedLatencyMs": latency,
                         "label": str(body.get("label", "镜像路径测试"))[:160], "createdAtMs": epoch_ms()}
            self.samples = {}
            self.stray_samples = []
            self.send_events = {}
            self.clock = {}
            self.save()
            return dict(self.plan)

    def ingest_samples(self, body):
        with self.lock:
            if body.get("runId") != self.plan["runId"] or not self.plan["runId"]:
                raise ValueError("测试计划已改变，请刷新手机页面")
            samples = body.get("samples", [])
            if not isinstance(samples, list) or len(samples) > 10000:
                raise ValueError("samples 格式无效")
            for sample in samples:
                if not isinstance(sample, dict):
                    raise ValueError("sample 格式无效")
                idx = sample.get("index")
                if isinstance(idx, bool) or not isinstance(idx, int) or not 1 <= idx <= len(self.plan["targetsMs"]):
                    raise ValueError("sample index 越界")
                received = finite_number(sample.get("receivedMacMs"), "receivedMacMs")
                clean = {key: sample[key] for key in ("eventType", "phonePerfMs", "offsetMs", "rttMs", "uncertaintyEstimateMs") if key in sample}
                clean.update(index=idx, receivedMacMs=received)
                self.samples[idx] = clean
            stray = body.get("straySamples", [])
            if not isinstance(stray, list) or len(stray) > 10000:
                raise ValueError("straySamples 格式无效")
            self.stray_samples = [dict(x) for x in stray if isinstance(x, dict)]
            clock = body.get("clock")
            if isinstance(clock, dict):
                self.clock = {k: v for k, v in clock.items() if k in
                              ("offsetMs", "rttMs", "uncertaintyEstimateMs", "calibratedAtMacMs", "rounds", "ageMs")}
            self.save()
            return self.summary()

    def ingest_sends(self, body):
        with self.lock:
            if body.get("runId") != self.plan["runId"] or not self.plan["runId"]:
                raise ValueError("runId 不匹配")
            events = body.get("events")
            if not isinstance(events, list) or len(events) > 10000:
                raise ValueError("events 格式无效")
            for event in events:
                idx = event.get("index")
                if isinstance(idx, bool) or not isinstance(idx, int) or not 1 <= idx <= len(self.plan["targetsMs"]):
                    raise ValueError("event index 越界")
                self.send_events[idx] = finite_number(event.get("sentUpMs"), "sentUpMs")
            self.save()
            return self.summary()

    def enriched_samples(self):
        result = []
        for idx, sample in sorted(self.samples.items()):
            row = dict(sample)
            target = self.plan["targetsMs"][idx - 1]
            row.update(targetMs=target, errorMs=row["receivedMacMs"] - target,
                       estimatedLatencyMs=row["receivedMacMs"] - target + self.plan["compensationMs"])
            if idx in self.send_events:
                row.update(sentUpMs=self.send_events[idx], latencyMs=row["receivedMacMs"] - self.send_events[idx])
            result.append(row)
        return result

    def summary(self):
        with self.lock:
            rows = self.enriched_samples()
            errors = [x["errorMs"] for x in rows]
            latencies = [x["latencyMs"] for x in rows if "latencyMs" in x]
            calibrated_at = self.clock.get("calibratedAtMacMs")
            clock_age = max(0.0, epoch_ms() - calibrated_at) if isinstance(calibrated_at, (int, float)) else None
            return {"runId": self.plan["runId"], "sampleCount": len(rows),
                    "plannedCount": len(self.plan["targetsMs"]), "matchedSendCount": len(latencies),
                    "strayCount": len(self.stray_samples),
                    "missingCount": max(0, len(self.plan["targetsMs"]) - len(rows)),
                    "clockUncertaintyEstimateMs": self.clock.get("uncertaintyEstimateMs"),
                    "clockRttMs": self.clock.get("rttMs"),
                    "clockAgeMs": clock_age, "clockFresh": clock_age is not None and clock_age <= 60000,
                    "medianLatencyMs": percentile(latencies, .5), "p95LatencyMs": percentile(latencies, .95),
                    "p50ErrorMs": percentile(errors, .5),
                    "p95AbsErrorMs": percentile([abs(x) for x in errors], .95),
                    "maxAbsErrorMs": max([abs(x) for x in errors], default=None),
                    "estimatedMedianLatencyMs": percentile([x["estimatedLatencyMs"] for x in rows], .5),
                    "compensationMs": self.plan["compensationMs"], "clock": self.clock,
                    "measurementBoundary": "Mac CGEvent mouseUp 发送到手机 Safari pointerup 回调；不是大麦或券商业务回执",
                    "clockCaveat": "RTT/2只作网络对称假设下的校时不确定度估计，不是准确度保证。",
                    "reportPath": str(self.report_path), "updatedAtMs": epoch_ms()}

    def save(self):
        self.report_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"version": 1, "plan": self.plan, "summary": self.summary(),
                   "samples": self.enriched_samples(), "sendEvents": self.send_events,
                   "straySamples": self.stray_samples}
        tmp = self.report_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")
        tmp.replace(self.report_path)


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            # /time and polling are intentionally quiet.
            if self.path not in ("/time", "/plan", "/summary", "/health"):
                super().log_message(fmt, *args)

        def respond(self, data, status=200):
            if isinstance(data, bytes):
                payload, mime = data, "text/html; charset=utf-8"
            else:
                payload = json.dumps(data, ensure_ascii=False, allow_nan=False).encode("utf-8")
                mime = "application/json; charset=utf-8"
            self.send_response(status)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            received = epoch_ms()
            path = urlsplit(self.path).path
            if path == "/time":
                self.respond({"receiveMs": received, "sendMs": epoch_ms()})
            elif path == "/health":
                self.respond({"ok": True, "service": "准点点击器手机校准", "version": 1})
            elif path == "/":
                self.respond((ROOT / "index.html").read_bytes())
            elif path == "/plan":
                with state.lock:
                    self.respond(dict(state.plan))
            elif path == "/summary":
                self.respond(state.summary())
            elif path == "/report":
                with state.lock:
                    self.respond({"plan": state.plan, "summary": state.summary(), "samples": state.enriched_samples(), "straySamples": state.stray_samples})
            else:
                self.respond({"error": "not found"}, 404)

        def do_POST(self):
            # No CORS permission is granted. Reject cross-origin browser writes.
            origin = self.headers.get("Origin")
            if origin and urlsplit(origin).netloc != self.headers.get("Host"):
                return self.respond({"error": "仅接受同源请求"}, 403)
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= MAX_BODY:
                    raise ValueError("请求内容为空或过大")
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict):
                    raise ValueError("JSON需要是对象")
                routes = {"/test-plan": state.set_plan, "/samples": state.ingest_samples,
                          "/send-events": state.ingest_sends}
                route = routes.get(urlsplit(self.path).path)
                if route is None:
                    return self.respond({"error": "not found"}, 404)
                self.respond(route(body))
            except (ValueError, TypeError, KeyError, json.JSONDecodeError) as error:
                self.respond({"error": str(error)}, 400)
    return Handler


def local_addresses():
    result = {"127.0.0.1"}
    try:
        for row in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            result.add(row[4][0])
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            # UDP connect chooses local interface; no packet is sent.
            sock.connect(("192.0.2.1", 9))
            result.add(sock.getsockname()[0])
    except OSError:
        pass
    return sorted(result, key=lambda ip: (ip.startswith("127."), ip))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), make_handler(CalibrationState(args.report)))
    print("手机与 Mac 连接同一局域网，在手机 Safari 打开：", flush=True)
    for address in local_addresses():
        print(f"  http://{address}:{args.port}", flush=True)
    print("数据仅保存本机；只测 Safari 镜像输入路径。Ctrl-C 停止。", flush=True)
    try:
        server.serve_forever(poll_interval=.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
