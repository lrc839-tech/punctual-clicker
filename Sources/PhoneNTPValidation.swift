import AppKit
import ApplicationServices

/// A single, real click in the user-selected phone test page, with one frozen
/// UTC reference shared by scheduler, LAN clock synchronization and report.
final class PhoneNTPValidationController: NSObject {
    unowned let app: AppDelegate
    private(set) var isPreparing = false
    private var token = UUID()
    private var selectedEpoch: Double?
    private var syncInFlight = false
    private var target: TargetWindow?
    private var profile: DamaiRegionProfile?
    private var overlays: [NSWindow] = []
    private var ownControls: [NSControl] = []
    private var status = NSTextField(wrappingLabelWithString: "NTP 校验会记录目标、Mac 发出、手机收到三个北京时间。先在手机打开校准页，再单独框选蓝色靶区。")
    private var selection = NSTextField(labelWithString: "测试靶区：尚未框选；与大麦三区独立。")
    private var lastResult: [String: Any]?

    init(app: AppDelegate) { self.app = app; super.init() }
    private static func time(_ epoch: Double) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date(timeIntervalSince1970: epoch))
    }

    func makePanel() -> NSView {
        let pick = makeButton("框选手机测试靶区", #selector(selectTarget))
        let soon = makeButton("15 秒后 NTP 单击校验", #selector(startSoon))
        let minute = makeButton("按所设整分校验", #selector(startSelected))
        let receipt = makeButton("挂单回执复盘…", #selector(reviewReceipt))
        ownControls = [pick, soon, minute, receipt]
        let first = NSStackView(views: [pick, soon, minute, receipt])
        first.orientation = .horizontal; first.spacing = 8
        for field in [selection, status] {
            field.font = .systemFont(ofSize: 12); field.textColor = .secondaryLabelColor
        }
        selection.setAccessibilityIdentifier("phone.ntp.selection")
        status.preferredMaxLayoutWidth = 825; status.setAccessibilityIdentifier("phone.ntp.result")
        let stack = NSStackView(views: [first, selection, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        return stack
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b
    }

    @objc private func selectTarget() {
        guard !app.normalBusy, !app.damai.isActive else { return }
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.isReleasedWhenClosed = false
            let view = SelectView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.regionName = "NTP 手机校准页的蓝色靶区（与大麦三区独立）"
            view.finish = { [weak self] rect in self?.finishSelection(rect) }
            window.contentView = view; overlays.append(window); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        }
    }

    private func finishSelection(_ rect: CGRect?) {
        overlays.forEach { $0.orderOut(nil) }; overlays.removeAll()
        guard let rect, rect.width >= 12, rect.height >= 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now()+0.12) { [weak self] in
            guard let self, !self.app.normalBusy, !self.app.damai.isActive else { return }
            guard let t = windowList().filter({ ($0[kCGWindowLayer as String] as? Int ?? -1) == 0 })
                .compactMap(metadata).first(where: { $0.frame.contains(rect) }),
                NSRunningApplication(processIdentifier: t.pid)?.bundleIdentifier == "com.apple.ScreenContinuity" else {
                self.app.fail("请只框选 iPhone 镜像里校准网页的蓝色靶区。"); return
            }
            self.target = t; self.profile = DamaiRegionProfile(regions: [rect, rect, rect], windowFrame: t.frame)
            self.selection.stringValue = String(format: "测试靶区：镜像窗口内 x %.0f / y %.0f · %.0f × %.0f 点；与大麦三区独立。", rect.minX-t.frame.minX, rect.minY-t.frame.minY, rect.width, rect.height)
            self.app.window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    @objc private func startSoon() { requestStart(atSelectedMinute: false) }
    @objc private func startSelected() { requestStart(atSelectedMinute: true) }
    @objc private func reviewReceipt() {
        guard !app.normalBusy, !app.damai.isActive else { return }
        BusinessReceiptReview.present(reportDirectory: app.reports, defaultTargetEpoch: app.targetField.dateValue.timeIntervalSince1970) { [weak self] url in
            self?.app.log("挂单回执复盘已保存：\(url.lastPathComponent)；不自动改变点击补偿。")
        }
    }

    private func resolvedTarget() -> (TargetWindow, CGPoint)? {
        guard let t = target, let profile,
              let current = windowList().compactMap(metadata).first(where: { $0.id == t.id && $0.pid == t.pid }),
              let mapped = profile.mappedRegions(to: current.frame), let region = mapped[0] else { return nil }
        return (current, CGPoint(x: region.midX, y: region.midY))
    }

    private func requestStart(atSelectedMinute: Bool) {
        guard !app.normalBusy, !app.damai.isActive else { return }
        guard !app.serverStarting else { app.fail("手机校准服务正在启动，请稍后再开始 NTP 校验。"); return }
        guard AXIsProcessTrusted() else { app.fail("NTP 手机单击校验需要当前 App 的辅助功能权限。"); return }
        guard resolvedTarget() != nil else { app.fail("先打开手机校准网页，并使用‘框选手机测试靶区’选中蓝色按钮。明显缩放后请重新框选。"); return }
        guard app.window.makeFirstResponder(nil) else { return }
        selectedEpoch = atSelectedMinute ? floor(app.targetField.dateValue.timeIntervalSince1970/60)*60 : nil
        let id = UUID(); token = id; isPreparing = true; syncInFlight = true; lastResult = nil
        setBusy(true); status.stringValue = "正在启动校准服务并获取 NTP 时间…；Esc 可取消。"
        app.launchServer { [weak self] result in
            guard let self, self.token == id, self.isPreparing else { return }
            if case .failure(let error) = result { self.failed(error.localizedDescription); return }
            self.app.synchronizeClock { [weak self] snapshot in
                guard let self, self.token == id, self.isPreparing else { return }
                self.syncInFlight = false
                guard let snapshot else { self.failed("NTP 授时失败；未发送测试点击。"); return }
                let now = snapshot.utcEpoch(atMonoNs: PrecisionClock.nowNs())
                let epoch = self.selectedEpoch ?? ceil(now+15)
                guard epoch-now >= 8, epoch-now <= 172800 else {
                    self.failed("请选择至少 8 秒之后、48 小时以内的整分，或使用‘15 秒后 NTP 单击校验’。"); return
                }
                self.selectedEpoch = epoch
                if epoch-now <= 30 { self.arm(snapshot, epoch: epoch, id: id) }
                else { self.status.stringValue = "等待 \(Self.time(epoch))；临近 25 秒重新授时。Esc 可取消。" }
            }
        }
    }

    func tick() {
        ownControls.forEach { $0.isEnabled = !app.normalBusy && !app.damai.isActive }
        guard isPreparing, !syncInFlight, let epoch = selectedEpoch else { return }
        guard let snapshot = app.networkTime else { return }
        let remaining = epoch-snapshot.utcEpoch(atMonoNs: PrecisionClock.nowNs())
        if remaining <= 25 {
            syncInFlight = true
            let id = token
            app.synchronizeClock { [weak self] snapshot in
                guard let self, self.token == id, self.isPreparing else { return }
                guard let snapshot else { self.failed("临近目标的 NTP 授时失败；未发送点击。"); return }
                self.arm(snapshot, epoch: epoch, id: id)
            }
        }
    }

    private func arm(_ snapshot: NetworkTimeSnapshot, epoch: Double, id: UUID) {
        syncInFlight = true
        let now = PrecisionClock.nowNs()
        guard snapshot.isUsable(atMonoNs: now), epoch-snapshot.utcEpoch(atMonoNs: now) >= 5,
              let server = app.server, server.isRunning, resolvedTarget() != nil else {
            failed("授时、目标窗口或准备时间无效；未发送点击。"); return
        }
        let run = UUID().uuidString
        do {
            try server.useTimeReference(CalibrationTimeReference(id: run, epochMs: snapshot.referenceEpoch*1000,
                monoNs: snapshot.referenceMonoNs, uncertaintyMs: snapshot.baseUncertaintyMs,
                validityMs: snapshot.validitySeconds*1000, driftPPM: snapshot.driftPPM, source: snapshot.sourceSummary))
        } catch { failed(error.localizedDescription); return }
        let body: [String: Any] = ["runId": run, "clockId": run, "timeBasis": "ntp-utc", "targetsMs": [epoch*1000],
                                  "compensationMs": 0, "label": "NTP 手机到点单击校验"]
        app.api("/test-plan", body: body) { [weak self] response in
            guard let self, self.token == id, self.isPreparing else { return }
            guard response != nil, response?["error"] == nil else { self.failed("NTP 测试计划发布失败；未发送点击。"); return }
            self.status.stringValue = "计划：\(Self.time(epoch))。等待手机页完成同一 NTP 基准校时；启动后保持镜像不动。"
            self.awaitPhoneClock(snapshot, epoch: epoch, id: id, run: run)
        }
    }

    private func awaitPhoneClock(_ snapshot: NetworkTimeSnapshot, epoch: Double, id: UUID, run: String) {
        guard token == id, isPreparing else { return }
        guard epoch-snapshot.utcEpoch(atMonoNs: PrecisionClock.nowNs()) >= 2 else {
            failed("手机页未在目标前完成校时，已取消且未点击。请在手机 Safari 刷新本 App 提供的校准页后重试。"); return
        }
        app.api("/summary") { [weak self] response in
            guard let self, self.token == id, self.isPreparing else { return }
            if let response, response["runId"] as? String == run,
               response["clockId"] as? String == run, response["clockFresh"] as? Bool == true {
                let local = response["clockUncertaintyEstimateMs"] as? Double ?? .infinity
                guard local + snapshot.estimatedUncertaintyMs(atMonoNs: PrecisionClock.nowNs()) <= 100 else {
                    self.failed("本轮估计校时不确定度超过 100 毫秒；未发送点击。请检查手机与 Mac 的网络后重试。"); return
                }
                guard let (target, point) = self.resolvedTarget() else { self.failed("测试窗口尺寸改变或已关闭；未发送点击。"); return }
                let config = ClickConfiguration(targetWallEpoch: epoch, point: point, frequencyHz: 1, count: 1, compensationMs: 0, holdMs: 8)
                do {
                    self.isPreparing = false
                    try self.app.begin(config, target: target, mode: "phone-ntp-validation", networkSnapshot: snapshot)
                    self.app.currentRunID = run; self.app.phoneRunClockID = run
                    self.status.stringValue = "已就绪，等待 \(Self.time(epoch)) 单击。当前不加补偿，用于直接检查到点误差。Esc 可取消。"
                } catch { self.failed(error.localizedDescription) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now()+0.3) { [weak self] in
                    self?.awaitPhoneClock(snapshot, epoch: epoch, id: id, run: run)
                }
            }
        }
    }

    func consumeSummary(_ json: [String: Any]) {
        guard json["timeBasis"] as? String == "ntp-utc" else { return }
        lastResult = json
        let target = json["latestTargetMs"] as? Double
        let sent = json["latestSentUpMs"] as? Double
        let received = json["latestReceivedMs"] as? Double
        let stamp: (Double?) -> String = { $0.map { Self.time($0/1000) } ?? "未收到" }
        let count = json["matchedSendCount"] as? Int ?? 0
        let sampleCount = json["sampleCount"] as? Int ?? 0
        let valid = count == 1 && sampleCount == 1 && (json["strayCount"] as? Int ?? 0) == 0 && (json["samplesClockValidAtEvent"] as? Bool) == true
        var text = "NTP 目标 \(stamp(target))\nMac 发出 \(stamp(sent))\n手机收到 \(stamp(received))"
        if valid, let target, let sent, let received {
            let uncertainty = json["totalUncertaintyEstimateMs"] as? Double ?? .infinity
            text += String(format: "\n发出相对目标 %+.3f ms；手机相对目标 %+.3f ms；发送→接收 %.3f ms；事件时估计校时不确定度约 ±%.3f ms。", sent-target, received-target, received-sent, uncertainty)
        } else { text += "\n接收不完整、校时过期或存在游离事件，本轮不能作为有效校验。可点‘读取手机结果’再次获取。" }
        text += "\n终点是手机测试页回调，不是券商受理；回传报告耗时未计入。单次结果不会自动覆盖补偿。"
        status.stringValue = text; app.calibrationLabel.stringValue = valid ? "NTP 手机到点校验：1/1；详见上方三个时刻。" : "NTP 手机到点校验未取得完整有效回执。"
        app.writeJSON(json, name: "phone-ntp-validation-latest.json")
        app.log(text)
    }

    func cancel() {
        overlays.forEach { $0.orderOut(nil) }; overlays.removeAll()
        guard isPreparing else { return }
        token = UUID(); isPreparing = false; syncInFlight = false; selectedEpoch = nil
        setBusy(false); status.stringValue = "已取消 NTP 手机校验；未发出的点击不会补发。"
    }
    private func failed(_ text: String) {
        token = UUID(); isPreparing = false; syncInFlight = false; selectedEpoch = nil
        setBusy(false); status.stringValue = text; app.log(text); app.fail(text)
    }
    private func setBusy(_ busy: Bool) {
        app.controls.forEach { $0.isEnabled = !busy }; app.startButton.isEnabled = !busy; app.stopButton.isEnabled = busy
        if busy, app.activity == nil {
            app.activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "NTP 手机到点校验")
        } else if !busy, let activity = app.activity {
            ProcessInfo.processInfo.endActivity(activity); app.activity = nil
        }
        app.updateRegionControls()
    }
}
