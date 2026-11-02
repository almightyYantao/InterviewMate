import AVFoundation
import Speech

/// 一路声音的识别通道：旧的 SpeechChannel（SFSpeechRecognizer）和新的 AnalyzerChannel（SpeechAnalyzer）都实现它
protocol SpeechSink: AnyObject, Sendable {
    var onPartial: (String) -> Void { get set }
    var onFinal: (String) -> Void { get set }
    var onFatal: (Error) -> Void { get set }
    func start()
    func stop()
    func append(_ buf: AVAudioPCMBuffer)
    func append(_ sb: CMSampleBuffer)
}

extension SpeechChannel: SpeechSink {}

/// macOS 26 起的 SpeechAnalyzer + SpeechTranscriber：长音频模型、整场一个会话不切段，识别器自己按停顿出整句。
@available(macOS 26, *)
final class AnalyzerChannel: SpeechSink, @unchecked Sendable {
    private let locale: Locale
    private let hints: [String]
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var target: AVAudioFormat?
    private var resampler: Resampler?
    private var running = false
    var onPartial: (String) -> Void = { _ in }
    var onFinal: (String) -> Void = { _ in }
    var onFatal: (Error) -> Void = { _ in }

    init(locale: Locale, hints: [String] = []) {
        self.locale = locale
        self.hints = hints
    }

    /// 找到对应的识别语言，模型没装就下载。返回 nil 表示不支持这个语言。
    static func prepare(locale: Locale) async throws -> Locale? {
        guard let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let t = makeTranscriber(l)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await req.downloadAndInstall()
        }
        return l
    }

    private static func makeTranscriber(_ l: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: l, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [])
    }

    func start() {
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        lock.lock(); continuation = cont; running = true; lock.unlock()
        Task { [weak self] in
            guard let self else { return }
            do {
                let t = Self.makeTranscriber(locale)
                let a = SpeechAnalyzer(modules: [t], options: .init(priority: .userInitiated, modelRetention: .lingering))
                let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
                try await a.prepareToAnalyze(in: fmt)
                if !hints.isEmpty {
                    let ctx = AnalysisContext()
                    ctx.contextualStrings[.general] = hints
                    try? await a.setContext(ctx)
                }
                lock.withLock { self.target = fmt; self.analyzer = a }
                Task { [weak self] in
                    do {
                        for try await r in t.results {
                            let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            DispatchQueue.main.async {
                                guard let self else { return }
                                if r.isFinal {
                                    if !text.isEmpty { self.onFinal(text) }
                                    self.onPartial("")
                                } else {
                                    self.onPartial(text)
                                }
                            }
                        }
                    } catch {
                        self?.fail(error)
                    }
                }
                try await a.start(inputSequence: stream)
            } catch {
                fail(error)
            }
        }
    }

    private func fail(_ e: Error) {
        lock.lock(); let was = running; running = false; lock.unlock()
        guard was else { return }
        DispatchQueue.main.async { self.onFatal(e) }
    }

    func stop() {
        lock.lock()
        running = false
        let c = continuation, a = analyzer
        continuation = nil
        lock.unlock()
        c?.finish()
        // 把最后一句识别完再结束
        if let a { Task { try? await a.finalizeAndFinishThroughEndOfInput() } }
    }

    func append(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let c = continuation, let out = convert(buf) else { return }
        c.yield(AnalyzerInput(buffer: out))
    }

    func append(_ sb: CMSampleBuffer) {
        guard let buf = pcmBuffer(from: sb) else { return }
        append(buf)
    }

    /// 转成识别器要的格式（一般是 16k 单声道）。调用方持锁。
    private func convert(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target else { return nil }      // 还没准备好，前几十毫秒丢掉
        if resampler?.target != target { resampler = Resampler(target: target) }
        return resampler?.convert(buf)
    }
}
