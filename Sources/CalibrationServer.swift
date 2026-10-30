import Foundation
import Network
import CoreFoundation
import Darwin

/// A small, explicitly started LAN service used only by the phone calibration page.
/// It never sends clicks; the caller uploads actual mouse-up timestamps separately.
enum CalibrationServerError: LocalizedError {
    case invalid(String)
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .invalid(let text), .unavailable(let text): return text }
    }
}

private func calibrationEpochMs() -> Double { Date().timeIntervalSince1970 * 1000 }
private let calibrationNull = NSNull()

/// A frozen UTC anchor supplied by the native NTP client. Nanoseconds use the
/// same mach_absolute_time conversion as PrecisionClock, without making this
/// standalone HTTP service depend on the mouse scheduler.
struct CalibrationTimeReference: Equatable {
    let id: String
    let epochMs: Double
    let monoNs: UInt64
    let uncertaintyMs: Double
    let validityMs: Double
    let driftPPM: Double
    let source: String
}

struct CalibrationClockReading {
    let epochMs: Double
    let clockId: String
    let timeBasis: String
    let fresh: Bool
    let uncertaintyMs: Double?
    let source: String
    let validUntilMs: Double?
    let driftPPM: Double?
    var metadata: [String: Any] {
        ["nowMs": epochMs, "clockId": clockId, "timeBasis": timeBasis,
         "clockFresh": fresh, "ntpEstimatedUncertaintyMs": uncertaintyMs as Any? ?? calibrationNull,
         "source": source, "clockValidUntilMs": validUntilMs as Any? ?? calibrationNull,
         "ntpDriftPPM": driftPPM as Any? ?? calibrationNull]
    }
}

final class CalibrationClockSource {
    private let lock = NSLock()
    private let rawId = "raw-" + UUID().uuidString
    private var reference: CalibrationTimeReference?
    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t(); mach_timebase_info(&value); return value
    }()
    static func nowNs() -> UInt64 {
        UInt64(Double(mach_absolute_time()) * Double(timebase.numer) / Double(timebase.denom))
    }
    func use(_ value: CalibrationTimeReference?) throws {
        if let value {
            guard !value.id.isEmpty, value.id.unicodeScalars.count <= 128,
                  value.epochMs.isFinite, value.epochMs > 0,
                  value.uncertaintyMs.isFinite, (0...100).contains(value.uncertaintyMs),
                  value.validityMs.isFinite, (0...600_000).contains(value.validityMs), value.validityMs > 0,
                  value.driftPPM.isFinite, (0...1000).contains(value.driftPPM),
                  !value.source.isEmpty, value.source.unicodeScalars.count <= 1024,
                  value.monoNs <= Self.nowNs() else {
                throw CalibrationServerError.invalid("NTP 校时参考无效、精度不合格或锚点在未来")
            }
        }
        lock.lock(); defer { lock.unlock() }
        if let old = reference, let value, old.id == value.id, old != value {
            throw CalibrationServerError.invalid("同一 clockId 不能更换 NTP 校时参考")
        }
        reference = value
    }
    func reading(atMonoNs mono: UInt64 = CalibrationClockSource.nowNs()) -> CalibrationClockReading {
        lock.lock(); let reference = self.reference; lock.unlock()
        guard let reference else {
            return CalibrationClockReading(epochMs: calibrationEpochMs(), clockId: rawId,
                timeBasis: "raw-system", fresh: true, uncertaintyMs: nil, source: "Mac 本机时钟", validUntilMs: nil, driftPPM: nil)
        }
        let age = (Double(mono)-Double(reference.monoNs))/1e6
        let uncertainty = reference.uncertaintyMs + max(0, age)*reference.driftPPM/1e6
        let precisionAge = reference.driftPPM > 0 ? (100-reference.uncertaintyMs)*1e6/reference.driftPPM : reference.validityMs
        return CalibrationClockReading(epochMs: reference.epochMs+age, clockId: reference.id,
            timeBasis: "ntp-utc", fresh: age >= 0 && age <= reference.validityMs && uncertainty <= 100,
            uncertaintyMs: uncertainty, source: reference.source,
            validUntilMs: reference.epochMs+min(reference.validityMs, precisionAge), driftPPM: reference.driftPPM)
    }
    /// Validate the event's time, rather than upload time. A delayed report must
    /// not turn transport back to the Mac into part of the measured click delay.
    func acceptsEvent(epochMs: Double, clockId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let reference else { return clockId == rawId }
        let age = epochMs-reference.epochMs
        return reference.id == clockId && age >= 0 && age <= reference.validityMs &&
            reference.uncertaintyMs+age*reference.driftPPM/1e6 <= 100
    }
}

private func calibrationNumber(_ value: Any?, _ name: String) throws -> Double {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
        throw CalibrationServerError.invalid("\(name) 必须是有限数值")
    }
    return number.doubleValue
}

private func calibrationInteger(_ value: Any?, _ name: String, _ range: ClosedRange<Int>) throws -> Int {
    let number = try calibrationNumber(value, name)
    guard number.rounded(.towardZero) == number,
          number >= Double(range.lowerBound), number <= Double(range.upperBound) else {
        throw CalibrationServerError.invalid("\(name) 越界或不是整数")
    }
    return Int(number)
}

private func calibrationValidateJSON(_ value: Any) throws {
    if let number = value as? NSNumber {
        guard CFGetTypeID(number) == CFBooleanGetTypeID() || number.doubleValue.isFinite else {
            throw CalibrationServerError.invalid("JSON 数值必须有限")
        }
    } else if let values = value as? [Any] {
        for item in values { try calibrationValidateJSON(item) }
    } else if let object = value as? [String: Any] {
        for item in object.values { try calibrationValidateJSON(item) }
    }
}

private func calibrationPercentile(_ values: [Double], _ percentile: Double) -> Any {
    guard !values.isEmpty else { return calibrationNull }
    let ordered = values.sorted(), position = Double(values.count - 1) * percentile
    let lower = Int(floor(position)), upper = Int(ceil(position)), fraction = position - floor(position)
    // Weighted interpolation avoids overflow in (upper - lower) for large finite inputs.
    return ordered[lower] * (1 - fraction) + ordered[upper] * fraction
}

/// State methods are locked, validate a complete batch before committing it, and save atomically.
final class CalibrationState {
    private struct Storage {
        var plan: [String: Any] = ["runId": "", "targetsMs": [Double](), "compensationMs": 0,
                                   "label": "尚未收到测试计划"]
        var samples: [Int: [String: Any]] = [:]
        var stray: [[String: Any]] = []
        var sends: [Int: Double] = [:]
        var clock: [String: Any] = [:]
    }
    private let lock = NSLock()
    private var storage = Storage()
    private let reportURL: URL
    private let clockSource: CalibrationClockSource

    init(reportURL: URL, clockSource: CalibrationClockSource = CalibrationClockSource()) {
        self.reportURL = reportURL; self.clockSource = clockSource
    }

    private func locked<T>(_ action: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try action()
    }
    func planSnapshot() -> [String: Any] { locked {
        var plan = storage.plan
        let reading = clockSource.reading()
        plan["clockFresh"] = reading.fresh && reading.clockId == plan["clockId"] as? String
        return plan
    } }
    func summary() -> [String: Any] { locked { Self.summary(storage, reading: clockSource.reading()) } }
    func reportSnapshot() -> [String: Any] { locked { Self.report(storage, includeSends: false, reading: clockSource.reading()) } }

    private static func targets(_ value: Storage) -> [Double] { value.plan["targetsMs"] as! [Double] }
    private static func compensation(_ value: Storage) -> Double { (value.plan["compensationMs"] as? Double) ?? 0 }
    private func verifyRun(_ body: [String: Any], _ value: Storage) throws {
        guard let run = body["runId"] as? String, !run.isEmpty, run == value.plan["runId"] as? String else {
            throw CalibrationServerError.invalid("测试计划已改变，runId 不匹配，请刷新手机页面")
        }
        let current = clockSource.reading()
        guard current.clockId == value.plan["clockId"] as? String,
              current.timeBasis == value.plan["timeBasis"] as? String else {
            throw CalibrationServerError.invalid("校时时间基准已改变，请刷新计划并重新校时")
        }
        if value.plan["timeBasis"] as? String == "ntp-utc" {
            guard body["clockId"] as? String == current.clockId else {
                throw CalibrationServerError.invalid("NTP 回执缺少匹配的 clockId，不能混用旧时钟")
            }
        } else if let id = body["clockId"] as? String, id != current.clockId {
            throw CalibrationServerError.invalid("回执 clockId 与当前校时不匹配")
        }
        if let basis = body["timeBasis"] as? String, basis != current.timeBasis {
            throw CalibrationServerError.invalid("回执 timeBasis 与当前校时不匹配")
        }
    }
    private static func rows(_ value: Storage) -> [[String: Any]] {
        value.samples.keys.sorted().map { index in
            var row = value.samples[index]!
            let target = targets(value)[index - 1], received = row["receivedMacMs"] as! Double
            row["targetMs"] = target
            row["errorMs"] = received - target
            row["estimatedLatencyMs"] = received - target + compensation(value)
            if let sent = value.sends[index] { row["sentUpMs"] = sent; row["latencyMs"] = received - sent }
            return row
        }
    }
    private static func summary(_ value: Storage, reading: CalibrationClockReading) -> [String: Any] {
        let rows = rows(value), errors = rows.map { $0["errorMs"] as! Double }
        let latencies = rows.compactMap { $0["latencyMs"] as? Double }
        let sameBasis = reading.clockId == value.plan["clockId"] as? String
        let age = sameBasis ? (value.clock["calibratedAtMacMs"] as? Double).map { max(0, reading.epochMs - $0) } : nil
        let lastIndex = rows.last?["index"] as? Int ?? value.sends.keys.max() ?? 1
        let measuredAt = rows.last?["receivedMacMs"] as? Double ?? (sameBasis ? reading.epochMs : value.plan["createdAtMs"] as? Double ?? 0)
        let elapsed = max(0, measuredAt-(value.plan["createdAtMs"] as? Double ?? measuredAt))
        let ntpUncertainty = (value.plan["ntpEstimatedUncertaintyMs"] as? Double).map {
            $0+elapsed*(value.plan["ntpDriftPPM"] as? Double ?? 0)/1e6
        }
        let lanUncertainty = value.clock["uncertaintyEstimateMs"] as? Double
        var result: [String: Any] = ["runId": value.plan["runId"]!, "sampleCount": rows.count,
                "plannedCount": targets(value).count, "matchedSendCount": latencies.count,
                "strayCount": value.stray.count, "missingCount": max(0, targets(value).count - rows.count),
                "clockUncertaintyEstimateMs": value.clock["uncertaintyEstimateMs"] ?? calibrationNull,
                "clockRttMs": value.clock["rttMs"] ?? calibrationNull,
                "clockAgeMs": age as Any? ?? calibrationNull,
                "clockFresh": (age.map { $0 <= 60_000 } ?? false) && reading.fresh,
                "medianLatencyMs": calibrationPercentile(latencies, 0.5),
                "p95LatencyMs": calibrationPercentile(latencies, 0.95),
                "p50ErrorMs": calibrationPercentile(errors, 0.5),
                "p95AbsErrorMs": calibrationPercentile(errors.map(abs), 0.95),
                "maxAbsErrorMs": errors.map(abs).max() as Any? ?? calibrationNull,
                "estimatedMedianLatencyMs": calibrationPercentile(rows.map { $0["estimatedLatencyMs"] as! Double }, 0.5),
                "compensationMs": compensation(value), "clock": value.clock,
                "clockId": value.plan["clockId"] ?? calibrationNull,
                "timeBasis": value.plan["timeBasis"] ?? "raw-system",
                "source": value.plan["source"] ?? "Mac 本机时钟",
                "ntpEstimatedUncertaintyMs": ntpUncertainty as Any? ?? calibrationNull,
                "totalUncertaintyEstimateMs": ntpUncertainty.flatMap { n in lanUncertainty.map { $0+n } } as Any? ?? calibrationNull,
                "latestTargetMs": targets(value).indices.contains(lastIndex-1) ? targets(value)[lastIndex-1] as Any : calibrationNull,
                "latestSentUpMs": value.sends[lastIndex] as Any? ?? calibrationNull,
                "latestReceivedMs": rows.last?["receivedMacMs"] ?? calibrationNull,
                "measurementBoundary": "Mac CGEvent mouseUp 发送到手机 Safari pointerup 回调；不是大麦或券商业务回执",
                "clockCaveat": "RTT/2只作网络对称假设下的校时不确定度估计，不是准确度保证。",
                "updatedAtMs": reading.epochMs]
        result["ntpClockFresh"] = sameBasis && reading.timeBasis == "ntp-utc" && reading.fresh
        // The validity of a captured event survives a later clock expiry or a
        // new test. It was checked against the frozen anchor and phone sync at
        // commit, rather than inferred from today's clock configuration.
        result["samplesClockValidAtEvent"] = value.plan["timeBasis"] as? String == "ntp-utc" &&
            !rows.isEmpty && rows.allSatisfy { $0["clockValidAtEvent"] as? Bool == true }
        return result
    }
    private static func report(_ value: Storage, includeSends: Bool, reading: CalibrationClockReading) -> [String: Any] {
        var result: [String: Any] = ["plan": value.plan, "summary": summary(value, reading: reading),
                                    "samples": rows(value), "straySamples": value.stray]
        if includeSends {
            result["version"] = 1
            result["sendEvents"] = Dictionary(uniqueKeysWithValues: value.sends.map { (String($0.key), $0.value) })
        }
        return result
    }
    private func commit(_ candidate: Storage) throws {
        let payload = Self.report(candidate, includeSends: true, reading: clockSource.reading())
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw CalibrationServerError.invalid("计算结果超出有限数值范围")
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: reportURL, options: .atomic)
        storage = candidate
    }

    func setPlan(_ body: [String: Any]) throws -> [String: Any] {
        try locked {
            try calibrationValidateJSON(body)
            guard let run = body["runId"] as? String, !run.isEmpty, run.unicodeScalars.count <= 128 else {
                throw CalibrationServerError.invalid("runId 需要是非空字符串，最长128字符")
            }
            guard let rawTargets = body["targetsMs"] as? [Any], (1...10_000).contains(rawTargets.count) else {
                throw CalibrationServerError.invalid("targetsMs 需要包含1到10000个目标时间")
            }
            let targets = try rawTargets.map { try calibrationNumber($0, "targetMs") }
            guard zip(targets, targets.dropFirst()).allSatisfy({ $1 > $0 }) else {
                throw CalibrationServerError.invalid("目标时间必须严格递增")
            }
            let compensation = try calibrationNumber(body["compensationMs"] ?? 0, "compensationMs")
            var latency: Any = calibrationNull
            if let raw = body["expectedLatencyMs"], !(raw is NSNull) {
                latency = try calibrationNumber(raw, "expectedLatencyMs")
            }
            if let label = body["label"], !(label is String) { throw CalibrationServerError.invalid("label 必须是字符串") }
            let clock = clockSource.reading()
            if clock.timeBasis == "ntp-utc" {
                guard clock.fresh, body["clockId"] as? String == clock.clockId,
                      body["timeBasis"] as? String == clock.timeBasis else {
                    throw CalibrationServerError.invalid("NTP 计划缺少有效的同源 clockId/timeBasis，请重新授时")
                }
                guard targets.allSatisfy({ clockSource.acceptsEvent(epochMs: $0, clockId: clock.clockId) }) else {
                    throw CalibrationServerError.invalid("NTP 目标时间超出本轮授时有效区间")
                }
            } else {
                if let id = body["clockId"] as? String, id != clock.clockId {
                    throw CalibrationServerError.invalid("计划 clockId 与当前时钟不匹配")
                }
                if let basis = body["timeBasis"] as? String, basis != clock.timeBasis {
                    throw CalibrationServerError.invalid("计划 timeBasis 与当前时钟不匹配")
                }
            }
            var candidate = Storage()
            candidate.plan = ["runId": run, "targetsMs": targets, "compensationMs": compensation,
                              "expectedLatencyMs": latency, "label": String((body["label"] as? String ?? "镜像路径测试").prefix(160)),
                              "createdAtMs": clock.epochMs, "clockId": clock.clockId, "timeBasis": clock.timeBasis,
                              "source": clock.source, "ntpEstimatedUncertaintyMs": clock.uncertaintyMs as Any? ?? calibrationNull,
                              "clockValidUntilMs": clock.validUntilMs as Any? ?? calibrationNull,
                              "ntpDriftPPM": clock.driftPPM as Any? ?? calibrationNull]
            try commit(candidate)
            return candidate.plan
        }
    }

    private static func cleanSample(_ sample: [String: Any], index: Int? = nil) throws -> [String: Any] {
        var clean: [String: Any] = ["receivedMacMs": try calibrationNumber(sample["receivedMacMs"], "receivedMacMs")]
        if let index { clean["index"] = index }
        for key in ["phonePerfMs", "offsetMs", "rttMs", "uncertaintyEstimateMs"] where sample[key] != nil {
            let number = try calibrationNumber(sample[key], key)
            if ["rttMs", "uncertaintyEstimateMs"].contains(key), number < 0 {
                throw CalibrationServerError.invalid("\(key) 不能为负数")
            }
            clean[key] = number
        }
        for key in ["eventType", "reason"] where sample[key] != nil {
            guard let text = sample[key] as? String else { throw CalibrationServerError.invalid("\(key) 必须是字符串") }
            clean[key] = String(text.prefix(200))
        }
        return clean
    }

    func ingestSamples(_ body: [String: Any]) throws -> [String: Any] {
        try locked {
            try calibrationValidateJSON(body); try verifyRun(body, storage)
            guard let samples = (body["samples"] ?? [Any]()) as? [Any], samples.count <= 10_000,
                  let stray = (body["straySamples"] ?? [Any]()) as? [Any], stray.count <= 10_000 else {
                throw CalibrationServerError.invalid("samples 或 straySamples 格式无效")
            }
            var candidate = storage
            if storage.plan["timeBasis"] as? String == "ntp-utc" {
                guard let clock = body["clock"] as? [String: Any],
                      clock["clockId"] as? String == storage.plan["clockId"] as? String,
                      clock["timeBasis"] as? String == "ntp-utc" else {
                    throw CalibrationServerError.invalid("NTP 手机样本未绑定本轮校时时钟")
                }
            }
            for raw in samples {
                guard let sample = raw as? [String: Any] else { throw CalibrationServerError.invalid("sample 格式无效") }
                let index = try calibrationInteger(sample["index"], "sample index", 1...Self.targets(candidate).count)
                let clean = try Self.cleanSample(sample, index: index)
                try validateEvent(clean["receivedMacMs"] as! Double, in: storage)
                candidate.samples[index] = clean
            }
            candidate.stray = try stray.map {
                guard let sample = $0 as? [String: Any] else { throw CalibrationServerError.invalid("stray sample 格式无效") }
                let clean = try Self.cleanSample(sample)
                try validateEvent(clean["receivedMacMs"] as! Double, in: storage)
                return clean
            }
            if let rawClock = body["clock"], !(rawClock is NSNull) {
                guard let clock = rawClock as? [String: Any] else { throw CalibrationServerError.invalid("clock 格式无效") }
                var clean: [String: Any] = [:]
                for key in ["offsetMs", "rttMs", "uncertaintyEstimateMs", "calibratedAtMacMs", "ageMs"] where clock[key] != nil {
                    let number = try calibrationNumber(clock[key], key)
                    if ["rttMs", "uncertaintyEstimateMs", "ageMs"].contains(key), number < 0 {
                        throw CalibrationServerError.invalid("\(key) 不能为负数")
                    }
                    clean[key] = number
                }
                if let rounds = clock["rounds"] { clean["rounds"] = try calibrationInteger(rounds, "rounds", 0...10_000) }
                for key in ["clockId", "timeBasis"] where clock[key] != nil {
                    guard let text = clock[key] as? String, text.unicodeScalars.count <= 128 else {
                        throw CalibrationServerError.invalid("\(key) 格式无效")
                    }
                    guard text == storage.plan[key] as? String else {
                        throw CalibrationServerError.invalid("手机校时 \(key) 不匹配")
                    }
                    clean[key] = text
                }
                if storage.plan["timeBasis"] as? String == "ntp-utc" {
                    guard let calibrated = clean["calibratedAtMacMs"] as? Double,
                          clean["uncertaintyEstimateMs"] is Double,
                          candidate.samples.values.allSatisfy({ sample in
                              let age = (sample["receivedMacMs"] as! Double)-calibrated
                              return age >= 0 && age <= 60_000
                          }) else {
                        throw CalibrationServerError.invalid("手机样本未使用有效的60秒内校时，需重新测试")
                    }
                    for index in candidate.samples.keys {
                        candidate.samples[index]?["clockValidAtEvent"] = true
                        candidate.samples[index]?["clockId"] = storage.plan["clockId"]
                        candidate.samples[index]?["timeBasis"] = "ntp-utc"
                        candidate.samples[index]?["phoneCalibratedAtMs"] = calibrated
                    }
                }
                candidate.clock = clean
            }
            try commit(candidate)
            return Self.summary(candidate, reading: clockSource.reading())
        }
    }

    func ingestSends(_ body: [String: Any]) throws -> [String: Any] {
        try locked {
            try calibrationValidateJSON(body); try verifyRun(body, storage)
            guard let events = body["events"] as? [Any], events.count <= 10_000 else {
                throw CalibrationServerError.invalid("events 格式无效")
            }
            var candidate = storage
            for raw in events {
                guard let event = raw as? [String: Any] else { throw CalibrationServerError.invalid("event 格式无效") }
                let index = try calibrationInteger(event["index"], "event index", 1...Self.targets(candidate).count)
                let sent = try calibrationNumber(event["sentUpMs"], "sentUpMs")
                try validateEvent(sent, in: storage)
                candidate.sends[index] = sent
            }
            try commit(candidate)
            return Self.summary(candidate, reading: clockSource.reading())
        }
    }
    private func validateEvent(_ epochMs: Double, in storage: Storage) throws {
        if storage.plan["timeBasis"] as? String == "ntp-utc",
           !clockSource.acceptsEvent(epochMs: epochMs, clockId: storage.plan["clockId"] as? String ?? "") {
            throw CalibrationServerError.invalid("事件超出本轮 NTP 授时有效区间，不能作为到点校验")
        }
    }
}

final class CalibrationHTTPServer {
    private let port: UInt16
    private let indexData: Data
    private let state: CalibrationState
    private let clockSource: CalibrationClockSource
    private let queue = DispatchQueue(label: "cn.punctualclicker.calibration.network", qos: .userInitiated)
    private let workQueue = DispatchQueue(label: "cn.punctualclicker.calibration.storage", qos: .utility)
    private let statusLock = NSLock()
    private var running = false
    private var actualPort: UInt16?
    private var listener: NWListener?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var connections: [UUID: CalibrationHTTPConnection] = [:]
    private var generation = UUID()
    var isRunning: Bool { statusLock.lock(); defer { statusLock.unlock() }; return running }
    var boundPort: UInt16? { statusLock.lock(); defer { statusLock.unlock() }; return actualPort }
    var clockMetadata: [String: Any] { clockSource.reading().metadata }
    func useTimeReference(_ reference: CalibrationTimeReference?) throws { try clockSource.use(reference) }

    init(port: Int = 18765, resourceRoot: URL, reports: URL) throws {
        guard (0...65535).contains(port) else { throw CalibrationServerError.invalid("校准服务端口无效") }
        self.port = UInt16(port)
        self.indexData = try Data(contentsOf: resourceRoot.appendingPathComponent("index.html"))
        let source = CalibrationClockSource(); self.clockSource = source
        self.state = CalibrationState(reportURL: reports.appendingPathComponent("phone-calibration.json"), clockSource: source)
    }

    /// Completion is always delivered on the main queue, after ready or a concrete failure.
    func start(_ callback: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            guard listener == nil else {
                DispatchQueue.main.async { callback(.failure(CalibrationServerError.unavailable("校准服务已经启动或正在启动"))) }
                return
            }
            let token = UUID(); generation = token; completion = callback
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = false
                let newListener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
                listener = newListener
                newListener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.generation == token, self.listener != nil else { connection.cancel(); return }
                    let identifier = UUID()
                    let session = CalibrationHTTPConnection(connection: connection, queue: self.queue,
                        clock: { [clockSource = self.clockSource] in clockSource.reading() },
                        handler: { [weak self] request, respond in self?.handle(request, respond: respond) },
                        finished: { [weak self] in self?.connections.removeValue(forKey: identifier) })
                    self.connections[identifier] = session
                    session.start()
                }
                newListener.stateUpdateHandler = { [weak self, weak newListener] update in
                    guard let self, self.generation == token, self.listener === newListener else { return }
                    switch update {
                    case .ready:
                        self.setStatus(true, newListener?.port?.rawValue)
                        self.finishStart(.success(()))
                    case .failed(let error): self.fail(error)
                    case .cancelled: self.setStatus(false, nil)
                    default: break
                    }
                }
                newListener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.generation == token, self.completion != nil else { return }
                    self.fail(CalibrationServerError.unavailable("校准服务启动超时，请检查端口或网络权限"))
                }
            } catch { fail(error) }
        }
    }
    func stop() {
        queue.async { [self] in
            generation = UUID()
            listener?.cancel(); listener = nil
            for session in Array(connections.values) { session.cancel() }
            connections.removeAll(); setStatus(false, nil)
            finishStart(.failure(CalibrationServerError.unavailable("校准服务已停止")))
        }
    }
    private func setStatus(_ value: Bool, _ port: UInt16?) {
        statusLock.lock(); running = value; actualPort = port; statusLock.unlock()
    }
    private func finishStart(_ result: Result<Void, Error>) {
        guard let callback = completion else { return }; completion = nil
        DispatchQueue.main.async { callback(result) }
    }
    private func fail(_ error: Error) {
        listener?.cancel(); listener = nil
        for session in Array(connections.values) { session.cancel() }
        connections.removeAll(); setStatus(false, nil); finishStart(.failure(error))
    }

    private func handle(_ request: CalibrationHTTPRequest, respond: @escaping (CalibrationHTTPResponse) -> Void) {
        if request.method == "GET" {
            switch request.path {
            case "/time":
                let send = clockSource.reading()
                guard request.clockId == send.clockId, request.timeBasis == send.timeBasis else {
                    respond(.error(400, "请求过程中校时基准已改变，请重新校时")); return
                }
                guard send.fresh else { respond(.error(400, "NTP 校时参考已过期，请在 Mac 重新授时")); return }
                var value = send.metadata
                value["receiveMs"] = request.receivedMs; value["sendMs"] = send.epochMs
                respond(.json(value)); return
            case "/health": respond(.json(["ok": true, "service": "准点点击器手机校准", "version": 1])); return
            case "/": respond(CalibrationHTTPResponse(status: 200, mime: "text/html; charset=utf-8", data: indexData)); return
            default: break
            }
        }
        if request.method == "POST", !request.sameOrigin {
            respond(.error(403, "仅接受同源请求")); return
        }
        workQueue.async { [state] in
            do {
                var result: [String: Any]
                if request.method == "GET" {
                    switch request.path {
                    case "/plan": result = state.planSnapshot()
                    case "/summary": result = state.summary()
                    case "/report": result = state.reportSnapshot()
                    default: respond(.error(404, "not found")); return
                    }
                } else if request.method == "POST" {
                    guard !request.body.isEmpty else { respond(.error(400, "请求内容为空或过大")); return }
                    let object = try JSONSerialization.jsonObject(with: request.body)
                    guard let body = object as? [String: Any] else { respond(.error(400, "JSON需要是对象")); return }
                    switch request.path {
                    case "/test-plan": result = try state.setPlan(body)
                    case "/samples": result = try state.ingestSamples(body)
                    case "/send-events": result = try state.ingestSends(body)
                    default: respond(.error(404, "not found")); return
                    }
                } else { respond(.error(405, "method not allowed")); return }
                respond(.json(result))
            } catch let error as CalibrationServerError { respond(.error(400, error.localizedDescription)) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == 3840 {
                respond(.error(400, "JSON 格式无效或含非有限数值"))
            } catch { respond(.error(500, "无法保存校准报告，请检查本机报告目录权限")) }
        }
    }
}

private struct CalibrationHTTPRequest {
    let method: String
    let path: String
    let body: Data
    let receivedMs: Double
    let clockId: String
    let timeBasis: String
    let headers: [String: String]
    var sameOrigin: Bool {
        guard let origin = headers["origin"] else { return true } // Native Mac requests do not send Origin.
        guard let host = headers["host"], let source = URLComponents(string: origin),
              source.scheme?.lowercased() == "http", source.user == nil, source.password == nil,
              source.query == nil, source.fragment == nil, source.path.isEmpty,
              let sourceHost = source.host?.lowercased(),
              let destination = URLComponents(string: "http://" + host), destination.user == nil,
              destination.password == nil, destination.path.isEmpty, destination.query == nil,
              destination.fragment == nil, sourceHost == destination.host?.lowercased() else { return false }
        return (source.port ?? 80) == (destination.port ?? 80)
    }
}

private struct CalibrationHTTPResponse {
    let status: Int
    let mime: String
    let data: Data
    static func json(_ object: [String: Any], status: Int = 200) -> Self {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return .error(500, "计算结果无法编码")
        }
        return Self(status: status, mime: "application/json; charset=utf-8", data: data)
    }
    static func error(_ status: Int, _ message: String) -> Self { .json(["error": message], status: status) }
    var wireData: Data {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                      408: "Request Timeout", 413: "Payload Too Large", 431: "Request Header Fields Too Large", 500: "Internal Server Error"][status] ?? "Error"
        var output = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8)
        output.append(data); return output
    }
}

/// One bounded HTTP request per connection. Connection-close framing deliberately avoids
/// ambiguity around pipelining, Transfer-Encoding and partially received request bodies.
private final class CalibrationHTTPConnection {
    private static let maximumBody = 2 * 1024 * 1024
    private static let maximumHeader = 16 * 1024
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: (CalibrationHTTPRequest, @escaping (CalibrationHTTPResponse) -> Void) -> Void
    private let finished: () -> Void
    private let clock: () -> CalibrationClockReading
    private var buffer = Data()
    private var receivedClock: CalibrationClockReading?
    private var headerEnd: Int?
    private var contentLength = 0
    private var method = ""
    private var path = ""
    private var headers: [String: String] = [:]
    private var responding = false
    private var cancelled = false
    init(connection: NWConnection, queue: DispatchQueue,
         clock: @escaping () -> CalibrationClockReading,
         handler: @escaping (CalibrationHTTPRequest, @escaping (CalibrationHTTPResponse) -> Void) -> Void,
         finished: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.handler = handler; self.finished = finished; self.clock = clock
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] value in
            if case .failed = value { self?.cancel() }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.cancelled, !self.responding else { return }; self.send(.error(408, "请求超时"))
        }
        receive()
    }
    func cancel() {
        guard !cancelled else { return }; cancelled = true
        connection.stateUpdateHandler = nil; connection.cancel(); finished()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.cancelled, !self.responding else { return }
            if let data, !data.isEmpty {
                if self.receivedClock == nil { self.receivedClock = self.clock() }
                self.buffer.append(data)
                if self.parse() { return }
            }
            if error != nil { self.cancel(); return }
            if complete { self.send(.error(400, "请求内容未完整接收")); return }
            self.receive()
        }
    }
    @discardableResult private func parse() -> Bool {
        if headerEnd == nil {
            if let terminator = buffer.range(of: Data([13, 10, 13, 10])) {
                guard terminator.upperBound <= Self.maximumHeader else { send(.error(431, "请求头过大")); return true }
                let data = buffer[..<terminator.lowerBound]
                guard let text = String(data: data, encoding: .utf8) else { send(.error(400, "请求头格式无效")); return true }
                let lines = text.components(separatedBy: "\r\n")
                let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
                guard parts.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(String(parts[2])),
                      parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"), !parts[1].contains("#") else {
                    send(.error(400, "请求行格式无效")); return true
                }
                method = String(parts[0]); path = String(parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                          !line.hasPrefix(" "), !line.hasPrefix("\t") else { send(.error(400, "请求头格式无效")); return true }
                    let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    guard key.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }),
                          headers[key] == nil, !value.contains("\r"), !value.contains("\n") else {
                        send(.error(400, "重复或无效请求头")); return true
                    }
                    headers[key] = value
                }
                if parts[2] == "HTTP/1.1", headers["host"]?.isEmpty != false { send(.error(400, "缺少 Host")); return true }
                guard headers["transfer-encoding"] == nil else { send(.error(400, "不支持 Transfer-Encoding")); return true }
                if let raw = headers["content-length"] {
                    guard !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let count = Int(raw) else {
                        send(.error(400, "Content-Length 无效")); return true
                    }
                    guard count <= Self.maximumBody else { send(.error(413, "请求内容过大")); return true }
                    contentLength = count
                } else if method == "POST" { send(.error(400, "缺少 Content-Length")); return true }
                headerEnd = terminator.upperBound
            } else {
                if buffer.count > Self.maximumHeader { send(.error(431, "请求头过大")); return true }
                return false
            }
        }
        let end = headerEnd! + contentLength
        guard buffer.count >= end else { return false }
        guard buffer.count == end else { send(.error(400, "请求尾部存在额外内容")); return true }
        responding = true
        let received = receivedClock ?? clock()
        let request = CalibrationHTTPRequest(method: method, path: path, body: buffer.subdata(in: headerEnd!..<end),
                                            receivedMs: received.epochMs, clockId: received.clockId,
                                            timeBasis: received.timeBasis, headers: headers)
        buffer.removeAll(keepingCapacity: false)
        handler(request) { [weak self] response in
            guard let self else { return }; self.queue.async { self.send(response) }
        }
        return true
    }
    private func send(_ response: CalibrationHTTPResponse) {
        guard !cancelled else { return }; responding = true
        connection.send(content: response.wireData, completion: .contentProcessed { [weak self] _ in self?.cancel() })
    }
}
