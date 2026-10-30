import Foundation
import CoreGraphics

@main
enum DamaiRegionProfileTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Legacy: Codable { var regions: [CGRect?]; var windowFrame: CGRect? }
    static var passed = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }
    static func check(_ title: String, _ body: () throws -> Void) throws {
        try body(); passed += 1; print("PASS \(title)")
    }
    static let frame = CGRect(x: -1000.25, y: -500.5, width: 800.75, height: 900.25)
    static let regions: [CGRect?] = [CGRect(x: -950.125, y: -450.25, width: 75.625, height: 24.125),
                                   CGRect(x: -900.875, y: -350.5, width: 77.25, height: 22.875),
                                   CGRect(x: -800.375, y: -250.625, width: 163.75, height: 24.25)]
    static let oldFactory: [CGRect?] = [CGRect(x: 1332, y: 760, width: 75, height: 24),
                                       CGRect(x: 1241, y: 616, width: 77, height: 22),
                                       CGRect(x: 1200, y: 529, width: 163, height: 24)]
    static func legacyData(_ regions: [CGRect?], _ frame: CGRect?) throws -> Data {
        try JSONEncoder().encode(Legacy(regions: regions, windowFrame: frame))
    }
    static func main() throws {
        try check("默认三区具有已知参考窗口及精确窗口内坐标") {
            let p = DamaiRegionProfile.defaults
            try expect(p.windowFrame == CGRect(x: 1115, y: 107, width: 326, height: 719), "参考窗口错误")
            try expect(p.relativeRegions == [CGRect(x: 217, y: 653, width: 75, height: 24),
                                             CGRect(x: 123.10546875, y: 498.5078125, width: 83.55859375, height: 16.28125),
                                             CGRect(x: 85, y: 422, width: 163, height: 24)], "窗口内坐标有误")
            try expect(p.isValid && p.isComplete && DamaiRegionProfile.decode(nil) == p, "默认状态错误")
        }
        try check("版本2实际存储窗口内坐标并无损往返") {
            let p = DamaiRegionProfile(regions: regions, windowFrame: frame)
            let data = try p.encoded()
            let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try expect(obj["schemaVersion"] as? Int == 2 && obj["coordinateSpace"] as? String == "window-relative-points", "持久格式未声明相对坐标")
            let raw = try JSONDecoder().decode(Legacy.self, from: data)
            try expect(raw.regions == p.relativeRegions, "存储的仍是全局坐标")
            try expect(DamaiRegionProfile.decode(data) == p && p.canBind(to: frame), "小数负坐标往返改变")
        }
        try check("旧版本完整绝对坐标无需原窗口即迁移") {
            let p = DamaiRegionProfile.decode(try legacyData(regions, frame))
            let moved = frame.offsetBy(dx: 1400.125, dy: 600.25)
            let expected = regions.map { $0?.offsetBy(dx: 1400.125, dy: 600.25) }
            try expect(p.regions == regions && p.windowFrame == frame, "旧数据改变")
            try expect(p.canBind(to: moved) && p.mappedRegions(to: moved) == expected, "旧数据不能跟随新位置")
        }
        try check("旧工厂区域迁移第二框并补齐已知窗口") {
            for anchor: CGRect? in [nil, DamaiRegionProfile.referenceWindowFrame] {
                let p = DamaiRegionProfile.decode(try legacyData(oldFactory, anchor))
                try expect(p == .defaults, "旧工厂迁移错误")
            }
            let p = DamaiRegionProfile.decode(try legacyData(DamaiRegionProfile.defaults.regions, nil))
            try expect(p == .defaults, "前版无anchor默认值无法迁移")
        }
        try check("任一自定义差异不被工厂迁移覆盖") {
            let anchor = CGRect(x: 1100, y: 450, width: 400, height: 400)
            for index in 0..<3 {
                var custom = oldFactory
                custom[index] = custom[index]!.offsetBy(dx: 0.25, dy: 0)
                let p = DamaiRegionProfile.decode(try legacyData(custom, anchor))
                try expect(p.regions == custom && p.windowFrame == anchor, "自定义区域被覆盖")
            }
            var custom = oldFactory
            custom[1] = CGRect(x: 1238, y: 606, width: 84, height: 16)
            try expect(DamaiRegionProfile.decode(try legacyData(custom, anchor)).regions == custom, "用户整数坐标被覆盖")
        }
        try check("多次保存与重启不重复扣除窗口原点") {
            var p = DamaiRegionProfile(regions: regions, windowFrame: frame)
            for _ in 0..<5 { p = DamaiRegionProfile.decode(try p.encoded()) }
            try expect(p.regions == regions && p.relativeRegions?[0]?.minX == 50.125, "窗口坐标重复转换")
        }
        try check("任意平移含负坐标跨屏保留大小及相对位置") {
            let p = DamaiRegionProfile.defaults
            let original = p.windowFrame!
            for delta in [CGPoint(x: 1, y: -1), CGPoint(x: -3000.125, y: -900.5), CGPoint(x: 12000.5, y: 8000.25)] {
                let moved = original.offsetBy(dx: delta.x, dy: delta.y)
                let expected = p.regions.map { $0?.offsetBy(dx: delta.x, dy: delta.y) }
                try expect(p.canBind(to: moved) && p.mappedRegions(to: moved) == expected, "平移坐标错误")
            }
        }
        try check("两点内尺寸抖动不缩放选区，较大缩放拒绝") {
            let p = DamaiRegionProfile(regions: regions, windowFrame: frame)
            let drift = CGRect(x: frame.minX + 3, y: frame.minY - 7, width: frame.width + 2, height: frame.height - 2)
            try expect(p.canBind(to: drift) && p.mappedRegions(to: drift) == regions.map { $0?.offsetBy(dx: 3, dy: -7) }, "轻微抖动没有保持local坐标")
            for changed in [CGRect(x: 0, y: 0, width: frame.width + 2.01, height: frame.height),
                            CGRect(x: 0, y: 0, width: frame.width, height: frame.height - 2.01),
                            CGRect(x: 0, y: 0, width: frame.width * 1.2, height: frame.height * 1.2)] {
                try expect(!p.canBind(to: changed) && p.mappedRegions(to: changed) == nil, "较大缩放仍允许使用")
            }
        }
        try check("边缘框因轻微缩窗越界也拒绝") {
            let edge = CGRect(x: frame.maxX - 12, y: frame.maxY - 12, width: 12, height: 12)
            let p = DamaiRegionProfile(regions: [edge, regions[1], regions[2]], windowFrame: frame)
            try expect(p.canBind(to: frame), "边界12点合法框被拒绝")
            let shrink = CGRect(x: 0, y: 0, width: frame.width - 0.5, height: frame.height)
            try expect(!p.canBind(to: shrink), "缩小后区域已越界仍绑定")
        }
        try check("部分编辑可往返，但不替换持久默认或绑定窗口") {
            for parts: [CGRect?] in [[regions[0], nil, nil], [regions[0], regions[1], nil], [nil, nil, nil]] {
                let p = DamaiRegionProfile(regions: parts, windowFrame: frame)
                try expect(p.isValid && !p.isComplete && !p.canBind(to: frame), "部分方案被当成完整")
                try expect(try JSONDecoder().decode(DamaiRegionProfile.self, from: p.encoded()) == p, "部分编辑模型不能往返")
                try expect(DamaiRegionProfile.decode(try p.encoded()) == .defaults, "部分持久数据没回默认")
            }
        }
        try check("旧自定义配置无参考窗口时不臆造偏移") {
            let p = DamaiRegionProfile(regions: regions, windowFrame: nil)
            try expect(p.isValid && !p.isComplete && p.relativeRegions == nil && p.mappedRegions(to: frame) == nil, "缺少anchor仍可映射")
            try expect(DamaiRegionProfile.decode(try legacyData(regions, nil)) == .defaults, "无anchor自定义数据被臆造迁移")
        }
        try check("损坏JSON未知schema及无效几何回默认") {
            for bytes in [Data(), Data("{broken".utf8), Data("null".utf8),
                          Data("{\"regions\": [NaN], \"windowFrame\": null}".utf8),
                          Data("{\"schemaVersion\":3,\"regions\":[],\"windowFrame\":null}".utf8)] {
                try expect(DamaiRegionProfile.decode(bytes) == .defaults, "损坏JSON未回默认")
            }
            let invalid = [DamaiRegionProfile(regions: [], windowFrame: nil),
                           DamaiRegionProfile(regions: Array(regions.prefix(2)), windowFrame: frame),
                           DamaiRegionProfile(regions: regions + [nil], windowFrame: frame),
                           DamaiRegionProfile(regions: [CGRect(x: 0, y: 0, width: 11.99, height: 12), nil, nil], windowFrame: nil),
                           DamaiRegionProfile(regions: regions, windowFrame: .zero),
                           DamaiRegionProfile(regions: regions, windowFrame: CGRect(x: 0, y: 0, width: 800, height: 900))]
            for p in invalid {
                try expect(!p.isValid && !p.canBind(to: frame), "无效模型通过校验")
                try expect(DamaiRegionProfile.decode(try JSONEncoder().encode(p)) == .defaults, "无效内容未回默认")
                do { _ = try p.encoded(); throw Failure(description: "允许保存无效模型") }
                catch is DamaiRegionProfile.ProfileError { }
            }
            try expect(!DamaiRegionProfile.defaults.canBind(to: .infinite) && !DamaiRegionProfile.defaults.canBind(to: .null), "非有限frame通过")
        }
        print("DamaiRegionProfileTests: \(passed) checks passed; data model only, no UserDefaults or UI.")
    }
}
