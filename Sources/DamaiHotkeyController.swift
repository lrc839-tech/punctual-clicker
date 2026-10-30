import AppKit
import ApplicationServices

private final class ThreeKeyFocusFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ valid: Bool) { lock.lock(); value = valid; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Human chooses the page action. No screen capture or OCR is on this input path.
final class DamaiHotkeyController: NSObject, NSWindowDelegate {
    unowned let app: AppDelegate
    let markers = RegionMarkerOverlay()
    let hotkeys = RegionHotkeys()
    var panel = NSStackView()
    var regions: [CGRect?] = [nil, nil, nil]
    var target: TargetWindow?
    var selectionWindows: [NSWindow] = []
    var session: UUID?
    var isActive: Bool { session != nil }
    var stopping = false
    var runner: HoldClickEngine?
    var settings: HoldClickSettings?
    var waitingEpoch: Double?
    var scheduledTargetEpoch: Double?
    var synchronizing = false
    var firstUp: UInt64?
    private var immediateStart: ImmediateClickStart?
    private var pendingInitialRegion = 0
    var activationRequested = false
    var activationConfirmed = false
    var activationStarted: UInt64 = 0
    var requestedRegion: Int?
    var counts = [0, 0, 0]
    var records: [HoldClickRecord] = []
    var keyRecords: [[String: Any]] = []
    var reason = ""
    var ownControls: [NSControl] = []
    let rates = [NSTextField(string: "5"), NSTextField(string: "5"), NSTextField(string: "5")]
    let baseCount = NSTextField(string: "0")
    let hold = NSTextField(string: "8")
    let duration = NSTextField(string: "90")
    let compensation = NSTextField(string: "0")
    let startDelay = NSTextField(string: "0")
    let showMarkers = NSButton(checkboxWithTitle: "显示透明数字与区域边框", target: nil, action: nil)
    let summary = NSTextField(wrappingLabelWithString: "默认点 1；按住 2／3 临时切换，松开回到 1。Esc 全部停止。")
    var regionLabels = (0..<3).map { NSTextField(labelWithString: "\($0+1)：尚未框选") }
    private let profileKey = "damai.keys.regions.v1"
    private var savedRegionProfile = DamaiRegionProfile.defaults
    // This reference geometry never changes merely because the window moves.
    // Test and partially edited regions use an ephemeral profile of their own.
    private var currentRegionProfile = DamaiRegionProfile.defaults
    private var showingSavedRegions = true
    private var nextProfileCheck: UInt64 = 0
    private let profileLabel = NSTextField(wrappingLabelWithString: "")
    var testWindow: NSWindow?
    var testView: ThreeRegionReceiverView?
    private var liveReceiver: ThreeRegionReceiverView?
    private var restorePhoneAfterTest = false
    private let receiverFocus = ThreeKeyFocusFlag()

    init(app: AppDelegate) {
        self.app = app
        super.init()
        hotkeys.canHandle = { [weak self] in
            guard let self = self, self.isActive, !self.stopping, let t = self.target else { return false }
            return self.targetIsFrontmost(t) && self.sameWindow(t)
        }
        hotkeys.onPress = { [weak self] index in self?.keyChanged(index, down: true) }
        hotkeys.onRelease = { [weak self] index in self?.keyChanged(index, down: false) }
        hotkeys.onStop = { [weak self] text in self?.stop(reason: text) }
    }
    private func label(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: 12); f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = 790
        return f
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views); s.orientation = .horizontal; s.spacing = 9; s.alignment = .centerY
        return s
    }
    private func button(_ text: String, _ selector: Selector) -> NSButton {
        let b = NSButton(title: text, target: self, action: selector); b.bezelStyle = .rounded; return b
    }
    func makePanel() -> NSView {
        let storedProfileData = UserDefaults.standard.data(forKey: profileKey)
        savedRegionProfile = DamaiRegionProfile.decode(storedProfileData)
        currentRegionProfile = savedRegionProfile
        regions = savedRegionProfile.regions
        // Also writes unchanged v1 reference data in the explicit v2 local format.
        persistRegionProfile()
        // The old field was used as a test-start delay despite its "advance"
        // label. Split the settings once; never apply that test value to NTP.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "damai.keys.startDelay") == nil {
            let legacy = Double(defaults.string(forKey: "damai.keys.compensation") ?? "0") ?? 0
            defaults.set(legacy.isFinite && (0...60000).contains(legacy) ? String(legacy) : "0", forKey: "damai.keys.startDelay")
        }
        for (key, control) in savedFields {
            if let value = UserDefaults.standard.string(forKey: key) { control.stringValue = value }
            control.widthAnchor.constraint(equalToConstant: 65).isActive = true
            control.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        }
        showMarkers.state = UserDefaults.standard.object(forKey: "damai.keys.markers") as? Bool == false ? .off : .on
        showMarkers.target = self; showMarkers.action = #selector(toggleMarkers)
        let selectButtons = [button("框选 1 · 底部购买", #selector(selectOne)),
                             button("框选 2 · 努力刷新", #selector(selectTwo)),
                             button("框选 3 · 继续尝试", #selector(selectThree))]
        let names = ["底部", "刷新", "重试"]
        var items: [NSView] = [label("大麦三键 · 人看页面，程序点选区。先预填场次、票档、张数和观演人，再按实际手机画面框选三个按钮。")]
        for i in 0..<3 {
            selectButtons[i].tag = i
            regionLabels[i].font = .systemFont(ofSize: 12); regionLabels[i].textColor = .secondaryLabelColor
            items.append(row([selectButtons[i], regionLabels[i]]))
        }
        let restore = button("恢复默认选区", #selector(restoreDefaultRegions))
        profileLabel.font = .systemFont(ofSize: 12); profileLabel.textColor = .secondaryLabelColor
        profileLabel.preferredMaxLayoutWidth = 640
        profileLabel.setAccessibilityIdentifier("damai.region-profile")
        items.append(row([restore, profileLabel]))
        items.append(row([showMarkers, label("青色亮框＝正在执行；橙色框＝待命；点击穿透标记。")]))
        items.append(row([label("连点频率"), label("1 · \(names[0])"), rates[0], label("2 · \(names[1])"), rates[1], label("3 · \(names[2])"), rates[2], label("次/秒")]))
        items.append(row([label("首次／返回底部次数"), baseCount, label("次（0 持续；到数暂停，按 1 重开）")]))
        items.append(row([label("鼠标按住"), hold, label("毫秒"), label("最长运行"), duration, label("秒"), label("整分首击提前"), compensation, label("毫秒")]))
        items.append(row([label("立即启动等待"), startDelay, label("毫秒（0 不等待；3000＝3 秒；不影响整分启动）")]))
        startDelay.toolTip = "从按启动按钮计时，到期且目标窗口就绪后开始点击；也用于三区测试台。"
        compensation.toolTip = "仅用于整分首击的提前补偿，正数提前、负数延后。立即启动使用独立等待时间。"
        summary.font = .systemFont(ofSize: 13); summary.preferredMaxLayoutWidth = 790
        summary.setAccessibilityIdentifier("damai.hotkeys.status")
        items.append(summary)
        let immediate = button("立即启动三键连点", #selector(startImmediately))
        let test = button("打开三区测试台", #selector(openTestBench))
        items.append(row([immediate, test, button("三键使用说明", #selector(showGuide))]))
        items.append(label("无按键时自动点 1；按住 2／3 接管，松开当前键返回 1 并重新计数。只有一个区域执行，不排队、不补发。按键 1 可立即回到底部。"))
        items.append(label("三区使用窗口内坐标，移动镜像时自动跟随。明显缩放需重框。整分首击不等截图识别；Esc、切换应用、休眠会停止。进入支付时请按 Esc。"))
        ownControls = selectButtons + rates + [baseCount, hold, duration, compensation, startDelay, immediate, test, restore]
        panel = NSStackView(views: items); panel.orientation = .vertical; panel.alignment = .leading; panel.spacing = 9
        panel.setAccessibilityIdentifier("damai.panel")
        bindSavedRegionsIfAvailable()
        return panel
    }
    private func presentRegionProfile() {
        let localRegions = currentRegionProfile.relativeRegions
        for i in 0..<3 {
            if let rect = localRegions?[i] {
                let name = target?.pid == getpid() ? "测试台窗口内" : "镜像窗口内"
                regionLabels[i].stringValue = String(format: "%d：%@ · x %.0f / y %.0f · %.0f × %.0f 点", i+1, name, rect.minX, rect.minY, rect.width, rect.height)
            } else { regionLabels[i].stringValue = "\(i+1)：尚未框选" }
        }
        if target?.pid == getpid() {
            profileLabel.stringValue = "测试台练习选区，不会覆盖已保存的手机坐标。"
        } else if !showingSavedRegions {
            profileLabel.stringValue = "重新框选中；同一窗口三区选全后自动保存。"
        } else {
            let name = savedRegionProfile.regions == DamaiRegionProfile.defaults.regions ? "初始默认选区" : "自定义选区已保存"
            profileLabel.stringValue = name + (target == nil ? " · 等待相同大小的镜像；位置不限。" : " · 已匹配镜像；移动自动跟随，修改后自动保存。")
        }
    }
    private func bindSavedRegionsIfAvailable() {
        guard showingSavedRegions, !isActive, target == nil else { return }
        let candidates = windowList().filter {
            ($0[kCGWindowLayer as String] as? Int ?? 0) == 0 &&
                ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0.05
        }.compactMap(metadata).filter { t in
            NSRunningApplication(processIdentifier: t.pid)?.bundleIdentifier == "com.apple.ScreenContinuity" &&
                savedRegionProfile.canBind(to: t.frame)
        }
        if candidates.count == 1, let mapped = savedRegionProfile.mappedRegions(to: candidates[0].frame) {
            target = candidates[0]; currentRegionProfile = savedRegionProfile; regions = mapped
        }
        presentRegionProfile()
        refreshMarkers(active: nil)
        writeRegionProfileDiagnostic()
    }
    private func persistRegionProfile() {
        guard savedRegionProfile.isComplete, let data = try? savedRegionProfile.encoded() else { return }
        UserDefaults.standard.set(data, forKey: profileKey)
    }
    private func saveSelectedPhoneRegions(_ t: TargetWindow) {
        guard NSRunningApplication(processIdentifier: t.pid)?.bundleIdentifier == "com.apple.ScreenContinuity" else { return }
        let profile = DamaiRegionProfile(regions: regions, windowFrame: t.frame)
        currentRegionProfile = profile
        showingSavedRegions = profile.isComplete
        if profile.isComplete { savedRegionProfile = profile; persistRegionProfile() }
        presentRegionProfile(); writeRegionProfileDiagnostic()
    }
    @objc private func restoreDefaultRegions() {
        guard !isActive, !app.normalBusy else { return }
        markers.hide(); target = nil; savedRegionProfile = .defaults
        currentRegionProfile = savedRegionProfile
        regions = savedRegionProfile.regions; showingSavedRegions = true
        UserDefaults.standard.removeObject(forKey: profileKey)
        bindSavedRegionsIfAvailable()
        app.log("已恢复初始默认选区；区域仍可重新框选，完整修改会自动保存。")
    }
    private func writeRegionProfileDiagnostic() {
        guard let data = try? savedRegionProfile.encoded(),
              let profile = try? JSONSerialization.jsonObject(with: data) else { return }
        app.writeJSON(["profile": profile, "bound": target != nil && showingSavedRegions,
                       "targetID": target?.id ?? 0, "targetPID": target?.pid ?? 0,
                       "coordinateSpace": "window-relative Quartz points from top-left; not iPhone pixels",
                       "currentWindowFrame": target.map { NSStringFromRect($0.frame) } ?? "unbound",
                       "resolvedDesktopRegions": regions.map { $0.map(NSStringFromRect) ?? "unset" },
                       "markerWindowIDs": markers.windowIDs,
                       "status": profileLabel.stringValue], name: "damai-region-profile-latest.json")
    }
    private var savedFields: [(String, NSTextField)] {
        [("damai.keys.rate1", rates[0]), ("damai.keys.rate2", rates[1]), ("damai.keys.rate3", rates[2]),
         ("damai.keys.baseCount", baseCount), ("damai.keys.hold", hold),
         ("damai.keys.duration", duration), ("damai.keys.scheduledCompensation", compensation),
         ("damai.keys.startDelay", startDelay)]
    }
    func savePreferences() {
        savedFields.forEach { UserDefaults.standard.set($0.1.stringValue, forKey: $0.0) }
        UserDefaults.standard.set(showMarkers.state == .on, forKey: "damai.keys.markers")
    }
    func updateControls() {
        ownControls.forEach { $0.isEnabled = !isActive && !app.normalBusy }
        if app.regionMode?.selectedSegment != 2 { markers.hide() }
        else if !isActive { refreshMarkers(active: nil) }
    }
    @objc func toggleMarkers() {
        UserDefaults.standard.set(showMarkers.state == .on, forKey: "damai.keys.markers")
        // Overlay identities are frozen during an armed run, so visibility changes
        // cannot silently change the validator's allow-list.
        if !isActive { refreshMarkers(active: nil) }
    }
    private func refreshMarkers(active: Int?, enabled: Bool = true) {
        guard showMarkers.state == .on, app.regionMode?.selectedSegment == 2,
              updateTargetGeometry() else { markers.hide(); return }
        // Zero-size placeholders preserve region numbers before all three are set.
        markers.show(regions: regions.map { $0 ?? .zero }, activeRegion: active, enabled: enabled)
    }
    @objc func selectOne() { select(0) }
    @objc func selectTwo() { select(1) }
    @objc func selectThree() { select(2) }
    private func select(_ index: Int) {
        guard !isActive, !app.normalBusy else { return }
        markers.hide()
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; w.isReleasedWhenClosed = false
            let v = SelectView(frame: CGRect(origin: .zero, size: screen.frame.size))
            v.regionName = "\(index+1) · \(["底部购买", "努力刷新", "继续尝试"][index])"
            v.finish = { [weak self] rect in self?.finishSelection(rect, index: index) }
            w.contentView = v; selectionWindows.append(w); w.makeKeyAndOrderFront(nil); w.makeFirstResponder(v)
        }
    }
    private func finishSelection(_ rect: CGRect?, index: Int) {
        selectionWindows.forEach { $0.orderOut(nil) }; selectionWindows.removeAll()
        guard let rect = rect else { refreshMarkers(active: nil); return }
        guard rect.width >= 12, rect.height >= 12 else { app.fail("请在按钮内部框选至少 12 × 12 点的范围，以便显示数字标记。"); return }
        DispatchQueue.main.asyncAfter(deadline: .now()+0.12) { [weak self] in
            guard let self = self, !self.isActive else { return }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard let t = windowList().filter({ ($0[kCGWindowLayer as String] as? Int ?? 0) == 0 })
                .compactMap(metadata).first(where: { $0.frame.contains(center) }), t.frame.contains(rect),
                NSRunningApplication(processIdentifier: t.pid)?.bundleIdentifier == "com.apple.ScreenContinuity" ||
                    (t.pid == getpid() && t.id == self.testWindow.map({ CGWindowID($0.windowNumber) })) else {
                self.app.fail("请框选实际 iPhone 镜像窗口中的按钮；也可以使用本工具的三区测试台。"); return
            }
            let sameSelectionWindow: Bool
            if let previous = self.target, previous.id == t.id, previous.pid == t.pid,
               let mapped = self.currentRegionProfile.mappedRegions(to: t.frame) {
                self.regions = mapped; sameSelectionWindow = true
            } else if self.target == nil, self.showingSavedRegions,
                      NSRunningApplication(processIdentifier: t.pid)?.bundleIdentifier == "com.apple.ScreenContinuity",
                      let mapped = self.savedRegionProfile.mappedRegions(to: t.frame) {
                self.regions = mapped; sameSelectionWindow = true
            } else { sameSelectionWindow = false }
            if !sameSelectionWindow {
                self.regions = [nil, nil, nil]
                for i in 0..<3 { self.regionLabels[i].stringValue = "\(i+1)：尚未框选" }
            }
            self.target = t; self.regions[index] = rect
            self.currentRegionProfile = DamaiRegionProfile(regions: self.regions, windowFrame: t.frame)
            self.saveSelectedPhoneRegions(t)
            self.presentRegionProfile()
            self.refreshMarkers(active: nil)
            self.app.window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
    private func currentWindow(_ t: TargetWindow) -> TargetWindow? {
        // Preparing the task may put our settings window over the receiver.
        // Identity/geometry must remain checkable while the target is occluded;
        // the sender separately requires a visible, unobstructed foreground target.
        let all = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return all.filter { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }.compactMap(metadata).first {
            $0.id == t.id && $0.pid == t.pid && currentRegionProfile.mappedRegions(to: $0.frame) != nil
        }
    }
    private func sameWindow(_ t: TargetWindow) -> Bool { currentWindow(t) != nil }
    @discardableResult private func updateTargetGeometry() -> Bool {
        guard let previous = target, let current = currentWindow(previous),
              let mapped = currentRegionProfile.mappedRegions(to: current.frame) else { return false }
        let changed = previous.frame != current.frame
        target = current; regions = mapped
        if changed {
            if isActive { app.activeTarget = current }
            presentRegionProfile(); writeRegionProfileDiagnostic()
        }
        return true
    }
    private func targetIsFrontmost(_ t: TargetWindow) -> Bool {
        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid &&
            (t.pid != getpid() || NSApplication.shared.keyWindow === testWindow)
        receiverFocus.set(isFront)
        return isFront
    }
    @objc func startImmediately() { start(scheduled: false) }
    func start(scheduled: Bool) {
        let requestedMono = PrecisionClock.nowNs()
        guard !isActive, !app.normalBusy else { return }
        bindSavedRegionsIfAvailable()
        guard app.window.makeFirstResponder(nil) else { return }
        guard AXIsProcessTrusted() else { app.fail("三键连点需要当前 App 的辅助功能权限。"); return }
        // Only the built-in receiver can be recomputed from its own view. Its
        // title-bar geometry settles after creation on some macOS versions.
        if let t = target, t.pid == getpid(), t.id == testWindow.map({ CGWindowID($0.windowNumber) }) {
            refreshTestSelection()
        }
        let located = updateTargetGeometry()
        guard let t = target, regions.allSatisfy({ $0 != nil }), located else {
            let all = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
            app.writeJSON(["targetID": target?.id ?? 0, "targetPID": target?.pid ?? 0,
                "targetFrame": (self.target.map { NSStringFromRect($0.frame) } ?? "nil") as String,
                "current": all.compactMap(metadata).filter { $0.pid == getpid() }.map { ["id": $0.id, "frame": NSStringFromRect($0.frame)] as [String: Any] }], name: "three-keys-start-diagnostic.json")
            app.fail("请打开相同大小的 iPhone 镜像窗口，或在当前窗口框选 1、2、3。移动位置无需重框；明显缩放后才需重新框选。"); return
        }
        guard let count = Int(baseCount.stringValue), let holdMs = Double(hold.stringValue),
              let seconds = Double(duration.stringValue), let advance = Double(compensation.stringValue),
              advance.isFinite, (-5000...5000).contains(advance),
              let delay = Double(startDelay.stringValue), delay.isFinite, (0...60000).contains(delay) else {
            app.fail("请输入有效数字：整分补偿 −5000～5000 毫秒，立即启动等待 0～60000 毫秒。"); return
        }
        let frequencies = rates.compactMap { Double($0.stringValue) }
        let config = HoldClickSettings(regions: regions.compactMap { $0 }, frequencies: frequencies,
                                       baseCount: count, holdMs: holdMs, maximumSeconds: seconds)
        do {
            try HoldClickEngine.validate(config)
            try hotkeys.install()
        } catch { hotkeys.uninstall(); app.fail(error.localizedDescription); return }
        savePreferences()
        session = UUID(); settings = config; stopping = false; reason = ""
        liveReceiver = (t.pid == getpid() && t.id == testWindow.map { CGWindowID($0.windowNumber) }) ? testView : nil
        liveReceiver?.reset()
        liveReceiver?.setStatus("已启用 · 正在准备测试窗口", running: true)
        records = []; keyRecords = []; counts = [0, 0, 0]; requestedRegion = nil
        activationRequested = false; activationConfirmed = false; firstUp = nil; waitingEpoch = nil; scheduledTargetEpoch = nil; synchronizing = false
        immediateStart = scheduled ? nil : ImmediateClickStart(requestedMonoNs: requestedMono, delayMs: delay)
        pendingInitialRegion = 0
        app.activeTarget = t; app.activeNetworkTime = nil
        app.controls.forEach { $0.isEnabled = false }; showMarkers.isEnabled = false
        app.startButton.isEnabled = false; app.stopButton.isEnabled = true; updateControls()
        app.activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "大麦三键连点")
        refreshMarkers(active: nil, enabled: false)
        app.log("大麦三键已启用：默认点 1，按住 2／3 临时切换，松开回 1；底部次数 \(count == 0 ? "持续" : String(count))，频率 \(frequencies)。Esc 全停。")
        if scheduled {
            let epoch = floor(app.targetField.dateValue.timeIntervalSince1970/60)*60
            app.targetField.dateValue = Date(timeIntervalSince1970: epoch); waitingEpoch = epoch; scheduledTargetEpoch = epoch
            synchronizeForStart()
        } else {
            app.log("立即启动等待 \(delay) 毫秒；从按钮请求计时，目标就绪后执行，等待不占最长运行时长。")
            requestActivation()
        }
    }
    private func synchronizeForStart() {
        guard let id = session, !synchronizing else { return }
        synchronizing = true; app.statusLabel.stringValue = "三键 · NTP 授时中"
        app.synchronizeClock { [weak self] snapshot in
            guard let self = self, self.session == id, !self.stopping else { return }
            self.synchronizing = false
            guard let s = snapshot, let epoch = self.waitingEpoch, let config = self.settings else {
                self.stop(reason: "未取得有效 NTP 授时，已停止定时三键任务。"); return
            }
            let advance = Double(self.compensation.stringValue) ?? 0
            let delay = epoch - s.utcEpoch(atMonoNs: PrecisionClock.nowNs()) - (advance+config.holdMs)/1000
            guard delay >= 0.35, delay <= 172800 else {
                self.stop(reason: "授时后的首击按下时间须在 350 毫秒到 48 小时以内，请重设未来整分。"); return
            }
            if delay <= 30 { self.armScheduled(snapshot: s, epoch: epoch, advance: advance) }
            else {
                self.app.statusLabel.stringValue = "三键 · 等待临近授时"
                self.summary.stringValue = "等待整分；首击前约 30 秒重新授时。键盘接管在镜像前台且进入调度后生效。"
            }
        }
    }
    private func armScheduled(snapshot: NetworkTimeSnapshot, epoch: Double, advance: Double) {
        let mono = Double(snapshot.referenceMonoNs) + (epoch-snapshot.referenceEpoch-advance/1000)*1e9
        guard mono.isFinite, mono > Double(PrecisionClock.nowNs()),
              snapshot.isUsable(atMonoNs: UInt64(mono)) else { stop(reason: "首击超过授时有效期，已停止。"); return }
        firstUp = UInt64(mono); waitingEpoch = nil
        launchEngine()
        app.statusLabel.stringValue = "三键 · 等待整分首击"
    }
    private func requestActivation() {
        guard !activationRequested, let t = target else { return }
        activationRequested = true; activationStarted = PrecisionClock.nowNs()
        app.statusLabel.stringValue = "三键 · 准备目标窗口"
        if t.pid == getpid(), let w = testWindow, CGWindowID(w.windowNumber) == t.id {
            w.makeKeyAndOrderFront(nil)
            if let v = testView { w.makeFirstResponder(v) }
            NSApplication.shared.activate(ignoringOtherApps: true); return
        }
        guard let targetApp = NSRunningApplication(processIdentifier: t.pid) else { stop(reason: "目标镜像进程已退出。"); return }
        let id = session
        DispatchQueue.main.asyncAfter(deadline: .now()+0.10) { [weak self] in
            guard self?.session == id, self?.stopping == false else { return }
            if #available(macOS 14.0, *) {
                NSApplication.shared.yieldActivation(to: targetApp)
                _ = targetApp.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
            } else { _ = targetApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) }
        }
    }
    private func launchEngine() {
        guard let id = session, let t = target, let config = settings, runner == nil else { return }
        refreshMarkers(active: nil)
        // Only these known nonactivating, mouse-transparent marker windows are
        // omitted. Ordinary windows and same-target dialogs retain the guard.
        let markerIDs = Set(markers.windowIDs)
        let receiverFocus = self.receiverFocus
        let clickTarget = WindowRelativeClickTarget(profile: currentRegionProfile, pid: t.pid, id: t.id)
        let engine = HoldClickEngine(pointResolver: { region, unitPoint in
            guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid else { return nil }
            if t.pid == getpid(), !receiverFocus.get() { return nil }
            let windows = windowList().compactMap { info -> VisibilityWindow? in
                guard let w = metadata(info), !markerIDs.contains(w.id) else { return nil }
                return VisibilityWindow(pid: w.pid, id: w.id, frame: w.frame,
                                        layer: info[kCGWindowLayer as String] as? Int ?? 0,
                                        alpha: info[kCGWindowAlpha as String] as? Double ?? 1)
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid else { return nil }
            return clickTarget.resolve(region: region, unitPoint: unitPoint, windows: windows)
        })
        runner = engine
        do {
            if let plan = immediateStart {
                firstUp = try plan.firstMouseUp(readyMonoNs: PrecisionClock.nowNs(), holdMs: config.holdMs)
            }
            try engine.start(config, firstMouseUpMonoNs: firstUp, initialRegion: pendingInitialRegion, onEvent: { [weak self] record in
                DispatchQueue.main.async {
                    guard let self = self, self.session == id else { return }
                    self.records.append(record); self.counts[record.regionIndex] += 1
                    self.renderStatus()
                }
            }, onState: { [weak self] region in
                DispatchQueue.main.async {
                    guard let self = self, self.session == id, !self.stopping else { return }
                    self.requestedRegion = region; self.renderStatus()
                }
            }, onComplete: { [weak self] text in
                DispatchQueue.main.async {
                    guard let self = self, self.session == id else { return }
                    if self.reason.isEmpty { self.reason = text }
                    self.stopping = true; self.hotkeys.uninstall(); self.markers.setActive(nil)
                    if t.pid == getpid() {
                        // Let the native receiver process the final posted up.
                        DispatchQueue.main.asyncAfter(deadline: .now()+0.08) { [weak self] in self?.completeRun() }
                    } else { self.completeRun() }
                }
            })
        } catch { runner = nil; stop(reason: error.localizedDescription) }
    }
    private func keyChanged(_ index: Int, down: Bool) {
        guard isActive, !stopping else { return }
        let now = PrecisionClock.nowNs()
        keyRecords.append(["region": index+1, "down": down, "callbackMonoNs": now])
        if down {
            pendingInitialRegion = index
            runner?.press(index)
        } else {
            if index != 0, pendingInitialRegion == index { pendingInitialRegion = 0 }
            runner?.release(index)
        }
    }
    func tick() {
        guard isActive, !stopping, let t = target else {
            if !isActive, target != nil {
                if updateTargetGeometry() { refreshMarkers(active: nil) }
                else {
                    markers.hide()
                    if showingSavedRegions { target = nil; presentRegionProfile() }
                }
            }
            if !isActive, target == nil, showingSavedRegions, PrecisionClock.nowNs() >= nextProfileCheck {
                nextProfileCheck = PrecisionClock.nowNs()+1_000_000_000
                bindSavedRegionsIfAvailable()
            }
            return
        }
        guard AXIsProcessTrusted(), updateTargetGeometry() else { stop(reason: "辅助功能权限、窗口大小或目标窗口已改变。平移无需重框；明显缩放请重框。"); return }
        refreshMarkers(active: requestedRegion, enabled: activationConfirmed)
        if let epoch = waitingEpoch {
            if !synchronizing, let s = app.networkTime,
               epoch-s.utcEpoch(atMonoNs: PrecisionClock.nowNs())-(Double(compensation.stringValue) ?? 0)/1000 <= 30 {
                synchronizeForStart()
            }
            return
        }
        let now = PrecisionClock.nowNs()
        let untilDown = firstUp.map { Double($0)-Double(now)-(settings?.holdMs ?? 8)*1e6 } ?? 0
        if !activationRequested, untilDown <= 1_000_000_000 { requestActivation() }
        if activationRequested {
            let foreground = targetIsFrontmost(t)
            if foreground {
                activationConfirmed = true
                if runner == nil { launchEngine() }
            } else if activationConfirmed || now-activationStarted > 750_000_000 { stop(reason: "镜像未在前台或你已切换应用，已停止三键连点。"); return }
        }
        renderStatus()
    }
    private func renderStatus() {
        guard isActive, !stopping else { return }
        let waiting = firstUp.map { PrecisionClock.nowNs() + UInt64((settings?.holdMs ?? 8)*1e6) < $0 } ?? false
        if waiting {
            let remaining = max(0, (Double(firstUp ?? 0)-Double(PrecisionClock.nowNs()))/1e9-(settings?.holdMs ?? 8)/1000)
            let next = (requestedRegion ?? pendingInitialRegion)+1
            let title = immediateStart == nil ? "等待整分首击" : "等待启动"
            let text = String(format: "%@ · 剩余 %.1f 秒 · 到点点 %d；Esc 停止", title, remaining, next)
            liveReceiver?.setStatus(text, running: true)
            app.statusLabel.stringValue = "三键 · \(title)"
            markers.setActive(nil); summary.stringValue = text
            return
        }
        liveReceiver?.setStatus(requestedRegion.map { "正在点 \($0+1) · 松开 2／3 回 1 · Esc 停止" }
            ?? "已启用 · 底部本轮到数暂停；按 1／2／3", running: true)
        markers.setActive(requestedRegion)
        app.statusLabel.stringValue = requestedRegion.map { "三键 · 正在点 \($0+1)" } ?? "三键 · 底部限次暂停"
        summary.stringValue = "已发出 1：\(counts[0]) ／ 2：\(counts[1]) ／ 3：\(counts[2]) 次 · " +
            (requestedRegion == nil ? "底部本轮到数暂停；按 1 重开，或按住 2／3。" : "按住 2／3 临时接管，松开回 1；Esc 全停。")
    }
    func stop(reason text: String) {
        selectionWindows.forEach { $0.orderOut(nil) }; selectionWindows.removeAll()
        guard isActive, !stopping else { return }
        stopping = true; reason = text; waitingEpoch = nil
        hotkeys.uninstall(); markers.setActive(nil)
        if let engine = runner, engine.isRunning { engine.cancel() } else { completeRun() }
    }
    private func completeRun() {
        guard let id = session else { return }
        hotkeys.uninstall(); markers.setActive(nil)
        var report: [String: Any] = ["runId": id.uuidString, "mode": "damai-three-keys", "reason": reason,
            "counts": counts, "keys": keyRecords,
            "records": records.map { record -> [String: Any] in
                var value = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(record.event))) as? [String: Any] ?? [:]
                value["region"] = record.regionIndex+1; value["generation"] = record.generation; return value
            }, "receiverCounts": liveReceiver?.counts ?? [], "receiverUnexpectedKeys": liveReceiver?.unexpectedKeys ?? 0,
            "measurementBoundary": "按键回调及Mac系统输入发送；测试台接收记录不代表手机或大麦业务受理。"]
        report["scheduledTargetEpoch"] = scheduledTargetEpoch
        report["firstMouseUpMonoNs"] = firstUp
        report["firstCompensationMs"] = immediateStart == nil ? Double(compensation.stringValue) : 0
        report["immediateStartDelayMs"] = immediateStart?.delayMs
        report["startRequestedMonoNs"] = immediateStart?.requestedMonoNs
        report["baseCount"] = settings?.baseCount
        report["frequencies"] = settings?.frequencies
        report["focusAtCompletion"] = ["frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            "keyWindow": NSApplication.shared.keyWindow?.windowNumber ?? 0,
            "testWindow": testWindow?.windowNumber ?? 0, "targetID": target?.id ?? 0] as [String: Any]
        liveReceiver?.setStatus("已停止 · \(reason)", running: false)
        app.writeJSON(report, name: "three-keys-\(id.uuidString).json")
        if let receiver = liveReceiver { app.writeJSON(receiver.report, name: "three-keys-receiver-latest.json") }
        session = nil; runner = nil; settings = nil; stopping = false; firstUp = nil; requestedRegion = nil
        immediateStart = nil; pendingInitialRegion = 0
        liveReceiver = nil
        app.activeTarget = nil; app.activeNetworkTime = nil
        if let activity = app.activity { ProcessInfo.processInfo.endActivity(activity); app.activity = nil }
        app.controls.forEach { $0.isEnabled = true }; showMarkers.isEnabled = true
        app.startButton.isEnabled = true; app.stopButton.isEnabled = false; app.updateRegionControls()
        app.statusLabel.stringValue = "三键 · 已停止"; summary.stringValue = "已发出 \(counts.reduce(0,+)) 次 · \(reason)"
        app.log(summary.stringValue)
        if restorePhoneAfterTest && !app.terminating { restoreSavedPhoneSelection() }
        if app.terminating { DispatchQueue.main.async { NSApplication.shared.reply(toApplicationShouldTerminate: true) } }
    }
    @objc func showGuide() {
        let a = NSAlert(); a.messageText = "大麦三键 · 使用步骤"
        a.informativeText = "1. 确认默认三区，或在实际 iPhone 镜像内重新框选按钮内部。完整修改会自动保存。\n2. 三区相对窗口左上角定位，镜像移到其他位置或显示器后自动跟随，无需重框。明显缩放会改变手机画面比例，需重新框选。\n3. 橙色框待命；执行区为青色亮框，标记不会挡住点击。分别设置三区频率；底部次数 0 为持续，填次数则每轮到数暂停。\n4. 立即启动会按‘立即启动等待’倒计时：3000 毫秒为 3 秒。整分启动仅使用‘整分首击提前’，不叠加这段等待。\n5. 等待时可以切区但不会提前点击。按住 2／3 接管，松开回 1；按 1 重开底部。互斥，无排队或补发。\n6. Esc 全停；切换应用、明显缩放或休眠也会停止。拖动窗口前建议先 Esc，避免与连点共用鼠标。\n\n本模式不截屏、不识别页面。已经按下的鼠标会原位释放，该次不能撤回。进入支付、验证等页面由你主动停止。三区测试台也使用立即启动等待。"
        a.runModal()
    }
    @objc func openTestBench() {
        guard !isActive, !app.normalBusy else { return }
        showingSavedRegions = false
        profileLabel.stringValue = "测试台练习选区，不会覆盖已保存的手机坐标。"
        markers.hide(); testWindow?.delegate = nil; testWindow?.close(); restorePhoneAfterTest = false
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "准点点击器 · 三区测试台"; w.isReleasedWhenClosed = false; w.animationBehavior = .none
        let v = ThreeRegionReceiverView(frame: CGRect(x: 0, y: 0, width: 360, height: 560))
        v.onStart = { [weak self] in
            guard let self = self, !self.isActive else { return }
            self.refreshTestSelection(); self.start(scheduled: false)
        }
        v.onStop = { [weak self] in self?.app.stop() }
        testWindow = w; testView = v; w.delegate = self; w.contentView = v; w.center(); w.makeKeyAndOrderFront(nil)
        // Keep the receiver visible beside the settings window where space permits.
        if let screen = app.window.screen, screen.visibleFrame.width >= app.window.frame.width + 380 {
            let visible = screen.visibleFrame
            let x = app.window.frame.maxX+16 <= visible.maxX-360 ? app.window.frame.maxX+16 : app.window.frame.minX-376
            if x >= visible.minX { w.setFrameOrigin(CGPoint(x: x, y: max(visible.minY, app.window.frame.midY-280))) }
        }
        w.makeFirstResponder(v)
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.4) { [weak self] in
            guard let self = self, !self.isActive else { return }
            self.refreshTestSelection()
            w.makeKeyAndOrderFront(nil); w.makeFirstResponder(v)
        }
    }
    private func refreshTestSelection() {
        guard let w = testWindow, let v = testView else { return }
        let all = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        guard let t = all.compactMap(metadata).first(where: { $0.id == CGWindowID(w.windowNumber) && $0.pid == getpid() }) else { return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        regions = v.localRegions.map { local in
            let r = w.convertToScreen(local)
            return CGRect(x: r.minX, y: top-r.maxY, width: r.width, height: r.height)
        }
        target = t
        currentRegionProfile = DamaiRegionProfile(regions: regions, windowFrame: t.frame)
        presentRegionProfile()
        refreshMarkers(active: nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === testWindow else { return }
        if isActive {
            restorePhoneAfterTest = true
            stop(reason: "三区测试台已关闭。")
        } else { restoreSavedPhoneSelection() }
    }
    private func restoreSavedPhoneSelection() {
        restorePhoneAfterTest = false
        markers.hide(); target = nil; showingSavedRegions = true
        currentRegionProfile = savedRegionProfile; regions = savedRegionProfile.regions
        bindSavedRegionsIfAvailable()
    }
}

final class ThreeRegionReceiverView: NSView {
    let localRegions = [CGRect(x: 24, y: 35, width: 312, height: 86),
                        CGRect(x: 24, y: 200, width: 312, height: 86),
                        CGRect(x: 24, y: 365, width: 312, height: 86)]
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var counts = [0, 0, 0]
    var unexpectedKeys = 0
    var received: [[String: Any]] = []
    private var running = false
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let startButton = NSButton(title: "开始三键测试", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let moveButton = NSButton(title: "平移窗口", target: nil, action: nil)
    private var moved = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let header = NSTextField(labelWithString: "三区练习 · 按住 2／3，松开回 1 · Esc 停止")
        header.frame = CGRect(x: 17, y: 537, width: 338, height: 20)
        header.font = .systemFont(ofSize: 12)
        header.textColor = .secondaryLabelColor
        addSubview(header)
        statusField.frame = CGRect(x: 24, y: 495, width: 312, height: 34)
        statusField.font = .systemFont(ofSize: 13, weight: .semibold)
        statusField.preferredMaxLayoutWidth = 312
        statusField.setAccessibilityIdentifier("damai.three-region-test.status")
        addSubview(statusField)
        startButton.frame = CGRect(x: 24, y: 461, width: 150, height: 28)
        stopButton.frame = CGRect(x: 180, y: 461, width: 60, height: 28)
        moveButton.frame = CGRect(x: 246, y: 461, width: 90, height: 28)
        for button in [startButton, stopButton, moveButton] {
            button.bezelStyle = .rounded
            button.target = self
            addSubview(button)
        }
        startButton.action = #selector(startPressed)
        stopButton.action = #selector(stopPressed)
        moveButton.action = #selector(movePressed)
        setStatus("尚未启动，请点击开始三键测试", running: false)
    }

    required init?(coder: NSCoder) { nil }

    func setStatus(_ text: String, running: Bool) {
        self.running = running
        statusField.stringValue = text
        statusField.textColor = running ? .systemTeal : .systemOrange
        startButton.isEnabled = !running
        stopButton.isEnabled = running
    }

    @objc private func startPressed() {
        guard !running else { return }
        onStart?()
    }

    @objc private func stopPressed() {
        guard running else { return }
        onStop?()
    }

    /// Exercise actual WindowServer geometry without sharing a physical drag
    /// with the automatic mouse. The controller still performs all remapping.
    @objc private func movePressed() {
        guard let window = window else { return }
        let delta: CGFloat = moved ? -48 : 48
        window.setFrameOrigin(CGPoint(x: window.frame.minX+delta, y: window.frame.minY+delta/2))
        moved.toggle()
    }

    func reset() { counts = [0, 0, 0]; unexpectedKeys = 0; received = []; needsDisplay = true }
    override var acceptsFirstResponder: Bool { true }
    var report: [String: Any] { ["counts": counts, "unexpectedKeys": unexpectedKeys, "received": received] }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        for i in 0..<3 {
            let r = localRegions[i]
            NSColor.systemOrange.withAlphaComponent(0.18).setFill(); NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
            let p = NSMutableParagraphStyle(); p.alignment = .center
            let text = "\(i+1) · \(["底部购买", "努力刷新", "继续尝试"][i])\n已收到 \(counts[i]) 次"
            text.draw(in: r.insetBy(dx: 16, dy: 17), withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: p])
        }
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let index = localRegions.firstIndex(where: { $0.contains(p) }),
              let cg = event.cgEvent, cg.getIntegerValueField(.eventSourceUserData) > 0 else { return }
        counts[index] += 1
        received.append(["region": index+1, "index": cg.getIntegerValueField(.eventSourceUserData), "receivedMonoNs": PrecisionClock.nowNs()])
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        let regionsByCode: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 83: 1, 84: 2, 85: 3]
        if let region = regionsByCode[event.keyCode] {
            unexpectedKeys += 1
            if !running {
                setStatus("已收到按键 \(region)，但测试尚未启动；请点击开始三键测试。", running: false)
            }
        }
    }
}
