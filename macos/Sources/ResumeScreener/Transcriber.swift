import AVFoundation
import CoreAudio
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
    var channel: SpeechSink?
    var recorder: AudioRecorder?
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        channel?.append(sb)
        recorder?.append(sb)
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
    @Published var refining: Set<String> = []       // 正在用 Whisper 重新识别的题目
    private let tap = ProcessTap()
    var currentQuestion = "" { didSet { if oldValue != currentQuestion { cut(oldValue) } } }
    private var recMe: AudioRecorder?
    private var recCand: AudioRecorder?
    private var refineCfg: (model: String, language: String, prompt: String)?
    private var segStart: Double = 0                // 当前这道题从第几秒开始录
    private var refineTasks: [Task<Void, Never>] = []
    /// 一道题识别完后按术语表纠正专有名词：传入题目和这道题的逐字稿，返回一一对应的新文字
    var corrector: ((String, [Utterance]) async -> [String]?)?

    private let engine = AVAudioEngine()
    private var mic: SpeechSink?
    private var sys: SpeechSink?
    private var stream: SCStream?
    private let output = SystemAudioOutput()
    private var micCapture: MicCapture?
    private var t0 = Date()

    /// 面试官按快捷键打的标记，放进逐字稿，生成总结时会重点看
    func addMark(_ kind: String) {
        let last = utterances.last(where: { $0.speaker == "candidate" && $0.questionId == currentQuestion })?.text ?? live["candidate"] ?? ""
        utterances.append(Utterance(speaker: kind, text: last.isEmpty ? L("（标记时候选人还没说话）") : last,
                                    questionId: currentQuestion, at: Date().timeIntervalSince(t0)))
    }

    func start(locale code: String = "zh-CN", silence: Double = 1.5, captureApp: String = "",
               speechEngine: String = "analyzer", refine: Bool = false, whisperModel: String = "",
               hints: [String] = [], volc: VolcChannel.Credentials? = nil) async -> String? {
        starting = true
        defer { starting = false }
        let auth = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard auth == .authorized else { return L("没有语音识别权限：请在「系统设置 › 隐私与安全性 › 语音识别」里允许「面搭子」。") }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return L("没有麦克风权限：请在「系统设置 › 隐私与安全性 › 麦克风」里允许「面搭子」。")
        }
        let locale = Locale(identifier: code)
        let name = Locale.current.localizedString(forIdentifier: code) ?? code
        var m: SpeechSink, s: SpeechSink
        var refine = refine
        if speechEngine == "volc" {
            guard let volc, !volc.appId.isEmpty, !volc.token.isEmpty else {
                return L("还没填豆包识别的 App ID 和 Access Token：请在「设置 › 语音转写」里填写。")
            }
            m = VolcChannel(credentials: volc, hints: hints); s = VolcChannel(credentials: volc, hints: hints)
            refine = false          // 云端识别已经够准，不用再拿 Whisper 重识别
        } else if #available(macOS 26, *), speechEngine == "analyzer", SpeechTranscriber.isAvailable {
            // 新识别器：长音频模型、整场不切段；模型没装会自动下载
            let l: Locale?
            do { l = try await AnalyzerChannel.prepare(locale: locale) } catch {
                return L("语音识别模型下载失败：") + error.localizedDescription
            }
            guard let l else { return String(format: L("本机不支持「%@」语音识别。"), name) }
            m = AnalyzerChannel(locale: l, hints: hints); s = AnalyzerChannel(locale: l, hints: hints)
        } else {
        guard let r1 = SFSpeechRecognizer(locale: locale), let r2 = SFSpeechRecognizer(locale: locale) else {
            return String(format: L("本机不支持「%@」语音识别。"), name)
        }
        guard r1.supportsOnDeviceRecognition else {
            return String(format: L("「%@」离线识别模型还没装：请在「系统设置 › 键盘 › 听写」里打开听写并添加这个语言，等模型下载完再试。"), name)
        }

        let a = SpeechChannel(recognizer: r1), b = SpeechChannel(recognizer: r2)
        a.silence = silence; b.silence = silence
        m = a; s = b
        }

        t0 = Date()
        segStart = 0
        utterances = []
        if refine && !whisperModel.isEmpty {
            let lead = code == "zh-CN" ? "以下是普通话的网络技术面试，中英混说，英文术语保留英文写法，使用简体中文和标点。常用术语：" : ""
            refineCfg = (whisperModel, WhisperEngine.language(code), lead + hints.joined(separator: "、"))
            recMe = AudioRecorder(); recCand = AudioRecorder()
            Task.detached { await WhisperEngine.shared.warmUp(whisperModel) }
        } else {
            refineCfg = nil; recMe = nil; recCand = nil
        }
        let rm = recMe, rc = recCand
        wire(m, speaker: "me")
        wire(s, speaker: "candidate")
        mic = m; sys = s
        m.start(); s.start()

        do {
            if let cap = MicCapture(channel: m, recorder: rm) {
                // 固定用 Mac 自带麦克风：不占用蓝牙耳机的麦克风，耳机就不会被切到通话模式（单声道、低采样率）
                micCapture = cap
                cap.start()
            } else {
                try Self.installTap(engine, channel: m, recorder: rm)
                engine.prepare()
                try engine.start()
            }
        } catch {
            stop()
            return L("麦克风启动失败：") + error.localizedDescription
        }

        // 优先只监听会议软件（仅需「系统录音」权限）；找不到或失败再退回屏幕录制方式采整机声音
        var tapError: Error?
        do {
            try tap.start(preferred: captureApp) { [s] buf in s.append(buf); rc?.append(buf) }
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
            output.recorder = rc
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
            recCand = nil
            source = nil
            warning = L("听不到候选人：请在「系统设置 › 隐私与安全性 › 屏幕与系统录音」里允许「面搭子」，然后重新开始转写。")
        }
        running = true
        return nil
    }

    func stop() {
        micCapture?.stop(); micCapture = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        mic?.stop(); sys?.stop()
        mic = nil; sys = nil
        output.channel = nil
        output.recorder = nil
        tap.stop()
        if let st = stream { Task { try? await st.stopCapture() } }
        stream = nil
        running = false
        cut(currentQuestion)          // 最后一道题也用 Whisper 过一遍
        recMe = nil; recCand = nil; refineCfg = nil
    }

    /// 等所有题目的 Whisper 重新识别做完（生成总结、保存逐字稿前调用）
    func finishRefining() async {
        while let t = refineTasks.first { await t.value; refineTasks.removeFirst() }
    }

    /// 一道题结束：取走这段录音，后台用 Whisper 重新识别，结果替换这道题的实时逐字稿
    private func cut(_ qid: String) {
        let from = segStart
        segStart = Date().timeIntervalSince(t0)
        guard !qid.isEmpty else { return }
        let cfg = refineCfg
        let jobs: [(String, [Float])] = cfg == nil ? [] : [("me", recMe?.take()), ("candidate", recCand?.take())]
            .compactMap { sp, a in a.map { (sp, $0) } }
            .filter { $0.1.count > Int(AudioRecorder.rate) }    // 不到 1 秒不处理
        guard !jobs.isEmpty || (corrector != nil && utterances.contains { $0.questionId == qid }) else { return }
        refining.insert(qid)
        refineTasks.append(Task { [weak self] in
            for (speaker, audio) in jobs {
                guard let cfg else { break }
                do {
                    let segs = try await WhisperEngine.shared.transcribe(audio, model: cfg.model, language: cfg.language, prompt: cfg.prompt)
                    self?.replace(qid, speaker, from: from, until: from + Double(audio.count) / AudioRecorder.rate, segs)
                } catch {
                    NSLog("whisper failed: \(error)")
                    self?.warning = L("Whisper 重新识别失败，这道题保留实时识别的结果：") + error.localizedDescription
                }
            }
            await self?.correct(qid)
            self?.refining.remove(qid)
        })
    }

    private func correct(_ qid: String) async {
        guard let corrector else { return }
        let lines = utterances.filter { $0.questionId == qid && ($0.speaker == "me" || $0.speaker == "candidate") }
        guard !lines.isEmpty, let out = await corrector(qid, lines), out.count == lines.count else { return }
        let fixed = Dictionary(uniqueKeysWithValues: zip(lines.map(\.id), out))
        for i in utterances.indices { if let t = fixed[utterances[i].id], !t.isEmpty { utterances[i].text = t } }
    }

    private func replace(_ qid: String, _ speaker: String, from: Double, until: Double, _ segs: [(start: Double, text: String)]) {
        guard !segs.isEmpty else { return }       // Whisper 没听出东西就保留实时结果
        // 实时结果是整句说完才记时间，往后放宽几秒
        let old = utterances.filter { $0.questionId == qid && $0.speaker == speaker && $0.at >= from - 1 && $0.at <= until + 5 }
        // Whisper 遇到没把握的片段会整段跳过：结果明显比实时字幕短时，说明丢了内容，保留实时字幕
        let oldLen = old.reduce(0) { $0 + $1.text.count }, newLen = segs.reduce(0) { $0 + $1.text.count }
        if oldLen > 20 && Double(newLen) < Double(oldLen) * 0.6 {
            NSLog("whisper result too short (\(newLen) vs \(oldLen)), keep live transcript")
            return
        }
        utterances.removeAll { $0.questionId == qid && $0.speaker == speaker && $0.at >= from - 1 && $0.at <= until + 5 }
        utterances += segs.map { Utterance(speaker: speaker, text: $0.text, questionId: qid, at: from + $0.start) }
        utterances.sort { $0.at < $1.at }
    }

    private func wire(_ c: SpeechSink, speaker: String) {
        c.onPartial = { [weak self] text in
            MainActor.assumeIsolated { self?.live[speaker] = text.isEmpty ? nil : text }
        }
        c.onFinal = { [weak self] text in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date().timeIntervalSince(self.t0)
                // 麦克风串进了候选人的声音：两路 15 秒内说的话几乎一样，以候选人那一路为准
                let other = speaker == "me" ? "candidate" : "me"
                let echo = { (u: Utterance) in u.speaker == other && now - u.at < 15 && Self.similar(u.text, text) }
                if speaker == "me", self.utterances.contains(where: echo) { return }
                if speaker == "candidate" { self.utterances.removeAll(where: echo) }
                self.utterances.append(Utterance(speaker: speaker, text: text, questionId: self.currentQuestion, at: now))
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
    }

    /// 两句话的字重合度（二元组），用来认出麦克风串音
    nonisolated static func similar(_ a: String, _ b: String) -> Bool {
        func grams(_ s: String) -> Set<String> {
            let c = Array(s.filter { !$0.isPunctuation && !$0.isWhitespace })
            return c.count < 2 ? Set(c.map(String.init)) : Set((0..<c.count - 1).map { String(c[$0...$0 + 1]) })
        }
        let x = grams(a), y = grams(b)
        guard min(x.count, y.count) >= 3 else { return false }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count)) > 0.6
    }

    /// 放在非隔离的静态方法里，避免音频线程上的回调被当成主线程闭包检查
    nonisolated private static func installTap(_ engine: AVAudioEngine, channel: SpeechSink, recorder: AudioRecorder?) throws {
        let input = engine.inputNode
        // 不开系统回声消除：它会另建音频链路，蓝牙耳机下和会议软件的进程监听冲突，候选人那一路收不到声音。
        // 外放串音靠 onFinal 里的文字去重处理
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { throw NSError(domain: "screener", code: 2, userInfo: [NSLocalizedDescriptionKey: L("没有可用的麦克风")]) }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in channel.append(buf); recorder?.append(buf) }
    }
}

/// 用 AVCaptureSession 采 Mac 自带麦克风（不经过系统默认输入设备）
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "screener.mic")
    private let channel: SpeechSink
    private let recorder: AudioRecorder?

    init?(channel: SpeechSink, recorder: AudioRecorder?) {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices.first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }
        guard let dev = found, let input = try? AVCaptureDeviceInput(device: dev) else { return nil }
        self.channel = channel
        self.recorder = recorder
        super.init()
        let out = AVCaptureAudioDataOutput()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(out) else { session.commitConfiguration(); return nil }
        session.addInput(input)
        session.addOutput(out)
        session.commitConfiguration()
        out.setSampleBufferDelegate(self, queue: queue)
    }

    func start() { queue.async { self.session.startRunning() } }
    func stop() { queue.async { self.session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buf = pcmBuffer(from: sb) else { return }
        channel.append(buf)
        recorder?.append(buf)
    }
}
