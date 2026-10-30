import Foundation
import CoreGraphics
import Darwin

@main enum WindowRelativeClickTargetTests {
    struct Failure: Error { let message: String }
    static var passed = 0
    static let pid: pid_t = 321
    static let id: CGWindowID = 654
    static let profile = DamaiRegionProfile.defaults
    static let reference = DamaiRegionProfile.referenceWindowFrame
    static let resolver = WindowRelativeClickTarget(profile: profile, pid: pid, id: id)
    static let unit = CGPoint(x: 0.5, y: 0.5)

    static func target(_ frame: CGRect = reference, pid: pid_t = pid, id: CGWindowID = id,
                       layer: Int = 0, alpha: Double = 1) -> VisibilityWindow {
        VisibilityWindow(pid: pid, id: id, frame: frame, layer: layer, alpha: alpha)
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    static func check(_ title: String, _ body: () throws -> Void) throws {
        try body(); passed += 1; print("PASS \(title)")
    }
    static func resolve(_ windows: [VisibilityWindow], region: Int = 0, at: CGPoint = unit) -> CGPoint? {
        resolver.resolve(region: region, unitPoint: at, windows: windows)
    }
    static func main() throws {
        try check("原始窗口按区域内单位坐标落点") {
            for index in 0..<3 {
                let rect = profile.regions[index]!
                try expect(resolve([target()], region: index) == CGPoint(x: rect.midX, y: rect.midY),
                           "默认区域中心未映射到原始位置")
            }
        }
        try check("窗口跨显示器负坐标平移，三区保持窗口内位置") {
            let moved = reference.offsetBy(dx: -2500.25, dy: -500.75)
            for index in 0..<3 {
                let rect = profile.regions[index]!.offsetBy(dx: -2500.25, dy: -500.75)
                try expect(resolve([target(moved)], region: index) == CGPoint(x: rect.midX, y: rect.midY),
                           "平移后仍使用旧绝对坐标")
            }
        }
        try check("两点内窗口边界抖动不改变本地选区") {
            var changed = reference.offsetBy(dx: 101, dy: -88)
            changed.size = CGSize(width: reference.width + 2, height: reference.height - 2)
            let rect = profile.regions[0]!.offsetBy(dx: 101, dy: -88)
            try expect(resolve([target(changed)]) == CGPoint(x: rect.midX, y: rect.midY),
                       "边界抖动错误地缩放或拒绝选区")
        }
        try check("超过两点的实际缩放不发送点击") {
            for size in [CGSize(width: reference.width + 2.01, height: reference.height),
                         CGSize(width: reference.width, height: reference.height - 2.01),
                         CGSize(width: reference.width * 1.25, height: reference.height * 1.25)] {
                let resized = CGRect(origin: reference.origin, size: size)
                try expect(resolve([target(resized)]) == nil, "实际缩放仍按原按钮布局点击")
            }
        }
        try check("窗口身份变化或窗口缺失时停止") {
            try expect(resolve([]) == nil, "缺失目标仍返回落点")
            try expect(resolve([target(id: id + 1)]) == nil, "其他窗口 ID 冒充目标")
            try expect(resolve([target(pid: pid + 1)]) == nil, "其他进程冒充目标")
            try expect(resolve([target(layer: 8)]) == nil, "浮层冒充目标主窗口")
            try expect(resolve([target(alpha: 0.05)]) == nil, "隐藏透明目标仍可点击")
            try expect(resolve([target(alpha: .nan)]) == nil, "非法透明度仍可点击")
            try expect(resolve([target(alpha: .infinity)]) == nil, "无穷透明度仍可点击")
        }
        try check("前方普通窗口遮挡时拒绝，后方普通窗口不影响") {
            let blocker = target(pid: pid + 1, id: id + 1)
            try expect(resolve([blocker, target()]) == nil, "前方窗口遮挡仍可点击")
            try expect(resolve([target(), blocker]) != nil, "后方窗口错误阻止点击")
        }
        try check("目标应用浮层遮挡时拒绝，后方浮层不影响") {
            let dialog = target(id: id + 1, layer: 8)
            try expect(resolve([dialog, target()]) == nil, "同应用浮层遮挡仍可点击")
            try expect(resolve([target(), dialog]) != nil, "后方浮层错误阻止点击")
        }
        try check("按最新窗口位置检查遮挡，旧位置上的遮挡不误报") {
            let moved = reference.offsetBy(dx: -1800, dy: 0)
            let oldBlocker = target(pid: pid + 1, id: id + 1)
            let liveBlocker = target(moved, pid: pid + 1, id: id + 2)
            try expect(resolve([oldBlocker, target(moved)]) != nil, "旧位置遮挡被套到新窗口")
            try expect(resolve([liveBlocker, target(moved)]) == nil, "新位置遮挡没有拦截")
        }
        try check("局部遮挡、透明窗口和系统合成层沿用现有落点保护") {
            let corner = VisibilityWindow(pid: pid + 1, id: id + 1,
                frame: CGRect(x: reference.minX, y: reference.minY, width: 20, height: 20), layer: 0, alpha: 1)
            let transparent = target(pid: pid + 1, id: id + 2, alpha: 0.05)
            let dock = VisibilityWindow(pid: pid + 1, id: id + 3,
                frame: CGRect(x: -10000, y: -10000, width: 20000, height: 20000), layer: 20, alpha: 1)
            try expect(resolve([corner, transparent, dock, target()]) != nil, "无关覆盖误报为输入遮挡")
        }
        try check("拒绝非法单位点与区域编号") {
            for index in [-1, 3, Int.max] {
                try expect(resolve([target()], region: index) == nil, "非法区域编号未拒绝")
            }
            for point in [CGPoint(x: -0.01, y: 0), CGPoint(x: 1, y: 0),
                          CGPoint(x: 0, y: -0.01), CGPoint(x: 0, y: 1),
                          CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity)] {
                try expect(resolve([target()], at: point) == nil, "非法单位点未拒绝")
            }
        }
        try check("随机点半开边界始终位于最新区域内") {
            let moved = reference.offsetBy(dx: -2000, dy: -400)
            let rect = profile.regions[1]!.offsetBy(dx: -2000, dy: -400)
            for point in [CGPoint.zero, CGPoint(x: CGFloat(1).nextDown, y: CGFloat(1).nextDown)] {
                guard let resolved = resolve([target(moved)], region: 1, at: point) else {
                    throw Failure(message: "有效单位点未解析")
                }
                try expect(rect.contains(resolved), "落点越过区域右下边界")
            }
        }
        try check("非法窗口几何或不完整配置不会解析") {
            for frame in [CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: reference.width, height: reference.height),
                          CGRect(x: 0, y: 0, width: reference.width, height: CGFloat.infinity)] {
                try expect(resolve([target(frame)]) == nil, "非法窗口几何未拒绝")
            }
            var partial = profile; partial.regions[2] = nil
            let partialResolver = WindowRelativeClickTarget(profile: partial, pid: pid, id: id)
            try expect(partialResolver.resolve(region: 0, unitPoint: unit, windows: [target()]) == nil,
                       "不完整配置仍允许点击")
        }
        print("WindowRelativeClickTargetTests: \(passed) checks passed; no system mouse events.")
    }
}
