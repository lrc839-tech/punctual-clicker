import Foundation
import CoreGraphics
import Darwin

/// Resolve and guard one click using a single front-to-back window snapshot.
/// A saved reference frame supplies local coordinates; the live window supplies
/// its current desktop origin. No screenshot or page recognition is involved.
struct WindowRelativeClickTarget {
    let profile: DamaiRegionProfile
    let pid: pid_t
    let id: CGWindowID

    func resolve(region: Int, unitPoint: CGPoint, windows: [VisibilityWindow]) -> CGPoint? {
        guard (0..<3).contains(region),
              unitPoint.x.isFinite, unitPoint.y.isFinite,
              (0..<1).contains(unitPoint.x), (0..<1).contains(unitPoint.y),
              let target = windows.first(where: {
                  $0.pid == pid && $0.id == id && $0.layer == 0 &&
                  $0.alpha.isFinite && $0.alpha > 0.05
              }),
              profile.canBind(to: target.frame),
              let mapped = profile.mappedRegions(to: target.frame),
              let rect = mapped[region] else { return nil }
        let point = CGPoint(x: min(rect.minX + unitPoint.x * rect.width, rect.maxX.nextDown),
                            y: min(rect.minY + unitPoint.y * rect.height, rect.maxY.nextDown))
        guard TargetVisibility.allows(point: point, targetPID: pid, targetID: id,
                                      targetFrame: target.frame, windows: windows) else { return nil }
        return point
    }
}
