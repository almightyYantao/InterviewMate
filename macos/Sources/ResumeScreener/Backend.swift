import Foundation
import Darwin

/// 在后台拉起 Python 服务，并封装 HTTP 接口。
@MainActor
final class Backend: ObservableObject {
    enum State: Equatable { case starting, ready, failed(String) }

    @Published var state: State = .starting
    private var process: Process?
    private(set) var base = URL(string: "http://127.0.0.1:0")!

    static let projectDir: URL = {
        if let p = ProcessInfo.processInfo.environment["SCREENER_PROJECT"] { return URL(fileURLWithPath: p) }
        if let p = Bundle.main.object(forInfoDictionaryKey: "ScreenerProjectDir") as? String {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop/Private/resume-screener")
    }()

    private var stopping = false

    func start() {
        Self.killOrphans()
        let port = Self.freePort()
        base = URL(string: "http://127.0.0.1:\(port)")!
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec uv run uvicorn screener.web:app --host 127.0.0.1 --port \(port) --log-level warning"]
        p.currentDirectoryURL = Self.projectDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let logURL = Self.projectDir.appending(path: "data/app.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); p.standardOutput = h; p.standardError = h }
        // 后台意外退出时自动拉起，地址换成新端口
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stopping, self.process === p else { return }
                try? await Task.sleep(for: .seconds(1))
                self.start()
            }
        }
        do { try p.run() } catch { state = .failed(L("无法启动后台服务：") + error.localizedDescription); return }
        process = p
        Task {
            for _ in 0..<240 {
                if let (_, r) = try? await URLSession.shared.data(from: base.appending(path: "positions")),
                   (r as? HTTPURLResponse)?.statusCode == 200 {
                    state = .ready; return
                }
                if !(process?.isRunning ?? false) { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            state = .failed(L("后台服务没有启动成功，日志见 ") + logURL.path)
        }
    }

    func stop() {
        stopping = true
        Self.killOrphans()
        guard let p = process, p.isRunning else { return }
        kill(-p.processIdentifier, SIGTERM)
        p.terminate()
    }

    /// 清掉之前没退干净的后台（App 被强制结束时会留下）
    nonisolated static func killOrphans() {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "uvicorn screener.web:app --host 127.0.0.1"]
        try? k.run()
        k.waitUntilExit()
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    // MARK: - HTTP

    struct APIError: LocalizedError { let message: String; var errorDescription: String? { message } }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }()
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e }()

    private func request(_ path: String, method: String = "GET", query: [String: String] = [:],
                         body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        var comps = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 300
        req.setValue(NSUserName(), forHTTPHeaderField: "X-User")
        if let body { req.httpBody = body; req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"]
            throw APIError(message: "\(code)：\(detail.map { "\($0)" } ?? String(decoding: data, as: UTF8.self))")
        }
        return data
    }

    private func json<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET",
                                    query: [String: String] = [:], body: Encodable? = nil) async throws -> T {
        let data = try await request(path, method: method, query: query, body: try body.map { try Self.encoder.encode($0) })
        return try Self.decoder.decode(T.self, from: data)
    }

    struct IDResp: Decodable { var id: String? ; var candidateId: String? }
    struct OK: Decodable {}

    func positions() async throws -> [Position] { try await json([Position].self, "positions") }

    struct PositionBody: Encodable { var title: String; var jdRaw: String; var companyCtx: String; var interviewMinutes: Int }
    func createPosition(_ b: PositionBody) async throws -> String {
        try await json(IDResp.self, "positions", method: "POST", body: b).id ?? ""
    }

    struct PositionPatch: Encodable {
        var title: String?; var jdRaw: String?; var jdStruct: JDStruct?; var companyCtx: String?; var interviewMinutes: Int?
    }
    func updatePosition(_ id: String, _ b: PositionPatch) async throws { _ = try await request("positions/\(id)", method: "PUT", body: try Self.encoder.encode(b)) }

    func candidates(_ pid: String) async throws -> [Candidate] { try await json([Candidate].self, "positions/\(pid)/candidates") }

    func upload(_ pid: String, file: URL) async throws {
        let boundary = "----screener\(UUID().uuidString)"
        var body = Data()
        let data = try Data(contentsOf: file)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        _ = try await request("positions/\(pid)/candidates", method: "POST", body: body,
                              contentType: "multipart/form-data; boundary=\(boundary)")
    }

    func report(_ cid: String) async throws -> ReportResponse { try await json(ReportResponse.self, "candidates/\(cid)/report") }

    func regenerate(_ cid: String, stage: String) async throws {
        _ = try await request("candidates/\(cid)/regenerate", method: "POST", query: ["stage": stage])
    }

    struct QuestionsPatch: Encodable { var questions: [Question] }
    func updateQuestions(_ rid: String, _ qs: [Question]) async throws {
        _ = try await request("reports/\(rid)", method: "PATCH", body: try Self.encoder.encode(QuestionsPatch(questions: qs)))
    }

    func export(_ rid: String, format: String, answers: Bool) async throws -> Data {
        try await request("reports/\(rid)/export", query: ["format": format, "answers": answers ? "true" : "false"])
    }

    func saveScores(_ rid: String, _ rows: [ScoreRow]) async throws {
        _ = try await request("reports/\(rid)/scores", method: "POST", body: try Self.encoder.encode(rows))
    }

    struct EvalBody: Encodable { var round: Int; var overallNote: String }
    func evaluate(_ cid: String, note: String) async throws -> EvaluationRow {
        try await json(EvaluationRow.self, "candidates/\(cid)/evaluation", method: "POST", body: EvalBody(round: 1, overallNote: note))
    }

    struct SummaryBody: Encodable { var transcript: [Utterance]; var overallNote: String }
    func summarize(_ cid: String, transcript: [Utterance], note: String) async throws -> InterviewSummary {
        try await json(InterviewSummary.self, "candidates/\(cid)/summary", method: "POST",
                       body: SummaryBody(transcript: transcript, overallNote: note))
    }

    struct NoteBody: Encodable { var questionId: String; var transcript: [Utterance] }
    struct NoteResult: Decodable { var note: String }
    func questionNote(_ cid: String, questionId: String, transcript: [Utterance]) async throws -> String {
        try await json(NoteResult.self, "candidates/\(cid)/question-note", method: "POST",
                       body: NoteBody(questionId: questionId, transcript: transcript)).note
    }

    func settings() async throws -> AppSettings { try await json(AppSettings.self, "settings") }
    func saveSettings(_ s: AppSettingsIn) async throws -> AppSettings {
        try await json(AppSettings.self, "settings", method: "PUT", body: s)
    }
    struct TestResult: Decodable { var model: String }
    func testSettings() async throws -> String { try await json(TestResult.self, "settings/test", method: "POST").model }

    func deletePosition(_ id: String) async throws { _ = try await request("positions/\(id)", method: "DELETE") }

    func snippetURL(_ cid: String, lines: [Int]) -> URL {
        var c = URLComponents(url: base.appending(path: "candidates/\(cid)/snippet"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "lines", value: lines.map(String.init).joined(separator: ","))]
        return c.url!
    }

    /// 下载原始简历到临时目录，返回本地文件
    func resumeFile(_ cid: String) async throws -> URL {
        let (data, resp) = try await URLSession.shared.data(from: base.appending(path: "candidates/\(cid)/file"))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw APIError(message: L("没有找到原始简历文件")) }
        let ext = (http.value(forHTTPHeaderField: "X-Filename") ?? ".pdf").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let url = FileManager.default.temporaryDirectory.appending(path: "screener-\(cid).\(ext)")
        try data.write(to: url)
        return url
    }

    func locate(_ cid: String, lines: [Int]) async throws -> [LineMark] {
        try await json([LineMark].self, "candidates/\(cid)/locate", query: ["lines": lines.map(String.init).joined(separator: ",")])
    }

    func pageSizes(_ cid: String) async throws -> [PageSize] { try await json([PageSize].self, "candidates/\(cid)/pages") }
    func pageURL(_ cid: String, _ n: Int) -> URL { base.appending(path: "candidates/\(cid)/pages/\(n).png") }

    func saveTranscript(_ cid: String, _ t: [Utterance]) async throws {
        _ = try await request("candidates/\(cid)/transcript", method: "POST",
                              body: try Self.encoder.encode(SummaryBody(transcript: t, overallNote: "")))
    }

    struct OverallNote: Encodable { var note: String }
    func saveNote(_ cid: String, _ note: String) async throws {
        _ = try await request("candidates/\(cid)/note", method: "PUT", body: try Self.encoder.encode(OverallNote(note: note)))
    }

    // MARK: HiBob
    struct HiBobTest: Decodable { var employeeId: String; var interviews: Int }
    func hibobTest() async throws -> HiBobTest { try await json(HiBobTest.self, "hibob/test", method: "POST") }
    func hibobOpenings() async throws -> [HiBobOpening] { try await json([HiBobOpening].self, "hibob/openings") }
    func hibobInterviews() async throws -> [HiBobInterview] { try await json([HiBobInterview].self, "hibob/interviews") }
    struct HiBobImport: Encodable { var id: String; var title: String; var jd: String }
    struct NewID: Decodable { var id: String }
    func hibobImport(_ o: HiBobOpening) async throws -> String {
        try await json(NewID.self, "hibob/openings/import", method: "POST", body: HiBobImport(id: o.id, title: o.title, jd: o.jd)).id
    }

    struct DecisionBody: Encodable { var decision: String }
    func setDecision(_ cid: String, _ d: String) async throws {
        _ = try await request("candidates/\(cid)/decision", method: "PUT", body: try Self.encoder.encode(DecisionBody(decision: d)))
    }
    func deleteCandidate(_ cid: String) async throws { _ = try await request("candidates/\(cid)", method: "DELETE") }

    // MARK: HiBob（个人账号）
    struct URLResult: Decodable { var url: String }
    struct MCPStatus: Decodable { var connected: Bool; var user: String }
    func hibobLoginURL() async throws -> URL { URL(string: try await json(URLResult.self, "hibob/mcp/login", method: "POST").url)! }
    func hibobStatus() async throws -> MCPStatus { try await json(MCPStatus.self, "hibob/mcp/status") }
    func hibobLogout() async throws { _ = try await request("hibob/mcp/logout", method: "POST") }
    func hibobPipeline() async throws -> [BobOpening] { try await json([BobOpening].self, "hibob/pipeline") }
    func calendarEvents() async throws -> [CalEvent] { try await json([CalEvent].self, "calendar/events") }
    struct LocalEvent: Encodable { var uid, title, start, end, notes, location, url: String; var attendees: [String] }
    func calendarMatch(_ e: [LocalEvent]) async throws -> [CalEvent] {
        try await json([CalEvent].self, "calendar/match", method: "POST", body: e)
    }
    struct LiveBody: Encodable { var questionId: String; var transcript: [Utterance] }
    func liveHint(_ cid: String, questionId: String, transcript: [Utterance]) async throws -> LiveHint {
        try await json(LiveHint.self, "candidates/\(cid)/live-hint", method: "POST", body: LiveBody(questionId: questionId, transcript: transcript))
    }
    struct CompareBody: Encodable { var candidateIds: [String]; var ai: Bool }
    func compare(_ ids: [String], ai: Bool) async throws -> CompareData {
        try await json(CompareData.self, "compare", method: "POST", body: CompareBody(candidateIds: ids, ai: ai))
    }
    func nextRound(_ cid: String) async throws { _ = try await request("candidates/\(cid)/next-round", method: "POST") }
    func shareLark(_ cid: String) async throws { _ = try await request("candidates/\(cid)/share-lark", method: "POST") }
    func insights() async throws -> Insights { try await json(Insights.self, "insights") }
}
