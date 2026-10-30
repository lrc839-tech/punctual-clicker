import Foundation

@main enum BusinessReceiptReviewTests {
    struct Failure: Error { let message: String }
    static var passed = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message: message) }
    }
    static func check(_ title: String, _ body: () throws -> Void) throws {
        try body(); passed += 1; print("PASS \(title)")
    }
    static func record(_ receipt: String = "2026-10-30 18:30:00.400",
                       kind: BusinessReceiptEventKind = .brokerAcceptance,
                       confirmed: Bool = true) throws -> BusinessReceiptRecord {
        try BusinessReceiptRecord.make(source: "金太阳", targetText: "2026-10-30 18:30:00.000",
            receiptText: receipt, eventKind: kind, clockComparableConfirmed: confirmed)
    }
    static func main() throws {
        try check("北京时间明确转换为 UTC+8，三位毫秒保留") {
            let ms = try BusinessReceiptRecord.parseBeijingMilliseconds("2026-10-30 18:30:00.400")
            let utc = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
            try expect(utc == "2026-10-30T10:30:00Z", "时区有误")
            try expect(BusinessReceiptRecord.formatBeijingMilliseconds(ms) == "2026-10-30 18:30:00.400", "毫秒丢失")
        }
        try check("40毫秒与400毫秒不混淆") {
            try expect(try record().differenceMs == 400, "400毫秒计算错误")
            try expect(try record("2026-10-30 18:30:00.040").differenceMs == 40, "40毫秒计算错误")
        }
        try check("只有用户确认且受理字段才按已声明口径描述总差值") {
            let accepted = try record()
            try expect(accepted.measurementKind == "declared-broker-acceptance-vs-target", "合法受理口径未记录")
            try expect(accepted.interpretation.contains("按你确认") && accepted.timeBasisAssumption.contains("程序未验证"), "把用户声明当成自动验证")
            for kind in BusinessReceiptEventKind.allCases {
                for confirmed in [false, true] where !(kind == .brokerAcceptance && confirmed) {
                    let unverified = try record(kind: kind, confirmed: confirmed)
                    try expect(unverified.measurementKind == "unverified-timestamp-difference" && unverified.interpretation.contains("不能当作链路延迟"), "未确认口径误报成延迟")
                }
            }
        }
        try check("跨日期与早到差值按带符号毫秒计算") {
            let next = try record("2026-10-31 00:00:00.000")
            try expect(next.differenceMs == 19_800_000, "跨日期计算有误")
            let early = try record("2026-10-30 18:29:59.900")
            try expect(early.differenceMs == -100 && early.interpretation.contains("早 100"), "早到差值有误")
        }
        try check("拒绝模糊格式、日期归一化和非三位毫秒") {
            let invalid = ["18:30:00.400", "2026-10-30 18:30:00:40", "2026-10-30 18:30:00.40",
                "2026-10-30 18:30:00.4", "2026-10-30 18:30:00.4000", "2026-02-30 18:30:00.400",
                "2026-10-30 25:30:00.400", "2026-10-30T18:30:00.400Z", "NaN", ""]
            for text in invalid {
                do { _ = try BusinessReceiptRecord.parseBeijingMilliseconds(text); throw Failure(message: "接受了无效时间：\(text)") }
                catch is BusinessReceiptRecord.ReviewError { }
            }
        }
        try check("来源不能为空或包含控制字符") {
            for source in ["", "   ", "x\ny", String(repeating: "x", count: 81)] {
                do {
                    _ = try BusinessReceiptRecord.make(source: source, targetText: "2026-10-30 18:30:00.000",
                        receiptText: "2026-10-30 18:30:00.400", eventKind: .unknown, clockComparableConfirmed: false)
                    throw Failure(message: "接受无效来源")
                } catch is BusinessReceiptRecord.ReviewError { }
            }
        }
        try check("原子保存完整声明与差值，不自动采用补偿") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReceiptReviewTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let value = try record(confirmed: false), url = try value.save(to: folder)
            let restored = try JSONDecoder().decode(BusinessReceiptRecord.self, from: Data(contentsOf: url))
            try expect(restored.id == value.id && restored.differenceMs == 400 && !restored.clockComparableConfirmed, "保存后数据改变")
            try expect(restored.measurementBoundary.contains("不自动采用提前补偿") && restored.measurementBoundary.contains("不自动挂单"), "测量边界缺失")
        }
        print("BusinessReceiptReviewTests: \(passed) checks passed; model only, no UI or orders.")
    }
}
