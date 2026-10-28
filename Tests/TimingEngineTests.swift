import Foundation
import CoreGraphics

@main
enum TimingEngineTests {
    struct TestFailure: Error, CustomStringConvertible { let description: String }
    static var passed = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(description: message) }
    }
    static func check(_ title: String, _ action: () throws -> Void) throws {
        try action(); passed += 1; print("PASS \(title)")
    }
    static func configuration(after: Double = 0.1, frequency: Double = 20,
                              count: Int = 1, compensation: Double = 0,
                              hold: Double = 2) -> ClickConfiguration {
        ClickConfiguration(targetWallEpoch: PrecisionClock.wallNow() + after,
                           point: CGPoint(x: 30, y: 40), frequencyHz: frequency,
                           count: count, compensationMs: compensation, holdMs: hold)
    }
    static func awaitCompletion(_ engine: ClickEngine, _ config: ClickConfiguration,
                                timeout: Double = 10) throws -> ([ClickEvent], ClickCompletion) {
        let done = DispatchSemaphore(value: 0)
        var events: [ClickEvent] = []
        var completed: ClickCompletion?
        try engine.start(config, onEvent: { events.append($0) }, onComplete: {
            completed = $0; done.signal()
        })
        guard done.wait(timeout: .now() + timeout) == .success, let result = completed else {
            engine.cancel(); throw TestFailure(description: "引擎未在测试时限内结束")
        }
        return (events, result)
    }
    static func percentile(_ values: [Double], _ quantile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[Int((Double(sorted.count - 1) * quantile).rounded())]
    }

    static func main() throws {
        try check("拒绝非法配置") {
            var invalid = [ClickConfiguration]()
            var config = configuration(); config.count = 0; invalid.append(config)
            config = configuration(); config.frequencyHz = .nan; invalid.append(config)
            config = configuration(); config.frequencyHz = 101; invalid.append(config)
            config = configuration(count: 2, hold: 50); config.frequencyHz = 100; invalid.append(config)
            config = configuration(); config.compensationMs = 5001; invalid.append(config)
            config = configuration(); config.maximumLatenessMs = 0; invalid.append(config)
            for bad in invalid {
                do { try ClickEngine.validate(bad); throw TestFailure(description: "非法配置被接受") }
                catch is ClickEngineError { }
            }
        }
        try check("拒绝已过期或过远的时刻") {
            for delay in [-1.0, 172_801.0] {
                do {
                    _ = try awaitCompletion(ClickEngine(sender: { _, _, _ in }), configuration(after: delay))
                    throw TestFailure(description: "无效时刻被接受")
                } catch is ClickEngineError { }
            }
        }
        try check("拒绝无效区域、溢出边界和过多区域") {
            let good = CGRect(x: -100, y: 20, width: 30, height: 40)
            let invalidRegions: [[CGRect]] = [
                [.zero], [CGRect(x: 1, y: 2, width: -3, height: 4)],
                [CGRect(x: 1, y: 2, width: 3, height: 0)],
                [CGRect(x: CGFloat.nan, y: 2, width: 3, height: 4)],
                [CGRect(x: 1, y: 2, width: CGFloat.infinity, height: 4)],
                [CGRect(x: CGFloat.greatestFiniteMagnitude, y: 2,
                        width: CGFloat.greatestFiniteMagnitude, height: 4)],
                [CGRect(x: 1, y: 2, width: CGFloat.leastNonzeroMagnitude, height: 4)],
                [good, good, good]
            ]
            for regions in invalidRegions {
                var config = configuration(); config.regions = regions
                do { try ClickEngine.validate(config); throw TestFailure(description: "无效区域被接受") }
                catch is ClickEngineError { }
            }
        }
        try check("固定节拍、点击数量与补偿含义") {
            var phases: [(ClickPhase, Int)] = []
            let engine = ClickEngine(sender: { phase, _, index in phases.append((phase, index)) })
            let (events, result) = try awaitCompletion(engine, configuration(after: 0.15, frequency: 20,
                                                                           count: 6, compensation: 15, hold: 2))
            try expect(result.reason == "completed" && result.sentCount == 6, "点击次数不符")
            try expect(phases.count == 12 && events.count == 6, "事件对不完整")
            for (position, phase) in phases.enumerated() {
                try expect(phase.0 == (position % 2 == 0 ? .mouseDown : .mouseUp), "按下释放顺序错误")
                try expect(phase.1 == position / 2 + 1, "序号错误")
            }
            for (position, event) in events.enumerated() {
                try expect(event.regionIndex == nil && event.pointX == 30 && event.pointY == 40,
                           "固定点校准坐标发生改变")
                try expect(abs(PrecisionClock.signedMilliseconds(event.targetMonoNs,
                            event.plannedMouseUpMonoNs) - 15) < 0.001, "补偿方向错误")
                try expect(abs(PrecisionClock.signedMilliseconds(event.plannedMouseUpMonoNs,
                            event.plannedMouseDownMonoNs) - 2) < 0.001, "按住时长错误")
                if position > 0 {
                    try expect(abs(PrecisionClock.signedMilliseconds(event.targetMonoNs,
                                events[position - 1].targetMonoNs) - 50) < 0.001, "计划节拍发生漂移")
                }
            }
        }
        try check("单区域每次随机且按下释放与日志坐标一致") {
            let region = CGRect(x: -230, y: 70, width: 90, height: 60)
            var config = configuration(after: 0.15, frequency: 25, count: 12)
            config.regions = [region]
            var phases: [(ClickPhase, CGPoint, Int)] = []
            let engine = ClickEngine(sender: { phases.append(($0, $1, $2)) })
            let (events, result) = try awaitCompletion(engine, config)
            try expect(result.reason == "completed" && events.count == 12, "单区域随机点击次数错误")
            var points = Set<String>()
            for (offset, event) in events.enumerated() {
                let point = CGPoint(x: event.pointX, y: event.pointY)
                try expect(region.contains(point) && point.x < region.maxX && point.y < region.maxY,
                           "随机坐标落在区域外")
                try expect(event.regionIndex == 0, "单区域日志错误")
                let down = phases[offset * 2], up = phases[offset * 2 + 1]
                try expect(down.0 == .mouseDown && up.0 == .mouseUp && down.1 == point && up.1 == point &&
                           down.2 == event.index && up.2 == event.index, "按下释放坐标不同或日志未记录实际坐标")
                points.insert("\(event.pointX),\(event.pointY)")
            }
            try expect(points.count > 1, "重复使用同一个落点")
        }
        try check("双区域交替从A开始且奇偶总次数与总频率不翻倍") {
            let regions = [CGRect(x: 50, y: 60, width: 30, height: 40),
                           CGRect(x: 200, y: -100, width: 40, height: 30)]
            for count in [6, 7] {
                var config = configuration(after: 0.15, frequency: 20, count: count)
                config.regions = regions
                let (events, result) = try awaitCompletion(ClickEngine(sender: { _, _, _ in }), config)
                try expect(result.reason == "completed" && result.sentCount == count && events.count == count,
                           "双区域把总次数当作轮数")
                try expect(events.filter { $0.regionIndex == 0 }.count == (count + 1) / 2 &&
                           events.filter { $0.regionIndex == 1 }.count == count / 2, "奇偶次数分配错误")
                for (offset, event) in events.enumerated() {
                    let expected = offset % 2
                    try expect(event.regionIndex == expected &&
                               regions[expected].contains(CGPoint(x: event.pointX, y: event.pointY)),
                               "双区域未按 A/B 交替或坐标越界")
                    if offset > 0 {
                        try expect(abs(PrecisionClock.signedMilliseconds(event.targetMonoNs,
                                   events[offset - 1].targetMonoNs) - 50) < 0.001,
                                   "双区域将总频率当作每个区域频率")
                    }
                }
            }
        }
        try check("目标保护检查当前实际随机落点") {
            let regions = [CGRect(x: 50, y: 60, width: 30, height: 40),
                           CGRect(x: 200, y: -100, width: 40, height: 30)]
            var config = configuration(after: 0.15, frequency: 20, count: 5)
            config.regions = regions
            var checked: [CGPoint] = [], sent: [CGPoint] = []
            let engine = ClickEngine(sender: { _, point, _ in sent.append(point) }, validator: { point in
                checked.append(point); return regions[0].contains(point)
            })
            let (events, result) = try awaitCompletion(engine, config)
            try expect(result.reason == "targetChanged" && result.sentCount == 1 && events.count == 1,
                       "B区域保护失败后仍点击")
            try expect(checked.count == 2 && regions[0].contains(checked[0]) && regions[1].contains(checked[1]),
                       "保护检查未使用当前实际落点")
            try expect(sent.count == 2 && sent.allSatisfy { $0 == checked[0] }, "保护失败仍有鼠标事件")
        }
        try check("授时锚点纠正快慢，且不污染系统时钟跳变检测") {
            for offset in [-5.0,5.0] {
                let anchor = PrecisionClock.anchor()
                let reference = ClickTimeReference(epoch:anchor.wall+offset,monoNs:anchor.monoNs)
                let correctedTarget = reference.epoch+0.18
                let c = ClickConfiguration(targetWallEpoch:correctedTarget,point:CGPoint(x:30,y:40),frequencyHz:5,count:1,compensationMs:10,holdMs:2)
                let engine = ClickEngine(sender:{ _,_,_ in })
                let done = DispatchSemaphore(value:0)
                var events = [ClickEvent](); var completion:ClickCompletion?
                try engine.start(c,timeReference:reference,onEvent:{ events.append($0) },onComplete:{ completion = $0; done.signal() })
                try expect(done.wait(timeout:.now()+1) == .success,"授时锚点没有纠正目标等待时间")
                try expect(completion?.reason == "completed" && events.count == 1,"NTP 偏差被误判为系统时钟跳变")
                let plannedDelay = PrecisionClock.signedMilliseconds(events[0].targetMonoNs,anchor.monoNs)
                try expect(abs(plannedDelay-180)<0.002,"UTC→单调时钟目标映射错误")
                // Raw send timestamps must retain the Mac system epoch for phone calibration.
                let rawDifference = events[0].mouseUpWallEpoch-correctedTarget
                try expect(abs(rawDifference+offset+0.010)<0.1,"授时修正污染了原始 Mac 发送时间字段")
            }
        }
        try check("远期等待可立即取消且未发送点击") {
            var sent = 0
            let engine = ClickEngine(sender: { _, _, _ in sent += 1 })
            let done = DispatchSemaphore(value: 0)
            var completed: ClickCompletion?
            try engine.start(configuration(after: 30), onEvent: { _ in }, onComplete: {
                completed = $0; done.signal()
            })
            Thread.sleep(forTimeInterval: 0.03)
            let beforeCancel = PrecisionClock.nowNs()
            engine.cancel()
            try expect(done.wait(timeout: .now() + 0.2) == .success, "取消未及时响应")
            let cancelMs = PrecisionClock.signedMilliseconds(PrecisionClock.nowNs(), beforeCancel)
            try expect(cancelMs < 70 && sent == 0 && completed?.cancelled == true, "取消有误或发出意外点击")
        }
        try check("按下后取消仍释放鼠标") {
            let pressed = DispatchSemaphore(value: 0)
            let done = DispatchSemaphore(value: 0)
            var phases: [ClickPhase] = [], points: [CGPoint] = []
            var completion: ClickCompletion?
            let engine = ClickEngine(sender: { phase, point, _ in
                phases.append(phase)
                points.append(point)
                if phase == .mouseDown { pressed.signal() }
            })
            var config = configuration(after: 0.4, hold: 200)
            let region = CGRect(x: -200, y: -100, width: 30, height: 40)
            config.regions = [region]
            try engine.start(config, onEvent: { _ in }, onComplete: {
                completion = $0; done.signal()
            })
            try expect(pressed.wait(timeout: .now() + 1) == .success, "未收到按下")
            engine.cancel()
            try expect(done.wait(timeout: .now() + 0.2) == .success, "按下后取消超时")
            try expect(phases == [.mouseDown, .mouseUp], "取消造成鼠标未释放")
            try expect(points.count == 2 && points[0] == points[1] && region.contains(points[0]),
                       "紧急释放没有使用按下的随机坐标")
            try expect(completion?.emergencyReleasePerformed == true && completion?.sentCount == 0,
                       "按下后取消必须报告紧急释放，不能把当前次描述为未发生")
        }
        try check("紧急释放失败必须报告") {
            let pressed = DispatchSemaphore(value: 0)
            let done = DispatchSemaphore(value: 0)
            var completion: ClickCompletion?
            let engine = ClickEngine(sender: { phase, _, _ in
                if phase == .mouseDown { pressed.signal() }
                else { throw TestFailure(description: "模拟释放失败") }
            })
            try engine.start(configuration(after: 0.4, hold: 200), onEvent: { _ in }, onComplete: {
                completion = $0; done.signal()
            })
            try expect(pressed.wait(timeout: .now() + 1) == .success, "未收到按下")
            engine.cancel()
            try expect(done.wait(timeout: .now() + 0.2) == .success, "取消未完成")
            try expect(completion?.emergencyReleasePerformed == false &&
                       completion?.error?.contains("紧急释放鼠标失败") == true,
                       "紧急释放失败被吞掉或错误标记成功")
        }
        try check("目标保护失败不点击") {
            var sent = 0
            let engine = ClickEngine(sender: { _, _, _ in sent += 1 }, validator: { _ in false })
            let (_, result) = try awaitCompletion(engine, configuration())
            try expect(result.reason == "targetChanged" && sent == 0, "目标改变后仍发出点击")
        }
        try check("迟到停止，不爆发式追赶") {
            var downCount = 0
            let engine = ClickEngine(sender: { phase, _, _ in
                if phase == .mouseDown { downCount += 1; Thread.sleep(forTimeInterval: 0.025) }
            })
            let (_, result) = try awaitCompletion(engine, configuration(frequency: 100, count: 10, hold: 1))
            try expect(result.reason == "late" && downCount == 1, "迟到后继续追赶点击")
        }
        try check("运行中拒绝重复启动") {
            let engine = ClickEngine(sender: { _, _, _ in })
            let done = DispatchSemaphore(value: 0)
            try engine.start(configuration(after: 3), onEvent: { _ in }, onComplete: { _ in done.signal() })
            do {
                try engine.start(configuration(), onEvent: { _ in }, onComplete: { _ in })
                throw TestFailure(description: "接受了并发启动")
            } catch ClickEngineError.alreadyRunning { }
            engine.cancel()
            try expect(done.wait(timeout: .now() + 0.2) == .success, "取消未完成")
        }

        // No system events are posted. This benchmark measures the scheduler only.
        let (events, completion) = try awaitCompletion(ClickEngine(sender: { _, _, _ in }),
            configuration(after: 0.25, frequency: 50, count: 150, hold: 2), timeout: 8)
        let lateness = events.map(\.upLatenessMs)
        let report: [String: Any] = [
            "测试范围": "仅后台调度器；发送器为空，不是目标应用或手机接收延迟",
            "测试时间": ISO8601DateFormatter().string(from: Date()),
            "通过用例数": passed,
            "计划样本数": 150,
            "实际样本数": events.count,
            "未发送数": 150 - events.count,
            "频率_Hz": 50,
            "状态": completion.reason,
            "终止原因": completion.error ?? "已完整执行",
            "发出迟到毫秒_p50": percentile(lateness, 0.5),
            "发出迟到毫秒_p95": percentile(lateness, 0.95),
            "发出迟到毫秒_p99": percentile(lateness, 0.99),
            "发出迟到毫秒_最大": lateness.max() ?? 0,
            "发出迟到毫秒_最小": lateness.min() ?? 0,
            "事件": try events.map { event -> [String: Any] in
                let data = try JSONEncoder().encode(event)
                return try JSONSerialization.jsonObject(with: data) as! [String: Any]
            }
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let output = CommandLine.arguments.dropFirst().first {
            try data.write(to: URL(fileURLWithPath: output))
        }
        print("调度基准 \(events.count)/150，p50=\(percentile(lateness, 0.5)) ms，p95=\(percentile(lateness, 0.95)) ms，max=\(lateness.max() ?? 0) ms，\(completion.reason)")
        if completion.reason != "completed" || events.count != 150 {
            print("调度基准因系统抖动触发迟到保护而提前结束；保留全部原始样本，不将本次基准宣称为完整通过。")
        }
        print("\(passed) 项引擎行为测试通过；无真实鼠标事件发送。")
    }
}
