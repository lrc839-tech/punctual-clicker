import AppKit
import ApplicationServices

/// An active, main-run-loop filter. Callbacks must stay synchronous and short:
/// revoke/switch the click engine here, and defer UI or disk work elsewhere.
final class RegionHotkeys {
    var onPress: ((Int) -> Void)?
    var onRelease: ((Int) -> Void)?
    var onStop: ((String) -> Void)?
    var canHandle: (() -> Bool)?

    private struct CapturedKey {
        let region: Int?
        let began: TimeInterval
        var observedReleasedAt: TimeInterval?
        var observedDownState = false
    }
    private enum InstallationError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }
    private static let regions: [CGKeyCode: Int] = [18: 0, 19: 1, 20: 2, 83: 0, 84: 1, 85: 2]
    private static let escape: CGKeyCode = 53
    private static let forbiddenModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    private static let keyboardMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    private static let eventMask = keyboardMask | (1 << CGEventType.flagsChanged.rawValue)

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?
    private var acceptingPresses = false
    private var hasValidFocus = false
    private var captured: [CGKeyCode: CapturedKey] = [:]
    private var activeRegions: Set<Int> = []
    // Keep a drain-only filter alive even if its owner releases the controller.
    private var drainKeepAlive: RegionHotkeys?
    private var isStopping = false

    var isInstalled: Bool { acceptingPresses && tap.map(CGEvent.tapIsEnabled(tap:)) == true }

    func install() throws {
        guard Thread.isMainThread else {
            throw InstallationError.message("三键键盘控制必须在主线程启动。")
        }
        if isInstalled { return }
        guard !isStopping, captured.isEmpty else {
            throw InstallationError.message("请先松开 1／2／3 和 Esc，再重新启动三键连点。")
        }
        destroyTap()
        guard AXIsProcessTrusted() else {
            throw InstallationError.message("尚未取得当前程序的辅助功能权限，无法拦截三键。请在系统设置中确认当前安装版本的授权。")
        }
        guard !Self.controlKeys.contains(where: { CGEventSource.keyState(.hidSystemState, key: $0) }) else {
            throw InstallationError.message("启动前请先松开 1／2／3 和 Esc，避免旧按住状态进入新任务。")
        }
        let previousIDs = Set(try Self.eventTaps().map(\.eventTapID))
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .defaultTap,
                                             eventsOfInterest: Self.eventMask,
                                             callback: { _, type, event, userInfo in
            guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<RegionHotkeys>.fromOpaque(userInfo).takeUnretainedValue()
            return controller.handle(type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw InstallationError.message("无法创建三键键盘拦截器。请检查当前程序的辅助功能授权；系统可能还会限制键盘输入访问，请按系统提示处理后重试。")
        }
        tap = newTap
        do {
            // A nonnil tap is insufficient: macOS may silently remove key bits.
            let newEntries = try Self.eventTaps().filter {
                !previousIDs.contains($0.eventTapID) && $0.tappingProcess == getpid() &&
                $0.tapPoint == .cgSessionEventTap && $0.options == .defaultTap
            }
            guard newEntries.count == 1, let entry = newEntries.first,
                  entry.eventsOfInterest & Self.keyboardMask == Self.keyboardMask,
                  entry.enabled, CGEvent.tapIsEnabled(tap: newTap) else {
                throw InstallationError.message("系统没有授予完整的按下／松开键盘拦截能力，已停止启动。请检查当前程序的辅助功能及系统要求的键盘输入权限；不能只凭权限开关或拦截器创建成功判断可用。")
            }
            guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
                throw InstallationError.message("无法建立三键键盘事件的主线程监听。")
            }
            source = newSource
            acceptingPresses = true
            hasValidFocus = false
            CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
            let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in self?.checkSafety() }
            timer.tolerance = 0.005
            watchdog = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            acceptingPresses = false
            destroyTap()
            throw error
        }
    }

    /// Revokes authority immediately. Held captured keys are drained (repeat/up
    /// only) before removing the tap; they can never restart a later run.
    func uninstall() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [self] in uninstall() }
            return
        }
        stop(reason: "三键键盘控制已停止。")
        finishDrainIfPossible()
    }

    private static var controlKeys: [CGKeyCode] { Array(regions.keys) + [escape] }
    private var focusIsValid: Bool { canHandle?() ?? false }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stop(reason: type == .tapDisabledByTimeout ? "键盘拦截器响应超时，三键连点已停止，请松开按键后重新启动。" : "系统已禁用键盘拦截，三键连点已停止，请松开按键后重新启动。")
            // Never silently re-enable a disabled tap. Its drain cannot operate.
            captured.removeAll()
            destroyTap()
            return pass
        }
        if type == .flagsChanged {
            if acceptingPresses && !event.flags.intersection(Self.forbiddenModifiers).isEmpty {
                stop(reason: "检测到组合键，三键连点已停止。")
            }
            return pass
        }
        guard type == .keyDown || type == .keyUp else { return pass }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if let held = captured[code] {
            if acceptingPresses && !focusIsValid { stop(reason: "镜像已失去前台或目标窗口改变，三键连点已停止。") }
            if type == .keyUp {
                captured.removeValue(forKey: code)
                if let region = held.region,
                   !captured.values.contains(where: { $0.region == region }),
                   activeRegions.remove(region) != nil {
                    onRelease?(region)
                }
                finishDrainIfPossible()
            }
            // Includes autorepeat and late key-up after stop/focus loss.
            return nil
        }
        guard acceptingPresses else { return pass }
        guard focusIsValid else {
            stop(reason: "镜像未在前台或目标窗口改变，三键连点已停止。")
            return pass
        }
        hasValidFocus = true
        guard event.flags.intersection(Self.forbiddenModifiers).isEmpty else {
            stop(reason: "检测到组合键，三键连点已停止。")
            return pass
        }
        guard type == .keyDown, code == Self.escape || Self.regions[code] != nil else { return pass }
        // An unpaired repeat may belong to a previous run; never treat it as a
        // fresh press. Capture it only to keep it out of the target input field.
        let region = Self.regions[code]
        captured[code] = CapturedKey(region: region, began: ProcessInfo.processInfo.systemUptime,
                                    observedDownState: CGEventSource.keyState(.hidSystemState, key: code))
        if code == Self.escape {
            stop(reason: "Esc 已停止三键连点。")
            return nil
        }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            stop(reason: "检测到未配对的重复按键，三键连点已停止；请松开后重新启动。")
            return nil
        }
        if let region = region, activeRegions.insert(region).inserted { onPress?(region) }
        return nil
    }

    private func checkSafety() {
        guard let currentTap = tap else { return }
        guard CGEvent.tapIsEnabled(tap: currentTap) else {
            stop(reason: "键盘拦截已失效，三键连点已停止。")
            captured.removeAll()
            destroyTap()
            return
        }
        if acceptingPresses {
            if focusIsValid { hasValidFocus = true }
            else if hasValidFocus { stop(reason: "镜像已失去前台或目标窗口改变，三键连点已停止。") }
        }
        let now = ProcessInfo.processInfo.systemUptime
        for code in Array(captured.keys) {
            guard var held = captured[code] else { continue }
            if CGEventSource.keyState(.hidSystemState, key: code) {
                held.observedDownState = true
                held.observedReleasedAt = nil
                captured[code] = held
            } else if held.observedDownState, now - held.began >= 0.10 {
                if held.observedReleasedAt == nil {
                    held.observedReleasedAt = now
                    captured[code] = held
                }
                // HID can report up before this run loop has delivered its
                // already-queued keyUp callback. Let that callback switch back
                // immediately; only a persistently missing event is a fault.
                let releasedFor = now - (held.observedReleasedAt ?? now)
                if acceptingPresses && releasedFor >= 0.05 {
                    stop(reason: "未收到按键松开事件，三键连点已停止；请松开按键后重新启动。")
                }
                if !acceptingPresses && releasedFor >= 0.15 {
                    // Allow queued up events time to drain before retiring a
                    // physically released key whose event was lost entirely.
                    captured.removeValue(forKey: code)
                }
            }
        }
        finishDrainIfPossible()
    }

    private func stop(reason: String) {
        guard acceptingPresses, !isStopping else { return }
        isStopping = true
        acceptingPresses = false
        let released = activeRegions.sorted()
        activeRegions.removeAll()
        if !captured.isEmpty { drainKeepAlive = self }
        // Revoke the engine before releases: release may otherwise resume its
        // default region. This also makes recursive uninstall from onStop safe.
        onStop?(reason)
        released.forEach { onRelease?($0) }
        isStopping = false
        finishDrainIfPossible()
    }

    private func finishDrainIfPossible() {
        guard !acceptingPresses, !isStopping, captured.isEmpty else { return }
        destroyTap()
    }

    private func destroyTap() {
        watchdog?.invalidate()
        watchdog = nil
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        if let tap = tap { CFMachPortInvalidate(tap) }
        tap = nil
        activeRegions.removeAll()
        drainKeepAlive = nil
    }

    private static func eventTaps() throws -> [CGEventTapInformation] {
        for _ in 0..<3 {
            var count: UInt32 = 0
            guard CGGetEventTapList(0, nil, &count) == .success, count <= 4096 else {
                throw InstallationError.message("无法读取系统键盘拦截状态，已停止启动。")
            }
            if count == 0 { return [] }
            var entries = Array(repeating: CGEventTapInformation(), count: Int(count))
            var actual: UInt32 = 0
            let result = entries.withUnsafeMutableBufferPointer { buffer in
                CGGetEventTapList(count, buffer.baseAddress, &actual)
            }
            guard result == .success else {
                throw InstallationError.message("无法校验系统键盘拦截权限，已停止启动。")
            }
            if actual <= count { return Array(entries.prefix(Int(actual))) }
        }
        throw InstallationError.message("系统键盘拦截状态正在变化，请稍后重试。")
    }

    deinit {
        watchdog?.invalidate()
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = tap { CFMachPortInvalidate(tap) }
    }
}
