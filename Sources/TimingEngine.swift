import Foundation
import CoreGraphics
import Darwin

// All monotonic values in this file use mach_absolute_time converted to nanoseconds.
// These are request timestamps, not a promise about another application's reception.
enum PrecisionClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    static func nowNs() -> UInt64 {
        UInt64(Double(mach_absolute_time()) * Double(timebase.numer) / Double(timebase.denom))
    }
    static func wallNow() -> Double { Date().timeIntervalSince1970 }
    static func anchor() -> (wall: Double, monoNs: UInt64, uncertaintyNs: UInt64) {
        let before = nowNs()
        let wall = wallNow()
        let after = nowNs()
        return (wall, before + (after - before) / 2, (after - before) / 2)
    }
    static func ticks(fromNs value: UInt64) -> UInt64 {
        UInt64(Double(value) * Double(timebase.denom) / Double(timebase.numer))
    }
    static func signedMilliseconds(_ actual: UInt64, _ planned: UInt64) -> Double {
        (Double(actual) - Double(planned)) / 1_000_000
    }
}

struct ClickConfiguration {
    /// Desired first mouse-up reception time in local wall-clock epoch seconds.
    var targetWallEpoch: Double
    var point: CGPoint
    var frequencyHz: Double
    var count: Int
    /// Positive values post earlier to compensate for measured transport/reception delay.
    var compensationMs: Double
    var holdMs: Double
    /// Stop instead of replaying an excessively overdue action.
    var maximumLatenessMs: Double = 50
}

/// A trusted epoch mapped to the monotonic clock. Kept separate from the raw
/// system-wall anchor used to detect clock changes during execution.
struct ClickTimeReference {
    let epoch: Double
    let monoNs: UInt64
    func epoch(at now: UInt64) -> Double {
        epoch + (Double(now) - Double(monoNs)) / 1e9
    }
}

enum ClickPhase: String, Codable { case mouseDown, mouseUp }

struct ClickEvent: Codable {
    let index: Int
    let targetWallEpoch: Double
    let targetMonoNs: UInt64
    let plannedMouseDownMonoNs: UInt64
    let plannedMouseUpMonoNs: UInt64
    let mouseDownCallStartMonoNs: UInt64
    let mouseDownCallEndMonoNs: UInt64
    let mouseUpCallStartMonoNs: UInt64
    let mouseUpCallEndMonoNs: UInt64
    let mouseDownWallEpoch: Double
    let mouseUpWallEpoch: Double
    let pointX: Double
    let pointY: Double

    var downLatenessMs: Double {
        PrecisionClock.signedMilliseconds(mouseDownCallStartMonoNs, plannedMouseDownMonoNs)
    }
    var upLatenessMs: Double {
        PrecisionClock.signedMilliseconds(mouseUpCallStartMonoNs, plannedMouseUpMonoNs)
    }
    var postCallDurationMs: Double {
        PrecisionClock.signedMilliseconds(mouseUpCallEndMonoNs, mouseUpCallStartMonoNs)
    }
    /// Actual request time minus the desired arrival time, so compensation is negative here.
    var requestVsTargetMs: Double {
        PrecisionClock.signedMilliseconds(mouseUpCallStartMonoNs, targetMonoNs)
    }
}

struct ClickCompletion: Codable {
    let reason: String
    let sentCount: Int
    let cancelled: Bool
    let error: String?
    /// A cancellation/error after mouse-down must still release the button. That release can
    /// trigger the current UI action even though no complete ClickEvent was emitted.
    var emergencyReleasePerformed: Bool = false
}

enum ClickEngineError: LocalizedError {
    case invalid(String)
    case alreadyRunning
    case eventCreation
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .alreadyRunning: return "已有点击任务正在执行，请先停止。"
        case .eventCreation: return "系统无法创建鼠标事件。"
        }
    }
}

/// Timing is performed on a dedicated worker. Callbacks are also on that worker.
/// A sender is injectable so scheduler tests never click any real application.
final class ClickEngine: @unchecked Sendable {
    typealias Sender = (ClickPhase, CGPoint, Int) throws -> Void
    typealias Validator = () -> Bool
    private let sender: Sender
    private let validator: Validator?
    private let lock = NSLock()
    private var activeID: UUID?
    private var cancelledID: UUID?

    init(sender: Sender? = nil, validator: Validator? = nil) {
        self.sender = sender ?? Self.postSystemEvent
        self.validator = validator
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return activeID != nil
    }

    static func postSystemEvent(_ phase: ClickPhase, _ point: CGPoint, _ index: Int) throws {
        let eventType: CGEventType = phase == .mouseDown ? .leftMouseDown : .leftMouseUp
        guard let event = CGEvent(mouseEventSource: nil, mouseType: eventType,
                                  mouseCursorPosition: point, mouseButton: .left) else {
            throw ClickEngineError.eventCreation
        }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        // Local calibration receiver can match index without relying on delivery order.
        event.setIntegerValueField(.eventSourceUserData, value: Int64(index))
        event.post(tap: .cghidEventTap)
    }

    func start(_ config: ClickConfiguration, timeReference: ClickTimeReference? = nil,
               onEvent: @escaping (ClickEvent) -> Void,
               onComplete: @escaping (ClickCompletion) -> Void) throws {
        try Self.validate(config)
        let anchor = PrecisionClock.anchor()
        if let reference = timeReference, !reference.epoch.isFinite {
            throw ClickEngineError.invalid("授时时间基准无效。")
        }
        let schedulingReference = timeReference ?? ClickTimeReference(epoch:anchor.wall,monoNs:anchor.monoNs)
        let nowWall = schedulingReference.epoch(at:anchor.monoNs)
        let nowMono = anchor.monoNs
        let downDelay = config.targetWallEpoch - nowWall - (config.compensationMs + config.holdMs) / 1000
        guard downDelay >= 0.02 else {
            throw ClickEngineError.invalid("首次点击发送时刻至少需要在 20 毫秒以后；请延后目标时间或减小提前量。")
        }
        guard downDelay <= 172_800 else {
            throw ClickEngineError.invalid("目标时间不能超过 48 小时以后。")
        }
        let runID = UUID()
        lock.lock()
        if activeID != nil { lock.unlock(); throw ClickEngineError.alreadyRunning }
        activeID = runID
        cancelledID = nil
        lock.unlock()

        let worker = Thread { [self] in
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
            execute(config, runID: runID, anchorWall: anchor.wall, anchorMono: nowMono,
                    schedulingReference:schedulingReference,
                    onEvent: onEvent, onComplete: onComplete)
        }
        worker.name = "准点点击器 · 高精度调度"
        worker.qualityOfService = .userInteractive
        worker.start()
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelledID = activeID
    }

    private func isCancelled(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledID == id || activeID != id
    }

    static func validate(_ config: ClickConfiguration) throws {
        let values = [config.targetWallEpoch, config.point.x, config.point.y, config.frequencyHz,
                      config.compensationMs, config.holdMs, config.maximumLatenessMs]
        guard values.allSatisfy({ $0.isFinite }) else {
            throw ClickEngineError.invalid("配置包含无效数字。")
        }
        guard (0.1...100).contains(config.frequencyHz) else {
            throw ClickEngineError.invalid("点击频率必须在 0.1～100 次/秒之间。")
        }
        guard (1...10_000).contains(config.count) else {
            throw ClickEngineError.invalid("点击次数必须在 1～10000 次之间。")
        }
        guard (-5000...5000).contains(config.compensationMs) else {
            throw ClickEngineError.invalid("延迟补偿必须在 -5000～5000 毫秒之间。")
        }
        guard (0.5...500).contains(config.holdMs) else {
            throw ClickEngineError.invalid("按住时长必须在 0.5～500 毫秒之间。")
        }
        guard config.count == 1 || config.holdMs + 1 <= 1000 / config.frequencyHz else {
            throw ClickEngineError.invalid("按住时长必须比相邻点击间隔至少短 1 毫秒。")
        }
        guard (1...1000).contains(config.maximumLatenessMs) else {
            throw ClickEngineError.invalid("最大迟到阈值必须在 1～1000 毫秒之间。")
        }
    }

    private enum WaitResult { case ready, cancelled, clockChanged }

    /// Coarse waits are capped at 20ms so cancellation and clock/sleep checks stay responsive.
    /// Only the last 2.5ms spins; this is best effort and is not a real-time OS guarantee.
    private func wait(until deadline: UInt64, id: UUID,
                      anchorWall: Double, anchorMono: UInt64) -> WaitResult {
        let spinNs: UInt64 = 2_500_000
        let sliceNs: UInt64 = 20_000_000
        var checkedAt = PrecisionClock.nowNs()
        while true {
            if isCancelled(id) { return .cancelled }
            let now = PrecisionClock.nowNs()
            if now >= deadline { return .ready }
            if now - checkedAt >= sliceNs {
                let expectedWall = anchorWall + Double(now - anchorMono) / 1e9
                if abs(PrecisionClock.wallNow() - expectedWall) > 0.1 { return .clockChanged }
                checkedAt = now
            }
            let remaining = deadline - now
            if remaining > spinNs {
                let sleepUntil = now + min(sliceNs, remaining - spinNs)
                mach_wait_until(PrecisionClock.ticks(fromNs: sleepUntil))
            } else {
                // Cancellation is checked on each spin iteration; never spin on the UI thread.
                while PrecisionClock.nowNs() < deadline {
                    if isCancelled(id) { return .cancelled }
                }
                return .ready
            }
        }
    }

    private func execute(_ config: ClickConfiguration, runID: UUID,
                         anchorWall: Double, anchorMono: UInt64,
                         schedulingReference: ClickTimeReference,
                         onEvent: (ClickEvent) -> Void,
                         onComplete: (ClickCompletion) -> Void) {
        let intervalNs = 1e9 / config.frequencyHz
        let holdNs = UInt64(config.holdMs * 1e6)
        let firstTarget = Double(schedulingReference.monoNs) + (config.targetWallEpoch - schedulingReference.epoch) * 1e9
        let compensationNs = config.compensationMs * 1e6
        var sent = 0
        var pressed = false
        var currentIndex = 0
        var completion = ClickCompletion(reason: "completed", sentCount: 0, cancelled: false, error: nil)

        func finish(_ reason: String, _ error: String? = nil) {
            completion = ClickCompletion(reason: reason, sentCount: sent,
                                         cancelled: reason == "cancelled", error: error)
        }

        defer {
            if pressed {
                do {
                    try sender(.mouseUp, config.point, currentIndex)
                    completion.emergencyReleasePerformed = true
                } catch {
                    let releaseError = "紧急释放鼠标失败：\(error.localizedDescription)；请手动释放鼠标并核对当前操作结果。"
                    let detail = [completion.error, releaseError].compactMap { $0 }.joined(separator: "\n")
                    completion = ClickCompletion(reason: completion.reason, sentCount: sent,
                                                 cancelled: completion.cancelled, error: detail)
                }
            }
            lock.lock()
            if activeID == runID { activeID = nil; cancelledID = nil }
            lock.unlock()
            onComplete(completion)
        }

        for index in 1...config.count {
            currentIndex = index
            // Derive every deadline from the original anchor, never from the previous actual click.
            let targetNs = UInt64(firstTarget + Double(index - 1) * intervalNs)
            let upNs = UInt64(Double(targetNs) - compensationNs)
            let downNs = upNs - holdNs
            switch wait(until: downNs, id: runID, anchorWall: anchorWall, anchorMono: anchorMono) {
            case .cancelled: finish("cancelled"); return
            case .clockChanged: finish("clockChanged", "系统时钟或睡眠状态发生变化，任务已停止，请重新校时并设置。"); return
            case .ready: break
            }
            if validator?() == false {
                finish("targetChanged", "目标窗口已改变，任务已停止。"); return
            }
            let downStart = PrecisionClock.nowNs()
            // At high frequencies, never burst overdue clicks to 'catch up'.
            let permittedLateness = min(config.maximumLatenessMs,
                                        config.count > 1 ? max(1, 500 / config.frequencyHz) : config.maximumLatenessMs)
            let downLateness = PrecisionClock.signedMilliseconds(downStart, downNs)
            if downLateness > permittedLateness {
                finish("late", String(format: "点击已迟到 %.3f 毫秒（阈值 %.3f 毫秒），任务已停止，未追赶补发。",
                                      downLateness, permittedLateness)); return
            }
            let downWall = PrecisionClock.wallNow()
            do {
                try sender(.mouseDown, config.point, index)
                pressed = true
                let downEnd = PrecisionClock.nowNs()
                // Preserve at least 0.5ms of actual press duration if down posting itself was late.
                let actualUpDeadline = max(upNs, downEnd + 500_000)
                switch wait(until: actualUpDeadline, id: runID, anchorWall: anchorWall, anchorMono: anchorMono) {
                case .cancelled: finish("cancelled"); return
                case .clockChanged: finish("clockChanged", "系统时钟或睡眠状态发生变化，任务已停止。"); return
                case .ready: break
                }
                let upStart = PrecisionClock.nowNs()
                let upWall = PrecisionClock.wallNow()
                try sender(.mouseUp, config.point, index)
                pressed = false
                let upEnd = PrecisionClock.nowNs()
                sent += 1
                let event = ClickEvent(index: index,
                                       targetWallEpoch: config.targetWallEpoch + Double(index - 1) / config.frequencyHz,
                                       targetMonoNs: targetNs,
                                       plannedMouseDownMonoNs: downNs,
                                       plannedMouseUpMonoNs: upNs,
                                       mouseDownCallStartMonoNs: downStart,
                                       mouseDownCallEndMonoNs: downEnd,
                                       mouseUpCallStartMonoNs: upStart,
                                       mouseUpCallEndMonoNs: upEnd,
                                       mouseDownWallEpoch: downWall, mouseUpWallEpoch: upWall,
                                       pointX: config.point.x, pointY: config.point.y)
                onEvent(event)
                // Release is essential, but a late release must not cause the next click to catch up.
                if event.upLatenessMs > permittedLateness {
                    finish("late", String(format: "鼠标释放已迟到 %.3f 毫秒（阈值 %.3f 毫秒），已停止后续点击，未追赶补发。",
                                          event.upLatenessMs, permittedLateness)); return
                }
            } catch {
                finish("error", error.localizedDescription); return
            }
        }
        finish("completed")
    }
}
