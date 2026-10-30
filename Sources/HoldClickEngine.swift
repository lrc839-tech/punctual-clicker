import Foundation
import CoreGraphics
import Darwin

struct HoldClickSettings {
    var regions: [CGRect]
    var frequencies: [Double]
    /// Zero repeats the base region indefinitely. A positive value pauses each
    /// base-region turn after that many completed clicks.
    var baseCount: Int
    var holdMs: Double
    var maximumSeconds: Double
}

struct HoldClickRecord {
    let event: ClickEvent
    let regionIndex: Int
    let generation: Int
}

/// One mouse, one worker, one current region. Region zero is the base; regions
/// one and two are temporary overrides. Callbacks run on the worker. Injected
/// senders/validators/resolvers must not synchronously call back into this engine: mouse
/// posting and key transitions deliberately share the same condition lock.
final class HoldClickEngine: @unchecked Sendable {
    /// Resolve a fresh screen point from the selected region and a random unit
    /// point in [0, 1). Called on the worker only after its deadline wait. A
    /// missing/invalid target returns nil and stops before posting mouse-down.
    typealias PointResolver = (_ regionIndex: Int, _ unitPoint: CGPoint) -> CGPoint?

    private let sender: ClickEngine.Sender
    private let validator: ClickEngine.Validator?
    private let pointResolver: PointResolver?
    private let condition = NSCondition()
    private var runID: UUID?
    private var stopReason: String?
    private var selected: Int?
    private var generation = 0
    private var held = Set<Int>()
    private var baseSent = 0

    init(sender: ClickEngine.Sender? = nil, validator: ClickEngine.Validator? = nil,
         pointResolver: PointResolver? = nil) {
        self.sender = sender ?? ClickEngine.postSystemEvent
        self.validator = validator
        self.pointResolver = pointResolver
    }

    var isRunning: Bool {
        condition.lock(); defer { condition.unlock() }
        return runID != nil
    }

    static func validate(_ settings: HoldClickSettings) throws {
        guard settings.regions.count == 3, settings.frequencies.count == 3 else {
            throw ClickEngineError.invalid("三键方案必须设置三个区域和三个频率。")
        }
        guard settings.frequencies.allSatisfy({ $0.isFinite && (0.1...100).contains($0) }),
              settings.holdMs.isFinite, (0.5...500).contains(settings.holdMs),
              settings.frequencies.allSatisfy({ settings.holdMs + 1 <= 1000 / $0 }) else {
            throw ClickEngineError.invalid("频率须为 0.1～100 次/秒，按住时长须为 0.5～500 毫秒且比各区域间隔至少短 1 毫秒。")
        }
        guard (0...10_000).contains(settings.baseCount), settings.maximumSeconds.isFinite,
              (1...600).contains(settings.maximumSeconds) else {
            throw ClickEngineError.invalid("底部每轮次数须为 0～10000（0 表示持续），最长运行须为 1～600 秒。")
        }
        for r in settings.regions {
            let values = [r.origin.x, r.origin.y, r.size.width, r.size.height,
                          r.minX, r.maxX, r.minY, r.maxY]
            guard values.allSatisfy({ $0.isFinite }), r.width > 0, r.height > 0,
                  r.maxX > r.minX, r.maxY > r.minY else {
                throw ClickEngineError.invalid("点击区域必须是宽高大于 0 的有效矩形。")
            }
        }
    }

    /// Keep the original cadence while there is room for another click. Once
    /// a hold overruns that slot, leave a complete interval after its release;
    /// never replay the missed slot immediately as a catch-up burst.
    static func nextDownDeadline(previousPlannedDown: UInt64, interval: UInt64,
                                 actualUpEnd: UInt64) -> UInt64 {
        let nominal = previousPlannedDown + interval
        return nominal > actualUpEnd + 1_000_000 ? nominal : actualUpEnd + interval
    }

    /// The caller maps NTP and any reception compensation to this absolute
    /// monotonic mouse-up deadline before starting. Waiting is excluded from
    /// maximumSeconds. No mouse-down is posted before deadline minus holdMs.
    func start(_ settings: HoldClickSettings, firstMouseUpMonoNs: UInt64? = nil,
               initialRegion: Int = 0,
               onEvent: @escaping (HoldClickRecord) -> Void,
               onState: @escaping (Int?) -> Void,
               onComplete: @escaping (String) -> Void) throws {
        try Self.validate(settings)
        guard (0..<3).contains(initialRegion) else {
            throw ClickEngineError.invalid("初始点击区域必须是 0、1 或 2。")
        }
        let anchor = PrecisionClock.anchor()
        let holdNs = UInt64(settings.holdMs * 1e6)
        let firstUp = firstMouseUpMonoNs ?? (anchor.monoNs + holdNs)
        guard firstUp >= anchor.monoNs + holdNs,
              firstUp - anchor.monoNs <= 172_800_000_000_000 else {
            throw ClickEngineError.invalid("首次发送时间已过期、按住时间不足或超过 48 小时。")
        }
        let id = UUID()
        condition.lock()
        guard runID == nil else { condition.unlock(); throw ClickEngineError.alreadyRunning }
        runID = id; stopReason = nil; selected = initialRegion; generation = 1
        held = initialRegion == 0 ? [] : [initialRegion]; baseSent = 0
        condition.unlock()
        let reference = ClickTimeReference(epoch: anchor.wall, monoNs: anchor.monoNs)
        let worker = Thread { [self] in
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
            execute(settings, id: id, firstDown: firstUp - holdNs,
                    firstUpFloor: firstMouseUpMonoNs ?? 0, reference: reference,
                    onEvent: onEvent, onState: onState, onComplete: onComplete)
        }
        worker.name = "准点点击器 · 三键互斥调度"
        worker.qualityOfService = .userInteractive
        worker.start()
    }

    func press(_ region: Int) {
        guard (0..<3).contains(region) else { return }
        condition.lock(); defer { condition.unlock() }
        guard runID != nil, stopReason == nil, held.insert(region).inserted else { return }
        selected = region; generation += 1
        if region == 0 { baseSent = 0 }
        condition.broadcast()
    }

    func release(_ region: Int) {
        guard (0..<3).contains(region) else { return }
        condition.lock(); defer { condition.unlock() }
        guard runID != nil, held.remove(region) != nil else { return }
        // A formerly active key neither restores itself nor overrides a newer
        // key when released. Releasing zero never stops the base turn.
        if region != 0, selected == region, stopReason == nil {
            selected = 0; generation += 1; baseSent = 0
            condition.broadcast()
        }
    }

    func cancel() {
        condition.lock(); defer { condition.unlock() }
        guard runID != nil else { return }
        stopReason = "cancelled"; condition.broadcast()
    }

    private enum WaitResult { case ready, changed, stopped }

    /// Enter and return with condition locked. Unlike a sleep, a key transition
    /// wakes this wait. A tiny final spin is only ever on the worker thread.
    private func waitLocked(until deadline: UInt64, end: UInt64, id: UUID,
                            expectedGeneration: Int?, reference: ClickTimeReference) -> WaitResult {
        while true {
            guard runID == id, stopReason == nil else { return .stopped }
            if let expected = expectedGeneration, generation != expected { return .changed }
            let now = PrecisionClock.nowNs()
            if now >= end { stopReason = "maximumDuration"; return .stopped }
            // The clock reference is the raw system anchor, never NTP-adjusted.
            if abs(PrecisionClock.wallNow() - reference.epoch(at: now)) > 0.25 {
                stopReason = "clockChanged"; return .stopped
            }
            if now >= deadline { return .ready }
            let remaining = min(deadline - now, end - now)
            if remaining > 500_000 {
                condition.wait(until: Date(timeIntervalSinceNow: Double(min(20_000_000, remaining - 250_000)) / 1e9))
            } else {
                condition.unlock()
                while PrecisionClock.nowNs() < deadline && PrecisionClock.nowNs() < end { }
                condition.lock()
            }
        }
    }

    private func execute(_ settings: HoldClickSettings, id: UUID, firstDown: UInt64,
                         firstUpFloor: UInt64,
                         reference: ClickTimeReference,
                         onEvent: (HoldClickRecord) -> Void, onState: (Int?) -> Void,
                         onComplete: (String) -> Void) {
        let holdNs = UInt64(settings.holdMs * 1e6)
        let end = firstDown + UInt64(settings.maximumSeconds * 1e9)
        var announcedGeneration = -1, plannedGeneration = -1
        var nextDown = firstDown, lastUpEnd: UInt64 = 0
        var index = 0, pressed = false
        var pressedPoint = CGPoint.zero
        var reason = "cancelled"
        defer {
            condition.lock()
            if pressed {
                do { try sender(.mouseUp, pressedPoint, index) }
                catch { reason += "; emergencyReleaseFailed: \(error.localizedDescription)" }
            }
            if runID == id {
                runID = nil; selected = nil; held.removeAll(); stopReason = nil
            }
            condition.unlock()
            onState(nil)
            onComplete(reason)
        }
        while true {
            condition.lock()
            if let stopped = stopReason { reason = stopped; condition.unlock(); return }
            let now = PrecisionClock.nowNs()
            if now >= end { reason = "maximumDuration"; condition.unlock(); return }
            if announcedGeneration != generation {
                announcedGeneration = generation
                let state = selected
                condition.unlock(); onState(state); continue
            }
            guard let region = selected else {
                // A finite base turn stays paused until another genuine key
                // press or temporary-region return starts a new turn.
                _ = waitLocked(until: now + 20_000_000, end: end, id: id,
                               expectedGeneration: generation, reference: reference)
                condition.unlock(); continue
            }
            let thisGeneration = generation
            let interval = UInt64(1e9 / settings.frequencies[region])
            if plannedGeneration != thisGeneration {
                plannedGeneration = thisGeneration
                nextDown = max(firstDown, now, lastUpEnd == 0 ? 0 : lastUpEnd + 1_000_000)
            }
            let downDeadline = nextDown, upDeadline = downDeadline + holdNs
            switch waitLocked(until: downDeadline, end: end, id: id,
                              expectedGeneration: thisGeneration, reference: reference) {
            case .changed: condition.unlock(); continue
            case .stopped: reason = stopReason ?? "cancelled"; condition.unlock(); return
            case .ready: break
            }
            let readyAt = PrecisionClock.nowNs()
            let permittedLateness = min(UInt64(50_000_000), max(2_000_000, interval / 2))
            if readyAt - downDeadline > permittedLateness {
                // Reset in the future; never replay missed slots in a burst.
                nextDown = readyAt + interval
                condition.unlock(); continue
            }
            // Never retain a desktop coordinate while waiting for a future
            // slot: the target window may move meanwhile. Resolve exactly once
            // for this press, and keep that point for its matching release.
            let unitPoint = CGPoint(x: CGFloat.random(in: 0..<1), y: CGFloat.random(in: 0..<1))
            let point: CGPoint
            if let resolver = pointResolver {
                guard let resolved = resolver(region, unitPoint),
                      resolved.x.isFinite, resolved.y.isFinite else {
                    reason = "targetChanged"; condition.unlock(); return
                }
                point = resolved
            } else {
                let r = settings.regions[region]
                point = CGPoint(x: min(r.minX + unitPoint.x * r.width, r.maxX.nextDown),
                                y: min(r.minY + unitPoint.y * r.height, r.maxY.nextDown))
            }
            guard validator?(point) != false else {
                reason = "targetChanged"; condition.unlock(); return
            }
            let downStart = PrecisionClock.nowNs()
            if downStart >= end { reason = "maximumDuration"; condition.unlock(); return }
            if downStart - downDeadline > permittedLateness {
                nextDown = downStart + interval
                condition.unlock(); continue
            }
            index += 1; pressedPoint = point
            let downWall = PrecisionClock.wallNow()
            // Set before calling an injected/system sender: a throwing sender
            // may already have posted mouse-down, so release conservatively.
            pressed = true
            do { try sender(.mouseDown, point, index) }
            catch { reason = "error: \(error.localizedDescription)"; condition.unlock(); return }
            let downEnd = PrecisionClock.nowNs()
            // A transition interrupts a long hold instead of making the user
            // wait its full duration. Release the old point before any new down;
            // preserve a minimum 0.5ms press for normal switches. Cancellation
            // or the runtime limit releases immediately.
            let releaseWait = waitLocked(until: max(upDeadline, downEnd + holdNs), end: end, id: id,
                                         expectedGeneration: thisGeneration, reference: reference)
            if case .changed = releaseWait {
                let earliestRelease = max(downEnd + 500_000, index == 1 ? firstUpFloor : 0)
                _ = waitLocked(until: earliestRelease, end: end, id: id,
                               expectedGeneration: nil, reference: reference)
            }
            let upStart = PrecisionClock.nowNs(), upWall = PrecisionClock.wallNow()
            do { try sender(.mouseUp, point, index); pressed = false }
            catch { reason = "error: \(error.localizedDescription)"; condition.unlock(); return }
            let upEnd = PrecisionClock.nowNs()
            lastUpEnd = upEnd
            if generation == thisGeneration, selected == 0, settings.baseCount > 0 {
                baseSent += 1
                if baseSent >= settings.baseCount { selected = nil; generation += 1 }
            }
            nextDown = Self.nextDownDeadline(previousPlannedDown: downDeadline,
                                            interval: interval, actualUpEnd: upEnd)
            let stopped = stopReason
            condition.unlock()
            let event = ClickEvent(index: index, targetWallEpoch: reference.epoch(at: upDeadline),
                                   targetMonoNs: upDeadline, plannedMouseDownMonoNs: downDeadline,
                                   plannedMouseUpMonoNs: upDeadline,
                                   mouseDownCallStartMonoNs: downStart, mouseDownCallEndMonoNs: downEnd,
                                   mouseUpCallStartMonoNs: upStart, mouseUpCallEndMonoNs: upEnd,
                                   mouseDownWallEpoch: downWall, mouseUpWallEpoch: upWall,
                                   pointX: point.x, pointY: point.y, regionIndex: region)
            onEvent(HoldClickRecord(event: event, regionIndex: region, generation: thisGeneration))
            if let stopped = stopped { reason = stopped; return }
        }
    }
}
