import Foundation
import os

/// Control for Yamaha AV receivers / sound bars speaking the YXC ("Yamaha
/// eXtended Control") protocol — XML over HTTP PUT to port 80.
///
/// Wire protocol:
///   PUT http://<host>/YamahaRemoteControl/ctrl
///   <YAMAHA_AV cmd="PUT"><Main_Zone>…</Main_Zone></YAMAHA_AV>
///   Success responses carry RC="0"; RC="1" means the command was rejected.
///
/// Commands:
///   setVolume: <Volume><Val>n</Val><Exp>1</Exp><Unit>1</Unit></Volume>
///              (Val is the raw YXC scale 0…161, 0.5 dB steps)
///   powerOn:   <Power_Control><Power>On</Power></Power_Control>
///   setInput:  <Input><Input_Sel>HDMI1|AV1|TUNER|…</Input_Sel></Input>
///
/// There is no pairing step on this protocol; callers set `host` (IP or
/// hostname) before issuing commands. All callbacks run on a private serial
/// queue; requests time out after 5 seconds and completions are called exactly
/// once.
public final class YamahaAVRController {
    private let queue = DispatchQueue(label: "dev.fisifla.fbd.yamaha")
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "YamahaAVRController")
    private let session: URLSession

    /// AVR host (IP or hostname). Required before any command.
    public var host = ""

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        // Route every callback through the controller's serial queue.
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = queue
        session = URLSession(configuration: config, delegate: nil, delegateQueue: operationQueue)
    }

    /// Set main-zone volume. `volume` is the raw YXC scale, 0…161 (Exp=1,
    /// 0.5 dB steps); values outside the range are clamped.
    public func setVolume(_ volume: Int, completion: ((Bool) -> Void)? = nil) {
        let value = min(max(volume, 0), 161)
        let xml = "<YAMAHA_AV cmd=\"PUT\"><Main_Zone><Volume><Val>\(value)</Val>"
            + "<Exp>1</Exp><Unit>1</Unit></Volume></Main_Zone></YAMAHA_AV>"
        put(xml: xml, completion: completion)
    }

    public func powerOn(completion: ((Bool) -> Void)? = nil) {
        let xml = "<YAMAHA_AV cmd=\"PUT\"><Main_Zone><Power_Control><Power>On</Power>"
            + "</Power_Control></Main_Zone></YAMAHA_AV>"
        put(xml: xml, completion: completion)
    }

    /// Switch the main-zone input (e.g. "HDMI1", "AV1", "TUNER", "NET RADIO").
    public func setInput(_ input: String, completion: ((Bool) -> Void)? = nil) {
        let xml = "<YAMAHA_AV cmd=\"PUT\"><Main_Zone><Input><Input_Sel>\(xmlEscape(input))</Input_Sel>"
            + "</Input></Main_Zone></YAMAHA_AV>"
        put(xml: xml, completion: completion)
    }

    // MARK: - HTTP

    private func put(xml: String, completion: ((Bool) -> Void)?) {
        queue.async { [weak self] in
            guard let self else {
                completion?(false)
                return
            }
            guard !self.host.isEmpty,
                  let url = URL(string: "http://\(self.displayHost(self.host))/YamahaRemoteControl/ctrl") else {
                completion?(false)
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(xml.utf8)

            self.session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else {
                    completion?(false)
                    return
                }
                if let error {
                    self.log.error("PUT failed: \(error.localizedDescription)")
                    completion?(false)
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    self.log.error("PUT returned HTTP \(status)")
                    completion?(false)
                    return
                }
                if let data, let body = String(data: data, encoding: .utf8) {
                    if body.contains("RC=\"1\"") {
                        self.log.error("AVR rejected command: \(body.prefix(200))")
                        completion?(false)
                        return
                    }
                    if !body.contains("RC=\"0\"") {
                        // Some models omit the RC attribute; accept HTTP 200.
                        self.log.warning("no RC attribute in response (lenient success)")
                    }
                }
                completion?(true)
            }.resume()
        }
    }

    private func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Brackets IPv6 literals so URL(string:) accepts them.
    private func displayHost(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }
}
