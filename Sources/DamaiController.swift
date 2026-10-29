import AppKit
import ApplicationServices

/// Main-thread coordinator. Each observed action grants exactly one short-lived
/// click. Every subsequent click requires two new agreeing frames.
final class DamaiController: NSObject {
    unowned let app: AppDelegate
    let observer = DamaiScreenObserver()
    let lease = DamaiClickLease()
    var panel = NSStackView()
    let viewportLabel = NSTextField(labelWithString:"尚未选择手机内容范围")
    let recognitionLabel = NSTextField(wrappingLabelWithString:"先框选实际手机内容，再预览识别；不需要选择 iPhone 机型。")
    let rate = NSTextField(string:"3"), limit = NSTextField(string:"120"), duration = NSTextField(string:"90")
    var ownControls:[NSControl] = []
    var previewButton:NSButton!
    var permissionButton:NSButton!
    var immediateButton:NSButton!
    var viewport:CGRect?
    var target:TargetWindow?
    var session:UUID?
    var isActive:Bool { session != nil }
    var stopping = false
    var waitingEpoch:Double?
    var freshening = false
    var activatedForDeadline = false
    var startedMono:UInt64 = 0
    var graceUntil:UInt64 = 0
    var nextObserve:UInt64 = 0
    var recognizing = false
    var previewGeneration = UUID()
    var runner:ClickEngine?
    var clickInFlight = false
    var completions:[[String:Any]] = []
    var priorDecision:DamaiDecision?
    var priorCapture:UInt64 = 0
    var unknownSince:UInt64?
    var lastState = ""
    var sent = 0
    var maximumClicks = 120
    var maximumSeconds:Double = 90
    var maximumRate:Double = 3
    var stopReason = ""
    var audit:[[String:Any]] = []
    var runEvents:[ClickEvent] = []
    var inspectRows:[[String:Any]] = []
    var selectionWindows:[NSWindow] = []

    init(app:AppDelegate) { self.app = app }
    private func label(_ text:String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString:text)
        f.font = .systemFont(ofSize:12); f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = 790
        return f
    }
    private func row(_ views:[NSView]) -> NSStackView {
        let s = NSStackView(views:views); s.orientation = .horizontal; s.spacing = 9; s.alignment = .centerY; return s
    }
    private func button(_ title:String,_ action:Selector) -> NSButton {
        let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; return b
    }
    func makePanel() -> NSView {
        for (key,control) in [("damai.rate",rate),("damai.limit",limit),("damai.duration",duration)] {
            if let saved = UserDefaults.standard.string(forKey:key) { control.stringValue = saved }
        }
        let select = button("① 框选手机内容",#selector(selectViewport))
        previewButton = button("② 只预览识别",#selector(preview))
        permissionButton = button("开启屏幕录制权限",#selector(requestScreenPermission))
        immediateButton = button("立即启动大麦识别",#selector(startImmediately))
        let guide = button("查看大麦方案说明",#selector(showGuide))
        for f in [rate,limit,duration] { f.widthAnchor.constraint(equalToConstant:65).isActive = true }
        viewportLabel.font = .systemFont(ofSize:12); viewportLabel.textColor = .secondaryLabelColor
        recognitionLabel.font = .systemFont(ofSize:13); recognitionLabel.preferredMaxLayoutWidth = 790
        recognitionLabel.setAccessibilityIdentifier("damai.recognition")
        ownControls = [select,previewButton,permissionButton,immediateButton,rate,limit,duration]
        panel = NSStackView(views:[
            label("大麦专用 · 根据按钮文字重新定位，不按固定区域轮流。先在大麦预填场次、票档、张数与观演人；本版不自动选座、换档或填写身份信息。"),
            row([select,previewButton,permissionButton]),viewportLabel,
            row([label("最多"),rate,label("次/秒"),label("最多点击"),limit,label("次"),label("最多运行"),duration,label("秒")]),
            recognitionLabel,
            label("自动处理：购票入口 → 选票确定 → 努力刷新／立即提交／继续尝试；每次点击后重新识别。加速刷新中先等待；缺票、验证、未知弹窗和支付页停止。"),
            row([immediateButton,guide]),
            label("下方整分按钮到点启动识别。大麦视觉流程包含识别与等待耗时，不应用 Safari 毫秒补偿，也不保证瞬间点击。频率是上限；单区／双区精确定时功能保留。")
        ])
        panel.orientation = .vertical; panel.alignment = .leading; panel.spacing = 10
        panel.setAccessibilityIdentifier("damai.panel")
        return panel
    }
    func updateControls() {
        ownControls.forEach { $0.isEnabled = !isActive && !app.normalBusy }
        if previewButton != nil { previewButton.isEnabled = !isActive && !app.normalBusy && !recognizing }
        if permissionButton != nil {
            permissionButton.title = DamaiScreenObserver.hasScreenCapturePermission ? "屏幕录制权限已开启" : "开启屏幕录制权限"
        }
    }
    @objc func requestScreenPermission() {
        _ = DamaiScreenObserver.requestScreenCapturePermission()
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        app.log("大麦页面识别需要 macOS 屏幕录制权限；请为当前安装的准点点击器开启，系统要求时重新打开 App。")
    }
    @objc func showGuide() {
        let alert = NSAlert(); alert.messageText = "大麦方案 · 使用步骤"
        alert.informativeText = "1. 手机先预填场次、票档、张数及观演人，停在大麦演出页面。\n2. 打开 iPhone 镜像，框选手机画面全部内容，避开 Mac 标题栏。\n3. 点只预览识别，核对识别状态及将点击的文字。\n4. 选择立即启动，或设置未来北京时间整分后启动。\n5. Esc 随时停止。窗口移动／缩放、切换 Mac 应用、库存不足、验证及支付会停止。\n\n仅自动点购票入口、已选票档的确定、努力刷新、立即提交和继续尝试。返回重选、我知道了、场次／票档选择和下拉刷新交给你处理。\n\n不按手机型号套坐标：在实际视口中每次重新找按钮，改变字体／界面后先预览。视频截图只用于参考，手机在抖音播放教程时会拒绝执行。"
        alert.runModal()
    }
    @objc func selectViewport() {
        guard !isActive,!app.normalBusy,!recognizing else { return }
        previewGeneration = UUID()
        let selection = previewGeneration
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false)
            w.isOpaque = false; w.backgroundColor = .clear; w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; w.isReleasedWhenClosed = false
            let v = SelectView(frame:CGRect(origin:.zero,size:screen.frame.size))
            v.regionName = "手机全部内容（避开 Mac 标题栏）"
            v.finish = { [weak self] rect in self?.finishSelection(rect,generation:selection) }; w.contentView = v
            selectionWindows.append(w); w.makeKeyAndOrderFront(nil); w.makeFirstResponder(v)
        }
    }
    private func finishSelection(_ rect:CGRect?,generation:UUID) {
        selectionWindows.forEach { $0.orderOut(nil) }; selectionWindows.removeAll()
        guard let rect = rect else { return }
        guard rect.width >= 120,rect.height >= 240,rect.height/rect.width >= 1.25,
              rect.height/rect.width <= 3.5 else { app.fail("请框选竖屏手机的全部内容，至少 120 × 240 点，不是单个按钮。"); return }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in
            guard let self = self,self.previewGeneration == generation,!self.isActive,!self.app.normalBusy else { return }
            let p = CGPoint(x:rect.midX,y:rect.midY)
            guard let t = windowList().compactMap(metadata).first(where:{ $0.frame.contains(p) &&
                NSRunningApplication(processIdentifier:$0.pid)?.bundleIdentifier == "com.apple.ScreenContinuity" }),
                  t.frame.contains(rect) else { self.app.fail("大麦方案仅支持实际 iPhone 镜像窗口。请在该窗口内框选完整手机内容。"); return }
            self.target = t; self.viewport = rect
            self.viewportLabel.stringValue = String(format:"手机内容 %.0f × %.0f 点 · 自动按实际视口映射，不需要选机型",rect.width,rect.height)
            self.recognitionLabel.stringValue = "已框选。请先预览，确认大麦当前页面与识别结果。"
            self.app.window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true)
        }
    }
    @objc func preview() {
        guard !isActive,!app.normalBusy,!recognizing else { return }
        guard let t = target,let rect = viewport else { app.fail("先框选 iPhone 镜像里的完整手机内容。"); return }
        guard DamaiScreenObserver.hasScreenCapturePermission else { app.fail(DamaiScreenError.permissionRequired.localizedDescription); return }
        let generation = UUID(); previewGeneration = generation; recognizing = true; updateControls()
        recognitionLabel.stringValue = "正在识别（首次初始化本机文字模型可能需要十几秒）…本次不会点击。"
        observer.observe(windowID:t.id,windowFrame:t.frame,viewport:rect) { [weak self] result in
            guard let self = self else { return }; self.recognizing = false; self.updateControls()
            guard self.previewGeneration == generation,!self.isActive else { return }
            switch result {
            case .failure(let e): self.recognitionLabel.stringValue = e.localizedDescription
            case .success(let frame):
                let d = DamaiPlan.evaluate(frame.observations)
                self.show(d,prefix:"仅预览 · ")
                self.app.log("大麦预览：\(d.state.displayName)；\(d.reason)")
            }
        }
    }
    @objc func startImmediately() { start(scheduled:false) }
    func start(scheduled:Bool) {
        guard !isActive,!app.normalBusy,!recognizing else { return }
        guard let t = target,let rect = viewport else { app.fail("先在大麦方案中框选完整手机内容，并预览识别。"); return }
        guard AXIsProcessTrusted() else { app.fail("大麦真实点击需要辅助功能权限。"); return }
        guard DamaiScreenObserver.hasScreenCapturePermission else { app.fail(DamaiScreenError.permissionRequired.localizedDescription); return }
        guard let f = Double(rate.stringValue),f.isFinite,(0.2...5).contains(f),
              let c = Int(limit.stringValue),(1...1000).contains(c),
              let seconds = Double(duration.stringValue),seconds.isFinite,(5...600).contains(seconds) else {
            app.fail("大麦方案：频率上限 0.2～5 次/秒，总点击上限 1～1000 次，最长运行 5～600 秒。"); return
        }
        guard currentWindow(t) != nil,t.frame.contains(rect) else { app.fail("镜像窗口已改变，请重新框选手机内容。"); return }
        guard app.window.makeFirstResponder(nil) else { return }
        for (key,control) in [("damai.rate",rate),("damai.limit",limit),("damai.duration",duration)] {
            UserDefaults.standard.set(control.stringValue,forKey:key)
        }
        session = UUID(); stopping = false; maximumRate = f; maximumClicks = c; maximumSeconds = seconds
        sent = 0; audit = []; runEvents = []; completions = []; clickInFlight = false
        priorDecision = nil; unknownSince = nil; lastState = ""
        inspectRows = []; waitingEpoch = nil; freshening = false; activatedForDeadline = false
        previewGeneration = UUID(); startedMono = 0; nextObserve = 0
        app.activeTarget = t; app.activeNetworkTime = nil; app.guardState.configure(t); app.guardState.set(false)
        app.controls.forEach { $0.isEnabled = false }; app.startButton.isEnabled = false; app.stopButton.isEnabled = true
        updateControls()
        app.activity = ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"大麦页面识别与有限点击")
        app.log("大麦方案启动：最多 \(f) 次/秒、\(c) 次、\(seconds) 秒；每个落点重新识别，不循环固定坐标。")
        if scheduled {
            let epoch = floor(app.targetField.dateValue.timeIntervalSince1970/60)*60
            app.targetField.dateValue = Date(timeIntervalSince1970:epoch); waitingEpoch = epoch
            refreshClockForStart()
        } else { beginObserving() }
    }
    private func refreshClockForStart() {
        guard let id = session else { return }
        freshening = true; app.statusLabel.stringValue = "大麦 · 等待授时"
        app.synchronizeClock { [weak self] snapshot in
            guard let self = self,self.session == id,!self.stopping else { return }
            self.freshening = false
            guard let s = snapshot,let epoch = self.waitingEpoch else { self.stop(reason:"大麦整分启动未取得有效 NTP 授时。"); return }
            let delay = epoch-s.utcEpoch(atMonoNs:PrecisionClock.nowNs())
            guard delay >= 0.35,delay <= 172800 else { self.stop(reason:"授时后目标须在 350 毫秒至 48 小时以内，请重新设定未来整分。"); return }
            self.app.statusLabel.stringValue = "大麦 · 等待整分"
            self.recognitionLabel.stringValue = "等待整分启动识别；首次识别仍会花费时间，建议提前做一次预览。"
        }
    }
    private func activateTarget() {
        guard let t = target,let targetApp = NSRunningApplication(processIdentifier:t.pid) else { return }
        let id = session
        NSApplication.shared.activate(ignoringOtherApps:true)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.12) { [weak self] in
            guard self?.session == id,self?.isActive == true,self?.stopping == false else { return }
            if #available(macOS 14.0, *) {
                NSApplication.shared.yieldActivation(to:targetApp)
                _ = targetApp.activate(from:NSRunningApplication.current,options:[.activateAllWindows])
            } else { _ = targetApp.activate(options:[.activateAllWindows,.activateIgnoringOtherApps]) }
        }
    }
    private func beginObserving() {
        waitingEpoch = nil; startedMono = DispatchTime.now().uptimeNanoseconds
        graceUntil = startedMono+1_500_000_000; nextObserve = graceUntil
        app.statusLabel.stringValue = "大麦 · 识别中"
        recognitionLabel.stringValue = "正在准备镜像前台与文字识别；Esc 随时停止。"
        activateTarget()
    }
    func tick() {
        guard isActive,!stopping else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if let epoch = waitingEpoch {
            guard !freshening else { return }
            guard let clock = app.networkTime else { stop(reason:"没有有效 NTP 授时，已停止。"); return }
            let delay = epoch-clock.utcEpoch(atMonoNs:PrecisionClock.nowNs())
            if delay <= 30 && (!clock.isUsable(atMonoNs:PrecisionClock.nowNs()) || clock.ageSeconds(atMonoNs:PrecisionClock.nowNs()) > 30) { refreshClockForStart(); return }
            if delay <= 0 {
                guard clock.isUsable(atMonoNs:PrecisionClock.nowNs()) else { stop(reason:"授时过期，停止大麦整分启动。"); return }
                beginObserving()
            }
            return
        }
        guard startedMono > 0 else { return }
        if Double(now-startedMono)/1e9 >= maximumSeconds { stop(reason:"已达到大麦方案运行时长上限。"); return }
        if sent >= maximumClicks { stop(reason:"已达到大麦方案总点击上限。"); return }
        guard now >= graceUntil else { return }
        guard let t = target,let rect = viewport,currentWindow(t) != nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid,
              AXIsProcessTrusted(),DamaiScreenObserver.hasScreenCapturePermission else {
            stop(reason:"镜像窗口、前台应用或输入／屏幕权限改变，已停止。"); return
        }
        guard !recognizing,!clickInFlight,now >= nextObserve,let id = session else { return }
        recognizing = true; nextObserve = now+150_000_000
        observer.observe(windowID:t.id,windowFrame:t.frame,viewport:rect) { [weak self] result in
            guard let self = self else { return }; self.recognizing = false
            guard self.session == id,!self.stopping else { return }
            switch result {
            case .failure(let e): self.stop(reason:e.localizedDescription)
            case .success(let frame): self.consume(frame,session:id)
            }
        }
    }
    private func currentWindow(_ target:TargetWindow) -> TargetWindow? {
        windowList().compactMap(metadata).first { $0.id == target.id && $0.pid == target.pid && $0.frame == target.frame }
    }
    private func show(_ decision:DamaiDecision,prefix:String = "") {
        recognitionLabel.stringValue = prefix+decision.state.displayName+" · "+(decision.target.map { "目标“\($0.text)” · " } ?? "")+decision.reason
    }
    private func consume(_ frame:DamaiScreenFrame,session id:UUID) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard DamaiRunPolicy.isFresh(captured:frame.capturedUptimeNs,now:now) else {
            priorDecision = nil; recognitionLabel.stringValue = "本帧识别耗时较长，已丢弃并重读；不会点击旧画面。"; return
        }
        guard let t = target,currentWindow(t) != nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid else { stop(reason:"识别期间镜像前台或窗口改变，已停止。"); return }
        let decision = DamaiPlan.evaluate(frame.observations)
        show(decision)
        let stateKey = decision.state.rawValue+decision.kind.rawValue+(decision.target?.text ?? "")
        if stateKey != lastState {
            lastState = stateKey; app.log("大麦：\(decision.state.displayName) · \(decision.reason)")
            audit.append(["time":Date().timeIntervalSince1970,"state":decision.state.rawValue,"kind":decision.kind.rawValue,"target":decision.target?.text ?? "","reason":decision.reason])
        }
        if decision.kind == .stop { stop(reason:decision.reason); return }
        if decision.state == .unknown {
            if unknownSince == nil { unknownSince = now }
            if now-(unknownSince ?? now) > 3_000_000_000 { stop(reason:"连续 3 秒无法确认页面／按钮，已停止，请处理后重新启动。"); return }
        } else { unknownSince = nil }
        guard decision.kind == .click,let observation = decision.target else { priorDecision = nil; return }
        let agreed = DamaiRunPolicy.agrees(priorDecision,decision) && frame.capturedUptimeNs > priorCapture && now-priorCapture <= 1_500_000_000
        priorDecision = decision; priorCapture = frame.capturedUptimeNs
        guard agreed,let r = DamaiRunPolicy.globalRect(observation.rect,viewport:frame.viewport),r.width >= 2,r.height >= 2 else { return }
        // Randomize inside the middle of the recognized label, not the entire
        // guessed button; adjacent “return” actions remain outside this box.
        let safe = r.insetBy(dx:r.width*0.2,dy:r.height*0.2)
        let p = CGPoint(x:CGFloat.random(in:safe.minX..<safe.maxX),y:CGFloat.random(in:safe.minY..<safe.maxY))
        let expiry = frame.capturedUptimeNs+DamaiRunPolicy.maximumFrameAgeNs
        lease.authorize(run:id,region:safe,deadline:expiry)
        app.guardState.set(NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid && AXIsProcessTrusted())
        let lease = self.lease
        let engine = ClickEngine(validator:{ [weak self] point in
            guard let self = self else { return false }
            return lease.permits(run:id,point:point) && AXIsProcessTrusted() &&
                NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid && self.app.guardState.check(at:point)
        })
        runner = engine; priorDecision = nil; clickInFlight = true
        let config = ClickConfiguration(targetWallEpoch:Date().timeIntervalSince1970+0.06,point:p,frequencyHz:1,count:1,compensationMs:0,holdMs:8)
        do {
            try engine.start(config,onEvent:{ [weak self] event in DispatchQueue.main.async {
                guard let self = self,self.session == id else { return }
                self.sent += 1; self.runEvents.append(event)
                self.inspectRows.append(["index":self.sent,"label":observation.text,"state":decision.state.rawValue,
                                         "pointX":p.x,"pointY":p.y,"frameAgeMs":Double(DispatchTime.now().uptimeNanoseconds-frame.capturedUptimeNs)/1e6])
            } },onComplete:{ [weak self] completion in DispatchQueue.main.async {
                guard let self = self,self.session == id else { return }
                self.clickInFlight = false
                self.lease.invalidate()
                self.completions.append(["reason":completion.reason,"sentCount":completion.sentCount,
                                         "emergencyReleasePerformed":completion.emergencyReleasePerformed,
                                         "error":completion.error ?? ""])
                if completion.emergencyReleasePerformed { self.app.log("停止时释放了已按下的鼠标，当前这一次仍可能触发，请核对页面。") }
                if self.stopping { self.completeRun(); return }
                guard completion.reason == "completed" else { self.stop(reason:"大麦单次点击被保护机制停止：\(completion.error ?? completion.reason)"); return }
                self.nextObserve = DispatchTime.now().uptimeNanoseconds+UInt64(1e9/self.maximumRate)
            } })
        } catch { clickInFlight = false; stop(reason:error.localizedDescription) }
    }
    func stop(reason:String) {
        selectionWindows.forEach { $0.orderOut(nil) }; selectionWindows.removeAll()
        previewGeneration = UUID()
        guard isActive,!stopping else { return }
        stopping = true; stopReason = reason; lease.invalidate(); waitingEpoch = nil
        if clickInFlight { runner?.cancel() } else { completeRun() }
    }
    private func completeRun() {
        guard let id = session else { return }
        lease.invalidate()
        var report:[String:Any] = ["runId":id.uuidString,"mode":"damai-vision","version":1,
            "reason":stopReason,"sentCount":sent,"maximumRate":maximumRate,"maximumClicks":maximumClicks,
            "maximumSeconds":maximumSeconds,"states":audit,"clicks":inspectRows,"completions":completions,
            "measurementBoundary":"仅系统输入发送记录；不代表大麦业务受理或购票成功。识别不保存屏幕图像及完整OCR文本。"]
        if let data = try? JSONEncoder().encode(runEvents),let events = try? JSONSerialization.jsonObject(with:data) as? [[String:Any]] {
            report["events"] = events.enumerated().map { offset,event -> [String:Any] in var e = event; e["index"] = offset+1; return e }
        }
        app.writeJSON(report,name:"damai-\(id.uuidString).json")
        session = nil; waitingEpoch = nil; runner = nil; stopping = false; priorDecision = nil
        app.activeTarget = nil; app.activeNetworkTime = nil
        if let a = app.activity { ProcessInfo.processInfo.endActivity(a); app.activity = nil }
        app.controls.forEach { $0.isEnabled = true }; app.startButton.isEnabled = true; app.stopButton.isEnabled = false
        app.updateRegionControls(); app.statusLabel.stringValue = "大麦 · 已停止"
        recognitionLabel.stringValue = "已发出 \(sent) 次 · "+stopReason; app.log(recognitionLabel.stringValue)
        if app.terminating { DispatchQueue.main.async { NSApplication.shared.reply(toApplicationShouldTerminate:true) } }
    }
}
