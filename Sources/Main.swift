import AppKit
import ApplicationServices
import Foundation
import Darwin

private func textLabel(_ text: String, size: CGFloat = 13, color: NSColor = .labelColor, bold: Bool = false) -> NSTextField {
    let v = NSTextField(labelWithString: text)
    v.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    v.textColor = color
    v.lineBreakMode = .byWordWrapping
    return v
}
private func field(_ value: String, width: CGFloat) -> NSTextField {
    let v = NSTextField(string: value)
    v.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
    v.widthAnchor.constraint(equalToConstant: width).isActive = true
    return v
}
private func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = .horizontal; s.spacing = spacing
    s.alignment = .centerY; return s
}
private func column(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = .vertical; s.spacing = spacing
    s.alignment = .leading; return s
}
private func cgPoint(_ cocoa: CGPoint) -> CGPoint {
    CGPoint(x: cocoa.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - cocoa.y)
}
private func formatTime(_ epoch: Double) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier:"Asia/Shanghai")!
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date(timeIntervalSince1970: epoch))
}
private func minutePicker() -> NSDatePicker {
    let picker = NSDatePicker()
    picker.datePickerStyle = .textFieldAndStepper
    picker.datePickerMode = .single
    picker.datePickerElements = [.yearMonthDay,.hourMinute]
    picker.locale = Locale(identifier:"zh_CN")
    picker.calendar = Calendar(identifier:.gregorian)
    picker.timeZone = TimeZone(identifier:"Asia/Shanghai")!
    picker.font = .monospacedDigitSystemFont(ofSize:15,weight:.regular)
    picker.isBezeled = true; picker.drawsBackground = true
    picker.widthAnchor.constraint(equalToConstant:270).isActive = true
    return picker
}
private func wholeMinute(_ epoch:Double) -> Double {
    floor(epoch/60)*60
}
private func percentile(_ values: [Double], _ p: Double) -> Double {
    let a = values.sorted(); guard !a.isEmpty else { return 0 }
    let k = Double(a.count - 1) * p, lo = Int(k), hi = min(Int(k) + 1, a.count - 1)
    return a[lo] + (a[hi] - a[lo]) * (k - Double(lo))
}

struct TargetWindow {
    let pid: pid_t
    let id: CGWindowID
    let frame: CGRect
    let title: String
}
private struct PendingNormalTask {
    let id = UUID()
    let configuration: ClickConfiguration
    let target: TargetWindow
}
private func windowList() -> [[String: Any]] {
    let rows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    return rows.filter { info in
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        let title = info[kCGWindowName as String] as? String ?? ""
        guard owner == "ChatGPT Computer Use" || owner == "Codex Computer Use" else { return true }
        if title == "Software Cursor" { return false }
        // Window titles can be withheld without Screen Recording permission.
        if let d = info[kCGWindowBounds as String] as? [String:Any],let r = CGRect(dictionaryRepresentation:d as CFDictionary),r.width <= 160,r.height <= 160 { return false }
        return true
    }
}
private func metadata(_ info: [String: Any]) -> TargetWindow? {
    guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
          let id = info[kCGWindowNumber as String] as? UInt32,
          let d = info[kCGWindowBounds as String] as? [String: Any],
          let r = CGRect(dictionaryRepresentation: d as CFDictionary) else { return nil }
    let name = info[kCGWindowOwnerName as String] as? String ?? "目标应用"
    return TargetWindow(pid: pid, id: id, frame: r, title: name)
}
private func targetAt(_ point: CGPoint) -> TargetWindow? {
    for info in windowList() {
        guard (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
              let t = metadata(info), t.frame.contains(point) else { continue }
        return t
    }
    return nil
}
final class GuardState: @unchecked Sendable {
    private let lock = NSLock(); private var valid = false; private var updated: UInt64 = 0
    private var selected: TargetWindow?
    private var lastIssue = ""
    var diagnostic: String { lock.lock(); defer { lock.unlock() }; return lastIssue }
    private func issue(_ message:String) { lock.lock(); lastIssue = message; lock.unlock() }
    func configure(_ target: TargetWindow) {
        lock.lock(); selected = target; lock.unlock()
    }
    func set(_ value: Bool) { lock.lock(); valid = value; updated = PrecisionClock.nowNs(); lock.unlock() }
    func check(at location: CGPoint) -> Bool {
        lock.lock()
        let fresh = valid && PrecisionClock.nowNs() - updated < 250_000_000
        let t = selected
        lock.unlock()
        guard fresh, let target = t, target.frame.contains(location) else {
            issue("前台／权限／窗口状态校验失败或状态已过期。"); return false
        }
        issue("")
        let windows = windowList().compactMap { info -> VisibilityWindow? in
            guard let w = metadata(info) else { return nil }
            return VisibilityWindow(pid:w.pid,id:w.id,frame:w.frame,
                                    layer:info[kCGWindowLayer as String] as? Int ?? 0,
                                    alpha:info[kCGWindowAlpha as String] as? Double ?? 1)
        }
        let visible = TargetVisibility.allows(point:location,targetPID:target.pid,targetID:target.id,
                                             targetFrame:target.frame,windows:windows)
        if !visible { issue("实际落点被其他普通窗口或目标应用的浮窗挡住，或目标窗口已变化。") }
        return visible
    }
}

final class SelectView: NSView {
    var start: CGPoint?; var current: CGPoint?
    var regionName = "A"
    var finish: ((CGRect?) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.30).setFill(); bounds.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 23), .foregroundColor: NSColor.white]
        "拖框圈选区域 \(regionName)，每次在框内随机点击 · Esc 取消".draw(at: CGPoint(x: 45, y: bounds.height - 70), withAttributes: attrs)
        if let a = start, let b = current {
            let r = CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(a.x-b.x), height: abs(a.y-b.y))
            NSColor.systemCyan.withAlphaComponent(0.22).setFill(); r.fill()
            NSColor.systemCyan.setStroke(); let p = NSBezierPath(rect: r); p.lineWidth = 2; p.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from:nil); current = start; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { current = convert(event.locationInWindow, from:nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        guard let a = start, let w = window else { return }
        let b = convert(event.locationInWindow, from:nil)
        let first = cgPoint(w.convertPoint(toScreen:a)), last = cgPoint(w.convertPoint(toScreen:b))
        finish?(CGRect(x:min(first.x,last.x),y:min(first.y,last.y),width:abs(first.x-last.x),height:abs(first.y-last.y)))
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { finish?(nil) } }
}
final class OverlayWindow: NSWindow { override var canBecomeKey: Bool { true } }
final class FlippedDocumentView: NSView { override var isFlipped: Bool { true } }

final class ReceiverView: NSView {
    var onReceive: ((Int, UInt64) -> Void)?
    var received = 0
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed:0.05,green:0.43,blue:0.36,alpha:1).setFill(); bounds.fill()
        let title = "本机点击接收区\n\n已收到 \(received) 次\n校准期间请保持此窗口在前台"
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:21,weight:.medium),.foregroundColor:NSColor.white,.paragraphStyle:style]
        title.draw(in: CGRect(x:20,y:bounds.midY-70,width:bounds.width-40,height:160),withAttributes:attrs)
    }
    override func mouseDown(with event: NSEvent) { /* Consume to avoid window dragging. */ }
    override func mouseUp(with event: NSEvent) {
        let arrival = PrecisionClock.nowNs()
        let index = Int(event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0)
        guard index > 0 else { return }
        received += 1; needsDisplay = true; onReceive?(index,arrival)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    var window: NSWindow!
    var overlays: [NSWindow] = []
    var receiverWindow: NSWindow?; var receiverView: ReceiverView?
    let targetField = minutePicker()
    let freqField = field("5",width:65), countField = field("1",width:70)
    let compensationField = field("0",width:85), holdField = field("8",width:65)
    let pointLabel = textLabel("A：尚未框选",color:.secondaryLabelColor)
    let secondPointLabel = textLabel("B：尚未框选",color:.secondaryLabelColor)
    let clickPlanLabel = textLabel("",size:12,color:.secondaryLabelColor)
    var regionMode: NSSegmentedControl!
    var secondPickButton: NSButton!
    let permissionLabel = textLabel("",color:.secondaryLabelColor)
    let statusLabel = textLabel("待设置",size:15,color:.systemTeal,bold:true)
    let calibrationLabel = textLabel("尚无实测数据；补偿以 mouseUp 到达为准",color:.secondaryLabelColor)
    let clockLabel = textLabel("",size:14,color:.secondaryLabelColor)
    let networkStatusLabel = textLabel("NTP 尚未校时；普通定时任务须取得有效授时。",size:12,color:.secondaryLabelColor)
    var syncButton: NSButton!
    var networkTime: NetworkTimeSnapshot?
    var activeNetworkTime: NetworkTimeSnapshot?
    private var pendingNormal: PendingNormalTask?
    var pendingRefreshInFlight = false
    var networkSyncing = false
    var networkWaiters: [(NetworkTimeSnapshot?) -> Void] = []
    var networkFailure = ""
    var networkSession = UUID()
    var initialTargetSuggestion: Double?
    let logView = NSTextView()
    var startButton: NSButton!, stopButton: NSButton!
    var controls: [NSControl] = []
    var point: CGPoint?; var targetWindow: TargetWindow?
    var regionA: CGRect?; var regionB: CGRect?
    var usesTwoRegions: Bool { regionMode?.selectedSegment == 1 }
    let guardState = GuardState()
    lazy var engine = ClickEngine(validator: { [weak self] location in
        guard let self = self, self.guardState.check(at:location) else { return false }
        if let snapshot = self.activeNetworkTime {
            return snapshot.isUsable(atMonoNs:PrecisionClock.nowNs())
        }
        return true
    })
    var activeTarget: TargetWindow?
    var events: [ClickEvent] = []; var arrivals: [Int:UInt64] = [:]
    var lastCalibration: Double?; var currentRunID = ""; var currentMode = "normal"
    var timer: Timer?; var monitor: Any?; var localMonitor: Any?
    var powerToken: NSObjectProtocol?; var activity: NSObjectProtocol?
    var server: CalibrationHTTPServer?; var benchmarkExit = false; var terminating = false
    var serverStarting = false
    var phoneExpectedLatency: Double?; var calibrationSource = ""
    var outputRoot: URL {
        if let i = CommandLine.arguments.firstIndex(of:"--report-dir"), CommandLine.arguments.count > i+1 {
            return URL(fileURLWithPath:CommandLine.arguments[i+1],isDirectory:true)
        }
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("PunctualClicker",isDirectory:true)
    }
    var reports: URL { outputRoot.appendingPathComponent("Reports") }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; return b
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at:reports,withIntermediateDirectories:true)
        buildUI(); setupMenu()
        timer = Timer.scheduledTimer(withTimeInterval:0.05,repeats:true) { [weak self] _ in self?.refresh() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.stop(); return nil }; return event
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching:.keyDown) { [weak self] event in if event.keyCode == 53 { self?.stop() } }
        powerToken = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            guard let self = self else { return }
            self.stop(); self.networkTime = nil; self.networkSession = UUID()
            self.networkSyncing = false; self.networkFailure = "设备休眠后需要重新授时。"
            let waiting = self.networkWaiters; self.networkWaiters = []
            waiting.forEach { $0(nil) }
        }
        NSApplication.shared.activate(ignoringOtherApps:true)
        if let i = CommandLine.arguments.firstIndex(of:"--select-point"),CommandLine.arguments.count > i+2,
           let x = Double(CommandLine.arguments[i+1]),let y = Double(CommandLine.arguments[i+2]) {
            finishSelection(CGPoint(x:x,y:y))
        }
        if CommandLine.arguments.contains("--native-self-test") {
            benchmarkExit = true
            DispatchQueue.main.asyncAfter(deadline:.now()+0.7) { self.localCalibration() }
        } else if CommandLine.arguments.contains("--ntp-self-test") {
            benchmarkExit = true
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                self.synchronizeClock { snapshot in
                    guard let snapshot = snapshot else { self.fail("NTP 真实授时失败，不能进行本机授时验证。"); return }
                    self.runLocal(compensated:false,networkSnapshot:snapshot)
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.synchronizeClock() }
        }
    }
    func setupMenu() {
        let main = NSMenu(), app = NSMenuItem(), sub = NSMenu()
        sub.addItem(withTitle:"退出准点点击器",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        app.submenu = sub; main.addItem(app); NSApplication.shared.mainMenu = main
    }
    func buildUI() {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 920
        window = NSWindow(contentRect:NSRect(x:120,y:120,width:890,height:min(880,visibleHeight-50)),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "准点点击器"; window.minSize = NSSize(width:890,height:620); window.delegate = self
        window.isReleasedWhenClosed = false
        let root = window.contentView!; root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let header = textLabel("准点点击",size:30,bold:true)
        let desc = textLabel("框选按钮区域 → 设置北京时间。每次在区域内随机落点，支持 A、B 轮流点击。",color:.secondaryLabelColor)
        syncButton = button("校准北京时间 · NTP",#selector(syncNetworkTime))
        networkStatusLabel.preferredMaxLayoutWidth = 825
        regionMode = NSSegmentedControl(labels:["单区域","双区域轮流"],trackingMode:.selectOne,target:self,action:#selector(regionModeChanged))
        regionMode.selectedSegment = 0
        let pick = button("框选区域 A",#selector(selectPosition))
        secondPickButton = button("框选区域 B",#selector(selectSecondPosition))
        let future = button("下一个整分",#selector(setFuture))
        let local = button("② 本机校准 · 30 次",#selector(localCalibration))
        let validate = button("本机验证补偿",#selector(localValidation))
        let phone = button("手机镜像校准…",#selector(phoneHelp))
        let phoneBase = button("镜像采样 · 30 次",#selector(phoneCalibration))
        let phoneValid = button("镜像验证补偿",#selector(phoneValidation))
        let readPhone = button("读取手机结果",#selector(readPhoneResults))
        let apply = button("采用实测补偿",#selector(applyCompensation))
        let permission = button("开启辅助功能权限",#selector(requestPermission))
        startButton = button("开始等待并点击",#selector(startNormal)); startButton.bezelColor = .systemTeal
        stopButton = button("立即停止 · Esc",#selector(stop)); stopButton.isEnabled = false
        controls = [targetField,freqField,countField,compensationField,holdField,regionMode,pick,secondPickButton,future,local,validate,phone,phoneBase,phoneValid,apply]
        freqField.delegate = self; countField.delegate = self
        clickPlanLabel.preferredMaxLayoutWidth = 825
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        logView.isEditable = false; logView.isSelectable = true; logView.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        logView.textContainerInset = NSSize(width:10,height:9); scroll.documentView = logView
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:125).isActive = true
        let items: [NSView] = [
            row([header, statusLabel]), desc, row([clockLabel,syncButton]), networkStatusLabel,
            row([permissionLabel,permission]),
            row([textLabel("点击模式"),regionMode,textLabel("两个区域需在同一窗口内",size:12,color:.secondaryLabelColor)]),
            row([pick,pointLabel]),
            row([secondPickButton,secondPointLabel]),
            row([textLabel("北京时间"),targetField,future,textLabel("秒固定为 00",size:12,color:.secondaryLabelColor)]),
            row([textLabel("总频率"),freqField,textLabel("次/秒"),textLabel("总点击数"),countField,textLabel("次"),textLabel("按住"),holdField,textLabel("毫秒")]),
            clickPlanLabel,
            row([textLabel("提前补偿"),compensationField,textLabel("毫秒（正数提前，负数延后）"),apply]),
            row([local,validate,phone]),
            row([phoneBase,phoneValid,readPhone]), calibrationLabel,
            row([startButton,stopButton]),
            textLabel("圈选后固定窗口位置与大小。切换目标应用、移动窗口或休眠会停止任务。",size:12,color:.secondaryLabelColor),
            scroll
        ]
        // Keep all controls reachable on smaller laptop displays after adding the B row.
        let formScroll = NSScrollView(); formScroll.hasVerticalScroller = true
        formScroll.drawsBackground = false; formScroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(formScroll)
        let document = FlippedDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        formScroll.documentView = document
        let stack = column(items,spacing:13); stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([
            formScroll.leadingAnchor.constraint(equalTo:root.leadingAnchor),formScroll.trailingAnchor.constraint(equalTo:root.trailingAnchor),
            formScroll.topAnchor.constraint(equalTo:root.topAnchor),formScroll.bottomAnchor.constraint(equalTo:root.bottomAnchor),
            document.widthAnchor.constraint(equalTo:formScroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo:formScroll.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo:document.leadingAnchor,constant:28),stack.topAnchor.constraint(equalTo:document.topAnchor,constant:24),
            stack.trailingAnchor.constraint(equalTo:document.trailingAnchor,constant:-24),stack.bottomAnchor.constraint(equalTo:document.bottomAnchor,constant:-22),
            scroll.widthAnchor.constraint(equalTo:stack.widthAnchor)
        ])
        setFuture(); initialTargetSuggestion = targetField.dateValue.timeIntervalSince1970
        updateRegionControls()
        refresh(); window.center(); window.makeKeyAndOrderFront(nil)
        log("点击完成的定义是鼠标抬起（mouseUp）。每次点击按固定节拍调度，过度迟到停止，不集中补发。")
    }
    @objc func regionModeChanged() { updateRegionControls() }
    func controlTextDidChange(_ obj: Notification) { updateClickPlan() }
    func updateRegionControls() {
        secondPickButton.isEnabled = usesTwoRegions && !engine.isRunning && pendingNormal == nil
        secondPointLabel.textColor = usesTwoRegions ? .secondaryLabelColor : .tertiaryLabelColor
        updateClickPlan()
    }
    func updateClickPlan() {
        guard let frequency = Double(freqField.stringValue),frequency.isFinite,(0.1...100).contains(frequency),
              let count = Int(countField.stringValue),(1...10000).contains(count) else {
            clickPlanLabel.stringValue = "总频率填 0.1～100 次/秒，总点击数填 1～10000；次数按每一次点击计算。"; return
        }
        let interval = String(format:"%.1f",1000/frequency)
        let span = String(format:"%.2f",Double(count-1)/frequency)
        if usesTwoRegions {
            clickPlanLabel.stringValue = "A → B → A → B；每隔 \(interval) 毫秒点击一次。A \((count+1)/2) 次，B \(count/2) 次，共 \(count) 次；首末点击相隔 \(span) 秒。"
        } else {
            clickPlanLabel.stringValue = "每隔 \(interval) 毫秒在 A 内随机点击，共 \(count) 次；首末点击相隔 \(span) 秒。"
        }
    }
    func refresh() {
        let now = PrecisionClock.nowNs()
        if let snapshot = networkTime {
            let fresh = snapshot.isUsable(atMonoNs:now)
            clockLabel.stringValue = (fresh ? "北京时间  " : "北京时间（校时已过期）  ") + formatTime(snapshot.utcEpoch(atMonoNs:now))
            clockLabel.textColor = fresh ? .labelColor : .systemOrange
            if !networkSyncing {
                let offset = (snapshot.utcEpoch(atMonoNs:now)-Date().timeIntervalSince1970)*1000
                networkStatusLabel.stringValue = String(format:"%@ · 本机%@ %.2f ms · RTT %.2f ms · 估计不确定度 ±%.2f ms · %.0f / 120秒",snapshot.sourceSummary,offset >= 0 ? "慢" : "快",abs(offset),snapshot.roundTripMs,snapshot.estimatedUncertaintyMs(atMonoNs:now),snapshot.ageSeconds(atMonoNs:now)) + (networkFailure.isEmpty ? "" : " · 最近授时失败")
            }
        } else {
            clockLabel.stringValue = "本机时间（未授时）  " + formatTime(Date().timeIntervalSince1970)
            clockLabel.textColor = .systemOrange
            if !networkSyncing { networkStatusLabel.stringValue = networkFailure.isEmpty ? "NTP 尚未校时；普通定时任务须取得有效授时。" : networkFailure }
        }
        syncButton.isEnabled = !networkSyncing && !engine.isRunning && pendingNormal == nil
        advancePendingNormal()
        let trusted = AXIsProcessTrusted()
        permissionLabel.stringValue = trusted ? "● 辅助功能权限已开启" : "● 尚未开启辅助功能权限"
        permissionLabel.textColor = trusted ? .systemTeal : .systemOrange
        if engine.isRunning, let t = activeTarget {
            let current = windowList().compactMap(metadata).first { $0.id == t.id }
            let sameFrame = current.map { abs($0.frame.minX-t.frame.minX)<1 && abs($0.frame.minY-t.frame.minY)<1 && abs($0.frame.width-t.frame.width)<1 && abs($0.frame.height-t.frame.height)<1 } ?? false
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid
            guardState.set(trusted && sameFrame && foreground)
        }
    }
    func log(_ message: String) {
        let s = "[\(formatTime(Date().timeIntervalSince1970).suffix(12))] \(message)\n"
        logView.textStorage?.append(NSAttributedString(string:s,attributes:[.foregroundColor:NSColor.labelColor,.font:NSFont.monospacedSystemFont(ofSize:11,weight:.regular)])); logView.scrollToEndOfDocument(nil)
    }
    func fail(_ text: String) {
        statusLabel.stringValue = "需要处理"; log(text)
        if benchmarkExit {
            writeJSON(["status":"blocked","reason":text,"accessibilityTrusted":AXIsProcessTrusted()],name:"native-self-test.json")
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { exit(2) }
        } else {
            let a = NSAlert(); a.messageText = "暂不能开始"; a.informativeText = text; a.runModal()
        }
    }
    @objc func setFuture() {
        let now = networkTime?.utcEpoch(atMonoNs:PrecisionClock.nowNs()) ?? Date().timeIntervalSince1970
        targetField.dateValue = Date(timeIntervalSince1970:wholeMinute(now)+60)
    }
    @objc func syncNetworkTime() { synchronizeClock() }
    func synchronizeClock(completion: ((NetworkTimeSnapshot?) -> Void)? = nil) {
        if let completion = completion { networkWaiters.append(completion) }
        guard !networkSyncing else { return }
        networkSyncing = true; syncButton.isEnabled = false
        networkStatusLabel.stringValue = "正在向公共 NTP 服务器授时…不修改系统时间。"
        log("NTP 授时开始：查询阿里云、Cloudflare、Apple；公共服务免费，无需账户。")
        let session = networkSession
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                let result = try NTPClient.synchronize()
                DispatchQueue.main.async {
                    guard self.networkSession == session else { return }
                    self.networkTime = result.snapshot; self.networkFailure = ""
                    if self.pendingNormal == nil,self.targetField.dateValue.timeIntervalSince1970 == self.initialTargetSuggestion {
                        self.setFuture(); self.initialTargetSuggestion = nil
                    }
                    if let data = try? JSONEncoder().encode(result),let object = try? JSONSerialization.jsonObject(with:data) {
                        self.writeJSON(object,name:"ntp-latest.json")
                        self.writeJSON(object,name:"ntp-\(UUID().uuidString).json")
                    }
                    self.log(String(format:"NTP 授时成功：%@；UTC−本机 %+.3f ms；RTT %.3f ms；估计不确定度 ±%.3f ms。",result.snapshot.sourceSummary,result.snapshot.offsetMs,result.snapshot.roundTripMs,result.snapshot.baseUncertaintyMs))
                    for issue in result.failures { self.log("NTP 来源诊断：\(issue)") }
                    self.completeNetworkSync(result.snapshot)
                }
            } catch {
                let detail = error.localizedDescription
                DispatchQueue.main.async {
                    guard self.networkSession == session else { return }
                    self.networkFailure = "NTP 授时失败：\(detail)"
                    self.log(self.networkFailure)
                    self.writeJSON(["status":"failed","reason":detail,"createdAtSystemTime":formatTime(Date().timeIntervalSince1970)],name:"ntp-last-failure.json")
                    self.completeNetworkSync(nil)
                }
            }
        }
    }
    func completeNetworkSync(_ snapshot:NetworkTimeSnapshot?) {
        networkSyncing = false
        let waiting = networkWaiters; networkWaiters = []
        waiting.forEach { $0(snapshot) }; refresh()
    }
    private func pendingFailed(_ message:String) {
        pendingNormal = nil; pendingRefreshInFlight = false; activeNetworkTime = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        controls.forEach { $0.isEnabled = true }; startButton.isEnabled = true; stopButton.isEnabled = false
        updateRegionControls()
        statusLabel.stringValue = "已停止"; log(message)
    }
    private func preparePending(_ task:PendingNormalTask,snapshot:NetworkTimeSnapshot) {
        guard pendingNormal?.id == task.id else { return }
        let now = PrecisionClock.nowNs()
        let delay = task.configuration.targetWallEpoch-snapshot.utcEpoch(atMonoNs:now)-(task.configuration.compensationMs+task.configuration.holdMs)/1000
        guard delay >= 0.35,delay <= 172800 else {
            pendingFailed("授时后的首次按下时间必须在 350 毫秒至 48 小时以内；请重新设置目标时间。"); return
        }
        if delay > 30 {
            pendingRefreshInFlight = false; statusLabel.stringValue = "等待临近授时"
            log("已按北京时间等待；首次按下前约 30 秒将重新 NTP 授时，成功后进入点击调度。")
            return
        }
        armPending(task,snapshot:snapshot)
    }
    private func armPending(_ task:PendingNormalTask,snapshot:NetworkTimeSnapshot) {
        guard pendingNormal?.id == task.id else { return }
        let now = PrecisionClock.nowNs(), c = task.configuration
        let lastSendEpoch = c.targetWallEpoch + Double(c.count-1)/c.frequencyHz-c.compensationMs/1000
        let untilLast = lastSendEpoch-snapshot.utcEpoch(atMonoNs:now)
        guard snapshot.isUsable(atMonoNs:now),untilLast >= 0,
              snapshot.isUsable(atMonoNs:now+UInt64(untilLast*1e9)) else {
            pendingFailed("本轮点击会超过本次授时 120 秒有效期，或授时质量不合格。请缩短连点总时长，再开始。"); return
        }
        pendingNormal = nil; pendingRefreshInFlight = false
        do { try begin(c,target:task.target,mode:"normal",networkSnapshot:snapshot) }
        catch { pendingFailed(error.localizedDescription) }
    }
    private func advancePendingNormal() {
        guard let task = pendingNormal,!pendingRefreshInFlight,let snapshot = networkTime else { return }
        let delay = task.configuration.targetWallEpoch-snapshot.utcEpoch(atMonoNs:PrecisionClock.nowNs())-(task.configuration.compensationMs+task.configuration.holdMs)/1000
        guard delay <= 30 else { return }
        pendingRefreshInFlight = true; statusLabel.stringValue = "临近执行 · 授时中"
        synchronizeClock { [weak self] fresh in
            guard let self = self,self.pendingNormal?.id == task.id else { return }
            guard let fresh = fresh else { self.pendingFailed("临近执行的 NTP 授时失败，任务已停止，没有回退系统时间。"); return }
            self.preparePending(task,snapshot:fresh)
        }
    }
    @objc func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        log("在系统设置中开启“准点点击器”的辅助功能权限，然后回到此窗口；无需输入账户密码给本工具。")
    }
    @objc func selectPosition() { selectRegion(0) }
    @objc func selectSecondPosition() { selectRegion(1) }
    func selectRegion(_ slot: Int) {
        guard !engine.isRunning,pendingNormal == nil else { return }
        guard slot == 0 || usesTwoRegions else { return }
        if slot == 1 && regionA == nil { fail("请先框选区域 A，再框选同一窗口内的区域 B。"); return }
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false)
            w.isOpaque = false; w.backgroundColor = .clear; w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; w.isReleasedWhenClosed = false
            let v = SelectView(frame:CGRect(origin:.zero,size:screen.frame.size))
            v.regionName = slot == 0 ? "A" : "B"
            v.finish = { [weak self] rect in self?.finishSelection(rect,slot:slot) }; w.contentView = v
            overlays.append(w); w.makeKeyAndOrderFront(nil); w.makeFirstResponder(v)
        }
    }
    // Developer CLI compatibility; normal selection always retains the entire rectangle.
    func finishSelection(_ p: CGPoint) {
        finishSelection(CGRect(x:p.x-1,y:p.y-1,width:2,height:2),slot:0)
    }
    func finishSelection(_ rect: CGRect?, slot: Int) {
        overlays.forEach { $0.orderOut(nil) }; overlays.removeAll()
        guard let rect = rect else { return }
        guard rect.width >= 2,rect.height >= 2 else { fail("请拖动框选至少 2 × 2 点的区域，范围应在可点击按钮内。"); return }
        let p = CGPoint(x:rect.midX,y:rect.midY)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {
            guard let t = targetAt(p) else { self.fail("该位置没有可识别的应用窗口，请重新圈选。"); return }
            guard t.frame.contains(rect) else { self.fail("整个区域必须位于同一个目标窗口内，请缩小选框。"); return }
            if slot == 1 {
                guard let first = self.targetWindow,first.id == t.id,first.frame == t.frame else {
                    self.fail("A、B 必须位于同一窗口，且窗口位置与大小不能变化。请重新框选。"); return
                }
                self.regionB = rect
                self.secondPointLabel.stringValue = self.regionDescription("B",rect:rect,target:t)
            } else {
                if self.targetWindow?.id != t.id || self.targetWindow?.frame != t.frame {
                    self.regionB = nil; self.secondPointLabel.stringValue = "B：尚未框选"
                }
                self.point = p; self.targetWindow = t; self.regionA = rect
                self.pointLabel.stringValue = self.regionDescription("A",rect:rect,target:t)
            }
            self.log("已框选区域 \(slot == 0 ? "A" : "B")：\(t.title)，x \(Int(rect.minX)) / y \(Int(rect.minY))，\(Int(rect.width)) × \(Int(rect.height)) 点。正常任务每次在框内随机落点；校准仍用 A 中心。")
            self.updateRegionControls()
            self.window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true)
        }
    }
    func regionDescription(_ name:String,rect:CGRect,target:TargetWindow) -> String {
        String(format:"%@：%@ · x %.0f / y %.0f · %.0f × %.0f 点",name,target.title,rect.minX,rect.minY,rect.width,rect.height)
    }
    func config(point: CGPoint, target: Double, count: Int? = nil, compensation: Double? = nil) throws -> ClickConfiguration {
        guard let f = Double(freqField.stringValue),let c = Int(countField.stringValue),let co = Double(compensationField.stringValue),let hold = Double(holdField.stringValue) else { throw ClickEngineError.invalid("频率、次数、补偿和按住时长必须是有效数字。") }
        return ClickConfiguration(targetWallEpoch:target,point:point,frequencyHz:f,count:count ?? c,compensationMs:compensation ?? co,holdMs:hold)
    }
    @objc func startNormal() {
        guard !engine.isRunning,pendingNormal == nil else { return }
        guard let p = point,let a = regionA,let t = targetWindow else { fail("先框选目标按钮的区域 A。"); return }
        if usesTwoRegions && regionB == nil { fail("双区域模式需要先框选区域 B。"); return }
        guard window.makeFirstResponder(nil) else { fail("请先完成日期和时分的输入。"); return }
        // NSDatePicker can retain hidden seconds; normalize the actual scheduled
        // value as well as its presentation, so every selected target is :00.000.
        let epoch = wholeMinute(targetField.dateValue.timeIntervalSince1970)
        targetField.dateValue = Date(timeIntervalSince1970:epoch)
        do {
            guard AXIsProcessTrusted() else { throw ClickEngineError.invalid("请先开启辅助功能权限。") }
            var c = try config(point:p,target:epoch)
            c.regions = usesTwoRegions ? [a,regionB!] : [a]
            try ClickEngine.validate(c)
            let task = PendingNormalTask(configuration:c,target:t); pendingNormal = task; pendingRefreshInFlight = true
            controls.forEach { $0.isEnabled = false }; startButton.isEnabled = false; stopButton.isEnabled = true
            statusLabel.stringValue = "校时 / 准备中"
            activity = ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"北京时间定时点击等待")
            let now = PrecisionClock.nowNs()
            if let snapshot = networkTime,snapshot.isUsable(atMonoNs:now),snapshot.ageSeconds(atMonoNs:now)<30 {
                preparePending(task,snapshot:snapshot)
            } else {
                synchronizeClock { [weak self] snapshot in
                    guard let self = self,self.pendingNormal?.id == task.id else { return }
                    guard let snapshot = snapshot else { self.pendingFailed("无法取得有效 NTP 授时，任务已停止。检查网络后可重新开始。"); return }
                    self.preparePending(task,snapshot:snapshot)
                }
            }
        } catch { fail(error.localizedDescription) }
    }
    @objc func localCalibration() { runLocal(compensated:false) }
    @objc func localValidation() { runLocal(compensated:true) }
    func runLocal(compensated: Bool,networkSnapshot:NetworkTimeSnapshot? = nil) {
        guard AXIsProcessTrusted() else { fail("需要先为已生成的“准点点击器.app”开启辅助功能权限。调度基准可在无此权限时运行，但真实系统点击测试不能跳过权限。"); return }
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:430,height:280),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        w.title = "准点点击器 · 本机接收测试"; w.isReleasedWhenClosed = false
        let v = ReceiverView(frame:CGRect(x:0,y:0,width:430,height:280)); w.contentView = v
        v.onReceive = { [weak self] i,n in self?.arrivals[i] = n }
        receiverWindow?.close(); receiverWindow = w; receiverView = v
        w.center(); w.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
            let p = cgPoint(w.convertPoint(toScreen:CGPoint(x:215,y:140)))
            // A background AX button invocation may not activate the new window.
            // Never calibrate by clicking another app that happens to cover its center.
            guard let t = windowList().compactMap(metadata).first(where:{ $0.id == CGWindowID(w.windowNumber) && $0.pid == getpid() }) else {
                self.fail("无法识别本机接收测试窗口。请保持测试窗口在前台后重试。"); return
            }
            let epoch = networkSnapshot?.utcEpoch(atMonoNs:PrecisionClock.nowNs()) ?? Date().timeIntervalSince1970
            var c = ClickConfiguration(targetWallEpoch:epoch+1,point:p,frequencyHz:10,count:30,compensationMs:compensated ? (Double(self.compensationField.stringValue) ?? 0) : 0,holdMs:8)
            c.maximumLatenessMs = 100
            do { try self.begin(c,target:t,mode:networkSnapshot == nil ? (compensated ? "local-validation" : "local-calibration") : "ntp-local-validation",networkSnapshot:networkSnapshot) } catch { self.fail(error.localizedDescription) }
        }
    }
    func begin(_ c: ClickConfiguration,target:TargetWindow,mode:String,networkSnapshot:NetworkTimeSnapshot? = nil) throws {
        guard AXIsProcessTrusted() else { throw ClickEngineError.invalid("请先开启辅助功能权限。") }
        guard !engine.isRunning else { throw ClickEngineError.alreadyRunning }
        try ClickEngine.validate(c)
        let current = windowList().compactMap(metadata).first { $0.id == target.id }
        guard let cur = current, cur.frame == target.frame else { throw ClickEngineError.invalid("目标窗口已移动、缩放或关闭，请重新圈选。") }
        if target.pid != getpid(), let app = NSRunningApplication(processIdentifier:target.pid) {
            // A background AX button invocation is not itself a foreground handoff.
            // First activate this app, then explicitly cooperate with the target app.
            NSApplication.shared.activate(ignoringOtherApps:true)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
                if #available(macOS 14.0, *) {
                    NSApplication.shared.yieldActivation(to:app)
                    _ = app.activate(from:NSRunningApplication.current,options:[.activateAllWindows])
                } else { _ = app.activate(options:[.activateAllWindows,.activateIgnoringOtherApps]) }
                if let url = app.bundleURL {
                    let options = NSWorkspace.OpenConfiguration(); options.activates = true
                    NSWorkspace.shared.openApplication(at:url,configuration:options,completionHandler:nil)
                }
            }
        }
        activeTarget = target; activeNetworkTime = networkSnapshot
        guardState.configure(target); guardState.set(true)
        events = []; arrivals = [:]; currentMode = mode; currentRunID = UUID().uuidString
        if mode != "normal" { lastCalibration = nil; calibrationSource = "" }
        if activity == nil { activity = ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"定时点击与校准") }
        do {
            let reference = networkSnapshot.map { ClickTimeReference(epoch:$0.referenceEpoch,monoNs:$0.referenceMonoNs) }
            try engine.start(c,timeReference:reference,onEvent:{ [weak self] e in DispatchQueue.main.async { self?.events.append(e) } },onComplete:{ [weak self] end in DispatchQueue.main.asyncAfter(deadline:.now()+0.35) { self?.finished(end,config:c) } })
        } catch {
            activeNetworkTime = nil
            if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }; throw error
        }
        controls.forEach { $0.isEnabled = false }; startButton.isEnabled = false; stopButton.isEnabled = true
        statusLabel.stringValue = "等待 / 执行中"
        log("\(mode) · 目标 \(formatTime(c.targetWallEpoch)) · \(networkSnapshot == nil ? "Mac原始时钟校准路径" : "NTP北京时间") · \(c.frequencyHz) 次/秒 × \(c.count) · 提前 \(c.compensationMs) ms")
        if !c.regions.isEmpty { log(c.regions.count == 2 ? "A、B 轮流，每次在区域内随机落点；A \((c.count+1)/2) 次，B \(c.count/2) 次。" : "每次在 A 区域内随机落点，共 \(c.count) 次。") }
    }
    @objc func stop() {
        if !overlays.isEmpty { overlays.forEach { $0.orderOut(nil) }; overlays.removeAll() }
        if pendingNormal != nil { pendingFailed("已取消北京时间等待；晚到的授时结果不会重新启动点击。") }
        engine.cancel()
    }
    func finished(_ completion: ClickCompletion,config:ClickConfiguration) {
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        controls.forEach { $0.isEnabled = true }; startButton.isEnabled = true; stopButton.isEnabled = false
        updateRegionControls()
        statusLabel.stringValue = completion.error == nil && !completion.cancelled ? "已完成" : "已停止"
        log("发出 \(completion.sentCount)/\(config.count) 次；\(completion.error ?? completion.reason)")
        if completion.reason == "targetChanged" {
            if let snapshot = activeNetworkTime,!snapshot.isUsable(atMonoNs:PrecisionClock.nowNs()) { log("NTP 授时已过期或质量不合格，停止后续点击。") }
            log("保护信息：目标 \(activeTarget?.title ?? "未知")；当前前台 \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知")。")
            if !guardState.diagnostic.isEmpty { log("保护诊断：\(guardState.diagnostic)") }
        }
        if completion.emergencyReleasePerformed { log("停止时另有一次已经按下的鼠标已释放，该次仍可能触发；请核对目标结果。") }
        var report: [String:Any] = ["runId":currentRunID,"mode":currentMode,"createdAt":formatTime(Date().timeIntervalSince1970),"targetWallEpoch":config.targetWallEpoch,"compensationMs":config.compensationMs,"frequencyHz":config.frequencyHz,"count":config.count,"sentCount":completion.sentCount,"receivedCount":arrivals.count,"reason":completion.reason,"accessibilityTrusted":AXIsProcessTrusted()]
        report["clickPattern"] = config.regions.isEmpty ? "fixed-calibration" : (config.regions.count == 2 ? "alternating-random-A-B" : "random-A")
        report["regions"] = config.regions.enumerated().map { i,r in ["name":i == 0 ? "A" : "B","x":r.minX,"y":r.minY,"width":r.width,"height":r.height] as [String:Any] }
        report["timeBasis"] = activeNetworkTime == nil ? "Mac raw system epoch for local/phone latency measurement" : "NTP UTC epoch, displayed and parsed in Asia/Shanghai"
        if let snapshot = activeNetworkTime,let data = try? JSONEncoder().encode(snapshot),let object = try? JSONSerialization.jsonObject(with:data) { report["ntpSnapshot"] = object }
        let rows: [[String:Any]] = events.map { e in
            var d: [String:Any] = ["index":e.index,"targetMs":e.targetWallEpoch*1000,"sentUpMs":e.mouseUpWallEpoch*1000,"schedulerErrorMs":e.upLatenessMs,"requestVsTargetMs":e.requestVsTargetMs,"sentUpMonoNs":e.mouseUpCallStartMonoNs]
            d["pointX"] = e.pointX; d["pointY"] = e.pointY
            if let slot = e.regionIndex { d["region"] = slot == 0 ? "A" : "B" }
            if let snapshot = activeNetworkTime {
                d["sentUpNTPMs"] = snapshot.utcEpoch(atMonoNs:e.mouseUpCallStartMonoNs)*1000
                d["ntpAgeSeconds"] = snapshot.ageSeconds(atMonoNs:e.mouseUpCallStartMonoNs)
                d["ntpEstimatedUncertaintyMs"] = snapshot.estimatedUncertaintyMs(atMonoNs:e.mouseUpCallStartMonoNs)
            }
            if let recv = arrivals[e.index] { d["receivedMonoNs"] = recv; d["latencyMs"] = PrecisionClock.signedMilliseconds(recv,e.mouseUpCallStartMonoNs); d["errorMs"] = PrecisionClock.signedMilliseconds(recv,e.targetMonoNs) }
            return d
        }
        report["events"] = rows
        report["emergencyReleasePerformed"] = completion.emergencyReleasePerformed
        report["schedulerP95AbsErrorMs"] = percentile(events.map{abs($0.upLatenessMs)},0.95)
        if currentMode.hasPrefix("local") || currentMode == "ntp-local-validation" {
            let measured = events.filter { arrivals[$0.index] != nil }
            let latencies = measured.map { PrecisionClock.signedMilliseconds(arrivals[$0.index]!,$0.mouseUpCallStartMonoNs) }
            let errors = measured.map { PrecisionClock.signedMilliseconds(arrivals[$0.index]!,$0.targetMonoNs) }
            let latency = percentile(latencies,0.5), p95 = percentile(errors.map(abs),0.95)
            if !measured.isEmpty {
                report["medianLatencyMs"] = latency; report["p50ErrorMs"] = percentile(errors,0.5); report["p95AbsErrorMs"] = p95
                report["minErrorMs"] = errors.min(); report["maxErrorMs"] = errors.max()
            }
            report["status"] = measured.count == config.count ? "received-all" : "receive-missing"
            if measured.count == config.count && completion.reason == "completed" {
                lastCalibration = latency; calibrationSource = "本机"
                calibrationLabel.stringValue = String(format:"本机：收到 %d/%d；发送→收到中位 %.3f ms；目标误差 p95 %.3f ms",measured.count,config.count,latency,p95)
            } else { lastCalibration = nil; calibrationLabel.stringValue = "本机收到 \(measured.count)/\(config.count)；接收不完整，不采用补偿" }
            log(calibrationLabel.stringValue)
        }
        let filename = currentMode+"-"+currentRunID+".json"; writeJSON(report,name:filename)
        activeNetworkTime = nil
        if currentMode.hasPrefix("phone") {
            let isAnchor = currentMode == "phone-anchor"
            api("/send-events",body:["runId":currentRunID,"events":events.map{["index":$0.index,"sentUpMs":$0.mouseUpWallEpoch*1000]}]) { _ in
                DispatchQueue.main.asyncAfter(deadline:.now()+0.8) {
                    if isAnchor && completion.reason == "completed" {
                        self.api("/summary") { j in
                            guard let json = j, let ms = json["medianLatencyMs"] as? Double,
                                  (json["matchedSendCount"] as? Int) == 1,
                                  (json["strayCount"] as? Int ?? 0) == 0, (json["clockFresh"] as? Bool) == true else {
                                self.fail("单击锚定未收到有效回执。确认手机页面已经校时、镜像测试按钮已正确圈选，再重试。"); return
                            }
                            self.phoneExpectedLatency = ms
                            self.log(String(format:"已单击锚定 %.3f ms，继续独立30次镜像采样。",ms))
                            self.runPhone(compensated:false)
                        }
                    } else { self.readPhoneResults() }
                }
            }
        }
        if benchmarkExit {
            writeJSON(report,name:"native-self-test.json")
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { exit(self.arrivals.count == config.count ? 0 : 3) }
        }
        if terminating { NSApplication.shared.reply(toApplicationShouldTerminate:true) }
    }
    @objc func applyCompensation() {
        guard let ms = lastCalibration else { fail("先完成本机或手机校准，并收到足够样本。"); return }
        compensationField.stringValue = String(format:"%.3f",ms)
        log(String(format:"已采用%@补偿 %.3f ms。请用独立一组“验证补偿”检查目标误差；本机数据不代表手机。",calibrationSource,ms))
    }
    func writeJSON(_ value:Any,name:String) {
        guard let d = try? JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]) else { return }
        try? d.write(to:reports.appendingPathComponent(name),options:.atomic)
    }
    func api(_ path:String,body:[String:Any]? = nil,completion:@escaping ([String:Any]?) -> Void) {
        var r = URLRequest(url:URL(string:"http://127.0.0.1:18765"+path)!); r.timeoutInterval = 3
        if let b = body { r.httpMethod = "POST"; r.setValue("application/json",forHTTPHeaderField:"Content-Type"); r.httpBody = try? JSONSerialization.data(withJSONObject:b) }
        URLSession.shared.dataTask(with:r) { d,_,_ in
            let json = d.flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
            DispatchQueue.main.async { completion(json) }
        }.resume()
    }
    func launchServer(completion:@escaping (Result<Void,Error>) -> Void) {
        if server?.isRunning == true { completion(.success(())); return }
        guard !serverStarting else { return }
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("Calibration",isDirectory:true) else {
            completion(.failure(ClickEngineError.invalid("安装包缺少手机校准资源，请重新安装。"))); return
        }
        do {
            serverStarting = true
            let native = try CalibrationHTTPServer(port:18765,resourceRoot:resources,reports:reports)
            server = native
            native.start { [weak self] result in
                self?.serverStarting = false
                if case .failure = result { self?.server = nil }
                completion(result)
            }
        } catch { serverStarting = false; completion(.failure(error)) }
    }
    func localIP() -> String {
        var ptr: UnsafeMutablePointer<ifaddrs>?; guard getifaddrs(&ptr) == 0 else { return "本机局域网IP" }
        defer { freeifaddrs(ptr) }; var item = ptr
        while let v = item {
            let name = String(cString:v.pointee.ifa_name)
            if name.hasPrefix("en"),let addr = v.pointee.ifa_addr,addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating:0,count:Int(NI_MAXHOST))
                if getnameinfo(addr,socklen_t(addr.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST) == 0 { return String(cString:host) }
            }
            item = v.pointee.ifa_next
        }
        return "本机局域网IP"
    }
    @objc func phoneHelp() {
        guard !serverStarting else { return }
        launchServer { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success: self.showPhoneHelp()
            case .failure(let error): self.fail("手机校准服务无法启动：\(error.localizedDescription)")
            }
        }
    }
    func showPhoneHelp() {
        let url = "http://\(localIP()):18765"
        let a = NSAlert(); a.messageText = "测量 iPhone 镜像的实际输入延迟"
        a.informativeText = "1. Mac 与 iPhone 连同一局域网。\n2. 在 iPhone Safari 打开下方网址，完成校时并保持前台。\n3. 锁定手机，打开 Mac 的 iPhone 镜像。\n4. 回到本工具，圈选手机页面的大按钮，再点“镜像采样”。\n5. 采用实测补偿后，再跑“镜像验证补偿”。\n\n\(url)\n\nSafari 测试结果只代表这条镜像测试路径，不代表其他 App 的业务处理延迟。"
        let f = NSTextField(string:url); f.isEditable = false; f.isSelectable = true; f.frame = NSRect(x:0,y:0,width:390,height:25); a.accessoryView = f
        a.addButton(withTitle:"知道了"); a.addButton(withTitle:"在 Mac 查看测试页")
        if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(URL(string:"http://127.0.0.1:18765")!) }
        log("内置手机校准服务已启动：\(url)；结果保存在 \(reports.appendingPathComponent("phone-calibration.json").path)")
    }
    @objc func phoneCalibration() { phoneExpectedLatency = nil; runPhone(compensated:false) }
    @objc func phoneValidation() { runPhone(compensated:true) }
    func runPhone(compensated:Bool) {
        guard let p = point,let t = targetWindow else { fail("先在 iPhone 镜像中的 Safari 校准页圈选测试按钮。"); return }
        guard t.pid != getpid() else { fail("镜像校准要圈选 iPhone 镜像中的按钮，不能选择本工具窗口。"); return }
        if compensated && phoneExpectedLatency == nil { fail("先完成镜像采样取得锚定延迟，再验证补偿。"); return }
        let isAnchor = phoneExpectedLatency == nil
        let sampleCount = isAnchor ? 1 : 30
        let run = UUID().uuidString, epoch = Date().timeIntervalSince1970+5
        let comp = compensated ? (Double(compensationField.stringValue) ?? 0) : 0
        let c = ClickConfiguration(targetWallEpoch:epoch,point:p,frequencyHz:5,count:sampleCount,compensationMs:comp,holdMs:8)
        var body:[String:Any] = ["runId":run,"targetsMs":(0..<sampleCount).map{(epoch+Double($0)/5)*1000},"compensationMs":comp,"label":isAnchor ? "单击锚定" : (compensated ? "镜像验证" : "镜像采样")]
        if let expected = phoneExpectedLatency { body["expectedLatencyMs"] = expected }
        api("/test-plan",body:body) { result in
            guard let result = result, result["error"] == nil else { self.fail("手机校准服务不可用。先点“手机镜像校准…”启动服务。"); return }
            do { try self.begin(c,target:t,mode:isAnchor ? "phone-anchor" : (compensated ? "phone-validation" : "phone-calibration")); self.currentRunID = run } catch { self.fail(error.localizedDescription) }
        }
    }
    @objc func readPhoneResults() {
        api("/summary") { json in
            guard let j = json else { self.fail("暂时读不到手机校准结果，请检查本地校准服务。"); return }
            if let ms = j["medianLatencyMs"] as? Double,let count = j["matchedSendCount"] as? Int,count == 30,
               (j["plannedCount"] as? Int) == 30,(j["strayCount"] as? Int ?? 0) == 0,(j["clockFresh"] as? Bool) == true,
               let run = j["runId"] as? String,run == self.currentRunID {
                self.lastCalibration = ms; self.phoneExpectedLatency = ms; self.calibrationSource = "手机镜像 Safari"
                self.calibrationLabel.stringValue = String(format:"手机：%d样本；中位 %.2f ms；p95误差 %.2f ms；校时 ±%.2f ms / %.0f秒前",count,ms,j["p95AbsErrorMs"] as? Double ?? 0,j["clockUncertaintyEstimateMs"] as? Double ?? 0,(j["clockAgeMs"] as? Double ?? 0)/1000)
            } else { self.lastCalibration = nil; self.calibrationLabel.stringValue = "手机回执不足30次或存在异常点；不采用补偿。请重新完成校时与采样。" }
            self.log(self.calibrationLabel.stringValue)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if pendingNormal != nil { pendingFailed("退出应用，已取消等待。") }
        if engine.isRunning { terminating = true; engine.cancel(); return .terminateLater }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification:Notification) {
        networkSession = UUID(); pendingNormal = nil
        engine.cancel(); server?.stop(); timer?.invalidate()
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { if engine.isRunning || pendingNormal != nil { stop() }; return true }
}

@main struct PunctualClicker {
    static func main() {
        if CommandLine.arguments.contains("--distribution-self-test") {
            exit(DistributionSelfTest.run())
        }
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = AppDelegate(); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
