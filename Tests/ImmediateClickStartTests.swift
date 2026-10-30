import Foundation
import CoreGraphics

@main
enum ImmediateClickStartTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var passed = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }
    static func check(_ title: String, _ body: () throws -> Void) throws {
        try body(); passed += 1; print("PASS \(title)")
    }
    static func rejects(_ body: () throws -> UInt64?) throws {
        do { _ = try body(); throw Failure(description: "非法启动时间通过") }
        catch is ImmediateClickStart.StartError { }
    }
    struct Posted { let phase: ClickPhase; let point: CGPoint; let time: UInt64 }
    final class Log: @unchecked Sendable {
        let lock = NSLock(), done = DispatchSemaphore(value: 0)
        var posts: [Posted] = [], records: [HoldClickRecord] = []
        var completion: String?
        func read<T>(_ action: (Log) -> T) -> T { lock.lock(); defer { lock.unlock() }; return action(self) }
        func post(_ phase: ClickPhase, _ point: CGPoint, _: Int) {
            read { $0.posts.append(Posted(phase: phase, point: point, time: PrecisionClock.nowNs())) }
        }
        func begin(_ engine: HoldClickEngine, first: UInt64?, region: Int = 0) throws {
            try engine.start(settings, firstMouseUpMonoNs: first, initialRegion: region,
                onEvent: { record in self.read { $0.records.append(record) } }, onState: { _ in },
                onComplete: { reason in self.read { $0.completion = reason }; self.done.signal() })
        }
        func finish(_ engine: HoldClickEngine) throws {
            engine.cancel()
            try expect(done.wait(timeout: .now() + 1) == .success && !engine.isRunning, "引擎停止超时")
        }
    }
    static let regions = [CGRect(x: 10, y: 10, width: 30, height: 30),
                          CGRect(x: 100, y: 10, width: 30, height: 30),
                          CGRect(x: 200, y: 10, width: 30, height: 30)]
    static var settings: HoldClickSettings {
        HoldClickSettings(regions: regions, frequencies: [10, 10, 10], baseCount: 1,
                          holdMs: 2, maximumSeconds: 5)
    }
    static func wait(_ message: String, _ predicate: () -> Bool) throws {
        let end = PrecisionClock.nowNs() + 2_000_000_000
        while !predicate() {
            if PrecisionClock.nowNs() >= end { throw Failure(description: message) }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    static func main() throws {
        try check("首击按下从按钮时刻起算，不额外叠加激活耗时") {
            let request: UInt64 = 1_000_000_000
            let helper = ImmediateClickStart(requestedMonoNs: request, delayMs: 3000)
            try expect(try helper.firstMouseUp(readyMonoNs: request + 100_000_000, holdMs: 8) == 4_008_000_000,
                       "3000ms 延迟或 hold 映射错误")
            try expect(try ImmediateClickStart(requestedMonoNs: request, delayMs: 0.0000001)
                .firstMouseUp(readyMonoNs: request - 100_000_000, holdMs: 0.5000001) == request + 500_002,
                       "不足一纳秒的延迟或 hold 被向下截断")
        }
        try check("激活耗尽延迟时从就绪后20ms开始，接近到期也保留余量") {
            let request: UInt64 = 1_000_000_000, ready: UInt64 = 1_100_000_000
            for delay in [40.0, 100, 110] {
                let up = try ImmediateClickStart(requestedMonoNs: request, delayMs: delay)
                    .firstMouseUp(readyMonoNs: ready, holdMs: 8)
                try expect(up == 1_128_000_000, "未保留就绪后的20ms余量")
            }
        }
        try check("零延迟保持nil即时路径，仍校验hold") {
            try expect(try ImmediateClickStart(requestedMonoNs: .max, delayMs: 0)
                .firstMouseUp(readyMonoNs: .max, holdMs: 0.5) == nil, "零延迟未使用即时路径")
            try rejects { try ImmediateClickStart(requestedMonoNs: 0, delayMs: 0).firstMouseUp(readyMonoNs: 0, holdMs: 0) }
        }
        try check("拒绝无效范围和非有限数字，接受合法端点") {
            for delay in [-0.1, 60_000.1, Double.nan, .infinity, -.infinity] {
                try rejects { try ImmediateClickStart(requestedMonoNs: 0, delayMs: delay).firstMouseUp(readyMonoNs: 0, holdMs: 8) }
            }
            for hold in [0.499, 500.001, Double.nan, .infinity, -.infinity] {
                try rejects { try ImmediateClickStart(requestedMonoNs: 0, delayMs: 1).firstMouseUp(readyMonoNs: 0, holdMs: hold) }
            }
            try expect(try ImmediateClickStart(requestedMonoNs: 0, delayMs: 60_000)
                .firstMouseUp(readyMonoNs: 0, holdMs: 500) == 60_500_000_000, "合法端点被改变")
        }
        try check("请求、就绪余量和最终hold三处溢出均拒绝") {
            try rejects { try ImmediateClickStart(requestedMonoNs: .max, delayMs: 1).firstMouseUp(readyMonoNs: 0, holdMs: 8) }
            try rejects { try ImmediateClickStart(requestedMonoNs: 0, delayMs: 1).firstMouseUp(readyMonoNs: .max, holdMs: 8) }
            try rejects { try ImmediateClickStart(requestedMonoNs: UInt64.max - 1_000_000, delayMs: 1)
                .firstMouseUp(readyMonoNs: 0, holdMs: 0.5) }
        }
        if CommandLine.arguments.contains("--deterministic-only") {
            print("ImmediateClickStartTests: \(passed) deterministic checks passed; real-thread waits remain in the full local suite.")
            return
        }
        try check("实际注入引擎等待200ms期间切区仍不提前发送") {
            let request = PrecisionClock.nowNs()
            let first = try ImmediateClickStart(requestedMonoNs: request, delayMs: 200)
                .firstMouseUp(readyMonoNs: PrecisionClock.nowNs(), holdMs: settings.holdMs)
            let log = Log(), engine = HoldClickEngine(sender: { log.post($0, $1, $2) })
            try log.begin(engine, first: first)
            engine.press(2)
            Thread.sleep(forTimeInterval: 0.1)
            try expect(log.read { $0.posts.isEmpty }, "切区导致200ms延迟提前发送")
            try wait("延迟后的首击未发生") { log.read { !$0.records.isEmpty } }
            try log.finish(engine)
            let post = log.read { $0.posts[0] }, record = log.read { $0.records[0] }
            try expect(post.time >= request + 200_000_000 && record.regionIndex == 2 && regions[2].contains(post.point),
                       "实际按下提前或未采用等待中的最新区域")
        }
        try check("initialRegion2原子启动，不先发底部；松开即回底部") {
            let log = Log(), engine = HoldClickEngine(sender: { log.post($0, $1, $2) })
            try log.begin(engine, first: nil, region: 2)
            try wait("初始区域二未点击") { log.read { !$0.records.isEmpty } }
            let initial = log.read { $0.records }
            try expect(initial.allSatisfy { $0.regionIndex == 2 } &&
                       log.read { regions[2].contains($0.posts[0].point) }, "初始区域生效前先发送底部")
            engine.press(2) // Auto-repeat of the already-held initial key must be ignored.
            engine.release(2)
            try wait("初始held状态未建立，释放不能回底部") { log.read { $0.records.contains { $0.regionIndex == 0 } } }
            try log.finish(engine)
            try expect(log.read { $0.records.first!.generation == 1 &&
                       $0.records.first { $0.regionIndex == 0 }!.generation == 2 }, "初始键重复按下未被忽略")
        }
        try check("等待延迟中取消没有任何鼠标发送") {
            let request = PrecisionClock.nowNs()
            let first = try ImmediateClickStart(requestedMonoNs: request, delayMs: 200)
                .firstMouseUp(readyMonoNs: request, holdMs: settings.holdMs)
            let log = Log(), engine = HoldClickEngine(sender: { log.post($0, $1, $2) })
            try log.begin(engine, first: first, region: 2)
            engine.press(1); engine.release(1)
            try log.finish(engine)
            try expect(log.read { $0.posts.isEmpty && $0.records.isEmpty && $0.completion == "cancelled" }, "取消后仍发送")
        }
        try check("非法initialRegion在启动前被拒绝") {
            for region in [-1, 3] {
                do {
                    try HoldClickEngine(sender: { _, _, _ in }).start(settings, initialRegion: region,
                        onEvent: { _ in }, onState: { _ in }, onComplete: { _ in })
                    throw Failure(description: "非法 initialRegion 通过")
                } catch is ClickEngineError { }
            }
        }
        print("ImmediateClickStartTests: \(passed) checks passed; injected sender only, no real clicks.")
    }
}
