import Foundation
import CoreGraphics

@main struct DamaiRunPolicyTests {
    static func main() throws {
        func check(_ condition:Bool,_ text:String) throws {
            if !condition { throw NSError(domain:"DamaiRunPolicy",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
            print("PASS \(text)")
        }
        let viewport = CGRect(x:1000,y:-800,width:390,height:844)
        let normalized = CGRect(x:0.25,y:0.6,width:0.5,height:0.04)
        let actual = DamaiRunPolicy.globalRect(normalized,viewport:viewport)!
        try check(abs(actual.minX-1097.5)<0.001 && abs(actual.minY+293.6)<0.001,
                  "归一化坐标正确映射到多屏负坐标，不依赖机型或Retina倍数")
        try check(DamaiRunPolicy.globalRect(CGRect(x:0.9,y:0.5,width:0.2,height:0.1),viewport:viewport) == nil,
                  "拒绝超出手机内容范围的坐标")
        let a = DamaiTextObservation(text:"继续尝试",rect:normalized)
        let decision = DamaiDecision(state:.retry,kind:.click,target:a,reason:"")
        try check(!DamaiRunPolicy.agrees(nil,decision),"仅一次识别不授权点击")
        try check(DamaiRunPolicy.agrees(decision,decision),"两帧按钮稳定一致才可授权")
        let shifted = DamaiDecision(state:.retry,kind:.click,target:DamaiTextObservation(text:"继续尝试",rect:normalized.offsetBy(dx:0,dy:0.1)),reason:"")
        try check(!DamaiRunPolicy.agrees(decision,shifted),"弹窗移动后旧位置不继续点击")
        let submit = DamaiDecision(state:.order,kind:.click,target:DamaiTextObservation(text:"立即提交",rect:normalized),reason:"")
        try check(!DamaiRunPolicy.agrees(decision,submit),"同一坐标按钮变义后重新观察")
        try check(!DamaiRunPolicy.isFresh(captured:10,now:10+DamaiRunPolicy.maximumFrameAgeNs+1),"丢弃首次模型初始化产生的旧帧")
        try check(!DamaiRunPolicy.isFresh(captured:20,now:10),"拒绝时间基准异常")
        let lease = DamaiClickLease(),run = UUID(),next = UUID(),point = CGPoint(x:actual.midX,y:actual.midY)
        lease.authorize(run:run,region:actual,deadline:1000)
        try check(lease.permits(run:run,point:point,now:999),"本轮新鲜授权允许框内点击")
        try check(!lease.permits(run:next,point:point,now:999),"下一轮不能复用上一轮授权")
        try check(!lease.permits(run:run,point:point,now:1001),"授权过期即拒绝发送")
        try check(!lease.permits(run:run,point:CGPoint(x:0,y:0),now:999),"授权不覆盖其他位置")
        lease.invalidate()
        try check(!lease.permits(run:run,point:point,now:999),"取消后即使晚到结果仍不得点击")
        print("13 项大麦坐标、新鲜度与撤销授权测试通过；无真实鼠标事件。")
    }
}
