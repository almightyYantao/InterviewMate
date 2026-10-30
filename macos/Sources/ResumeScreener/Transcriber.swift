import AVFoundation
import ScreenCaptureKit
import Speech
import SwiftUI

struct Utterance: Identifiable, Codable, Hashable {
    var id = UUID()
    var speaker: String          // me / candidate
    var text: String
    var questionId: String
    var at: Double               // 距开始的秒数
    enum CodingKeys: String, CodingKey { case speaker, text, questionId, at }
}

/// 一路声音 → 本机语音识别。停顿约 1.5 秒切一句。
final class SpeechChannel: @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var commitWork: DispatchWorkItem?
    private var running = false
    var silence: Double = 1.5
    var onPartial: (String) -> Void = { _ in }
    var onFinal: (String) -> Void = { _ in }
    var onFatal: (Error) -> Void = { _ in }

    init(recognizer: SFSpeechRecognizer) { self.recognizer = recognizer }

    func start() {
        lock.lock(); running = true; lock.unlock()
        newSegment()
    }

    func stop() {
        lock.lock()
        running = false
        let r = request
        request = nil
        lock.unlock()
        r?.endAudio()   // 让最后一句的结果回来
    }

    func append(_ buf: AVAudioPCMBuffer) {
        lock.lock(); request?.append(buf); lock.unlock()
    }

    func append(_ sb: CMSampleBuffer) {
        lock.lock(); request?.appendAudioSampleBuffer(sb); lock.unlock()
    }

    private func isCurrent(_ req: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return request === req && running
    }

    private func newSegment() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        lock.lock()
        guard running else { lock.unlock(); return }
        request = req
        lock.unlock()

        var latest = ""
        var done = false
        let t = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self, !done else { return }
            if let result { latest = result.bestTranscription.formattedString }
            if let e = error as NSError?, Self.isFatal(e) {
                done = true
                self.lock.lock(); self.running = false; self.lock.unlock()
                DispatchQueue.main.async { self.onFatal(e) }
                return
            }
            if (result?.isFinal ?? false) || error != nil {
                done = true
                let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    if !text.isEmpty { self.onFinal(text) }
                    self.onPartial("")
                }
                // 识别器自己结束（超时、出错）而不是我们切的句：重开一段；出错且没内容时等 1 秒，避免空转
                if self.isCurrent(req) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + (text.isEmpty && error != nil ? 1 : 0)) { self.newSegment() }
                }
            } else {
                let text = latest
                DispatchQueue.main.async {
                    self.onPartial(text)
                    self.scheduleCommit(req, immediately: text.count > 160)
                }
            }
        }
        lock.lock(); task = t; lock.unlock()
    }

    /// 重试也没用的错误：听写被关闭、没有权限等
    static func isFatal(_ e: NSError) -> Bool {
        e.domain == "kLSRErrorDomain" && [201, 300].contains(e.code)
            || e.domain == "kAFAssistantErrorDomain" && [1700].contains(e.code)
    }

    private func scheduleCommit(_ req: SFSpeechAudioBufferRecognitionRequest, immediately: Bool) {
        commitWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.commit(req) }
        commitWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : silence), execute: w)
    }

    /// 切句：先换上新的请求，再结束旧请求，旧请求的最终结果回来后作为一句话发出。
    private func commit(_ req: SFSpeechAudioBufferRecognitionRequest) {
        guard isCurrent(req) else { return }
        newSegment()
        req.endAudio()
    }
}

final class SystemAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    var channel: SpeechChannel?
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        channel?.append(sb)
    }
}

@MainActor
final class Transcriber: ObservableObject {
    @Published var running = false
    @Published var starting = false
    @Published var utterances: [Utterance] = []
    @Published var live: [String: String] = [:]     // speaker → 正在说的半句
    @Published var warning: String?
    @Published var fatal: String?
    @Published var source: String?      // 候选人那一路的来源，例如「Lark」「系统声音」
    private let tap = ProcessTap()
    var currentQuestion = ""

    private let engine = AVAudioEngine()
    private var mic: SpeechChannel?
    private var sys: SpeechChannel?
    private var stream: SCStream?
    private let output = SystemAudioOutput()
    private var t0 = Date()

    /// 面试官按快捷键打的标记，放进逐字稿，生成总结时会重点看
    func addMark(_ kind: String) {
        let last = utterances.last(where: { $0.speaker == "candidate" && $0.questionId == currentQuestion })?.text ?? live["candidate"] ?? ""
        utterances.append(Utterance(speaker: kind, text: last.isEmpty ? L("（标记时候选人还没说话）") : last,
                                    questionId: currentQuestion, at: Date().timeIntervalSince(t0)))
    }

    func start(locale code: String = "zh-CN", silence: Double = 1.5, captureApp: String = "") async -> String? {
        starting = true
        defer { starting = false }
        let auth = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard auth == .authorized else { return L("没有语音识别权限：请在「系统设置 › 隐私与安全性 › 语音识别」里允许「面搭子」。") }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return L("没有麦克风权限：请在「系统设置 › 隐私与安全性 › 麦克风」里允许「面搭子」。")
        }
        let locale = Locale(identifier: code)
        let name = Locale.current.localizedString(forIdentifier: code) ?? code
        guard let r1 = SFSpeechRecognizer(locale: locale), let r2 = SFSpeechRecognizer(locale: locale) else {
            return String(format: L("本机不支持「%@」语音识别。"), name)
        }
        guard r1.supportsOnDeviceRecognition else {
            return String(format: L("「%@」离线识别模型还没装：请在「系统设置 › 键盘 › 听写」里打开听写并添加这个语言，等模型下载完再试。"), name)
        }

        t0 = Date()
        utterances = []
        let m = makeChannel(r1, speaker: "me")
        let s = makeChannel(r2, speaker: "candidate")
        m.silence = silence; s.silence = silence
        mic = m; sys = s
        m.start(); s.start()

        do {
            try Self.installTap(engine, channel: m)
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            return L("麦克风启动失败：") + error.localizedDescription
        }

        // 优先只监听会议软件（仅需「系统录音」权限）；找不到或失败再退回屏幕录制方式采整机声音
        var tapError: Error?
        do {
            try tap.start(preferred: captureApp) { [s] buf in s.append(buf) }
            source = tap.targetName
            warning = nil
            running = true
            return nil
        } catch {
            tapError = error
            NSLog("process tap failed: \(error)")
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw NSError(domain: "screener", code: 1) }
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 16000
            cfg.channelCount = 1
            cfg.width = 2; cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let st = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
            output.channel = s
            let q = DispatchQueue(label: "screener.system-audio")
            try st.addStreamOutput(output, type: .audio, sampleHandlerQueue: q)
            try st.addStreamOutput(output, type: .screen, sampleHandlerQueue: q)
            try await st.startCapture()
            stream = st
            source = L("系统声音")
            warning = String(format: L("没能单独监听会议软件（%@），改为采集整机声音，其他 App 的声音也会算作候选人。"),
                             tapError?.localizedDescription ?? "")
        } catch {
            NSLog("system audio capture failed: \(error)")
            // 系统声音拿不到时仍保留麦克风那一路
            s.stop(); sys = nil
            source = nil
            warning = L("听不到候选人：请在「系统设置 › 隐私与安全性 › 屏幕与系统录音」里允许「面搭子」，然后重新开始转写。")
        }
        running = true
        return nil
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        mic?.stop(); sys?.stop()
        mic = nil; sys = nil
        output.channel = nil
        tap.stop()
        if let st = stream { Task { try? await st.stopCapture() } }
        stream = nil
        running = false
    }

    private func makeChannel(_ r: SFSpeechRecognizer, speaker: String) -> SpeechChannel {
        let c = SpeechChannel(recognizer: r)
        c.onPartial = { [weak self] text in
            MainActor.assumeIsolated { self?.live[speaker] = text.isEmpty ? nil : text }
        }
        c.onFinal = { [weak self] text in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.utterances.append(Utterance(speaker: speaker, text: text, questionId: self.currentQuestion,
                                                 at: Date().timeIntervalSince(self.t0)))
            }
        }
        c.onFatal = { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.stop()
                let e = e as NSError
                self.fatal = e.domain == "kLSRErrorDomain" && e.code == 201
                    ? L("系统的「听写」没有打开，离线语音识别用不了。请在「系统设置 › 键盘 › 听写」里打开听写，语言选对应的识别语言，然后重新开始转写。")
                    : L("语音识别出错：") + e.localizedDescription
            }
        }
        return c
    }

    /// 放在非隔离的静态方法里，避免音频线程上的回调被当成主线程闭包检查
    nonisolated private static func installTap(_ engine: AVAudioEngine, channel: SpeechChannel) throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { throw NSError(domain: "screener", code: 2, userInfo: [NSLocalizedDescriptionKey: L("没有可用的麦克风")]) }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in channel.append(buf) }
    }
}
