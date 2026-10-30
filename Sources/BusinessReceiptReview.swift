import Foundation
import AppKit

enum BusinessReceiptEventKind: String, Codable, CaseIterable {
    case brokerAcceptance = "broker-acceptance"
    case successDisplayed = "success-displayed"
    case unknown = "unknown"

    var title: String {
        switch self {
        case .brokerAcceptance: return "券商受理时间"
        case .successDisplayed: return "界面显示成功时刻"
        case .unknown: return "字段含义未确认"
        }
    }
}

/// A manual comparison of an existing receipt. It does not observe an order,
/// establish the broker's clock accuracy, or derive a transport compensation.
struct BusinessReceiptRecord: Codable {
    let schemaVersion: Int
    let id: String
    let createdAtEpochMs: Int64
    let source: String
    let targetBeijing: String
    let receiptBeijing: String
    let targetEpochMs: Int64
    let receiptEpochMs: Int64
    let eventKind: BusinessReceiptEventKind
    let clockComparableConfirmed: Bool
    let differenceMs: Int64
    let measurementKind: String
    let interpretation: String
    let timeBasisAssumption: String
    let measurementBoundary: String

    static func make(source: String, targetText: String, receiptText: String,
                     eventKind: BusinessReceiptEventKind,
                     clockComparableConfirmed: Bool) throws -> BusinessReceiptRecord {
        let name = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ReviewError.invalid("请填写 1～80 字的回执来源名称，不含换行或控制字符。")
        }
        let target = try parseBeijingMilliseconds(targetText)
        let receipt = try parseBeijingMilliseconds(receiptText)
        let difference = receipt - target
        let accepted = clockComparableConfirmed && eventKind == .brokerAcceptance
        let direction = difference >= 0 ? "晚" : "早"
        let detail = accepted
            ? "按你确认的时间口径：券商受理回执相对目标\(direction) \(abs(difference)) 毫秒。此差值未拆分网络、App 处理或后台排队耗时。"
            : "时间字段差值，口径未确认，不能当作链路延迟：回执字段相对目标\(direction) \(abs(difference)) 毫秒。"
        return BusinessReceiptRecord(schemaVersion: 1, id: UUID().uuidString,
            createdAtEpochMs: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
            source: name, targetBeijing: formatBeijingMilliseconds(target),
            receiptBeijing: formatBeijingMilliseconds(receipt), targetEpochMs: target,
            receiptEpochMs: receipt, eventKind: eventKind,
            clockComparableConfirmed: clockComparableConfirmed, differenceMs: difference,
            measurementKind: accepted ? "declared-broker-acceptance-vs-target" : "unverified-timestamp-difference",
            interpretation: detail,
            timeBasisAssumption: clockComparableConfirmed
                ? "用户声明该回执字段的时间基准与 NTP 目标可比较；程序未验证券商时钟或字段定义。"
                : "回执字段与 NTP 目标的时间基准尚未确认。",
            measurementBoundary: "仅复盘用户手工填写的既有回执；不自动挂单、不与另一轮 Safari 测试相减、不自动采用提前补偿。")
    }

    static func parseBeijingMilliseconds(_ input: String) throws -> Int64 {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}$"#,
                          options: .regularExpression) != nil else {
            throw ReviewError.invalid("时间须完整填写为 yyyy-MM-dd HH:mm:ss.SSS，例如 2026-10-30 18:30:00.400；.040 是 40 毫秒，.400 是 400 毫秒。")
        }
        let formatter = beijingFormatter()
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw ReviewError.invalid("日期或时间无效，请检查年月日、时分秒和三位毫秒。")
        }
        let milliseconds = date.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds > Double(Int64.min), milliseconds < Double(Int64.max) else {
            throw ReviewError.invalid("时间超出可记录范围。")
        }
        return Int64(milliseconds.rounded())
    }

    static func formatBeijingMilliseconds(_ value: Int64) -> String {
        beijingFormatter().string(from: Date(timeIntervalSince1970: Double(value) / 1000))
    }

    private static func beijingFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.isLenient = false
        return formatter
    }

    func save(to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("business-receipt-\(id).json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: destination, options: .atomic)
        return destination
    }

    enum ReviewError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
}

enum BusinessReceiptReview {
    /// The caller must stop active clicking before presenting this manual form.
    static func present(reportDirectory: URL, defaultTargetEpoch: Double,
                        completion: ((URL) -> Void)? = nil) {
        precondition(Thread.isMainThread)
        let alert = NSAlert(); alert.messageText = "挂单回执复盘"
        alert.informativeText = "对照已有委托回执，记录相对目标时间的差值。请核实回执字段的含义和时间基准；这里不会发起任何交易。所有时间按北京时间填写。"
        let source = NSTextField(string: "金太阳")
        let safeTargetEpoch = defaultTargetEpoch.isFinite && abs(defaultTargetEpoch) < 9_000_000_000_000
        let target = NSTextField(string: safeTargetEpoch
            ? BusinessReceiptRecord.formatBeijingMilliseconds(Int64((defaultTargetEpoch * 1000).rounded())) : "")
        let receipt = NSTextField(string: "")
        receipt.placeholderString = "yyyy-MM-dd HH:mm:ss.SSS"
        let event = NSPopUpButton(); event.addItems(withTitles: BusinessReceiptEventKind.allCases.map(\.title))
        event.selectItem(at: BusinessReceiptEventKind.allCases.firstIndex(of: .unknown)!)
        let confirmed = NSButton(checkboxWithTitle: "已确认该字段的时间基准与 NTP 目标可比较", target: nil, action: nil)
        confirmed.state = .off
        let help = NSTextField(wrappingLabelWithString: "毫秒必须为三位：.040＝40 毫秒，.400＝400 毫秒。未确认口径的差值仅作为字段对照；不会自动用于点击补偿。")
        help.font = .systemFont(ofSize: 12); help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = 510
        let panel = NSStackView(); panel.orientation = .vertical; panel.alignment = .leading; panel.spacing = 9
        for (title, control) in [("回执来源", source as NSView), ("目标时间", target), ("回执时间", receipt), ("时间字段含义", event)] {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 100).isActive = true
            control.widthAnchor.constraint(equalToConstant: 400).isActive = true
            let row = NSStackView(views: [label, control]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
            panel.addArrangedSubview(row)
        }
        for field in [target, receipt] { field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular) }
        panel.addArrangedSubview(confirmed); panel.addArrangedSubview(help)
        panel.frame = NSRect(x: 0, y: 0, width: 510, height: 205)
        alert.accessoryView = panel
        alert.addButton(withTitle: "保存复盘"); alert.addButton(withTitle: "取消")
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                let kind = BusinessReceiptEventKind.allCases[max(0, event.indexOfSelectedItem)]
                let record = try BusinessReceiptRecord.make(source: source.stringValue,
                    targetText: target.stringValue, receiptText: receipt.stringValue,
                    eventKind: kind, clockComparableConfirmed: confirmed.state == .on)
                let destination = try record.save(to: reportDirectory)
                completion?(destination)
                let result = NSAlert(); result.messageText = "复盘已保存"
                result.informativeText = record.interpretation + "\n\n来源：\(record.source)；字段：\(record.eventKind.title)。\n\(record.timeBasisAssumption)"
                result.runModal(); return
            } catch {
                let problem = NSAlert(); problem.messageText = "暂不能保存"
                problem.informativeText = error.localizedDescription; problem.alertStyle = .warning
                problem.runModal()
            }
        }
    }
}
