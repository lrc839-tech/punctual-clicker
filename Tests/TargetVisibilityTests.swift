import Foundation
import CoreGraphics
import Darwin

@main enum TargetVisibilityTests {
    struct Failure: Error { let message: String }
    static let pid:pid_t = 123
    static let frame = CGRect(x:-100,y:40,width:430,height:312)
    static let point = CGPoint(x:115,y:196)
    static let target = VisibilityWindow(pid:pid,id:456,frame:frame,layer:0,alpha:1)
    static var passed = 0
    static func expect(_ condition:Bool,_ name:String) throws {
        guard condition else { throw Failure(message:name) }
        passed += 1; print("PASS \(name)")
    }
    static func allows(_ windows:[VisibilityWindow],at:CGPoint = point) -> Bool {
        TargetVisibility.allows(point:at,targetPID:pid,targetID:456,targetFrame:frame,windows:windows)
    }
    static func main() throws {
        try expect(allows([target]),"可见目标可点击")
        let dock = VisibilityWindow(pid:999,id:37,frame:CGRect(x:-1000,y:-1000,width:4000,height:4000),layer:20,alpha:1)
        try expect(allows([dock,target]),"整屏系统合成层不误报普通窗口遮挡")
        let other = VisibilityWindow(pid:999,id:10,frame:frame,layer:0,alpha:1)
        try expect(!allows([dock,other,target]),"系统合成层后仍检查其他普通窗口")
        let dialog = VisibilityWindow(pid:pid,id:11,frame:frame,layer:8,alpha:1)
        try expect(!allows([dialog,target]),"同应用浮窗遮挡时停止")
        try expect(allows([target,other]),"后方窗口不影响目标")
        let moved = VisibilityWindow(pid:pid,id:456,frame:frame.offsetBy(dx:0.5,dy:0),layer:0,alpha:1)
        try expect(!allows([moved]),"目标移动时停止")
        try expect(!allows([other]),"目标身份或记录不匹配时停止")
        try expect(!allows([]),"目标窗口缺失时停止")
        try expect(!allows([target],at:CGPoint(x:frame.maxX+1,y:point.y)),"随机点超出目标时停止")
        try expect(!allows([target],at:CGPoint(x:CGFloat.nan,y:point.y)),"非法坐标不点击")
        let transparent = VisibilityWindow(pid:999,id:12,frame:frame,layer:0,alpha:0.05)
        try expect(allows([transparent,target]),"透明普通窗口不误报遮挡")
        let small = VisibilityWindow(pid:999,id:13,frame:CGRect(x:0,y:40,width:40,height:40),layer:0,alpha:1)
        try expect(allows([small,target]) && !allows([small,target],at:CGPoint(x:10,y:50)),"按实际落点检查局部遮挡")
        print("\(passed) 项窗口保护测试通过；未发送系统鼠标事件。")
    }
}
