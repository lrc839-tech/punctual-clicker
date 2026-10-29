import Foundation
import CoreGraphics

/// OCR coordinates are normalized to the selected phone-content viewport, with
/// the origin at its top-left. They are not model-specific screen coordinates.
struct DamaiTextObservation: Codable, Equatable {
    let text: String
    let rect: CGRect
    var confidence: Float = 1

    init(text: String, rect: CGRect, confidence: Float = 1) {
        self.text = text
        self.rect = rect
        self.confidence = confidence
    }
}

enum DamaiPageState: String, Codable {
    case detail, sku, order, refresh, retry, soldOut, payment, verification, unknown, busy

    var displayName: String {
        switch self {
        case .detail: return "购票入口"
        case .sku: return "选票确认"
        case .order: return "订单提交"
        case .refresh: return "加载失败，可刷新"
        case .retry: return "拥挤，可继续尝试"
        case .soldOut: return "缺票／需要重选"
        case .payment: return "支付／成功页面"
        case .verification: return "需要人工验证"
        case .unknown: return "未识别／页面切换中"
        case .busy: return "正在加载／提交"
        }
    }
}

enum DamaiDecisionKind: String, Codable { case click, wait, stop }

struct DamaiDecision: Codable, Equatable {
    let state: DamaiPageState
    let kind: DamaiDecisionKind
    let target: DamaiTextObservation?
    let reason: String
}

/// A conservative, stateless allow-list classifier. A caller must separately
/// bind the viewport to the real iPhone Mirroring window, check visibility and
/// observation freshness, enforce cooldowns/limits, and re-observe after clicks.
/// OCR cannot establish server acceptance, enabled button state, or inventory.
enum DamaiPlan {
    private struct Line {
        let observation: DamaiTextObservation
        let key: String
    }

    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_CN"))
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func validRect(_ rect: CGRect) -> Bool {
        let values = [rect.origin.x, rect.origin.y, rect.width, rect.height, rect.maxX, rect.maxY]
        return values.allSatisfy { $0.isFinite } && rect.width > 0 && rect.height > 0 &&
            rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1
    }

    private static func buttonSized(_ rect: CGRect) -> Bool {
        validRect(rect) && rect.width >= 0.025 && rect.width <= 0.9 &&
            rect.height >= 0.007 && rect.height <= 0.085
    }

    private static func decision(_ state: DamaiPageState, _ kind: DamaiDecisionKind,
                                 _ reason: String, target: DamaiTextObservation? = nil) -> DamaiDecision {
        DamaiDecision(state: state, kind: kind, target: target, reason: reason)
    }

    static func evaluate(_ observations: [DamaiTextObservation]) -> DamaiDecision {
        let lines = observations.filter {
            // Low-confidence busy/context text may veto an action, but can
            // never itself authorize a click. The supplied screenshot's busy
            // line is confidence 0.3 while its refresh label is confidence 1.
            $0.confidence.isFinite && $0.confidence >= 0.2 && validRect($0.rect)
        }.map { Line(observation: $0, key: normalized($0.text)) }.filter { !$0.key.isEmpty }
        let keys = lines.map(\.key)
        func has(_ words: [String]) -> Bool {
            keys.contains { key in words.contains { key.contains(normalized($0)) } }
        }
        func exact(_ words: [String], above: CGFloat? = nil) -> Bool {
            let accepted = Set(words.map(normalized))
            return lines.contains { accepted.contains($0.key) && (above == nil || $0.observation.rect.midY <= above!) }
        }
        func target(_ words: [String], in range: ClosedRange<CGFloat>) -> (DamaiTextObservation?, Bool) {
            let accepted = Set(words.map(normalized))
            let candidates = lines.filter {
                accepted.contains($0.key) && $0.observation.confidence >= 0.4 &&
                    buttonSized($0.observation.rect) && range.contains($0.observation.rect.midY)
            }.sorted { $0.observation.confidence > $1.observation.confidence }
            var unique: [Line] = []
            for candidate in candidates {
                let duplicate = unique.contains { previous in
                    let a = candidate.observation.rect, b = previous.observation.rect
                    // OCR can return the same label twice with slightly different
                    // boxes. Only overlap at the same position is deduplicated.
                    return previous.key == candidate.key && abs(a.midX - b.midX) < 0.015 &&
                        abs(a.midY - b.midY) < 0.015 && !a.intersection(b).isNull
                }
                if !duplicate { unique.append(candidate) }
            }
            return (unique.count == 1 ? unique[0].observation : nil, unique.count > 1)
        }

        // The supplied evidence is a video-player screenshot. Runtime must not
        // treat a tutorial playing inside the mirrored phone as the live App.
        // Crop the evidence to phone content for rule demonstrations, but never
        // ignore visible player chrome in a real capture.
        if exact(["期待你的评论", "拍同款", "发条评论吧", "前往抖音", "抖音精选"]) {
            return decision(.unknown, .stop, "检测到短视频播放器界面；请切回真实大麦页面后重新开始。")
        }

        // Exact success labels, actual cashier headings, or payment actions with
        // payment-specific context. Static order copy such as “支付成功后，无需
        // 取票” and the order's “支付方式” row are deliberately not sufficient.
        let success = exact(["支付成功", "付款成功", "交易成功", "订单支付成功", "购票成功"])
        let cashierHeader = exact(["收银台", "确认付款", "支付订单", "支付宝支付", "微信支付"], above: 0.25)
        let paymentInstruction = has(["请输入支付密码", "付款码", "剩余支付时间", "付款倒计时", "支付剩余时间"])
        let paymentButton = target(["确认付款", "确认支付", "立即付款", "立即支付", "去支付"], in: 0.4...0.99)
        if success || cashierHeader || paymentInstruction ||
            (paymentButton.0 != nil && has(["付款", "支付密码", "订单金额", "应付金额"])) {
            return decision(.payment, .stop, "已进入支付或成功页面，停止自动点击，由你核对并完成付款。")
        }

        if has(["请拖动滑块", "拖动滑块", "拖动下方滑块", "完成拼图", "请完成验证", "人机验证", "安全验证", "请输入验证码", "短信验证码", "请进行人脸识别", "请先登录", "登录已过期", "账号异常", "操作过于频繁"]) ||
            exact(["验证码", "人脸识别", "登录", "账号登录", "身份验证"], above: 0.5) {
            return decision(.verification, .stop, "出现验证、登录或账户提示，暂停并由你处理。")
        }
        if has(["请先选择观演人", "请选择观演人", "请添加观演人", "请选择实名观演人", "请先选择票档", "请选择票档", "请先选择场次", "请选择场次", "请选择票价", "请选择观演日期", "请阅读并同意", "请勾选协议"]) {
            return decision(.unknown, .stop, "购票信息或协议尚未完成，请手动确认观演人、场次、票档及必选项后重新开始。")
        }
        if has(["观演人无购票特权", "观演人没有购票特权", "未获得购票特权", "暂无购票资格", "不具备购票资格", "无购票资格", "购票特权不足"]) {
            return decision(.verification, .stop, "出现购票资格或特权提示，请先手动核对，不继续提交。")
        }

        // A title or rules panel is only context, never itself a click target.
        let orderHeader = exact(["确认购买", "确认订单", "订单确认"], above: 0.3)
        let orderContext = orderHeader || has(["实名观演人", "配送方式", "联系方式", "电子票", "票档"])
        let congested = has(["人数太多", "人数较多", "排队人数", "下单人数", "抢票人数", "继续尝试别放弃", "请稍后再试"])
        let inventoryFailure = has(["库存不足", "已售罄", "已抢光", "票档无票", "当前无票", "商品无货", "票品售罄", "票已售完", "票已抢光", "手慢了"])
        let retry = target(["继续尝试"], in: 0.22...0.88)
        let goBack = target(["返回重新选购", "返回重选", "重新选购"], in: 0.22...0.9)
        if inventoryFailure {
            return decision(.soldOut, .stop, "检测到库存不足或售罄，停止点击；请手动决定场次、票档及是否重选。")
        }
        if retry.1 {
            return decision(.unknown, .wait, "同时识别到多个继续尝试按钮，位置有歧义，等待清晰画面。")
        }
        if let button = retry.0, orderContext && (congested || goBack.0 != nil) {
            // Modal action is intentionally evaluated before the submit button
            // still visible on the dimmed order page below it.
            return decision(.retry, .click, "拥挤弹窗：只点击文字为继续尝试的按钮，不点击返回。", target: button)
        }
        if goBack.0 != nil && retry.0 == nil && orderContext {
            return decision(.soldOut, .stop, "当前只提供返回重新选购，需要你决定后续选票，程序不自动返回。")
        }

        // Unknown modal controls must block a submit button in the underlying
        // page. “我知道了” can also mean lost purchase privilege, not success.
        let modal = target(["我知道了", "知道了", "返回", "取消", "确认", "确定"], in: 0.22...0.78)
        if modal.0 != nil || modal.1 {
            return decision(.unknown, .stop, "出现未列入自动处理的弹窗，暂停；请先阅读提示。")
        }
        if lines.contains(where: { ["温馨提示", "系统提示", "购票失败", "订单提交失败", "风险提示", "错误提示"].map(normalized).contains($0.key) && (0.2...0.78).contains($0.observation.rect.midY) }) {
            return decision(.unknown, .stop, "出现未列入自动处理的提示，暂停；请先阅读提示。")
        }
        if retry.0 != nil || goBack.0 != nil {
            return decision(.unknown, .wait, "看到了重试或返回按钮，但缺少大麦订单上下文，等待人工核对。")
        }

        // Busy text may coexist with the refresh button (the user's first
        // screenshot). Wait for that request rather than repeatedly interrupt it.
        if has(["加速刷新中", "正在刷新", "正在加载", "加载中", "正在提交", "提交中", "正在跳转", "正在处理", "正在排队", "请稍候", "请稍等"]) {
            return decision(.busy, .wait, "正在刷新、加载或提交，等待本次请求结果。")
        }
        let refresh = target(["努力刷新"], in: 0.3...0.88)
        if refresh.1 {
            return decision(.unknown, .wait, "刷新按钮位置有歧义，等待清晰画面。")
        }
        if let button = refresh.0, orderContext || congested {
            return decision(.refresh, .click, "订单加载失败，只点击努力刷新；内容加载出来后重新识别。", target: button)
        }

        let soldOutAction = target(["缺货登记", "提交缺货登记", "付款候补", "立即候补"], in: 0.7...0.99)
        if soldOutAction.0 != nil || soldOutAction.1 {
            return decision(.soldOut, .stop, "当前是缺货登记或候补入口，不作为立即购票继续点击。")
        }

        let submit = target(["立即提交", "提交订单"], in: 0.78...0.99)
        if submit.1 {
            return decision(.unknown, .wait, "订单提交按钮位置有歧义，等待清晰画面。")
        }
        if let button = submit.0, orderHeader && orderContext {
            return decision(.order, .click, "订单确认页：点击立即提交，随后重新识别服务端返回的页面。", target: button)
        }

        let confirmation = target(["确定", "确定购买", "确认购买"], in: 0.78...0.99)
        if confirmation.1 {
            return decision(.unknown, .wait, "选票确认按钮位置有歧义，等待清晰画面。")
        }
        if let button = confirmation.0, has(["场次"]) && has(["票档", "票价"]) {
            return decision(.sku, .click, "选票确认页：使用你已经选好的场次与票档，点击确认。", target: button)
        }

        let purchase = target(["立即购买", "立即购票", "立即抢票", "立即预订", "立即预定"], in: 0.78...0.99)
        if purchase.1 {
            return decision(.unknown, .wait, "同时出现多个购票入口，等待你确定目标。")
        }
        if let button = purchase.0,
           has(["演出介绍", "购票须知", "抢票攻略", "场次", "票档", "演唱会", "音乐节", "巡回", "演出详情"]) {
            return decision(.detail, .click, "演出详情页：点击当前可见的购票入口，进入后重新识别。", target: button)
        }
        if target(["预约抢票", "提交抢票预约", "已预约", "开售提醒"], in: 0.7...0.99).0 != nil {
            return decision(.detail, .wait, "仍是预约或提醒入口，等待正式购票按钮出现。")
        }
        return decision(.unknown, .wait, "没有找到明确、唯一且带上下文的购票按钮；本帧不点击。")
    }
}
