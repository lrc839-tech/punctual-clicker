import Foundation
import CoreGraphics
import Vision

enum DamaiScreenError: LocalizedError {
    case permissionRequired
    case busy
    case invalidViewport
    case windowUnavailable
    case windowChanged
    case captureUnavailable
    case blankFrame
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "大麦页面识别需要屏幕录制权限。请为当前准点点击器开启权限后重试。"
        case .busy:
            return "上一帧页面识别尚未完成，请稍后再试。"
        case .invalidViewport:
            return "手机内容范围无效或超出所选窗口，请重新框选手机屏幕内容。"
        case .windowUnavailable:
            return "找不到所选镜像窗口，请重新打开镜像并框选手机内容。"
        case .windowChanged:
            return "所选镜像窗口的位置或大小已改变，请重新框选手机内容。"
        case .captureUnavailable:
            return "无法读取所选镜像窗口，请检查屏幕录制权限及镜像连接状态。"
        case .blankFrame:
            return "所选手机内容为空白或黑屏，请检查镜像连接及所选范围。"
        case .recognitionFailed(let message):
            return "大麦页面文字识别失败：\(message)"
        }
    }
}

struct DamaiScreenFrame {
    let observations: [DamaiTextObservation]
    /// The capture timestamp is sampled before the screenshot request, so a slow
    /// request cannot make an old image appear newer than it actually is.
    let capturedAt: Date
    /// Compare with DispatchTime.now().uptimeNanoseconds for freshness checks;
    /// unlike Date this value is unaffected by a system clock correction.
    let capturedUptimeNs: UInt64
    /// Pixel rounding can expand the requested rectangle by less than one image
    /// pixel. Use this rectangle when mapping normalized OCR boxes to global points.
    let viewport: CGRect
    let pixelSize: CGSize
}

/// Captures only the selected window and recognizes only the user-selected phone
/// viewport. It never requests screen-capture permission implicitly, saves screen
/// images, or captures the entire desktop. The caller owns cancellation/run tokens.
final class DamaiScreenObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.lrc.punctual-clicker.damai-vision",
                                      qos: .userInitiated)
    private let lock = NSLock()
    private var processing = false

    static var hasScreenCapturePermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Call only from an explicit permission-button action. The OS owns the prompt.
    @discardableResult
    static func requestScreenCapturePermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Completion always runs on the main queue. Busy requests fail without being
    /// queued, preventing a backlog of screenshots that could cause stale clicks.
    func observe(windowID: CGWindowID, windowFrame: CGRect, viewport: CGRect,
                 completion: @escaping (Result<DamaiScreenFrame, Error>) -> Void) {
        lock.lock()
        guard !processing else {
            lock.unlock()
            DispatchQueue.main.async { completion(.failure(DamaiScreenError.busy)) }
            return
        }
        processing = true
        lock.unlock()
        queue.async { [self] in
            let result: Result<DamaiScreenFrame, Error>
            do {
                guard Self.hasScreenCapturePermission else { throw DamaiScreenError.permissionRequired }
                try Self.validate(viewport: viewport, in: windowFrame)
                try Self.validateWindow(windowID, expectedFrame: windowFrame)
                let capturedAt = Date()
                let capturedUptimeNs = DispatchTime.now().uptimeNanoseconds
                guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                                                          [.boundsIgnoreFraming, .bestResolution]),
                      image.width > 0, image.height > 0 else {
                    throw DamaiScreenError.captureUnavailable
                }
                // Capture bounds and scale are checked again after requesting the
                // image: moving a window during capture must not silently remap it.
                try Self.validateWindow(windowID, expectedFrame: windowFrame)
                let crop = try Self.crop(image: image, windowFrame: windowFrame, viewport: viewport)
                guard !Self.isBlackOrTransparent(crop.image) else { throw DamaiScreenError.blankFrame }
                let observations = try Self.recognize(cgImage: crop.image)
                result = .success(DamaiScreenFrame(observations: observations,
                                                   capturedAt: capturedAt,
                                                   capturedUptimeNs: capturedUptimeNs,
                                                   viewport: crop.viewport,
                                                   pixelSize: CGSize(width: crop.image.width,
                                                                     height: crop.image.height)))
            } catch {
                result = .failure(error)
            }
            lock.lock(); processing = false; lock.unlock()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// OCR-only entry point used for local fixture verification. It performs no
    /// screen capture and consequently does not need screen-recording permission.
    static func recognize(cgImage: CGImage) throws -> [DamaiTextObservation] {
        guard cgImage.width > 0, cgImage.height > 0 else { throw DamaiScreenError.captureUnavailable }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        request.customWords = ["努力刷新", "继续尝试", "返回重新选购", "立即提交", "立即购买",
                               "立即购票", "立即预订", "立即预定", "确认购买", "确认订单",
                               "提交缺货登记", "预约抢票", "加速刷新中"]
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            throw DamaiScreenError.recognitionFailed(error.localizedDescription)
        }
        return (request.results ?? []).compactMap { observation -> DamaiTextObservation? in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let r = observation.boundingBox
            let normalized = CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
            return DamaiTextObservation(text: candidate.string, rect: normalized,
                                        confidence: candidate.confidence)
        }.sorted { a, b in
            abs(a.rect.minY - b.rect.minY) > 0.005 ? a.rect.minY < b.rect.minY : a.rect.minX < b.rect.minX
        }
    }

    private static func validate(viewport: CGRect, in frame: CGRect) throws {
        let numbers = [frame.minX, frame.minY, frame.width, frame.height,
                       viewport.minX, viewport.minY, viewport.width, viewport.height]
        guard numbers.allSatisfy({ $0.isFinite }), frame.width >= 40, frame.height >= 40,
              viewport.width >= 40, viewport.height >= 40,
              frame.contains(viewport) else { throw DamaiScreenError.invalidViewport }
    }

    private static func validateWindow(_ id: CGWindowID, expectedFrame: CGRect) throws {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?
            .first(where: { ($0[kCGWindowNumber as String] as? UInt32) == id }),
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let actual = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
            throw DamaiScreenError.windowUnavailable
        }
        // Quartz rounds some window coordinates to device-independent points.
        let differences = [abs(actual.minX - expectedFrame.minX), abs(actual.minY - expectedFrame.minY),
                           abs(actual.width - expectedFrame.width), abs(actual.height - expectedFrame.height)]
        guard differences.allSatisfy({ $0 <= 0.5 }) else { throw DamaiScreenError.windowChanged }
    }

    private static func crop(image: CGImage, windowFrame: CGRect, viewport: CGRect) throws
        -> (image: CGImage, viewport: CGRect) {
        let sx = CGFloat(image.width) / windowFrame.width
        let sy = CGFloat(image.height) / windowFrame.height
        // Best-resolution captures can be Retina. Map point coordinates using
        // actual image dimensions instead of assuming one or two pixels per point.
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0,
              abs(sx - sy) / max(sx, sy) < 0.025 else { throw DamaiScreenError.captureUnavailable }
        let pixels = CGRect(x: (viewport.minX - windowFrame.minX) * sx,
                            y: (viewport.minY - windowFrame.minY) * sy,
                            width: viewport.width * sx, height: viewport.height * sy)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixels.width >= 40, pixels.height >= 40,
              let cropped = image.cropping(to: pixels) else { throw DamaiScreenError.invalidViewport }
        let actualViewport = CGRect(x: windowFrame.minX + pixels.minX / sx,
                                    y: windowFrame.minY + pixels.minY / sy,
                                    width: pixels.width / sx, height: pixels.height / sy)
        return (cropped, actualViewport)
    }

    private static func isBlackOrTransparent(_ image: CGImage) -> Bool {
        let size = 48
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        return bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            var nonBlank = 0
            for offset in stride(from: 0, to: raw.count, by: 4) {
                if raw[offset + 3] > 8 && max(raw[offset], max(raw[offset + 1], raw[offset + 2])) > 12 {
                    nonBlank += 1
                }
            }
            return nonBlank < 4
        }
    }
}
