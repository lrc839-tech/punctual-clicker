import Foundation
import CryptoKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 6 else {
    fputs("Usage: release-manifest.swift output version signing notarized dmg zip\n", stderr)
    exit(2)
}
let assets: [[String: Any]] = try args[4...5].map { path in
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return ["name": url.lastPathComponent, "sizeBytes": data.count, "sha256": digest]
}
let manifest: [String: Any] = [
    "application": "准点点击器",
    "version": args[1],
    "architectures": ["arm64", "x86_64"],
    "minimumMacOS": "13.0",
    "runtimeDependencies": "macOS system frameworks only; no Python, Node.js, AI or developer tools",
    "signing": args[2],
    "notarized": args[3] == "true",
    "firstRunPermissions": ["Accessibility for mouse input", "Local Network for optional iPhone calibration"],
    "note": "Universal slices are verified at packaging time. Intel hardware and clean-Mac acceptance require separate verification.",
    "assets": assets
]
let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try data.write(to: URL(fileURLWithPath: args[0]), options: .atomic)
