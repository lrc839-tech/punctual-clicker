# 手机镜像路径校准协议与开发参考

发行 App 使用 `Sources/CalibrationServer.swift` 中的原生校准服务，网页已内置；普通用户直接点击 App 中的“手机镜像校准…”即可，无需 Python。

本目录保留 `server.py` 及其测试作为协议参考和开发回归工具。仅开发者需要单独运行参考服务时，才使用 `python3 server.py`。手机与 Mac 接入同一局域网，在手机 Safari 打开服务列出的网址。不要与 App 内置服务同时占用端口 18765。

1. 手机页面首次打开自动做20轮校时。页面用 `performance.timeOrigin + performance.now()` 的单调时间序列，与 Mac 墙钟做多轮往返校时，选最小 RTT 样本。显示校时年龄与不确定度；校时有效期60秒；新计划到来时如校时已超过40秒会提前刷新。
2. Mac 点击器向 `/test-plan` 发送计划。手机每500ms自动接收新计划并重置样本，无需每组手动刷新。手机 Safari 始终保持前台；通过 Mac iPhone 镜像选中页面蓝色靶区。
3. Mac 发送有固定节拍的测试点击，同时向 `/send-events` 写入每次实际 mouseUp 发出时刻。手机仅记录 `pointerup`（旧版浏览器降级 `touchend`），不同时监听合成 `click`，避免重复计数。
4. 查看 `/summary` 的实测中位延迟，再将该值作为提前补偿进行下一轮验证。需要同时记录 P95、最大绝对误差，不能只看中位数。

## HTTP 接口

- `GET /time` → `{receiveMs, sendMs}`，单位均为 Unix epoch 毫秒。
- `POST /test-plan` → `{runId:"唯一轮次", targetsMs:[...], compensationMs:0, expectedLatencyMs:240, label:"未补偿基线"}`。目标是手机应接收到 pointerup 的时刻；数组须严格递增。新计划会重置本轮样本。首次单击锚定时可省略expectedLatencyMs。
- `GET /plan` → 最近的测试计划。
- `POST /send-events` → `{runId,events:[{index:1,sentUpMs:...}]}`，index 从 1 开始。时间使用 Mac 实际全局 mouseUp 发出前的墙钟采样。允许分批追加/更新。
- `POST /samples` → `{runId,samples:[{index:1,receivedMacMs:...,eventType:"pointerup",...}],straySamples:[...],clock:{offsetMs,rttMs,uncertaintyEstimateMs,calibratedAtMacMs,...}}`。手机页面自动调用。
- `GET /summary` → `medianLatencyMs`（有真实发送记录才计算）、`p50ErrorMs`、`p95AbsErrorMs`、`maxAbsErrorMs`、`strayCount`、`missingCount`、`clockUncertaintyEstimateMs`、样本量及完整校时信息。
- `GET /report` → 本轮完整计划、样本与汇总。
- `GET /health` → 服务探活。

误差定义：`errorMs = receivedMacMs - targetMs`；正数为晚到。实际发送延迟：`latencyMs = receivedMacMs - sentUpMs`。如果缺实际发送记录，`estimatedMedianLatencyMs = median(errorMs + compensationMs)` 只是基于计划的估算，不可冒充实际输入延迟。

## 精度边界

RTT/2 是网络路径近似对称条件下的不确定度估计，不是严格误差上限。网页回调时间包含手机浏览器事件调度延迟，不能识别触屏采样的硬件时刻；也不等于大麦或券商确认收到业务请求的时刻。校准到 Mac 墙钟，不能单独证明 Mac 与票务/券商服务器的绝对时钟一致。

周期点击+未知延迟+可能漏首个事件，无法仅凭接收时刻唯一确定错了几拍。因此首次用1次单击锚定得到匹配用的粗延迟（允许最多3秒输入延迟），其后多次计划必须带expectedLatencyMs。按`received - (expectedLatencyMs - compensationMs)`寻找最近未消费目标，门限为`min(最短间隔×0.45,150ms)`；漏首个点击不会占用错误序号。没有基线的多次计划拒绝盲配index，超门限事件单独记为stray。开始窗口之前的手动点击直接忽略。正式补偿只有在多次完整样本、无stray的情况下才应采用；单击锚定不直接作为正式补偿。

页面自带“15 秒后 · 单击锚定”只生成计划，不会自动在页面触发伪造点击。真实镜像链路测试必须由 Mac 发出实际输入。

## 测试

运行 `python3 -m unittest discover -s . -p 'test_*.py'`。覆盖校时公式、计划校验、真实发送匹配、重复样本去重和 HTTP 接口，不代表已在真实 iPhone 镜像链路验收。
