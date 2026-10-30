import Foundation

/// Maps an immediate-mode delay to the existing engine's absolute mouse-up
/// gate. The delay begins at the start-button request, including activation.
struct ImmediateClickStart {
    let requestedMonoNs: UInt64
    let delayMs: Double

    enum StartError: LocalizedError {
        case invalidDelay, invalidHold, overflow
        var errorDescription: String? {
            switch self {
            case .invalidDelay: return "立即启动延迟须为 0～60000 毫秒的有限数字。"
            case .invalidHold: return "按住时长须为 0.5～500 毫秒的有限数字。"
            case .overflow: return "立即启动时间超出单调时钟可表示的范围。"
            }
        }
    }

    func firstMouseUp(readyMonoNs: UInt64, holdMs: Double) throws -> UInt64? {
        guard delayMs.isFinite, (0...60_000).contains(delayMs) else { throw StartError.invalidDelay }
        guard holdMs.isFinite, (0.5...500).contains(holdMs) else { throw StartError.invalidHold }
        guard delayMs > 0 else { return nil }
        // Round upward so fractional nanoseconds cannot make down precede the
        // requested delay. Both validated products are far below UInt64.max.
        let delayNs = UInt64((delayMs * 1e6).rounded(.up))
        let holdNs = UInt64((holdMs * 1e6).rounded(.up))
        let (requestedDown, requestOverflow) = requestedMonoNs.addingReportingOverflow(delayNs)
        let (readyDown, readyOverflow) = readyMonoNs.addingReportingOverflow(20_000_000)
        guard !requestOverflow, !readyOverflow else { throw StartError.overflow }
        let (firstUp, upOverflow) = max(requestedDown, readyDown).addingReportingOverflow(holdNs)
        guard !upOverflow else { throw StartError.overflow }
        return firstUp
    }
}
