import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class Store: ObservableObject {
    weak var backend: Backend?

    @Published var positions: [Position] = []
    @Published var selectedPositionID: String?
    @Published var candidates: [Candidate] = []
    @Published var selectedCandidateID: String?
    @Published var report: ReportResponse?
    @Published var highlightedLine: Int?
    @Published var resumeMarks: [Int] = []
    @Published var resumeFocusToken = 0
    @Published var resumeShowOriginal = false
    @Published var expandedQuestions: Set<String> = []
    @Published var showHiBob = false
    @Published var hibobConnected = false
    @Published var showCalendar = false
    var pendingCandidateID: String?
    var pendingInterview = false
    @Published var compareMode = false            // 候选人列表处于「选人对比」状态
    @Published var compareIDs: [String] = []
    @Published var showCompare = false
    @Published var showInsights = false
    @Published var detailAnchor: CGRect = .zero   // 被点的日程在窗口里的位置，卡片贴着它弹出
    var detailTap: CGPoint = .zero
    @Published var detailEvent: CalEvent?
    @Published var focusEventID: String?        // 从侧边栏 / 日历格子点进来要展开的日程     // 正在看详情的日程（App 自绘弹窗，点背景关闭）

    /// 直接打开某个候选人的报告（可能在别的岗位下）
    func openCandidate(_ pid: String, _ cid: String) {
        showHiBob = false; showCalendar = false; showCompare = false; compareMode = false; showInsights = false; detailEvent = nil
        if selectedPositionID == pid { selectedCandidateID = cid }
        else { pendingCandidateID = cid; selectedPositionID = pid }
    }
    let reminder = InterviewReminder()
    let watcher = ResumeWatcher()
    // HiBob 招聘数据缓存：切页面不重新拉，超过 5 分钟后台更新
    @Published var bobPipeline: [BobOpening]? = Store.cachedBob() {
        didSet { if let v = bobPipeline, let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: "bobPipeline") } }
    }
    static func cachedBob() -> [BobOpening]? {
        UserDefaults.standard.data(forKey: "bobPipeline").flatMap { try? JSONDecoder().decode([BobOpening].self, from: $0) }
    }
    @Published var bobExpanded: Set<String> = []
    var bobLoadedAt: Date?
    @Published var deletingCandidate: Candidate?
    @Published var showResume = false
    @Published var reportTab = 0
    @Published var showNewPosition = false
    @Published var showSettings = false
    @Published var candidatesLoaded = false
    @Published var settings: AppSettings?
    @Published var deletingPosition: Position?
    @Published var editingPosition: Position?
    @Published var showImporter = false
    @Published var interviewing = false
    @Published var errorMessage: String?

    var selectedPosition: Position? { positions.first { $0.id == selectedPositionID } }
    var selectedCandidate: Candidate? { candidates.first { $0.id == selectedCandidateID } }

    func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { errorMessage = error.localizedDescription }
        }
    }

    func deletePosition(_ p: Position) {
        Task {
            do {
                try await backend?.deletePosition(p.id)
                if selectedPositionID == p.id { selectedPositionID = nil }
                await loadPositions()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// 跳到「简历原文」并高亮这些行
    func locateInResume(_ lines: [Int]) {
        guard !lines.isEmpty else { return }
        resumeMarks = lines
        resumeFocusToken += 1
        resumeShowOriginal = true
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { reportTab = 5 }
    }

    /// 手动改面试结论（通过 / 待定 / 不通过）
    func setDecision(_ cid: String, _ d: String) {
        run {
            try await self.backend?.setDecision(cid, d)
            // HiBob 页缓存里的同一个人一起改
            if var v = self.bobPipeline {
                for i in v.indices { for j in v[i].applicants.indices where v[i].applicants[j].candidateId == cid { v[i].applicants[j].localDecision = d } }
                self.bobPipeline = v
            }
            await self.loadCandidates()
            if self.selectedCandidateID == cid { await self.loadReport() }
        }
    }

    func deleteCandidate(_ cid: String) {
        run {
            try await self.backend?.deleteCandidate(cid)
            if self.selectedCandidateID == cid { self.selectedCandidateID = nil }
            await self.loadCandidates()
        }
    }

    /// 截图用：环境变量 SCREENER_DEMO=gallery|board|compare|interview|report:<tab> 打开指定页面
    func applyDemo() async {
        guard let mode = ProcessInfo.processInfo.environment["SCREENER_DEMO"] else { return }
        UserDefaults.standard.set(mode == "board" ? "board" : "cards", forKey: "galleryMode")
        try? await Task.sleep(for: .seconds(1.5))
        await loadCandidates()
        let done = candidates.filter { $0.status == "done" }.sorted { $0.scoreSort > $1.scoreSort }
        if mode == "compare" { compareIDs = done.map(\.id); showCompare = true }
        if mode.hasPrefix("report") || mode == "interview", let c = done.first {
            selectedCandidateID = c.id
            try? await Task.sleep(for: .seconds(1))   // 切候选人会把 Tab 重置为概览，等它之后再设
            reportTab = Int(mode.split(separator: ":").last ?? "0") ?? 0
            if mode == "interview" { pendingInterview = true }
        }
        // SCREENER_SHOT=路径：几秒后把窗口内容存成 PNG 并退出（不需要录屏权限）
        if let path = ProcessInfo.processInfo.environment["SCREENER_SHOT"] {
            try? await Task.sleep(for: .seconds(6))
            let win = NSApp.windows.filter { $0.isVisible }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            if let v = (win?.attachedSheet ?? win)?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    func loadPositions() async {
        guard let backend else { return }
        do {
            let ps = try await backend.positions()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { positions = ps }
            if settings == nil { settings = try? await backend.settings() }
            hibobConnected = (try? await backend.hibobStatus().connected) ?? false
            if ProcessInfo.processInfo.environment["SCREENER_DEMO"] == nil { reminder.start(store: self, backend: backend) }   // 截图时不读真实日历
            watcher.start()
            if selectedPositionID == nil { selectedPositionID = positions.first?.id }
        } catch { errorMessage = error.localizedDescription }
    }

    func loadCandidates() async {
        guard let backend, let pid = selectedPositionID else { candidates = []; return }
        if let cs = try? await backend.candidates(pid), pid == selectedPositionID {
            let wasDone = Set(candidates.filter { $0.status == "done" }.map(\.id))
            if cs.map(\.id) == candidates.map(\.id) { candidates = cs }
            else { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { candidates = cs } }
            candidatesLoaded = true
            // 当前选中的候选人刚生成完，自动刷新报告
            if let sel = selectedCandidateID, !wasDone.contains(sel),
               cs.first(where: { $0.id == sel })?.status == "done" { await loadReport() }
        }
    }

    func loadReport() async {
        guard let backend, let cid = selectedCandidateID,
              candidates.first(where: { $0.id == cid })?.status == "done" else { report = nil; return }
        do {
            let r = try await backend.report(cid)
            if cid == selectedCandidateID {
                report = r; highlightedLine = nil
                if pendingInterview { pendingInterview = false; interviewing = true }   // 从日程详情点了「开始面试」
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// 上传到指定岗位（下载文件夹自动发现的简历用）；导入后切到这个岗位
    func upload(_ urls: [URL], to pid: String) {
        showHiBob = false; showCalendar = false; showCompare = false
        if selectedPositionID != pid { selectedPositionID = pid }
        selectedCandidateID = nil
        upload(urls)
    }

    func upload(_ urls: [URL]) {
        for u in urls { watcher.handled.insert(u.path) }
        guard let backend, let pid = selectedPositionID else { return }
        run {
            for u in urls { try await backend.upload(pid, file: u) }
            await self.loadCandidates()
        }
    }

    func regenerate(_ stage: String) {
        guard let backend, let cid = selectedCandidateID else { return }
        run {
            try await backend.regenerate(cid, stage: stage)
            self.report = nil
            try? await Task.sleep(for: .milliseconds(400))
            await self.loadCandidates()
        }
    }

    /// 带着这一轮的遗留，生成下一轮的面试题和准备材料
    func nextRound() {
        guard let backend, let cid = selectedCandidateID else { return }
        run {
            try await backend.nextRound(cid)
            self.report = nil; self.reportTab = 3
            try? await Task.sleep(for: .milliseconds(400))
            await self.loadCandidates()
        }
    }

    func deleteQuestion(_ q: Question) {
        guard let backend, let r = report else { return }
        run {
            try await backend.updateQuestions(r.id, r.report.questions.filter { $0.id != q.id })
            await self.loadReport()
        }
    }

    func export(format: String, answers: Bool) {
        guard let backend, let r = report else { return }
        let panel = NSSavePanel()
        let suffix = answers ? "一面准备" : "面试记录表"
        panel.nameFieldStringValue = "\(r.report.candidate)-\(suffix).\(format)"
        panel.allowedContentTypes = [format == "html" ? .html : format == "md" ? UTType(filenameExtension: "md") ?? .plainText
                                                    : UTType(filenameExtension: "docx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run {
            let data = try await backend.export(r.id, format: format, answers: answers)
            try data.write(to: url)
            // 网页直接用浏览器打开，其他格式在访达里选中
            if format == "html" { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
