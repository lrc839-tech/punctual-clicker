import Foundation
import Darwin

/// Public NTP measures UTC. Asia/Shanghai formatting is a separate UI concern.
/// This client never changes the macOS clock and does not claim an accuracy bound.
struct NTPSample: Codable {
    let server: String
    let address: String
    let version: Int
    let stratum: Int
    let leapIndicator: Int
    let offsetMs: Double // server UTC minus the virtual, monotonic-projected system clock
    let roundTripMs: Double
    let rootDelayMs: Double
    let rootDispersionMs: Double
    let precisionMs: Double
    let estimatedUncertaintyMs: Double
    let localSendEpoch: Double
    let localReceiveEpoch: Double
    let serverReceiveEpoch: Double
    let serverTransmitEpoch: Double
    let receiveMonoNs: UInt64
    let utcEpochAtReceive: Double
}

struct NetworkTimeSnapshot: Codable {
    let referenceEpoch: Double
    let referenceMonoNs: UInt64
    let systemWallEpochAtAnchor: Double
    let offsetMs: Double
    let selectedServers: [String]
    let crossChecked: Bool
    let roundTripMs: Double
    let baseUncertaintyMs: Double
    let validitySeconds: Double
    let driftPPM: Double
    let measurementNote: String
    var calibratedAtMonoNs: UInt64 { referenceMonoNs }
    var utcEpochAtAnchor: Double { referenceEpoch }
    var sourceSummary: String { selectedServers.joined(separator: "、") + (crossChecked ? "（多源一致）" : "（单源，未交叉验证）") }
    func ageSeconds(atMonoNs now: UInt64 = PrecisionClock.nowNs()) -> Double {
        now >= referenceMonoNs ? Double(now - referenceMonoNs) / 1e9 : .infinity
    }
    func utcEpoch(atMonoNs now: UInt64 = PrecisionClock.nowNs()) -> Double {
        referenceEpoch + (Double(now) - Double(referenceMonoNs)) / 1e9
    }
    func isFresh(atMonoNs now: UInt64 = PrecisionClock.nowNs()) -> Bool {
        let age = ageSeconds(atMonoNs: now)
        return age.isFinite && age <= validitySeconds
    }
    func estimatedUncertaintyMs(atMonoNs now: UInt64 = PrecisionClock.nowNs()) -> Double {
        baseUncertaintyMs + ageSeconds(atMonoNs: now) * driftPPM / 1000
    }
    func isUsable(atMonoNs now: UInt64 = PrecisionClock.nowNs()) -> Bool {
        isFresh(atMonoNs: now) && estimatedUncertaintyMs(atMonoNs: now) <= 100
    }
    /// Diagnostic only: UTC scheduling itself does not read Date() after anchoring.
    func systemClockDeviationMs(atMonoNs now: UInt64, wallEpoch: Double) -> Double {
        (wallEpoch - (systemWallEpochAtAnchor + (Double(now) - Double(referenceMonoNs)) / 1e9)) * 1000
    }
}

struct NetworkTimeCalibration: Codable {
    let snapshot: NetworkTimeSnapshot
    let samples: [NTPSample]
    let failures: [String]
    let rejectedServers: [String]
}

enum NetworkTimeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

enum NTPPacket {
    static let epochDelta = 2_208_988_800.0
    static let eraSeconds = 4_294_967_296.0
    static func uint32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        bytes[index..<index+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    static func writeUInt32(_ value: UInt32, to bytes: inout [UInt8], at index: Int) {
        for i in 0..<4 { bytes[index+i] = UInt8(truncatingIfNeeded: value >> (24-8*i)) }
    }
    static func timestampBytes(epoch: Double) -> [UInt8] {
        let ntp = epoch + epochDelta
        let whole = floor(ntp)
        var result = [UInt8](repeating: 0, count: 8)
        writeUInt32(UInt32(whole.truncatingRemainder(dividingBy: eraSeconds)), to: &result, at: 0)
        writeUInt32(UInt32(min(eraSeconds - 1, max(0, floor((ntp-whole)*eraSeconds)))), to: &result, at: 4)
        return result
    }
    /// Select the NTP era nearest the local date; unambiguous within +/- 68 years.
    static func timestamp(_ bytes: [UInt8], at index: Int, near epoch: Double) -> Double {
        let seconds = Double(uint32(bytes,index)), fraction = Double(uint32(bytes,index+4))/eraSeconds
        let era = ((epoch + epochDelta - seconds) / eraSeconds).rounded()
        return seconds + era*eraSeconds + fraction - epochDelta
    }
    static func request(epoch: Double) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 48)
        bytes[0] = 0x23 // LI=0, NTPv4, client mode=3
        bytes.replaceSubrange(40..<48, with: timestampBytes(epoch: epoch))
        return bytes
    }
    static func parse(_ response: [UInt8], request: [UInt8], server: String, address: String,
                      sendEpoch: Double, receiveEpoch: Double, sendMonoNs: UInt64,
                      receiveMonoNs: UInt64, anchorUncertaintyMs: Double = 0) throws -> NTPSample {
        func reject(_ text: String) throws -> Never { throw NetworkTimeError.invalid("\(server)：\(text)") }
        guard response.count >= 48, request.count >= 48 else { try reject("NTP 响应长度不足") }
        let leap = Int(response[0] >> 6), version = Int((response[0] >> 3) & 7), mode = Int(response[0] & 7)
        guard mode == 4, version == 3 || version == 4 else { try reject("无效的 NTP 模式或版本") }
        guard leap != 3 else { try reject("服务器时钟尚未同步") }
        let stratum = Int(response[1])
        guard (1...15).contains(stratum) else { try reject(stratum == 0 ? "服务器限流或拒绝授时（KoD）" : "服务器层级无效") }
        guard Array(response[24..<32]) == Array(request[40..<48]) else { try reject("请求与响应时间戳不匹配") }
        guard response[32..<40].contains(where: { $0 != 0 }), response[40..<48].contains(where: { $0 != 0 }) else { try reject("服务器时间戳为空") }
        guard receiveMonoNs >= sendMonoNs else { try reject("单调时钟发生倒退") }
        let elapsed = Double(receiveMonoNs-sendMonoNs)/1e9
        guard elapsed > 0, elapsed <= 2 else { try reject("请求超时") }
        let virtualReceive = sendEpoch + elapsed
        guard abs(receiveEpoch-virtualReceive) <= 0.020 else { try reject("查询期间本机系统时间跳变") }
        let t2 = timestamp(response,at:32,near:sendEpoch), t3 = timestamp(response,at:40,near:sendEpoch)
        guard t2.isFinite, t3.isFinite, abs(t2-sendEpoch) < 31_557_600*50,
              t3 >= t2-0.001, t3-t2 <= elapsed+0.001 else { try reject("服务器时间戳不合理") }
        if leap != 0 {
            // LI=1/2 may be advertised for the entire month. Only block the actual
            // month-end window, including headroom for the 120-second validity.
            var calendar = Calendar(identifier:.gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT:0)!
            let date = Date(timeIntervalSince1970:t3)
            let components = calendar.dateComponents([.month,.hour,.minute],from:date)
            let tomorrow = calendar.date(byAdding:.day,value:1,to:date)!
            let lastDay = calendar.component(.month,from:tomorrow) != components.month
            if lastDay && components.hour == 23 && (components.minute ?? 0) >= 55 {
                try reject("临近服务器预告的闰秒窗口，请过窗口后重新校时")
            }
        }
        let delay = elapsed - (t3-t2)
        guard delay >= -0.001, delay <= 0.5 else { try reject("网络往返延迟超过 500 毫秒或无效") }
        let rootDelay = Double(Int32(bitPattern:uint32(response,4)))/65536*1000
        let dispersion = Double(uint32(response,8))/65536*1000
        let precisionExponent = Int(Int8(bitPattern:response[3]))
        guard (-40...0).contains(precisionExponent), rootDelay >= -1, rootDelay <= 1000,
              dispersion <= 1000 else { try reject("服务器精度或根距离参数异常") }
        let precision = pow(2,Double(precisionExponent))*1000
        let delayMs = max(0,delay*1000)
        let uncertainty = delayMs/2 + max(0,rootDelay)/2 + dispersion + precision + anchorUncertaintyMs
        guard uncertainty <= 100 else { try reject("估计校时不确定度超过 100 毫秒") }
        let offset = ((t2-sendEpoch)+(t3-virtualReceive))/2
        return NTPSample(server:server,address:address,version:version,stratum:stratum,leapIndicator:leap,
                         offsetMs:offset*1000,roundTripMs:delayMs,rootDelayMs:rootDelay,
                         rootDispersionMs:dispersion,precisionMs:precision,estimatedUncertaintyMs:uncertainty,
                         localSendEpoch:sendEpoch,localReceiveEpoch:receiveEpoch,serverReceiveEpoch:t2,
                         serverTransmitEpoch:t3,receiveMonoNs:receiveMonoNs,utcEpochAtReceive:virtualReceive+offset)
    }
}

enum NTPClient {
    static let defaultServers = ["ntp.aliyun.com", "time.cloudflare.com", "time.apple.com"]
    private final class RoundResults: @unchecked Sendable {
        private let lock = NSLock()
        private var samples = [NTPSample](), failures = [String]()
        private var completedServers = Set<String>()
        private var accepting = true
        var isAccepting: Bool {
            lock.lock(); defer { lock.unlock() }; return accepting
        }
        func publish(server: String, samples: [NTPSample], failures: [String]) {
            lock.lock(); defer { lock.unlock() }
            // DNS can outlive the total deadline. A late worker cannot mutate
            // the frozen return value or publish into a later calibration round.
            guard accepting else { return }
            self.samples.append(contentsOf:samples)
            self.failures.append(contentsOf:failures)
            completedServers.insert(server)
        }
        func freeze(servers: [String]) -> (samples: [NTPSample], failures: [String]) {
            lock.lock(); defer { lock.unlock() }
            accepting = false
            let timedOut = servers.filter { !completedServers.contains($0) }
            return (samples, failures + timedOut.map {
                "\($0)：本轮授时超过 10 秒总时限（可能 DNS 或 UDP 查询阻塞）"
            })
        }
    }
    static func synchronize(servers: [String] = defaultServers, samplesPerServer: Int = 3,
                            timeoutSeconds: Double = 1.2) throws -> NetworkTimeCalibration {
        guard (2...8).contains(samplesPerServer), (0.1...3).contains(timeoutSeconds),
              !servers.isEmpty, servers.count <= 8, Set(servers).count == servers.count else {
            throw NetworkTimeError.invalid("NTP 查询参数无效")
        }
        let results = RoundResults(), group = DispatchGroup()
        let overallDeadline = DispatchTime.now() + 10
        for server in servers {
            group.enter()
            DispatchQueue.global(qos:.userInitiated).async {
                defer { group.leave() }
                var local = [NTPSample](), errors = [String]()
                for i in 0..<samplesPerServer {
                    guard results.isAccepting else { return }
                    do { local.append(try query(server:server,timeoutSeconds:timeoutSeconds)) }
                    catch { errors.append(error.localizedDescription) }
                    if i+1 < samplesPerServer { Thread.sleep(forTimeInterval:0.25) }
                }
                results.publish(server:server,samples:local,failures:errors)
            }
        }
        // getaddrinfo has no portable per-call deadline; bound the entire round,
        // including DNS, and use only complete sources available at this point.
        _ = group.wait(timeout:overallDeadline)
        let completed = results.freeze(servers:servers)
        let anchor = PrecisionClock.anchor()
        return try select(samples:completed.samples, failures:completed.failures,
                          nowMonoNs:anchor.monoNs, nowWallEpoch:anchor.wall)
    }

    static func select(samples: [NTPSample], failures: [String] = [], nowMonoNs: UInt64,
                       nowWallEpoch: Double) throws -> NetworkTimeCalibration {
        let grouped = Dictionary(grouping:samples,by: { $0.server })
        func projectedEpoch(_ sample: NTPSample) -> Double {
            sample.utcEpochAtReceive + (Double(nowMonoNs)-Double(sample.receiveMonoNs))/1e9
        }
        func distance(_ sample: NTPSample) -> Double {
            sample.estimatedUncertaintyMs + max(0,(Double(nowMonoNs)-Double(sample.receiveMonoNs))/1e9)*0.05
        }
        let best = grouped.values.compactMap { values -> NTPSample? in
            guard values.count >= 2 else { return nil }
            // A lowest-RTT outlier must not win over two mutually consistent rounds.
            var ranked = [(sample: NTPSample, count: Int)]()
            for candidate in values {
                var agreeing = 0
                let candidateEpoch = projectedEpoch(candidate)
                let candidateDistance = distance(candidate)
                for other in values {
                    let separation = abs(projectedEpoch(other)-candidateEpoch)*1000
                    if separation <= distance(other)+candidateDistance { agreeing += 1 }
                }
                if agreeing >= values.count/2+1 { ranked.append((candidate,agreeing)) }
            }
            ranked.sort { left, right in
                if left.count != right.count { return left.count > right.count }
                return left.sample.roundTripMs < right.sample.roundTripMs
            }
            return ranked.first?.sample
        }.sorted(by:{ $0.server < $1.server })
        guard !best.isEmpty else {
            throw NetworkTimeError.invalid("NTP 授时失败：每个来源至少需要两条有效响应。请检查 UDP 123 网络连通性。" + (failures.first.map { " 首个错误：\($0)" } ?? ""))
        }
        let projected = best.map { projectedEpoch($0) }
        var chosen = [Int](), bestWidth = Double.infinity
        // Majority interval intersection. For the default three independent providers,
        // two agreeing providers may reject one outlier; two conflicting providers fail.
        let minimum = best.count == 1 ? 1 : best.count/2+1
        for mask in 1..<(1 << best.count) {
            let indices = best.indices.filter { mask & (1 << $0) != 0 }
            guard indices.count >= minimum else { continue }
            let lower = indices.map { projected[$0]-distance(best[$0])/1000 }.max()!
            let upper = indices.map { projected[$0]+distance(best[$0])/1000 }.min()!
            guard lower <= upper else { continue }
            let width = upper-lower
            if indices.count > chosen.count || (indices.count == chosen.count && width < bestWidth) {
                chosen = indices; bestWidth = width
            }
        }
        guard !chosen.isEmpty else { throw NetworkTimeError.invalid("NTP 各来源时间不一致，无法可靠校准；请换网络后重试。") }
        let primary = chosen.min { best[$0].estimatedUncertaintyMs < best[$1].estimatedUncertaintyMs }!
        let epoch = projected[primary]
        let spreadMs = chosen.map { abs(projected[$0]-epoch)*1000 }.max() ?? 0
        // Keep the selected source's distance and add observed cross-source disagreement.
        // These remain estimates, because NTP is not a proof of symmetric network paths.
        let uncertainty = distance(best[primary]) + spreadMs
        guard uncertainty <= 100 else { throw NetworkTimeError.invalid("NTP 来源分歧使估计校时不确定度超过 100 毫秒。") }
        let chosenServers = chosen.map { best[$0].server }
        let snapshot = NetworkTimeSnapshot(referenceEpoch:epoch,referenceMonoNs:nowMonoNs,
             systemWallEpochAtAnchor:nowWallEpoch,offsetMs:(epoch-nowWallEpoch)*1000,
             selectedServers:chosenServers,crossChecked:chosen.count >= 2,roundTripMs:best[primary].roundTripMs,
             baseUncertaintyMs:uncertainty,validitySeconds:120,driftPPM:50,
             measurementNote:"普通 NTP（非 NTS）；不确定度含 RTT/2、服务器根延迟/离散度、精度、来源分歧及假定 50 ppm 本机漂移，属于估计而非准确度保证。")
        return NetworkTimeCalibration(snapshot:snapshot,samples:samples,failures:failures,
               rejectedServers:grouped.keys.filter { !chosenServers.contains($0) }.sorted())
    }

    static func query(server: String, timeoutSeconds: Double) throws -> NTPSample {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_DGRAM; hints.ai_protocol = IPPROTO_UDP
        var addresses: UnsafeMutablePointer<addrinfo>?
        let dns = getaddrinfo(server,"123",&hints,&addresses)
        guard dns == 0, let first = addresses else { throw NetworkTimeError.invalid("\(server)：DNS 解析失败（\(dns)）") }
        defer { freeaddrinfo(first) }
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        var lastError = "无法建立 UDP 查询"
        // Limit address attempts to keep an IPv6-blackholed host from stalling the UI worker.
        var attempts = 0
        while let current = pointer, attempts < 2 {
            pointer = current.pointee.ai_next; attempts += 1
            let info = current.pointee
            let fd = socket(info.ai_family,info.ai_socktype,info.ai_protocol)
            guard fd >= 0 else { lastError = "创建 UDP socket 失败"; continue }
            defer { close(fd) }
            guard connect(fd,info.ai_addr,info.ai_addrlen) == 0 else { lastError = "UDP 连接失败"; continue }
            var numeric = [CChar](repeating:0,count:Int(NI_MAXHOST))
            getnameinfo(info.ai_addr,info.ai_addrlen,&numeric,socklen_t(numeric.count),nil,0,NI_NUMERICHOST)
            let address = String(cString:numeric)
            let anchor = PrecisionClock.anchor()
            let bytes = NTPPacket.request(epoch:anchor.wall)
            let sent = bytes.withUnsafeBytes { Darwin.send(fd,$0.baseAddress,$0.count,0) }
            guard sent == bytes.count else { lastError = "UDP 发包失败"; continue }
            var poller = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            let ready = poll(&poller,1,Int32(timeoutSeconds*1000))
            guard ready > 0, poller.revents & Int16(POLLIN) != 0 else { lastError = "UDP 123 超时或被网络拦截"; continue }
            var response = [UInt8](repeating:0,count:512)
            let count = response.withUnsafeMutableBytes { Darwin.recv(fd,$0.baseAddress,$0.count,0) }
            let receivedMono = PrecisionClock.nowNs(), receivedWall = PrecisionClock.wallNow()
            guard count >= 48 else { lastError = "UDP 响应无效"; continue }
            return try NTPPacket.parse(Array(response.prefix(count)),request:bytes,server:server,address:address,
                         sendEpoch:anchor.wall,receiveEpoch:receivedWall,sendMonoNs:anchor.monoNs,
                         receiveMonoNs:receivedMono,anchorUncertaintyMs:Double(anchor.uncertaintyNs)/1e6)
        }
        throw NetworkTimeError.invalid("\(server)：\(lastError)")
    }
}
