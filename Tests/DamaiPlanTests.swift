import Foundation
import CoreGraphics

@main
enum DamaiPlanTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var passed = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    static func check(_ name: String, _ action: () throws -> Void) throws {
        try action(); passed += 1; print("PASS \(name)")
    }
    static func o(_ text: String, x: CGFloat = 0.35, y: CGFloat, w: CGFloat = 0.3,
                  h: CGFloat = 0.025, confidence: Float = 1) -> DamaiTextObservation {
        DamaiTextObservation(text: text, rect: CGRect(x: x, y: y, width: w, height: h), confidence: confidence)
    }
    static var order: [DamaiTextObservation] {
        [o("确认购买", y: 0.045), o("实名观演人", x: 0.04, y: 0.38),
         o("配送方式", x: 0.04, y: 0.58), o("支付方式", x: 0.04, y: 0.72),
         o("支付成功后，无需取票，前往票夹查看入场凭证", x: 0.04, y: 0.64, w: 0.88),
         o("立即提交", x: 0.72, y: 0.94, w: 0.2)]
    }
    static func main() throws {
        try check("裁去视频叠层后忙态与努力刷新并存时等待") {
            let d = DamaiPlan.evaluate([o("¥917.00 票档 ×1张", y: 0.22),
                o("加速刷新中…", y: 0.60, confidence: 0.3), o("努力刷新", y: 0.67)])
            try expect(d.kind == .wait && d.state == .busy && d.target == nil, "忙态仍发点击")
        }
        try check("用户完整视频截图含播放器叠层必须停止") {
            let chrome = [o("期待你的评论", y: 0.94), o("拍同款", x: 0.8, y: 0.86, w: 0.1)]
            let refresh = [o("确认购买", y: 0.05), o("加速刷新中…", y: 0.60, confidence: 0.3), o("努力刷新", y: 0.67)]
            let retry = order + [o("抢票人数太多啦，继续尝试别放弃", y: 0.47, w: 0.6),
                o("继续尝试", y: 0.53), o("返回重新选购", y: 0.59)]
            for underlying in [refresh, retry] {
                let d = DamaiPlan.evaluate(underlying + chrome)
                try expect(d.kind == .stop && d.target == nil, "教程视频里的大麦按钮被点击")
            }
        }
        try check("加载失败刷新只选择努力刷新文本") {
            let button = o("努力刷新", y: 0.67)
            let d = DamaiPlan.evaluate([o("确认购买", y: 0.05),
                o("抢票人数太多啦，继续尝试别放弃", y: 0.60, w: 0.6), button])
            try expect(d.kind == .click && d.state == .refresh && d.target == button, "刷新目标错误")
        }
        try check("用户继续尝试弹窗优先于底层立即提交") {
            let button = o("继续尝试", y: 0.53)
            let d = DamaiPlan.evaluate(order + [o("抢票人数太多啦，继续尝试别放弃", y: 0.47, w: 0.6),
                button, o("返回重新选购", y: 0.59)])
            try expect(d.kind == .click && d.state == .retry && d.target == button, "点到了底层提交或返回")
        }
        try check("旧版上下倒置仍按继续尝试文字选目标") {
            let button = o("继续尝试", y: 0.67)
            let d = DamaiPlan.evaluate(order + [o("当前排队的人数太多，请稍后再试哦", y: 0.53, w: 0.6),
                o("返回", y: 0.61), button])
            try expect(d.kind == .click && d.target == button, "按旧版主按钮位置点返回")
        }
        try check("支付成功后的订单说明不会误判支付成功") {
            let d = DamaiPlan.evaluate(order)
            try expect(d.state == .order && d.kind == .click && d.target?.text == "立即提交", "静态支付说明导致误停")
        }
        try check("库存不足时停止且不自动返回换票") {
            let d = DamaiPlan.evaluate(order + [o("对不起，您选购的商品库存不足，请重新选购", y: 0.5, w: 0.7),
                o("返回重新选购", y: 0.6)])
            try expect(d.state == .soldOut && d.kind == .stop && d.target == nil, "库存不足仍操作")
        }
        try check("只剩返回重新选购时停止") {
            let d = DamaiPlan.evaluate(order + [o("返回重新选购", y: 0.6)])
            try expect(d.state == .soldOut && d.kind == .stop, "只剩返回时仍提交")
        }
        try check("我知道了未知弹窗挡住底层提交") {
            let d = DamaiPlan.evaluate(order + [o("当前观演人无购票特权", y: 0.5), o("我知道了", y: 0.6)])
            try expect(d.kind == .stop && d.target == nil, "未知弹窗仍点底层按钮")
        }
        try check("实际收银台停止") {
            for heading in ["确认付款", "收银台", "支付宝支付"] {
                let d = DamaiPlan.evaluate([o(heading, y: 0.07), o("确认付款", y: 0.9)])
                try expect(d.state == .payment && d.kind == .stop && d.target == nil, "自动进入付款")
            }
        }
        try check("成功状态停止") {
            let d = DamaiPlan.evaluate([o("支付成功", y: 0.2), o("立即购买", y: 0.94)])
            try expect(d.state == .payment && d.kind == .stop, "支付成功后仍购票")
        }
        try check("滑块及短信验证停止") {
            for text in ["请拖动滑块完成验证", "请输入短信验证码", "请先登录", "操作过于频繁"] {
                let d = DamaiPlan.evaluate(order + [o(text, y: 0.4, w: 0.6)])
                try expect(d.state == .verification && d.kind == .stop, "验证未阻止提交")
            }
        }
        try check("缺少观演人票档等必选项时停止") {
            for text in ["请先选择观演人", "请选择观演人", "请选择实名观演人", "请选择票档", "请先选择场次", "请选择票价", "请勾选协议"] {
                let d = DamaiPlan.evaluate(order + [o(text, y: 0.5, w: 0.6)])
                try expect(d.kind == .stop && d.target == nil, "缺项提示仍提交：\(text)")
            }
        }
        try check("无购票特权时停止但普通资格入口不是错误") {
            for text in ["当前所选观演人无购票特权", "该账号暂无购票资格", "未获得购票特权"] {
                let d = DamaiPlan.evaluate(order + [o(text, y: 0.5, w: 0.6)])
                try expect(d.kind == .stop && d.target == nil, "无资格仍提交")
            }
            let normal = DamaiPlan.evaluate(order + [o("购票特权", y: 0.3)])
            try expect(normal.kind == .click && normal.state == .order, "特权普通标签被当成错误")
        }
        try check("陌生错误提示挡住底层提交") {
            let d = DamaiPlan.evaluate(order + [o("系统提示", y: 0.4), o("发生错误，请联系在线客服", y: 0.5)])
            try expect(d.kind == .stop && d.target == nil, "错误弹窗仍点底层")
        }
        try check("详情页只点明确购票白名单") {
            let b = o("立即购买", x: 0.6, y: 0.94)
            let d = DamaiPlan.evaluate([o("薛之谦演唱会", y: 0.2), o("抢票攻略", y: 0.4), b])
            try expect(d.state == .detail && d.kind == .click && d.target == b, "购票入口未选中")
            let unrelated = DamaiPlan.evaluate([b])
            try expect(unrelated.kind == .wait, "无上下文也点击购买")
        }
        try check("预约与缺货登记不当成立即购票") {
            for text in ["预约抢票", "提交抢票预约", "已预约"] {
                let d = DamaiPlan.evaluate([o("演唱会", y: 0.2), o(text, y: 0.94)])
                try expect(d.kind == .wait && d.target == nil, "预约按钮被点")
            }
            for text in ["缺货登记", "提交缺货登记", "付款候补"] {
                let d = DamaiPlan.evaluate([o("场次", y: 0.2), o("票档", y: 0.4), o(text, y: 0.94)])
                try expect(d.state == .soldOut && d.kind == .stop, "缺货入口被点")
            }
        }
        try check("选票确认只在有场次票档时点击") {
            let b = o("确定", x: 0.75, y: 0.94, w: 0.15)
            let d = DamaiPlan.evaluate([o("场次", x: 0.04, y: 0.3), o("票档", x: 0.04, y: 0.5), b])
            try expect(d.state == .sku && d.kind == .click && d.target == b, "选票确认未通过")
            try expect(DamaiPlan.evaluate([b]).kind == .wait, "无选票上下文也确认")
        }
        try check("低置信、越界、过大文字框不能作为点击目标") {
            let bad = [o("立即提交", y: 0.9, h: 0.1), o("立即提交", y: 0.94, confidence: 0.39),
                       o("立即提交", x: 0.8, y: 0.94, w: 0.3), o("立即提交", y: -0.1),
                       o("立即提交", y: .nan)]
            let context = order.filter { $0.text != "立即提交" }
            for observation in bad {
                try expect(DamaiPlan.evaluate(context + [observation]).kind == .wait, "非法框被点击")
            }
        }
        try check("两个分离的提交按钮有歧义时不点击") {
            let d = DamaiPlan.evaluate(order + [o("立即提交", x: 0.1, y: 0.85, w: 0.2)])
            try expect(d.kind == .wait && d.target == nil, "多个按钮被随意挑选")
        }
        try check("重复OCR同一个框去重但不改目标语义") {
            let b = o("立即提交", x: 0.72, y: 0.94, w: 0.2, confidence: 0.95)
            let d = DamaiPlan.evaluate(order.filter { $0.text != "立即提交" } + [b,
                o("立即提交", x: 0.721, y: 0.941, w: 0.2, confidence: 0.8)])
            try expect(d.kind == .click && d.target == b, "同一框重复识别导致歧义")
        }
        try check("空画面和无关手机号评论不产生动作") {
            for observations in [[], [o("13800138000", y: 0.6), o("点击分享", y: 0.94), o("搜索", y: 0.07)]] {
                let d = DamaiPlan.evaluate(observations)
                try expect(d.kind == .wait && d.target == nil, "无关画面产生动作")
            }
        }
        try check("中文空格和标点规范化后仍严格匹配按钮") {
            let d = DamaiPlan.evaluate([o("确 认 购 买", y: 0.05), o("抢票人数太多啦！", y: 0.5),
                o("继 续 尝 试", y: 0.6), o("返回重新选购", y: 0.67)])
            try expect(d.state == .retry && d.kind == .click, "OCR空格导致无法匹配")
            let prose = DamaiPlan.evaluate(order.filter { $0.text != "立即提交" } + [o("请点击立即提交按钮", y: 0.94)])
            try expect(prose.kind == .wait, "说明句被当作按钮")
        }
        try check("刷新和提交忙态不持续重发") {
            for text in ["正在提交订单…", "加载中", "正在排队，请稍候"] {
                let d = DamaiPlan.evaluate(order + [o(text, y: 0.55)])
                try expect(d.state == .busy && d.kind == .wait, "忙态重复发起动作")
            }
        }
        print("\(passed) 项大麦决策规则测试通过；无截图捕获或真实点击。")
    }
}
