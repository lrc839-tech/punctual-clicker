import Foundation
import CoreGraphics

/// A short, revocable lease checked immediately before system input. OCR results
/// never grant indefinite permission to keep clicking their old coordinates.
final class DamaiClickLease: @unchecked Sendable {
    private let lock = NSLock()
    private var run: UUID?
    private var deadline: UInt64 = 0
    private var region = CGRect.zero
    func authorize(run:UUID, region:CGRect, deadline:UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.run = run; self.region = region; self.deadline = deadline
    }
    func invalidate() { lock.lock(); run = nil; lock.unlock() }
    func permits(run:UUID, point:CGPoint, now:UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.run == run && now <= deadline && region.contains(point)
    }
}

enum DamaiRunPolicy {
    static let maximumFrameAgeNs: UInt64 = 900_000_000
    static func globalRect(_ normalized:CGRect, viewport:CGRect) -> CGRect? {
        let values = [normalized.minX,normalized.minY,normalized.width,normalized.height,
                      viewport.minX,viewport.minY,viewport.width,viewport.height]
        guard values.allSatisfy({ $0.isFinite }),normalized.width > 0,normalized.height > 0,
              normalized.minX >= 0,normalized.minY >= 0,normalized.maxX <= 1,normalized.maxY <= 1,
              viewport.width >= 40,viewport.height >= 40 else { return nil }
        return CGRect(x:viewport.minX+normalized.minX*viewport.width,
                      y:viewport.minY+normalized.minY*viewport.height,
                      width:normalized.width*viewport.width,height:normalized.height*viewport.height)
    }
    static func agrees(_ a:DamaiDecision?, _ b:DamaiDecision) -> Bool {
        guard let a = a,a.kind == .click,b.kind == .click,a.state == b.state,
              let x = a.target,let y = b.target,
              DamaiPlan.normalized(x.text) == DamaiPlan.normalized(y.text) else { return false }
        let intersection = x.rect.intersection(y.rect)
        guard !intersection.isNull else { return false }
        let smaller = min(x.rect.width*x.rect.height,y.rect.width*y.rect.height)
        return smaller > 0 && intersection.width*intersection.height/smaller >= 0.65 &&
            abs(x.rect.midX-y.rect.midX) < 0.025 && abs(x.rect.midY-y.rect.midY) < 0.02
    }
    static func isFresh(captured:UInt64, now:UInt64) -> Bool {
        now >= captured && now-captured <= maximumFrameAgeNs
    }
}
