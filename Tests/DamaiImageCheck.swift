import Foundation
import CoreGraphics
import ImageIO
import Darwin

/// Standalone, read-only fixture verifier. Compile separately from Main.swift:
/// swiftc -O -swift-version 5 -parse-as-library Sources/DamaiPlan.swift \
///   Sources/DamaiScreenObserver.swift Tests/DamaiImageCheck.swift \
///   -framework Vision -framework ImageIO -o .build/DamaiImageCheck
///
/// Each input produces one JSON line. An optional --expect STATE:KIND applies
/// only to the next image; failed expectations make the process exit nonzero.
/// This executable never captures a screen or sends a mouse event. It prints
/// only allow-listed action labels rather than unrelated personal screen text.
@main
struct DamaiImageCheckCLI {
    private static let actionLabels = Set([
        "努力刷新", "继续尝试", "返回重新选购", "返回重选", "重新选购", "立即提交", "提交订单",
        "立即购买", "立即购票", "立即抢票", "立即预订", "立即预定", "确定", "确定购买", "确认购买",
        "缺货登记", "提交缺货登记", "付款候补", "立即候补", "预约抢票", "提交抢票预约", "已预约",
        "支付成功", "付款成功", "交易成功", "订单支付成功", "购票成功", "确认付款", "确认支付",
        "立即付款", "立即支付", "去支付", "我知道了", "返回", "取消"
    ].map(DamaiPlan.normalized))

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else { usage(); exit(2) }
        var index = 0, failures = 0, checked = 0
        var expected: String?
        while index < args.count {
            let argument = args[index]
            if argument == "--help" || argument == "-h" { usage(); return }
            if argument == "--expect" {
                guard expected == nil, index + 1 < args.count,
                      args[index + 1].split(separator: ":").count == 2 else {
                    fputs("--expect requires STATE:KIND followed by one image path.\n", stderr); exit(2)
                }
                expected = args[index + 1]; index += 2; continue
            }
            guard !argument.hasPrefix("--") else {
                fputs("Unknown argument: \(argument)\n", stderr); exit(2)
            }
            let url = URL(fileURLWithPath: argument).standardizedFileURL
            var report: [String: Any] = ["file": url.path]
            do {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw NSError(domain: "DamaiImageCheck", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Cannot read the image file."])
                }
                let began = DispatchTime.now().uptimeNanoseconds
                let observations = try DamaiScreenObserver.recognize(cgImage: image)
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
                let decision = DamaiPlan.evaluate(observations)
                report["width"] = image.width; report["height"] = image.height
                report["ocrElapsedMs"] = elapsedMs
                report["observationCount"] = observations.count
                report["state"] = decision.state.rawValue
                report["kind"] = decision.kind.rawValue
                report["reason"] = decision.reason
                report["actionLabels"] = observations.filter {
                    actionLabels.contains(DamaiPlan.normalized($0.text))
                }.map { observation in
                    ["text": observation.text, "confidence": observation.confidence,
                     "rect": rectDictionary(observation.rect)] as [String: Any]
                }
                if let target = decision.target {
                    report["target"] = ["text": target.text, "confidence": target.confidence,
                                        "rect": rectDictionary(target.rect)]
                } else {
                    report["target"] = NSNull()
                }
                if let expected = expected {
                    let actual = "\(decision.state.rawValue):\(decision.kind.rawValue)"
                    report["expected"] = expected
                    report["passed"] = actual == expected
                    if actual != expected { failures += 1 }
                }
            } catch {
                report["error"] = error.localizedDescription
                failures += 1
            }
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
            expected = nil; checked += 1; index += 1
        }
        guard expected == nil, checked > 0 else {
            fputs("Each --expect must be followed by an image path.\n", stderr); exit(2)
        }
        exit(failures == 0 ? 0 : 1)
    }

    private static func rectDictionary(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY),
         "width": Double(rect.width), "height": Double(rect.height)]
    }

    private static func usage() {
        print("Usage: DamaiImageCheck [--expect STATE:KIND] image.png [[--expect STATE:KIND] image.jpg ...]")
        print("Example expectations: busy:wait, retry:click, order:click, payment:stop, soldOut:stop")
        print("Read-only local image OCR; no live screen capture or mouse input.")
    }
}
