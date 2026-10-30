#!/bin/zsh
set -eu

cd "${0:A:h}"
mkdir -p .build Reports

if ! command -v python3 >/dev/null 2>&1; then
  print -u2 -- "需要 python3 才能运行手机校准服务测试。"
  exit 1
fi

xcrun swiftc -O -swift-version 5 -parse-as-library \
  Sources/TimingEngine.swift Tests/TimingEngineTests.swift \
  -o .build/TimingEngineTests -framework ApplicationServices

task_test_status=0
xcrun swiftc -O -swift-version 5 -parse-as-library \
  Sources/DamaiRegionProfile.swift Tests/DamaiRegionProfileTests.swift \
  -o .build/DamaiRegionProfileTests -framework ApplicationServices
if ! .build/DamaiRegionProfileTests; then task_test_status=1; fi
xcrun swiftc -O -swift-version 5 -parse-as-library \
  Sources/TimingEngine.swift Sources/HoldClickEngine.swift Sources/ImmediateClickStart.swift Tests/ImmediateClickStartTests.swift \
  -o .build/ImmediateClickStartTests -framework ApplicationServices
if ! .build/ImmediateClickStartTests; then task_test_status=1; fi
xcrun swiftc -O -swift-version 5 -parse-as-library \
  Sources/BusinessReceiptReview.swift Tests/BusinessReceiptReviewTests.swift \
  -o .build/BusinessReceiptReviewTests -framework AppKit
if ! .build/BusinessReceiptReviewTests; then task_test_status=1; fi
task_node_binary="$(command -v node || true)"
if [[ -z "$task_node_binary" && -x "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node" ]]; then
  task_node_binary="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"
fi
if [[ -z "$task_node_binary" ]]; then
  print -u2 -- "开发测试需要 Node.js；发行 App 运行不需要。"; task_test_status=1
elif ! "$task_node_binary" Tests/PhoneCalibrationPageTests.js; then task_test_status=1; fi
xcrun swiftc -O -swift-version 5 -parse-as-library \
  Sources/TimingEngine.swift Sources/HoldClickEngine.swift Tests/HoldClickEngineTests.swift \
  -o .build/HoldClickEngineTests -framework ApplicationServices
if ! .build/HoldClickEngineTests; then task_test_status=1; fi
for test_name in DamaiPlanTests DamaiRunPolicyTests; do
  xcrun swiftc -O -swift-version 5 -parse-as-library Sources/DamaiPlan.swift Sources/DamaiRunPolicy.swift "Tests/$test_name.swift" -framework ApplicationServices -o ".build/$test_name"
  if ! ".build/$test_name"; then task_test_status=1; fi
done
xcrun swiftc -O -swift-version 5 -parse-as-library \
  Sources/TargetVisibility.swift Tests/TargetVisibilityTests.swift \
  -o .build/TargetVisibilityTests -framework ApplicationServices
if ! .build/TargetVisibilityTests; then
  task_test_status=1
fi
xcrun swiftc -O -swift-version 5 -parse-as-library \
  Sources/DamaiRegionProfile.swift Sources/TargetVisibility.swift Sources/WindowRelativeClickTarget.swift Tests/WindowRelativeClickTargetTests.swift \
  -o .build/WindowRelativeClickTargetTests -framework ApplicationServices
if ! .build/WindowRelativeClickTargetTests; then
  task_test_status=1
fi
xcrun swiftc -O -swift-version 5 -parse-as-library \
  Sources/CalibrationServer.swift Tests/CalibrationServerTests.swift \
  -o .build/CalibrationServerTests -framework Network
if ! .build/CalibrationServerTests; then
  task_test_status=1
fi
xcrun swiftc -O -swift-version 5 -parse-as-library \
  Sources/TimingEngine.swift Sources/NetworkTime.swift Tests/NetworkTimeTests.swift \
  -o .build/NetworkTimeTests -framework ApplicationServices
if ! .build/NetworkTimeTests; then
  task_test_status=1
fi
# The executable accepts the output path as its first argument, not --report.
# Its injected sender is empty: this run never posts system mouse events.
if ! .build/TimingEngineTests "$PWD/Reports/scheduler-benchmark.json"; then
  task_test_status=1
fi

if ! python3 -m unittest discover -s Calibration -p test_server.py -v; then
  task_test_status=1
fi

# Preserve raw timing samples and make an incomplete benchmark visible to callers.
if ! python3 - "$PWD/Reports/scheduler-benchmark.json" <<'PY'
import json
from pathlib import Path
import sys

report = Path(sys.argv[1])
if not report.is_file():
    print("调度基准报告未生成。", file=sys.stderr)
    raise SystemExit(1)
data = json.loads(report.read_text(encoding="utf-8"))
count = data.get("实际样本数", 0)
planned = data.get("计划样本数", 0)
status = data.get("状态")
print(f"调度基准原始报告：{report}")
if status != "completed" or count != planned or planned != 150:
    print(f"调度基准未完整完成：{count}/{planned}，状态 {status}；请检查原始报告。", file=sys.stderr)
    raise SystemExit(1)
print("调度基准完整完成；该结果仅代表调度器，不代表系统/手机接收精度。")
PY
then
  task_test_status=1
fi

exit "$task_test_status"
