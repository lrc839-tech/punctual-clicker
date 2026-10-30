import Foundation
import CoreGraphics

/// Persistable geometry only. In memory, regions retain their reference desktop
/// coordinates for compatibility with the selection UI. Version 2 stores local
/// window coordinates; every use resolves them against the current window.
struct DamaiRegionProfile: Codable, Equatable {
    var regions: [CGRect?]
    var windowFrame: CGRect?

    static let referenceWindowFrame = CGRect(x: 1115, y: 107, width: 326, height: 719)
    static let defaults = DamaiRegionProfile(regions: [
        CGRect(x: 1332, y: 760, width: 75, height: 24),
        CGRect(x: 1238.10546875, y: 605.5078125, width: 83.55859375, height: 16.28125),
        CGRect(x: 1200, y: 529, width: 163, height: 24)
    ], windowFrame: referenceWindowFrame)

    private static let legacyFactoryRegions: [CGRect?] = [
        CGRect(x: 1332, y: 760, width: 75, height: 24),
        CGRect(x: 1241, y: 616, width: 77, height: 22),
        CGRect(x: 1200, y: 529, width: 163, height: 24)
    ]

    init(regions: [CGRect?], windowFrame: CGRect?) {
        self.regions = regions; self.windowFrame = windowFrame
    }

    /// Coordinates in Quartz points from the reference window's top-left.
    var relativeRegions: [CGRect?]? {
        guard let frame = windowFrame, Self.validRect(frame) else { return nil }
        return regions.map { $0?.offsetBy(dx: -frame.minX, dy: -frame.minY) }
    }

    var isValid: Bool {
        guard regions.count == 3 else { return false }
        let present = regions.compactMap { $0 }
        guard present.allSatisfy({ Self.validRect($0) && $0.size.width >= 12 && $0.size.height >= 12 }) else {
            return false
        }
        if let frame = windowFrame {
            guard Self.validRect(frame), present.allSatisfy({ frame.contains($0) }) else { return false }
        }
        return true
    }

    var isComplete: Bool { isValid && windowFrame != nil && regions.allSatisfy { $0 != nil } }

    /// Translation is exact, including across displays with negative origins.
    /// Up to 2pt of frame-size jitter preserves local coordinates. Substantial
    /// resizing requires new selections because fixed window chrome does not
    /// scale with the phone image.
    func mappedRegions(to frame: CGRect) -> [CGRect?]? {
        guard isValid, let reference = windowFrame, Self.validRect(frame),
              let local = relativeRegions else { return nil }
        guard abs(frame.width - reference.width) <= 2,
              abs(frame.height - reference.height) <= 2 else { return nil }
        let mapped = local.map { rect -> CGRect? in
            guard let r = rect else { return nil }
            return r.offsetBy(dx: frame.minX, dy: frame.minY)
        }
        guard mapped.compactMap({ $0 }).allSatisfy({ Self.validRect($0) && frame.contains($0) }) else { return nil }
        return mapped
    }

    func canBind(to frame: CGRect) -> Bool {
        isComplete && mappedRegions(to: frame) != nil
    }

    /// Old complete global profiles migrate using their saved reference frame;
    /// the old window does not need to be visible or remain at that location.
    static func decode(_ data: Data?) -> DamaiRegionProfile {
        guard let data = data, var profile = try? JSONDecoder().decode(Self.self, from: data),
              profile.isValid, profile.regions.allSatisfy({ $0 != nil }) else { return defaults }
        if profile.regions == legacyFactoryRegions {
            profile.regions[1] = defaults.regions[1]
        }
        if profile.windowFrame == nil {
            // Only factory data has an independently known reference window.
            guard profile.regions == defaults.regions else { return defaults }
            profile.windowFrame = referenceWindowFrame
        }
        return profile.isComplete ? profile : defaults
    }

    func encoded() throws -> Data {
        guard isValid else { throw ProfileError.invalidGeometry }
        return try JSONEncoder().encode(self)
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, coordinateSpace, regions, windowFrame }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let stored = try c.decode([CGRect?].self, forKey: .regions)
        windowFrame = try c.decodeIfPresent(CGRect.self, forKey: .windowFrame)
        if version == 1 {
            regions = stored
        } else if version == 2,
                  try c.decode(String.self, forKey: .coordinateSpace) == "window-relative-points",
                  let frame = windowFrame, Self.validRect(frame) {
            regions = stored.map { $0?.offsetBy(dx: frame.minX, dy: frame.minY) }
        } else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c,
                                                   debugDescription: "Unknown or incomplete window-relative profile")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let local = relativeRegions {
            try c.encode(2, forKey: .schemaVersion)
            try c.encode("window-relative-points", forKey: .coordinateSpace)
            try c.encode(local, forKey: .regions)
        } else {
            // Partial, unbound editing models are never persisted by controller.
            try c.encode(1, forKey: .schemaVersion)
            try c.encode(regions, forKey: .regions)
        }
        try c.encodeIfPresent(windowFrame, forKey: .windowFrame)
    }

    enum ProfileError: LocalizedError {
        case invalidGeometry
        var errorDescription: String? { "无法保存无效的三个点击区域或窗口边界。" }
    }

    private static func validRect(_ rect: CGRect) -> Bool {
        let values = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
                      rect.minX, rect.minY, rect.maxX, rect.maxY]
        return !rect.isNull && !rect.isInfinite && values.allSatisfy { $0.isFinite } &&
            rect.size.width > 0 && rect.size.height > 0 &&
            rect.maxX > rect.minX && rect.maxY > rect.minY
    }
}
