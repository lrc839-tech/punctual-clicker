import Foundation
import Darwin

/// Verifies a copied release bundle without posting input or requiring dev tools.
enum DistributionSelfTest {
    static func run() -> Int32 {
        let files = FileManager.default
        let temporary = files.temporaryDirectory.appendingPathComponent("punctual-clicker-smoke-" + UUID().uuidString,isDirectory:true)
        var server: CalibrationHTTPServer?
        var finished = false
        var result: Int32 = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration:configuration)
        defer { server?.stop(); session.invalidateAndCancel(); try? files.removeItem(at:temporary) }
        func complete(_ error:String? = nil) {
            guard !finished else { return }
            finished = true; result = error == nil ? 0 : 1
            let report: [String:Any] = ["status":error == nil ? "passed" : "failed",
                "version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown",
                "resourceAndNativeHTTPChecks":error == nil,"postedSystemClicks":false,
                "externalRuntimeRequired":false,"error":(error as Any?) ?? NSNull()]
            if let data = try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),let text = String(data:data,encoding:.utf8) { print(text) }
        }
        func request(_ port:UInt16,_ path:String,_ body:[String:Any]? = nil,_ then:@escaping (Data) -> Void) {
            var request = URLRequest(url:URL(string:"http://127.0.0.1:\(port)\(path)")!)
            if let body = body {
                request.httpMethod = "POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject:body)
            }
            session.dataTask(with:request) { data,response,error in
                DispatchQueue.main.async {
                    guard !finished else { return }
                    guard error == nil,let response = response as? HTTPURLResponse,response.statusCode == 200,let data = data else {
                        complete("Native HTTP failed at \(path): \(error?.localizedDescription ?? "invalid response")"); return
                    }
                    then(data)
                }
            }.resume()
        }
        func json(_ data:Data) -> [String:Any] { (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:] }
        do {
            guard let resources = Bundle.main.resourceURL?.appendingPathComponent("Calibration",isDirectory:true),
                  files.fileExists(atPath:resources.appendingPathComponent("index.html").path) else {
                complete("Bundled calibration page is missing"); return result
            }
            try files.createDirectory(at:temporary,withIntermediateDirectories:true)
            let native = try CalibrationHTTPServer(port:0,resourceRoot:resources,reports:temporary)
            server = native
            native.start { state in
                guard case .success = state,let port = native.boundPort else {
                    if case .failure(let error) = state { complete(error.localizedDescription) }
                    else { complete("Native server has no bound port") }; return
                }
                request(port,"/health") { data in
                    guard json(data)["ok"] as? Bool == true else { complete("Health check failed"); return }
                    request(port,"/") { page in
                        guard String(data:page,encoding:.utf8)?.contains("点击校准靶区") == true else { complete("Bundled page was not served"); return }
                        request(port,"/time") { data in
                            let time = json(data)
                            guard let receive = time["receiveMs"] as? Double,let send = time["sendMs"] as? Double,send >= receive else { complete("Server timestamps invalid"); return }
                            let now = Date().timeIntervalSince1970*1000
                            let run = "distribution-smoke-" + UUID().uuidString
                            let target = now+1000
                            request(port,"/test-plan",["runId":run,"targetsMs":[target],"compensationMs":0,"expectedLatencyMs":40]) { _ in
                                request(port,"/send-events",["runId":run,"events":[["index":1,"sentUpMs":target-1]]]) { _ in
                                    request(port,"/samples",["runId":run,"samples":[["index":1,"receivedMacMs":target+39]],"straySamples":[],"clock":["calibratedAtMacMs":now,"rttMs":2,"uncertaintyEstimateMs":1]]) { _ in
                                        request(port,"/summary") { data in
                                            let summary = json(data)
                                            guard summary["matchedSendCount"] as? Int == 1,summary["sampleCount"] as? Int == 1,
                                                  summary["clockFresh"] as? Bool == true,let latency = summary["medianLatencyMs"] as? Double,abs(latency-40)<0.001,
                                                  files.fileExists(atPath:temporary.appendingPathComponent("phone-calibration.json").path) else {
                                                complete("Synthetic calibration roundtrip or report persistence failed"); return
                                            }
                                            complete()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            let deadline = ProcessInfo.processInfo.systemUptime+15
            while !finished && ProcessInfo.processInfo.systemUptime < deadline {
                RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))
            }
            if !finished { complete("Distribution self-test timed out") }
        } catch { complete(error.localizedDescription) }
        return result
    }
}
