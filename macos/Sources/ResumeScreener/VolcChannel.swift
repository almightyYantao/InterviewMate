import AVFoundation
import Foundation

/// 火山引擎「豆包流式语音识别大模型」：一路声音一个 WebSocket 连接，按 200ms 一包推 16k 单声道 PCM。
/// 协议：每包 = 4 字节包头 +（可选序号）+ 4 字节长度 + 内容；这里不压缩，请求用 JSON。
final class VolcChannel: NSObject, SpeechSink, URLSessionWebSocketDelegate, @unchecked Sendable {
    struct Credentials: Sendable { var appId: String; var token: String; var resourceId: String }

    static let url = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    private static let chunkBytes = 6400          // 200ms：16000 × 2 字节 × 0.2

    private let cred: Credentials
    private let hints: [String]
    private let lock = NSLock()
    private let rs = Resampler(target: AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!)
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var ready = false
    private var running = false
    private var pending = Data()                  // 连上之前、以及凑不满一包的音频
    private var emitted = Set<Int>()              // 已经作为整句发出的 utterance（按开始时间）
    private var failures = 0
    var onPartial: (String) -> Void = { _ in }
    var onFinal: (String) -> Void = { _ in }
    var onFatal: (Error) -> Void = { _ in }

    init(credentials: Credentials, hints: [String]) {
        cred = credentials
        self.hints = hints
    }

    func start() {
        lock.withLock { running = true }
        connect()
    }

    func stop() {
        lock.lock()
        running = false
        let t = task, rest = pending
        pending = Data()
        lock.unlock()
        guard let t else { return }
        // 剩下的音频作为最后一包发出去，等服务端把最后一句返回
        t.send(.data(Self.packet(type: 0b0010, flags: 0b0010, payload: rest))) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { t.cancel(with: .normalClosure, reason: nil) }
    }

    func append(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard running, let out = rs.convert(buf), let p = out.int16ChannelData else { return }
        pending.append(Data(bytes: p[0], count: Int(out.frameLength) * 2))
        // 断线重连期间最多攒 30 秒
        if pending.count > 16000 * 2 * 30 { pending.removeFirst(pending.count - 16000 * 2 * 30) }
        guard ready, let t = task else { return }
        while pending.count >= Self.chunkBytes {
            let chunk = pending.prefix(Self.chunkBytes)
            pending.removeFirst(Self.chunkBytes)
            t.send(.data(Self.packet(type: 0b0010, flags: 0, payload: Data(chunk)))) { _ in }
        }
    }

    func append(_ sb: CMSampleBuffer) {
        if let b = pcmBuffer(from: sb) { append(b) }
    }

    // MARK: 连接

    private func connect() {
        var req = URLRequest(url: Self.url)
        req.setValue(cred.appId, forHTTPHeaderField: "X-Api-App-Key")
        req.setValue(cred.token, forHTTPHeaderField: "X-Api-Access-Key")
        req.setValue(cred.resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let t = s.webSocketTask(with: req)
        lock.withLock { session = s; task = t; ready = false; emitted = [] }
        t.resume()
        t.send(.data(Self.packet(type: 0b0001, flags: 0, payload: firstRequest()))) { [weak self] e in
            guard let self else { return }
            if let e { self.dropped(e); return }
            self.lock.withLock { if self.task === t { self.ready = true } }
        }
        receive(t)
    }

    private func firstRequest() -> Data {
        var request: [String: Any] = [
            "model_name": "bigmodel", "enable_itn": true, "enable_punc": true, "enable_ddc": false,
            "show_utterances": true, "result_type": "full", "end_window_size": 800,
        ]
        if !hints.isEmpty {
            // 热词：职位、JD 和题目里的术语
            let ctx = ["hotwords": hints.prefix(100).map { ["word": $0] }]
            if let d = try? JSONSerialization.data(withJSONObject: ctx), let s = String(data: d, encoding: .utf8) {
                request["corpus"] = ["context": s]
            }
        }
        let body: [String: Any] = [
            "user": ["uid": "interviewmate"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": request,
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(.data(let d)):
                self.handle(d)
                self.receive(t)
            case .success:
                self.receive(t)
            case .failure(let e):
                if self.lock.withLock({ self.task === t }) { self.dropped(e) }
            }
        }
    }

    /// 连接断了：还在转写就 1 秒后重连；连续失败 3 次报错
    private func dropped(_ e: Error) {
        lock.lock()
        let again = running
        ready = false; task = nil
        failures += 1
        let n = failures
        lock.unlock()
        guard again else { return }
        if n >= 3 {
            lock.withLock { running = false }
            DispatchQueue.main.async { self.onFatal(e) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.lock.withLock({ self.running }) else { return }
            self.connect()
        }
    }

    // MARK: 协议

    static func packet(type: UInt8, flags: UInt8, payload: Data) -> Data {
        // 版本 1、包头 1×4 字节 | 消息类型、标志 | 序列化（1 = JSON，0 = 无）、压缩（0 = 无）| 保留
        var d = Data([0x11, (type << 4) | flags, type == 0b0001 ? 0x10 : 0x00, 0x00])
        var n = UInt32(payload.count).bigEndian
        d.append(Data(bytes: &n, count: 4))
        d.append(payload)
        return d
    }

    private func handle(_ d: Data) {
        let b = [UInt8](d)
        guard b.count >= 8 else { return }
        let headerSize = Int(b[0] & 0x0f) * 4
        let type = b[1] >> 4, flags = b[1] & 0x0f
        var i = headerSize
        func u32() -> UInt32? {
            guard i + 4 <= b.count else { return nil }
            defer { i += 4 }
            return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
        }
        if type == 0b1111 {          // 错误
            let code = u32() ?? 0, n = Int(u32() ?? 0)
            let msg = i + n <= b.count ? String(decoding: b[i..<i + n], as: UTF8.self) : ""
            NSLog("volc asr error \(code): \(msg)")
            dropped(NSError(domain: "volc", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "豆包识别出错（\(code)）：\(msg)"]))
            return
        }
        guard type == 0b1001 else { return }
        if flags & 0b0001 != 0 { _ = u32() }          // 序号
        guard let n = u32().map(Int.init), i + n <= b.count,
              let json = try? JSONSerialization.jsonObject(with: Data(b[i..<i + n])) as? [String: Any],
              let result = json["result"] as? [String: Any] else { return }
        lock.withLock { failures = 0 }
        let utts = result["utterances"] as? [[String: Any]] ?? []
        var finals: [String] = []
        var partial = ""
        lock.lock()
        for u in utts {
            let text = (u["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let start = u["start_time"] as? Int ?? 0
            if u["definite"] as? Bool == true {
                if !emitted.contains(start) { emitted.insert(start); if !text.isEmpty { finals.append(text) } }
            } else {
                partial = text
            }
        }
        lock.unlock()
        DispatchQueue.main.async {
            for f in finals { self.onFinal(f) }
            self.onPartial(partial)
        }
    }
}
