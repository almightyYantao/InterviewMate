import AVFoundation
import WhisperKit

/// 把任意格式的音频转成目标格式。非线程安全，调用方自己加锁。
final class Resampler {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?
    init(target: AVAudioFormat) { self.target = target }

    func convert(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buf.format == target { return buf }
        if converter?.inputFormat != buf.format {
            converter = AVAudioConverter(from: buf.format, to: target)
        }
        guard let converter else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }
}

func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let desc = sb.formatDescription,
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
    var a = asbd.pointee
    guard let fmt = AVAudioFormat(streamDescription: &a) else { return nil }
    let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
    guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
    buf.frameLength = n
    let s = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList)
    return s == noErr ? buf : nil
}

/// 一路声音的内存录音（16k 单声道），每道题取走一次。不写磁盘。
final class AudioRecorder: @unchecked Sendable {
    static let rate = 16000.0
    private let lock = NSLock()
    private var samples: [Float] = []
    private let rs = Resampler(target: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!)

    func append(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let out = rs.convert(buf), let p = out.floatChannelData else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: p[0], count: Int(out.frameLength)))
    }

    func append(_ sb: CMSampleBuffer) {
        if let b = pcmBuffer(from: sb) { append(b) }
    }

    func take() -> [Float] {
        lock.lock(); defer { lock.unlock(); samples = [] }
        return samples
    }
}

/// 本机 Whisper：第一次用时下载模型，之后常驻
actor WhisperEngine {
    static let shared = WhisperEngine()
    private var kit: WhisperKit?
    private var model = ""

    private func load(_ model: String) async throws -> WhisperKit {
        if let kit, self.model == model { return kit }
        kit = nil
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InterviewMate/whisper")
        let k = try await WhisperKit(WhisperKitConfig(model: model, downloadBase: base, verbose: false,
                                                      prewarm: true, load: true, download: true))
        kit = k; self.model = model
        return k
    }

    /// 先把模型下好、载入，避免第一道题结束时才开始下载
    func warmUp(_ model: String) async { _ = try? await load(model) }

    func transcribe(_ audio: [Float], model: String, language: String, prompt: String) async throws -> [(start: Double, text: String)] {
        let k = try await load(model)
        var tokens: [Int]?
        if let tz = k.tokenizer, !prompt.isEmpty {
            tokens = Array(tz.encode(text: " " + prompt).filter { $0 < tz.specialTokens.specialTokenBegin }.prefix(200))
        }
        let opts = DecodingOptions(language: language, temperature: 0, usePrefillPrompt: true, detectLanguage: false,
                                   skipSpecialTokens: true, withoutTimestamps: false, promptTokens: tokens,
                                   noSpeechThreshold: 0.6, chunkingStrategy: .vad)
        let rs = try await k.transcribe(audioArray: audio, decodeOptions: opts)
        return rs.flatMap(\.segments).compactMap { seg in
            let t = seg.text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 没声音时 Whisper 偶尔会把提示词原样吐回来
            if t.isEmpty || (t.count > 4 && prompt.contains(t)) { return nil }
            return (Double(seg.start), t)
        }
    }

    static func language(_ locale: String) -> String {
        locale == "zh-HK" ? "yue" : String(locale.prefix(2))
    }
}
