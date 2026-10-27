import Foundation
import Darwin

@main
enum CalibrationServerTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var passed = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }
    static func check(_ name: String, _ test: () throws -> Void) throws {
        try test(); passed += 1; print("PASS \(name)")
    }
    static func rejects(_ test: () throws -> Void) throws {
        do { try test() } catch { return }
        throw Failure(description: "应拒绝异常输入")
    }
    static func number(_ object: [String: Any], _ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
    static func waitUntil(_ condition: () -> Bool) throws {
        let limit = Date().addingTimeInterval(7)
        while !condition() && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        try expect(condition(), "等待异步操作超时")
    }
    struct Response {
        let status: Int
        let body: Data
        let headers: String
        func json() throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw Failure(description: "响应不是JSON对象")
            }
            return object
        }
    }
    static func raw(_ port: UInt16, _ chunks: [Data], halfClose: Bool = false) throws -> Response {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure(description: "socket失败") }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw Failure(description: "连接失败 errno=\(errno)") }
        for chunk in chunks {
            try chunk.withUnsafeBytes { pointer in
                var offset = 0
                while offset < chunk.count {
                    let sent = Darwin.send(descriptor, pointer.baseAddress!.advanced(by: offset), chunk.count - offset, 0)
                    guard sent > 0 else { throw Failure(description: "发送失败 errno=\(errno)") }
                    offset += sent
                }
            }
            if chunks.count > 1 { usleep(2_000) }
        }
        if halfClose { _ = shutdown(descriptor, SHUT_WR) }
        var output = Data(), bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = recv(descriptor, &bytes, bytes.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw Failure(description: "接收失败 errno=\(errno)") }
            output.append(contentsOf: bytes[0..<count])
        }
        guard let separator = output.range(of: Data([13,10,13,10])),
              let header = String(data: output[..<separator.lowerBound], encoding: .utf8),
              let status = header.components(separatedBy: " ").dropFirst().first.flatMap(Int.init) else {
            throw Failure(description: "HTTP响应格式无效")
        }
        let body = output.subdata(in: separator.upperBound..<output.count)
        let lengthLine = header.components(separatedBy: "\r\n").first { $0.hasPrefix("Content-Length: ") }
        try expect(lengthLine == "Content-Length: \(body.count)", "Content-Length与实际响应不符")
        return Response(status: status, body: body, headers: header)
    }
    static func request(_ port: UInt16, _ path: String, body: Any? = nil, origin: String? = nil) throws -> Response {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var header = "\(body == nil ? "GET" : "POST") \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
        if let origin { header += "Origin: \(origin)\r\n" }
        if body != nil { header += "Content-Type: application/json\r\nContent-Length: \(data.count)\r\n" }
        header += "\r\n"
        var wire = Data(header.utf8); wire.append(data)
        return try raw(port, [wire])
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CalibrationServerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = root.appendingPathComponent("state/phone-calibration.json")
        let state = CalibrationState(reportURL: report)
        try check("实际发送记录前不计算延迟；重复索引覆盖并统计缺失/游离事件") {
            _ = try state.setPlan(["runId": "a", "targetsMs": [1000, 1500], "compensationMs": 5])
            let sample: [String: Any] = ["index": 2, "receivedMacMs": 1502]
            let summary = try state.ingestSamples(["runId": "a", "samples": [sample, sample],
                "straySamples": [["receivedMacMs": 1400, "reason": "outside-match-window-or-ambiguous-phase"]]])
            try expect(summary["medianLatencyMs"] is NSNull, "未发送却显示实际延迟")
            try expect(number(summary, "p50ErrorMs") == 2, "目标误差错误")
            try expect(number(summary, "estimatedMedianLatencyMs") == 7, "估计延迟错误")
            try expect(number(summary, "sampleCount") == 1 && number(summary, "missingCount") == 1 && number(summary, "strayCount") == 1, "计数错误")
            let sent = try state.ingestSends(["runId": "a", "events": [["index": 2, "sentUpMs": 1490]]])
            try expect(number(sent, "medianLatencyMs") == 12 && number(sent, "matchedSendCount") == 1, "实际延迟错误")
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as! [String: Any]
            let rows = saved["samples"] as! [[String: Any]]
            try expect(number(rows[0], "latencyMs") == 12, "原子报告未保存实际延迟")
            try expect(saved["sendEvents"] as? [String: Double] == ["2": 1490], "发送记录未持久化")
            try expect(sent["reportPath"] == nil, "HTTP状态不应泄露本地报告路径")
        }
        try check("P50/P95线性插值和新计划清空旧数据") {
            _ = try state.setPlan(["runId": "percentiles", "targetsMs": [1000, 2000, 3000, 4000]])
            _ = try state.ingestSends(["runId": "percentiles", "events": (1...4).map { ["index": $0, "sentUpMs": $0 * 1000] }])
            let summary = try state.ingestSamples(["runId": "percentiles", "samples": (1...4).map { ["index": $0, "receivedMacMs": $0 * 1000 + $0 * 10] }])
            try expect(number(summary, "medianLatencyMs") == 25, "中位值错误")
            try expect(abs(number(summary, "p95LatencyMs")! - 38.5) < 0.00001, "P95插值错误")
            _ = try state.setPlan(["runId": "reset", "targetsMs": [1000]])
            try expect(number(state.summary(), "sampleCount") == 0 && number(state.summary(), "matchedSendCount") == 0, "新计划未清空数据")
        }
        try check("手机校时60秒新鲜度和时钟字段校验") {
            let now = Date().timeIntervalSince1970 * 1000
            let fresh = try state.ingestSamples(["runId": "reset", "samples": [], "clock": ["calibratedAtMacMs": now - 5000, "rttMs": 6, "uncertaintyEstimateMs": 3, "rounds": 20]])
            try expect(fresh["clockFresh"] as? Bool == true, "有效校时被误判")
            try expect(number(fresh, "clockRttMs") == 6 && number(fresh, "clockUncertaintyEstimateMs") == 3, "校时统计错误")
            let expired = try state.ingestSamples(["runId": "reset", "samples": [], "clock": ["calibratedAtMacMs": now - 61000]])
            try expect(expired["clockFresh"] as? Bool == false, "过期校时仍有效")
            try rejects { _ = try state.ingestSamples(["runId": "reset", "clock": ["rttMs": "NaN"]]) }
            try rejects { _ = try state.ingestSamples(["runId": "reset", "clock": ["rounds": true]]) }
        }
        try check("runId、索引、计数、可选有限数值和整批事务性") {
            for plan: [String: Any] in [
                ["runId": "", "targetsMs": [1]], ["runId": "x", "targetsMs": []],
                ["runId": "x", "targetsMs": [2, 1]], ["runId": "x", "targetsMs": [true]],
                ["runId": String(repeating: "x", count: 129), "targetsMs": [1]],
                ["runId": "x", "targetsMs": [1], "compensationMs": Double.infinity],
                ["runId": "x", "targetsMs": Array(repeating: 1, count: 10001)]
            ] { try rejects { _ = try state.setPlan(plan) } }
            for index: Any in [true, 0, 2, 1.2, "1"] {
                try rejects { _ = try state.ingestSamples(["runId": "reset", "samples": [["index": index, "receivedMacMs": 1000]]]) }
                try rejects { _ = try state.ingestSends(["runId": "reset", "events": [["index": index, "sentUpMs": 1000]]]) }
            }
            try rejects { _ = try state.ingestSamples(["runId": "stale", "samples": []]) }
            try rejects { _ = try state.ingestSends(["runId": "reset", "events": ["invalid"]]) }
            try rejects { _ = try state.ingestSamples(["runId": "reset", "samples": [["index": 1, "receivedMacMs": 1001], ["index": 2, "receivedMacMs": 1002]]]) }
            try expect(number(state.summary(), "sampleCount") == 0, "无效批次部分提交")
            try rejects { _ = try state.ingestSamples(["runId": "reset", "samples": [["index": 1, "receivedMacMs": 1000, "offsetMs": Double.nan]]]) }
            try rejects { _ = try state.ingestSamples(["runId": "reset", "straySamples": [["receivedMacMs": Double.infinity]]]) }
        }
        try check("有限输入的计算溢出被拒绝并保留原状态") {
            _ = try state.setPlan(["runId": "overflow", "targetsMs": [-Double.greatestFiniteMagnitude]])
            try rejects { _ = try state.ingestSamples(["runId": "overflow", "samples": [["index": 1, "receivedMacMs": Double.greatestFiniteMagnitude]]]) }
            try expect(number(state.summary(), "sampleCount") == 0, "溢出数据已污染状态")
        }
        try check("并发上传保持完整报告与索引一致") {
            _ = try state.setPlan(["runId": "concurrent", "targetsMs": (1...20).map { $0 * 1000 }])
            let group = DispatchGroup(), errorLock = NSLock()
            var errors = [String]()
            for index in 1...20 {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }
                    do {
                        _ = try state.ingestSamples(["runId": "concurrent", "samples": [["index": index, "receivedMacMs": index * 1000 + 10]]])
                        _ = try state.ingestSends(["runId": "concurrent", "events": [["index": index, "sentUpMs": index * 1000]]])
                    } catch { errorLock.lock(); errors.append(error.localizedDescription); errorLock.unlock() }
                }
            }
            try expect(group.wait(timeout: .now() + 5) == .success, "并发状态测试超时")
            try expect(errors.isEmpty, "并发上传失败")
            let result = state.summary()
            try expect(number(result, "sampleCount") == 20 && number(result, "matchedSendCount") == 20 && number(result, "medianLatencyMs") == 10, "并发上传丢失数据")
            _ = try JSONSerialization.jsonObject(with: Data(contentsOf: report))
        }

        try Data("<!doctype html><p>原生手机校准 · 校时 20 轮</p>".utf8).write(to: root.appendingPathComponent("index.html"))
        let server = try CalibrationHTTPServer(port: 0, resourceRoot: root, reports: root.appendingPathComponent("http"))
        defer { server.stop() }
        var started: Result<Void, Error>?, mainCallback = false
        server.start { result in mainCallback = Thread.isMainThread; started = result }
        try waitUntil { started != nil }
        try started!.get()
        let port = server.boundPort!
        try check("异步启动只在listener ready后主线程回调，支持端口0") {
            try expect(mainCallback && server.isRunning && port > 0, "启动状态或回调线程错误")
        }
        try check("真实HTTP提供手机页、时钟、健康和计划JSON") {
            let before = Date().timeIntervalSince1970 * 1000
            let time = try request(port, "/time?round=1").json()
            let after = Date().timeIntervalSince1970 * 1000
            try expect(number(time, "receiveMs")! >= before && number(time, "sendMs")! <= after && number(time, "sendMs")! >= number(time, "receiveMs")!, "HTTP时钟边界错误")
            let page = try request(port, "/")
            try expect(page.status == 200 && String(data: page.body, encoding: .utf8)!.contains("校时 20 轮"), "静态手机页错误")
            try expect(page.headers.contains("Cache-Control: no-store") && page.headers.contains("X-Content-Type-Options: nosniff"), "响应缺少缓存/类型保护")
            try expect(try request(port, "/health").json()["ok"] as? Bool == true, "健康检查失败")
            let plan = try request(port, "/test-plan", body: ["runId": "http", "targetsMs": [1000, 1500]], origin: "http://127.0.0.1:\(port)")
            try expect(plan.status == 200, "同源计划请求失败")
            try expect(try request(port, "/plan").json()["runId"] as? String == "http", "计划GET错误")
            let samples = try request(port, "/samples", body: ["runId": "http", "samples": [["index": 2, "receivedMacMs": 1510]]])
            try expect(samples.status == 200 && (try samples.json())["medianLatencyMs"] is NSNull, "真实HTTP未发送却显示延迟")
            let sends = try request(port, "/send-events", body: ["runId": "http", "events": [["index": 2, "sentUpMs": 1490]]])
            try expect(sends.status == 200 && number(try sends.json(), "medianLatencyMs") == 20, "真实HTTP发送记录失败")
            let report = try request(port, "/report").json()
            try expect((report["samples"] as? [[String: Any]])?.count == 1 && number(try request(port, "/summary").json(), "missingCount") == 1, "报告/摘要失败")
            try expect(!String(data: try request(port, "/report").body, encoding: .utf8)!.contains(root.path), "响应泄露本地路径")
            try expect(try request(port, "/no-such-route").status == 404, "未知路由错误")
        }
        try check("拒绝跨站和协议伪造写入，原生无Origin请求可用") {
            for origin in ["http://evil.example", "null", "https://127.0.0.1:\(port)", "http://user@127.0.0.1:\(port)", "http://127.0.0.1:\(port)/x"] {
                try expect(try request(port, "/test-plan", body: ["runId": "forbidden", "targetsMs": [1]], origin: origin).status == 403, "应拒绝Origin \(origin)")
            }
            try expect(try request(port, "/plan").json()["runId"] as? String == "http", "跨站写已改变状态")
        }
        try check("拆分请求头/JSON、Content-Length和断开处理") {
            let payload = Data("{\"runId\":\"split\",\"targetsMs\":[1000]}".utf8)
            let prefix = "POST /test-plan HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: \(payload.count)\r\n\r\n"
            let parts = [Data(prefix.prefix(17).utf8), Data(prefix.dropFirst(17).utf8), payload.prefix(9), payload.dropFirst(9)]
            try expect(try raw(port, parts).status == 200, "拆分请求未重组")
            let malformed = [
                "POST /samples HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n",
                "POST /samples HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
                "POST /samples HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n",
                "POST /samples HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\n{}",
                "POST /samples HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n[",
                "POST /samples HTTP/1.1\r\nHost: x\r\n\r\n",
                "GET /health HTTP/1.1\r\n\r\n"
            ]
            for wire in malformed { try expect(try raw(port, [Data(wire.utf8)], halfClose: true).status == 400, "非法HTTP被接受") }
            let emptyLimitBody = "{\"runId\":\"limit\",\"targetsMs\":[1000],\"padding\":\"\"}"
            let limitBody = Data(emptyLimitBody.replacingOccurrences(of: "\"padding\":\"\"", with: "\"padding\":\"" + String(repeating: "a", count: 2097152 - emptyLimitBody.utf8.count) + "\"").utf8)
            try expect(limitBody.count == 2097152, "边界测试大小错误")
            var limitWire = Data("POST /test-plan HTTP/1.1\r\nHost: x\r\nContent-Length: 2097152\r\n\r\n".utf8)
            limitWire.append(limitBody)
            try expect(try raw(port, [limitWire]).status == 200, "合法2MiB边界请求被拒绝")
            let tooLarge = "POST /samples HTTP/1.1\r\nHost: x\r\nContent-Length: 2097153\r\n\r\n"
            try expect(try raw(port, [Data(tooLarge.utf8)]).status == 413, "未限制2MiB请求")
            let header = "GET /health HTTP/1.1\r\nHost: x\r\nX-Long: " + String(repeating: "a", count: 17000)
            try expect(try raw(port, [Data(header.utf8)]).status == 431, "未限制请求头")
            let badJSON = "POST /test-plan HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nNaN"
            try expect(try raw(port, [Data(badJSON.utf8)]).status == 400, "非JSON被接受")
        }
        try check("端口冲突明确失败，停止后状态归零且可重启") {
            let duplicate = try CalibrationHTTPServer(port: Int(port), resourceRoot: root, reports: root.appendingPathComponent("duplicate"))
            defer { duplicate.stop() }
            var collision: Result<Void, Error>?
            duplicate.start { collision = $0 }
            try waitUntil { collision != nil }
            if case .success = collision! { throw Failure(description: "端口冲突却启动成功") }
            try expect(!duplicate.isRunning && duplicate.boundPort == nil, "端口冲突保留错误状态")
            let idle = socket(AF_INET, SOCK_STREAM, 0)
            guard idle >= 0 else { throw Failure(description: "停止连接测试socket失败") }
            defer { close(idle) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(idle, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(idle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            try expect(connected == 0, "停止连接测试connect失败")
            let partial = Data("GET /health HTTP/1.1\r\nHost: x\r\n".utf8)
            _ = partial.withUnsafeBytes { Darwin.send(idle, $0.baseAddress!, partial.count, 0) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            server.stop(); try waitUntil { !server.isRunning && server.boundPort == nil }
            var byte: UInt8 = 0
            let closed = recv(idle, &byte, 1, 0)
            try expect(closed == 0 || (closed < 0 && errno == ECONNRESET), "stop没有关闭活动连接")
            var restart: Result<Void, Error>?
            server.start { restart = $0 }
            try waitUntil { restart != nil }; try restart!.get()
            try expect(try request(server.boundPort!, "/health").status == 200, "重启失败")
        }
        print("CalibrationServerTests: \(passed) passed; no clicks sent, user app not started")
    }
}
