import Foundation
import CoreGraphics
import Darwin

struct VisibilityWindow {
    let pid: pid_t
    let id: CGWindowID
    let frame: CGRect
    let layer: Int
    let alpha: Double
}

enum TargetVisibility {
    /// Preserve the established normal-window and same-app floating-window guard.
    /// Quartz also exposes full-screen compositor surfaces (for example Dock layer
    /// 20); their bounds and overall alpha do not establish an input hit target.
    /// This is a best-effort window guard, not complete system-overlay hit testing.
    static func allows(point: CGPoint, targetPID: pid_t, targetID: CGWindowID,
                       targetFrame: CGRect, windows: [VisibilityWindow]) -> Bool {
        let values = [point.x, point.y, targetFrame.origin.x, targetFrame.origin.y,
                      targetFrame.size.width, targetFrame.size.height]
        guard values.allSatisfy({ $0.isFinite }), targetFrame.size.width > 0,
              targetFrame.size.height > 0, targetFrame.contains(point) else { return false }
        for window in windows {
            guard window.alpha > 0.05, window.frame.contains(point),
                  window.layer == 0 || (window.layer > 0 && window.pid == targetPID) else { continue }
            return window.pid == targetPID && window.id == targetID && window.frame == targetFrame
        }
        return false
    }
}
