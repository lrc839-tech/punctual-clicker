import Foundation
import Darwin

@main
enum NetworkTimeTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var passed = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description:message) }
    }
    static func check(_ name: String, _ block: () throws -> Void) throws {
        try block(); passed += 1; print("PASS \(name)")
    }
    static func rejects(_ block: () throws -> Void) throws {
        do { try block() } catch is NetworkTimeError { return }
        throw Failure(description:"应拒绝异常数据")
    }
    static let epoch = 1_793_000_000.0
    static func response(request:[UInt8], t2:Double, t3:Double) -> [UInt8] {
        var bytes = [UInt8](repeating:0,count:48)
        bytes[0] = 0x24; bytes[1] = 2; bytes[3] = UInt8(bitPattern:-20)
        NTPPacket.writeUInt32(UInt32(0.002*65536),to:&bytes,at:4)
        NTPPacket.writeUInt32(UInt32(0.001*65536),to:&bytes,at:8)
        bytes.replaceSubrange(24..<32,with:request[40..<48])
        bytes.replaceSubrange(32..<40,with:NTPPacket.timestampBytes(epoch:t2))
        bytes.replaceSubrange(40..<48,with:NTPPacket.timestampBytes(epoch:t3))
        return bytes
    }
    static func sample(_ response:[UInt8]? = nil, receiveWall:Double? = nil,
                       elapsed:Double = 0.022) throws -> NTPSample {
        let req = NTPPacket.request(epoch:epoch)
        return try NTPPacket.parse(response ?? self.response(request:req,t2:epoch+0.015,t3:epoch+0.017),
             request:req,server:"test",address:"127.0.0.1",sendEpoch:epoch,receiveEpoch:receiveWall ?? epoch+elapsed,
             sendMonoNs:1_000_000_000,receiveMonoNs:1_000_000_000+UInt64(elapsed*1e9))
    }
    static func synthetic(_ server:String, offsetMs:Double, uncertainty:Double = 10,
                          rtt:Double = 10, mono:UInt64 = 2_000_000_000) -> NTPSample {
        NTPSample(server:server,address:"127.0.0.1",version:4,stratum:2,leapIndicator:0,
            offsetMs:offsetMs,roundTripMs:rtt,rootDelayMs:2,rootDispersionMs:1,precisionMs:0.001,
            estimatedUncertaintyMs:uncertainty,localSendEpoch:epoch-0.01,localReceiveEpoch:epoch,
            serverReceiveEpoch:epoch+offsetMs/1000,serverTransmitEpoch:epoch+offsetMs/1000,
            receiveMonoNs:mono,utcEpochAtReceive:epoch+offsetMs/1000)
    }
    static func pair(_ server:String, offset:Double, uncertainty:Double = 10) -> [NTPSample] {
        [synthetic(server,offsetMs:offset,uncertainty:uncertainty,rtt:10),
         synthetic(server,offsetMs:offset+0.1,uncertainty:uncertainty,rtt:12)]
    }
    static func main() throws {
        if CommandLine.arguments.contains("--live") {
            let result = try NTPClient.synchronize()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            let data = try encoder.encode(result)
            if let i = CommandLine.arguments.firstIndex(of:"--report"), CommandLine.arguments.count > i+1 {
                try data.write(to:URL(fileURLWithPath:CommandLine.arguments[i+1]),options:.atomic)
            }
            print(String(data:data,encoding:.utf8)!)
            return
        }
        try check("NTP四时间戳公式、RTT和来源精度") {
            let value = try sample()
            try expect(abs(value.offsetMs-5)<0.002,"offset计算错误")
            try expect(abs(value.roundTripMs-20)<0.002,"RTT计算错误")
            try expect(value.estimatedUncertaintyMs >= 11.9,"未计入RTT和来源误差")
        }
        try check("2036翻转前后及下一era时间戳") {
            for epoch in [2_085_978_495.25,2_085_978_497.75,3_000_000_000.125] {
                let decoded = NTPPacket.timestamp(NTPPacket.timestampBytes(epoch:epoch),at:0,near:epoch+100)
                try expect(abs(decoded-epoch)<0.000002,"NTP era换算错误")
            }
        }
        try check("拒绝短包、错误模式版本和originate") {
            try rejects { _ = try sample([1,2,3]) }
            for header:UInt8 in [0x23,0x14] {
                var packet = response(request:NTPPacket.request(epoch:epoch),t2:epoch+0.015,t3:epoch+0.017)
                packet[0] = header
                try rejects { _ = try sample(packet) }
            }
            var packet = response(request:NTPPacket.request(epoch:epoch),t2:epoch+0.015,t3:epoch+0.017)
            packet[24] ^= 1
            try rejects { _ = try sample(packet) }
        }
        try check("拒绝未同步和KoD") {
            for header:UInt8 in [0xe4] {
                var packet = response(request:NTPPacket.request(epoch:epoch),t2:epoch+0.015,t3:epoch+0.017)
                packet[0] = header; try rejects { _ = try sample(packet) }
            }
            for level:UInt8 in [0,16,255] {
                var packet = response(request:NTPPacket.request(epoch:epoch),t2:epoch+0.015,t3:epoch+0.017)
                packet[1] = level; try rejects { _ = try sample(packet) }
            }
        }
        try check("闰秒整月预告可用，实际月末窗口拒绝") {
            var packet = response(request:NTPPacket.request(epoch:epoch),t2:epoch+0.015,t3:epoch+0.017)
            packet[0] = 0x64
            _ = try sample(packet)
            let nearLeap = 1_483_228_790.0 // 2016-12-31 23:59:50 UTC
            let request = NTPPacket.request(epoch:nearLeap)
            packet = response(request:request,t2:nearLeap+0.015,t3:nearLeap+0.017)
            packet[0] = 0x64
            try rejects {
                _ = try NTPPacket.parse(packet,request:request,server:"test",address:"127.0.0.1",sendEpoch:nearLeap,
                    receiveEpoch:nearLeap+0.022,sendMonoNs:1_000_000_000,receiveMonoNs:1_022_000_000)
            }
        }
        try check("拒绝系统跳时、过大RTT和负RTT") {
            try rejects { _ = try sample(receiveWall:epoch+1) }
            try rejects { _ = try sample(elapsed:0.8) }
            let packet = response(request:NTPPacket.request(epoch:epoch),t2:epoch+0.01,t3:epoch+0.08)
            try rejects { _ = try sample(packet) }
        }
        try check("拒绝空时间戳及异常服务器精度根离散度") {
            var packet = response(request:NTPPacket.request(epoch:epoch),t2:epoch+0.015,t3:epoch+0.017)
            packet.replaceSubrange(32..<40,with:[UInt8](repeating:0,count:8))
            try rejects { _ = try sample(packet) }
            packet = response(request:NTPPacket.request(epoch:epoch),t2:epoch+0.015,t3:epoch+0.017)
            packet[3] = 1; try rejects { _ = try sample(packet) }
            packet[3] = UInt8(bitPattern:-20)
            NTPPacket.writeUInt32(UInt32(0.2*65536),to:&packet,at:8)
            try rejects { _ = try sample(packet) }
        }
        try check("多数来源一致并剔除偏离源") {
            let result = try NTPClient.select(samples:pair("a",offset:8)+pair("b",offset:10)+pair("c",offset:2000),nowMonoNs:2_000_000_000,nowWallEpoch:epoch)
            try expect(result.snapshot.crossChecked && Set(result.snapshot.selectedServers) == Set(["a","b"]),"多数选择错误")
            try expect(result.rejectedServers == ["c"],"未标明剔除来源")
        }
        try check("两个冲突来源及无多数的两簇均拒绝") {
            try rejects { _ = try NTPClient.select(samples:pair("a",offset:0)+pair("b",offset:1000),nowMonoNs:2_000_000_000,nowWallEpoch:epoch) }
            try rejects { _ = try NTPClient.select(samples:pair("a",offset:0)+pair("b",offset:1)+pair("c",offset:1000)+pair("d",offset:1001),nowMonoNs:2_000_000_000,nowWallEpoch:epoch) }
        }
        try check("单源降级明确标识，单样本不能校时") {
            let result = try NTPClient.select(samples:pair("a",offset:9),nowMonoNs:2_000_000_000,nowWallEpoch:epoch)
            try expect(!result.snapshot.crossChecked && result.snapshot.sourceSummary.contains("单源"),"单源冒充交叉验证")
            try rejects { _ = try NTPClient.select(samples:[synthetic("a",offsetMs:9)],nowMonoNs:2_000_000_000,nowWallEpoch:epoch) }
        }
        try check("同一来源不稳定时拒绝，低RTT异常点不胜出") {
            try rejects { _ = try NTPClient.select(samples:[synthetic("a",offsetMs:0),synthetic("a",offsetMs:1000)],nowMonoNs:2_000_000_000,nowWallEpoch:epoch) }
            let samples = pair("a",offset:8)+[synthetic("a",offsetMs:2000,rtt:1)]
            let value = try NTPClient.select(samples:samples,nowMonoNs:2_000_000_000,nowWallEpoch:epoch)
            try expect(abs(value.snapshot.offsetMs-8)<0.002,"最低RTT异常点污染了校准")
        }
        try check("采样到汇总间的漂移同样计入") {
            let s = try NTPClient.select(samples:pair("a",offset:0),nowMonoNs:12_000_000_000,nowWallEpoch:epoch+10).snapshot
            try expect(s.baseUncertaintyMs >= 10.49,"遗漏采样到锚点期间的漂移预算")
        }
        try check("UTC使用单调时钟，系统快慢不影响倒计时") {
            let result = try NTPClient.select(samples:pair("a",offset:85),nowMonoNs:2_000_000_000,nowWallEpoch:epoch)
            let s = result.snapshot
            try expect(abs(s.offsetMs-85)<0.002,"快慢符号错误")
            try expect(abs(s.utcEpoch(atMonoNs:3_000_000_000)-(epoch+1.085))<0.000002,"未按单调时钟映射UTC")
            try expect(abs(s.systemClockDeviationMs(atMonoNs:3_000_000_000,wallEpoch:epoch+2)-1000)<0.002,"系统时钟跳变诊断错误")
        }
        try check("新鲜度和漂移预算") {
            let s = try NTPClient.select(samples:pair("a",offset:0),nowMonoNs:2_000_000_000,nowWallEpoch:epoch).snapshot
            try expect(s.isUsable(atMonoNs:122_000_000_000),"120秒以内不应过期")
            try expect(!s.isUsable(atMonoNs:122_000_000_001),"过期后仍可用")
            try expect(!s.isUsable(atMonoNs:1_000_000_000),"旧启动会话时钟被接受")
            try expect(abs(s.estimatedUncertaintyMs(atMonoNs:102_000_000_000)-s.baseUncertaintyMs-5)<0.000001,"未添加50ppm漂移预算")
        }
        try check("校准报告可往返JSON保留时间基准") {
            let result = try NTPClient.select(samples:pair("a",offset:8)+pair("b",offset:9),nowMonoNs:2_000_000_000,nowWallEpoch:epoch)
            let decoded = try JSONDecoder().decode(NetworkTimeCalibration.self,from:JSONEncoder().encode(result))
            try expect(decoded.snapshot.referenceMonoNs == result.snapshot.referenceMonoNs && decoded.samples.count == 4,"报告数据丢失")
        }
        print("NetworkTime tests: \(passed) passed; no system clicks or system clock changes.")
    }
}
