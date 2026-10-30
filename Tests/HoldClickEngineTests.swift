import Foundation
import CoreGraphics

@main
enum HoldClickEngineTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Posted { let phase: ClickPhase; let point: CGPoint; let index: Int; let time: UInt64 }
    final class Log: @unchecked Sendable {
        let lock = NSLock()
        var posts: [Posted] = [], records: [HoldClickRecord] = [], states: [Int?] = []
        var completion: String?
        let done = DispatchSemaphore(value: 0)
        func read<T>(_ body: (Log) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
        func post(_ phase: ClickPhase, _ point: CGPoint, _ index: Int) {
            read { $0.posts.append(Posted(phase: phase, point: point, index: index, time: PrecisionClock.nowNs())) }
        }
        func begin(_ engine: HoldClickEngine, _ settings: HoldClickSettings,
                   first: UInt64? = nil, extraEvent: ((HoldClickRecord) -> Void)? = nil) throws {
            try engine.start(settings, firstMouseUpMonoNs: first, onEvent: { record in
                self.read { $0.records.append(record) }; extraEvent?(record)
            }, onState: { state in self.read { $0.states.append(state) } }, onComplete: { reason in
                self.read { $0.completion = reason }; self.done.signal()
            })
        }
        func finish(_ engine: HoldClickEngine) throws {
            engine.cancel()
            try expect(done.wait(timeout: .now() + 2) == .success, "停止超时")
            try expect(!engine.isRunning, "完成后仍标记运行")
        }
    }
    final class MovingGeometry: @unchecked Sendable {
        private let lock = NSLock()
        private var rect: CGRect
        private var resolutions: [(Int, CGPoint, UInt64)] = []
        init(_ rect: CGRect) { self.rect = rect }
        func move(to newRect: CGRect) {
            lock.lock(); defer { lock.unlock() }; rect = newRect
        }
        func resolve(_ region: Int, _ unit: CGPoint) -> CGPoint? {
            lock.lock(); defer { lock.unlock() }
            resolutions.append((region, unit, PrecisionClock.nowNs()))
            return CGPoint(x: min(rect.minX + unit.x * rect.width, rect.maxX.nextDown),
                           y: min(rect.minY + unit.y * rect.height, rect.maxY.nextDown))
        }
        func read() -> [(Int, CGPoint, UInt64)] {
            lock.lock(); defer { lock.unlock() }; return resolutions
        }
    }
    static var passed = 0
    static let regions = [CGRect(x: 10, y: 10, width: 30, height: 30),
                          CGRect(x: 110, y: 50, width: 40, height: 40),
                          CGRect(x: 220, y: -30, width: 50, height: 50)]
    static func settings(base: Int = 0, rates: [Double] = [25, 25, 25], hold: Double = 2,
                         seconds: Double = 5) -> HoldClickSettings {
        HoldClickSettings(regions: regions, frequencies: rates, baseCount: base,
                          holdMs: hold, maximumSeconds: seconds)
    }
    static func expect(_ ok: @autoclosure () -> Bool, _ message: String) throws {
        if !ok() { throw Failure(description: message) }
    }
    static func wait(_ message: String, timeout: Double = 2, _ predicate: () -> Bool) throws {
        let end = PrecisionClock.nowNs() + UInt64(timeout * 1e9)
        while !predicate() {
            if PrecisionClock.nowNs() >= end { throw Failure(description: message) }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
    static func check(_ title: String, _ body: () throws -> Void) throws {
        try body(); passed += 1; print("PASS \(title)")
    }
    static func main() throws {
        try check("拒绝无效配置、边界和过期计划") {
            var bad: [HoldClickSettings] = []
            var s = settings(); s.regions = Array(regions.prefix(2)); bad.append(s)
            s = settings(); s.frequencies = [25, 25]; bad.append(s)
            s = settings(); s.frequencies[0] = .nan; bad.append(s)
            s = settings(); s.frequencies[2] = 101; bad.append(s)
            s = settings(); s.baseCount = -1; bad.append(s)
            s = settings(); s.baseCount = 10001; bad.append(s)
            s = settings(); s.holdMs = .infinity; bad.append(s)
            s = settings(); s.holdMs = 40; bad.append(s)
            s = settings(); s.maximumSeconds = 601; bad.append(s)
            s = settings(); s.regions[1] = .zero; bad.append(s)
            s = settings(); s.regions[1] = CGRect(x: CGFloat.infinity, y: 1, width: 5, height: 5); bad.append(s)
            for invalid in bad {
                do { try HoldClickEngine.validate(invalid); throw Failure(description: "非法配置通过") }
                catch is ClickEngineError { }
            }
            for first in [PrecisionClock.nowNs() - 1_000_000, PrecisionClock.nowNs() + 172_801_000_000_000] {
                do {
                    try HoldClickEngine(sender: { _, _, _ in }).start(settings(), firstMouseUpMonoNs: first,
                        onEvent: { _ in }, onState: { _ in }, onComplete: { _ in })
                    throw Failure(description: "无效首次时间通过")
                } catch is ClickEngineError { }
            }
        }
        try check("默认底部随机落点、成对事件与固定节拍") {
            let log = Log(), engine = HoldClickEngine(sender: { log.post($0, $1, $2) })
            try log.begin(engine, settings(base: 6))
            try wait("底部未限次暂停") { log.read { $0.records.count == 6 && $0.states.last! == nil } }
            Thread.sleep(forTimeInterval: 0.09)
            let snapshot = log.read { ($0.posts, $0.records) }
            try expect(snapshot.0.count == 12 && snapshot.1.count == 6, "限次后仍点击")
            for (i, record) in snapshot.1.enumerated() {
                let down = snapshot.0[2 * i], up = snapshot.0[2 * i + 1]
                try expect(down.phase == .mouseDown && up.phase == .mouseUp && down.index == up.index,
                           "鼠标事件不成对")
                try expect(down.point == up.point && regions[0].contains(down.point), "按下释放位置错误")
                try expect(record.regionIndex == 0 && record.event.regionIndex == 0 && record.generation == 1,
                           "默认区域或日志世代错误")
                try expect(record.event.pointX == down.point.x && record.event.pointY == down.point.y, "日志坐标错误")
                if i > 0 {
                    try expect(abs(PrecisionClock.signedMilliseconds(record.event.plannedMouseDownMonoNs,
                        snapshot.1[i - 1].event.plannedMouseDownMonoNs) - 40) < 0.001, "固定节拍漂移")
                }
            }
            try expect(Set(snapshot.0.filter { $0.phase == .mouseDown }.map { "\($0.point.x),\($0.point.y)" }).count > 1,
                       "落点未随机")
            try log.finish(engine)
        }
        try check("按住中切区先原地释放，不跨区拖鼠标") {
            let down = DispatchSemaphore(value: 0)
            let log = Log(), engine = HoldClickEngine(sender: { phase, point, index in
                log.post(phase, point, index)
                if phase == .mouseDown && index == 1 { down.signal() }
            })
            try log.begin(engine, settings(base: 0, rates: [2, 2, 2], hold: 400))
            try expect(down.wait(timeout: .now() + 1) == .success, "未按下底部")
            engine.press(1)
            let switched = PrecisionClock.nowNs()
            try wait("切区未产生区域一点击") { log.read { $0.records.contains { $0.regionIndex == 1 } } }
            try log.finish(engine)
            let posts = log.read { $0.posts }
            try expect(posts.count >= 4 && posts[0].phase == .mouseDown && posts[1].phase == .mouseUp &&
                       posts[0].point == posts[1].point && posts[2].phase == .mouseDown && regions[1].contains(posts[2].point),
                       "切区未先原地释放")
            try expect(posts.filter { $0.phase == .mouseDown && $0.time >= switched }.allSatisfy { regions[1].contains($0.point) },
                       "切换返回后仍发送旧区域按下")
            try expect(PrecisionClock.signedMilliseconds(posts[1].time, posts[0].time) < 200 &&
                       PrecisionClock.signedMilliseconds(posts[2].time, switched) < 200,
                       "切换等待了完整的 400ms 持有时长")
        }
        try check("旧键释放不影响新键，旧键按住也不恢复") {
            let log = Log(), engine = HoldClickEngine(sender: { log.post($0, $1, $2) })
            try log.begin(engine, settings(base: 1))
            try wait("初始底部未暂停") { log.read { $0.records.count == 1 && $0.states.last! == nil } }
            engine.press(1)
            try wait("区域一未运行") { log.read { $0.records.contains { $0.regionIndex == 1 } } }
            engine.press(2)
            try wait("区域二未运行") { log.read { $0.records.contains { $0.regionIndex == 2 } } }
            engine.release(1)
            let boundary = log.read { $0.records.count }
            try wait("区域二未继续") { log.read { $0.records.count >= boundary + 2 } }
            try expect(log.read { $0.records.suffix(2).allSatisfy { $0.regionIndex == 2 } }, "释放旧键覆盖新键")
            engine.press(1) // Region two remains held, but a new press of one takes over.
            try wait("区域一未重新接管") { log.read { $0.records.last?.regionIndex == 1 } }
            engine.release(1)
            try wait("释放当前键没有回底部") { log.read { $0.records.last?.regionIndex == 0 && $0.states.last! == nil } }
            let count = log.read { $0.records.count }
            Thread.sleep(forTimeInterval: 0.12)
            try expect(log.read { $0.records.count == count }, "仍按着的旧键二被自动恢复")
            engine.release(2)
            Thread.sleep(forTimeInterval: 0.05)
            try expect(log.read { $0.records.count == count }, "旧键二释放触发了额外底部轮次")
            try log.finish(engine)
        }
        try check("切换与提交共用锁，切换返回后不能再提交旧区按下") {
            let entered = DispatchSemaphore(value: 0), permit = DispatchSemaphore(value: 0)
            let attempting = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
            let log = Log(), engine = HoldClickEngine(sender: { phase, point, index in
                log.post(phase, point, index)
                if phase == .mouseDown && index == 1 {
                    entered.signal(); _ = permit.wait(timeout: .now() + 1)
                }
            })
            try log.begin(engine, settings(rates: [5, 5, 5], hold: 100))
            try expect(entered.wait(timeout: .now() + 1) == .success, "sender 未进入")
            DispatchQueue.global().async {
                attempting.signal(); engine.press(1); returned.signal()
            }
            try expect(attempting.wait(timeout: .now() + 1) == .success, "切换线程未启动")
            try expect(returned.wait(timeout: .now() + 0.02) == .timedOut, "sender 提交未与切换互斥")
            permit.signal()
            try expect(returned.wait(timeout: .now() + 1) == .success, "切换锁未释放")
            let switched = PrecisionClock.nowNs()
            try wait("切换后未点击新区域") { log.read { $0.records.contains { $0.regionIndex == 1 } } }
            try log.finish(engine)
            try expect(log.read { $0.posts.filter { $0.phase == .mouseDown && $0.time >= switched }
                .allSatisfy { regions[1].contains($0.point) } }, "切换返回后旧区仍有新按下")
        }
        try check("重复按下被忽略，底部键可重启限次，松开底部不停止") {
            let log = Log(), engine = HoldClickEngine(sender: { log.post($0, $1, $2) })
            try log.begin(engine, settings(base: 2, rates: [10, 10, 10]))
            try wait("初始底部未暂停") { log.read { $0.records.count == 2 && $0.states.last! == nil } }
            engine.press(0); engine.release(0)
            try wait("松开底部错误停止了当前轮") { log.read { $0.records.count == 4 && $0.states.last! == nil } }
            engine.press(0)
            try wait("底部重启失败") { log.read { $0.records.count == 6 && $0.states.last! == nil } }
            for _ in 0..<10 { engine.press(0) }
            Thread.sleep(forTimeInterval: 0.15)
            try expect(log.read { $0.records.count == 6 }, "重复键盘按下重启了轮次")
            try log.finish(engine)
        }
        try check("返回底部重置本轮次数，各区频率独立") {
            let log = Log(), engine = HoldClickEngine(sender: { log.post($0, $1, $2) })
            try log.begin(engine, settings(base: 3, rates: [5, 40, 10]))
            try wait("底部首击未完成") { log.read { $0.records.count >= 1 } }
            engine.press(1)
            try wait("区域一没有独立连点") { log.read { $0.records.filter { $0.regionIndex == 1 }.count >= 3 } }
            engine.release(1)
            try wait("底部未完成重置后的三次") { log.read { $0.records.filter { $0.regionIndex == 0 }.count == 4 && $0.states.last! == nil } }
            let records = log.read { $0.records }
            let override = records.filter { $0.regionIndex == 1 }
            try expect(abs(PrecisionClock.signedMilliseconds(override[1].event.plannedMouseDownMonoNs,
                        override[0].event.plannedMouseDownMonoNs) - 25) < 0.001, "区域一频率未生效")
            try expect(records.filter { $0.regionIndex == 0 }.suffix(3).allSatisfy { $0.generation > 1 }, "底部未新建轮次")
            try log.finish(engine)
        }
        try check("等待阶段切换不提前首击，计划使用绝对单调时钟") {
            let log = Log(), engine = HoldClickEngine(sender: { log.post($0, $1, $2) })
            let first = PrecisionClock.nowNs() + 300_000_000
            try log.begin(engine, settings(base: 1), first: first)
            engine.press(1); engine.press(2)
            Thread.sleep(forTimeInterval: 0.15)
            try expect(log.read { $0.posts.isEmpty }, "按键使计划首击提前")
            try wait("计划首击未完成") { log.read { !$0.records.isEmpty } }
            try log.finish(engine)
            let record = log.read { $0.records[0] }, post = log.read { $0.posts[0] }
            try expect(record.regionIndex == 2 && record.event.plannedMouseUpMonoNs == first,
                       "等待时最新区域或绝对计划丢失")
            try expect(post.time >= first - 2_000_000 && record.event.mouseUpCallStartMonoNs >= first,
                       "计划事件提前发送")
        }
        try check("延时等待后才解析坐标，首次点击采用移动后的窗口") {
            let old = CGRect(x: 800, y: 500, width: 40, height: 30)
            let moved = CGRect(x: -1100, y: -200, width: 80, height: 60)
            let geometry = MovingGeometry(old), log = Log()
            let engine = HoldClickEngine(sender: { log.post($0, $1, $2) },
                                         pointResolver: geometry.resolve)
            let first = PrecisionClock.nowNs() + 300_000_000
            try log.begin(engine, settings(base: 1), first: first)
            Thread.sleep(forTimeInterval: 0.12)
            try expect(geometry.read().isEmpty && log.read { $0.posts.isEmpty }, "等待时缓存了旧坐标")
            geometry.move(to: moved)
            try wait("移动后首击未完成") { log.read { $0.records.count == 1 } }
            try log.finish(engine)
            let posts = log.read { $0.posts }, resolutions = geometry.read()
            try expect(posts.count == 2 && moved.contains(posts[0].point) &&
                       posts[0].point == posts[1].point, "首击仍使用旧窗口或释放不同位置")
            try expect(resolutions.count == 1 && resolutions[0].0 == 0 &&
                       resolutions[0].2 >= first - 2_000_000, "解析坐标早于发送时刻")
            try expect((0..<1).contains(resolutions[0].1.x) && (0..<1).contains(resolutions[0].1.y),
                       "随机单位坐标不在半开区间内")
        }
        try check("运行期间每次按下重新映射，切区使用最新区域号") {
            let old = CGRect(x: 800, y: 500, width: 40, height: 30)
            let moved = CGRect(x: -1100, y: -200, width: 80, height: 60)
            let geometry = MovingGeometry(old), log = Log()
            let engine = HoldClickEngine(sender: { log.post($0, $1, $2) },
                                         pointResolver: geometry.resolve)
            try log.begin(engine, settings(base: 1, rates: [5, 5, 5]))
            try wait("移动前首击未完成") { log.read { $0.records.count == 1 } }
            geometry.move(to: moved)
            engine.press(2)
            try wait("移动并切区后未产生新点击") { log.read { $0.records.contains { $0.regionIndex == 2 } } }
            try log.finish(engine)
            let records = log.read { $0.records }, resolutions = geometry.read()
            try expect(old.contains(CGPoint(x: records[0].event.pointX, y: records[0].event.pointY)),
                       "首击未使用原始窗口")
            try expect(records.dropFirst().allSatisfy {
                $0.regionIndex == 2 && moved.contains(CGPoint(x: $0.event.pointX, y: $0.event.pointY))
            }, "移动或切区后仍用旧窗口坐标")
            try expect(resolutions.dropFirst().allSatisfy { $0.0 == 2 }, "解析器收到旧区域号")
        }
        try check("按住期间移动窗口，释放保持本次按下原坐标") {
            let down = DispatchSemaphore(value: 0)
            let old = CGRect(x: 800, y: 500, width: 40, height: 30)
            let moved = CGRect(x: -1100, y: -200, width: 80, height: 60)
            let geometry = MovingGeometry(old), log = Log()
            let engine = HoldClickEngine(sender: { phase, point, index in
                log.post(phase, point, index); if phase == .mouseDown { down.signal() }
            }, pointResolver: geometry.resolve)
            try log.begin(engine, settings(base: 1, rates: [2, 2, 2], hold: 350))
            try expect(down.wait(timeout: .now() + 1) == .success, "未收到鼠标按下")
            geometry.move(to: moved)
            try wait("移动后原地释放未完成") { log.read { $0.records.count == 1 } }
            try log.finish(engine)
            let posts = log.read { $0.posts }
            try expect(posts.count == 2 && posts[0].point == posts[1].point && old.contains(posts[1].point),
                       "窗口移动导致原地按下变成跨窗口拖动")
            try expect(geometry.read().count == 1, "释放时重新解析了另一个坐标")
        }
        try check("坐标解析失败或非有限数值时停止，不发送或进入后续保护") {
            for resolved in [nil, CGPoint(x: CGFloat.nan, y: 1), CGPoint(x: 1, y: CGFloat.infinity)] as [CGPoint?] {
                let log = Log()
                var validated = false
                let engine = HoldClickEngine(sender: { log.post($0, $1, $2) },
                    validator: { _ in validated = true; return true },
                    pointResolver: { _, _ in resolved })
                try log.begin(engine, settings())
                try expect(log.done.wait(timeout: .now() + 1) == .success, "无效坐标解析未停止")
                try expect(log.read { $0.posts.isEmpty && $0.completion == "targetChanged" }, "无效坐标仍点击")
                try expect(!validated, "无效坐标传给后续保护器")
            }
        }
        try check("低频旧区域等待可被按键唤醒，不排队旧动作") {
            let log = Log(), engine = HoldClickEngine(sender: { log.post($0, $1, $2) })
            try log.begin(engine, settings(rates: [0.5, 25, 25]))
            try wait("底部首击未完成") { log.read { !$0.records.isEmpty } }
            let pressedAt = PrecisionClock.nowNs()
            engine.press(1)
            try wait("区域切换仍在等待旧的两秒周期", timeout: 0.4) { log.read { $0.records.contains { $0.regionIndex == 1 } } }
            let first = log.read { $0.records.first { $0.regionIndex == 1 }! }
            try expect(PrecisionClock.signedMilliseconds(first.event.mouseDownCallStartMonoNs, pressedAt) < 300,
                       "按键未立即唤醒")
            try log.finish(engine)
        }
        try check("计划首击已经按下后切换也不提前释放") {
            let down = DispatchSemaphore(value: 0)
            let log = Log(), engine = HoldClickEngine(sender: { phase, point, index in
                log.post(phase, point, index)
                if phase == .mouseDown && index == 1 { down.signal() }
            })
            let first = PrecisionClock.nowNs() + 250_000_000
            try log.begin(engine, settings(rates: [5, 5, 5], hold: 100), first: first)
            try expect(down.wait(timeout: .now() + 1) == .success, "计划首次按下未发生")
            engine.press(1)
            try wait("计划首次释放未发生") { log.read { !$0.records.isEmpty } }
            let record = log.read { $0.records[0] }
            try expect(record.event.mouseUpCallStartMonoNs >= first, "切换在计划首击持有期间导致提前点击")
            try log.finish(engine)
        }
        try check("按下后取消仍原地释放，且不发送新按下") {
            let down = DispatchSemaphore(value: 0)
            let log = Log(), engine = HoldClickEngine(sender: { phase, point, index in
                log.post(phase, point, index); if phase == .mouseDown { down.signal() }
            })
            try log.begin(engine, settings(rates: [4, 4, 4], hold: 200))
            try expect(down.wait(timeout: .now() + 1) == .success, "未收到按下")
            try log.finish(engine)
            let posts = log.read { $0.posts }
            try expect(posts.count == 2 && posts[0].phase == .mouseDown && posts[1].phase == .mouseUp &&
                       posts[0].point == posts[1].point, "取消未原地释放或产生额外点击")
            try expect(log.read { $0.completion == "cancelled" && $0.records.count == 1 }, "已释放动作未记录")
        }
        try check("长暂停后重置节拍，不集中补发") {
            let log = Log(), engine = HoldClickEngine(sender: { log.post($0, $1, $2) })
            try log.begin(engine, settings(base: 4, rates: [20, 20, 20]), extraEvent: { record in
                if record.event.index == 1 { Thread.sleep(forTimeInterval: 0.22) }
            })
            try wait("暂停后的有限轮次未完成") { log.read { $0.records.count == 4 && $0.states.last! == nil } }
            let down = log.read { $0.posts.filter { $0.phase == .mouseDown } }
            try expect(PrecisionClock.signedMilliseconds(down[1].time, down[0].time) >= 240,
                       "暂停后未在未来重置")
            for i in 2..<down.count {
                try expect(PrecisionClock.signedMilliseconds(down[i].time, down[i - 1].time) >= 25,
                           "迟到事件集中补发")
            }
            try log.finish(engine)
        }
        try check("保护拒绝和发送错误均停止，按下异常仍尝试释放") {
            let log = Log(), engine = HoldClickEngine(sender: { log.post($0, $1, $2) }, validator: { _ in false })
            try log.begin(engine, settings())
            try expect(log.done.wait(timeout: .now() + 1) == .success, "保护拒绝未停止")
            try expect(log.read { $0.posts.isEmpty && $0.completion == "targetChanged" }, "保护拒绝后仍点击")
            let errorLog = Log(), errorEngine = HoldClickEngine(sender: { phase, point, index in
                errorLog.post(phase, point, index)
                if phase == .mouseDown { throw Failure(description: "模拟 sender 已提交后抛错") }
            })
            try errorLog.begin(errorEngine, settings())
            try expect(errorLog.done.wait(timeout: .now() + 1) == .success, "发送异常未停止")
            try expect(errorLog.read { $0.posts.map { $0.phase } == [.mouseDown, .mouseUp] && $0.completion!.hasPrefix("error:") },
                       "发送异常后未保守释放")
        }
        try check("限次暂停仍有总时长上限，重复启动被拒绝") {
            let log = Log(), engine = HoldClickEngine(sender: { log.post($0, $1, $2) })
            try log.begin(engine, settings(base: 1, seconds: 1))
            do {
                try engine.start(settings(), onEvent: { _ in }, onState: { _ in }, onComplete: { _ in })
                throw Failure(description: "允许重复启动")
            } catch is ClickEngineError { }
            try expect(log.done.wait(timeout: .now() + 2) == .success, "暂停后无最大运行限制")
            try expect(log.read { $0.records.count == 1 && $0.completion == "maximumDuration" }, "总时长停止错误")
        }
        print("HoldClickEngineTests: \(passed) checks passed; injected sender only, no real clicks.")
    }
}
