import AppKit
import SwiftUI

struct InterviewView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backend: Backend
    @Environment(\.dismiss) private var dismiss

    let response: ReportResponse
    var questions: [Question] { response.report.questions }

    @State private var index = 0
    @State private var scores: [String: String] = [:]
    @State private var notes: [String: String] = [:]
    @State private var startedAt = Date()
    @State private var questionStartedAt = Date()
    @State private var showAnswer = true
    @State private var finished = false
    @State private var overall = ""
    @State private var evaluation: EvaluationRow?
    @State private var generating = false
    @State private var copied = false
    @StateObject private var tr = Transcriber()
    @State private var askConsent = false
    @State private var startError: String?
    @State private var noting: Set<String> = []
    @State private var hints: [String: LiveHint] = [:]      // 每道题最新的实时提示
    @State private var hintBusy = false
    @State private var hintedAt: [String: Int] = [:]        // 上次出提示时这道题有几句
    @State private var review: InterviewSummary?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
            HStack(spacing: 0) {
                rail
                Rectangle().fill(Color.black.opacity(0.06)).frame(width: 1)
                ZStack {
                    if questions.isEmpty { ContentUnavailableView("这份报告没有面试题", systemImage: "list.bullet.rectangle", description: Text("先在报告里重新出题")) }   // 防止空题目时越界崩溃
                    else if finished { summary.transition(.opacity.combined(with: .scale(scale: 0.98))) }
                    else { questionPage.id(index).transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity)) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.spring(response: 0.38, dampingFraction: 0.88), value: index)
                .animation(.spring(response: 0.38, dampingFraction: 0.88), value: finished)
                if !finished && (tr.running || !tr.utterances.isEmpty) {
                    Rectangle().fill(Color.black.opacity(0.06)).frame(width: 1)
                    TranscriptPane(tr: tr, questionId: questions[index].id, hint: hints[questions[index].id], hintBusy: hintBusy) { refreshHint(force: true) }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: tr.running)
        }
        .overlay(alignment: .top) {
            if let k = markFlash {
                Label(k == "mark_good" ? L("已标记为亮点") : L("已标记为存疑"), systemImage: k == "mark_good" ? "hand.thumbsup.fill" : "questionmark.diamond.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background((k == "mark_good" ? Color.green : Color.orange).gradient, in: Capsule())
                    .padding(.top, 76).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: 1180, height: 780)
        .background(Color.white)
        .tint(Theme.brand)
        .onAppear {
            for s in response.scores {
                if let v = s.score { scores[s.questionId] = v }
                if let n = s.note { notes[s.questionId] = n }
            }
            tr.currentQuestion = questions.first?.id ?? ""
            overall = response.overallNote ?? ""
        }
        .onChange(of: index) { tr.currentQuestion = questions[index].id }
        // 候选人每多说两句，就根据这道题的逐字稿更新一次追问提示
        .onChange(of: tr.utterances.count) { refreshHint(force: false) }
        .onDisappear { tr.stop() }
        .onChange(of: tr.fatal) { if let f = tr.fatal { startError = f; tr.fatal = nil } }
        .alert("没法开始转写", isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } })) {
            Button("打开系统设置") {
                let dictation = startError?.contains("听写") == true || startError?.contains("Dictation") == true
                NSWorkspace.shared.open(URL(string: dictation ? "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
                                                              : "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
            }
            Button("好", role: .cancel) {}
        } message: { Text(startError ?? "") }
        .alert("开始录音转写", isPresented: $askConsent) {
            Button("已征得同意，开始") { startTranscribing() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先告知候选人本次面试会录音转写，并征得同意。\n音频只在本机识别、不保存；逐字稿会随面试记录保存 \(store.settings?.retentionDays ?? 180) 天，结束时发送给 AI 生成总结。\n建议戴耳机，避免候选人的声音被麦克风重复收进来。")
        }
    }

    // MARK: 顶栏

    var header: some View {
        HStack(spacing: 14) {
            Text(String(response.report.candidate.prefix(1))).font(.headline).foregroundStyle(.white)
                .frame(width: 38, height: 38).background(Theme.brand.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("正在面试 · \(response.report.candidate)").font(.headline)
                Text(response.report.position).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            RecordControl(tr: tr) { askConsent = true }
            if tr.running && !finished {
                HStack(spacing: 6) {
                    PillButton(title: "亮点", symbol: "hand.thumbsup") { mark("mark_good") }
                        .keyboardShortcut("g", modifiers: .command).help(L("把候选人刚说的这句标为亮点（⌘G）"))
                    PillButton(title: "存疑", symbol: "questionmark.diamond") { mark("mark_doubt") }
                        .keyboardShortcut("d", modifiers: .command).help(L("把候选人刚说的这句标为存疑（⌘D）"))
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 10) {
                    TimeChip(title: "总用时", seconds: Int(ctx.date.timeIntervalSince(startedAt)),
                             limit: response.report.interviewMinutes * 60)
                    if !finished, index < questions.count {
                        TimeChip(title: "本题", seconds: Int(ctx.date.timeIntervalSince(questionStartedAt)),
                                 limit: questions[index].minutes * 60)
                    }
                }
            }
            PillButton(title: "退出", symbol: "xmark") {
                tr.stop()
                // 先关窗口，保存放后台做，不让人等网络
                let cid = store.selectedCandidateID ?? "", note = overall, lines = tr.utterances, hasReview = review != nil
                if !note.isEmpty { store.report?.overallNote = note }
                dismiss()
                Task {
                    await saveScores()
                    if !note.isEmpty { try? await backend.saveNote(cid, note) }
                    // 逐字稿还没随总结保存过的，退出时先存下来，「面试反馈」里能看到、能补生成总结
                    if !lines.isEmpty && !hasReview { try? await backend.saveTranscript(cid, lines) }
                    await store.loadReport()
                    await store.loadCandidates()
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    // MARK: 左侧题目导航

    var rail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(questions.enumerated()), id: \.element.id) { i, q in
                        RailRow(q: q, score: scores[q.id], selected: !finished && i == index) { jump(to: i) }.id(i)
                    }
                    Divider().padding(.vertical, 8)
                    RailFinishRow(selected: finished, scored: questions.filter { (scores[$0.id] ?? "") != "" }.count,
                                  total: questions.count) {
                        Task { await saveScores() }
                        finished = true
                    }
                }
                .padding(10)
            }
            .onChange(of: index) { withAnimation { proxy.scrollTo(index, anchor: .center) } }
        }
        .frame(width: 250)
        .background(Theme.page)
    }

    // MARK: 逐题

    var questionPage: some View {
        let q = questions[index]
        let color = Theme.section[q.section] ?? Theme.brand
        return VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in timeAlert(ctx.date) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        Pill(text: q.section, symbol: Labels.sectionSymbol[q.section] ?? "circle", color: color)
                        Text("第 \(index + 1) / \(questions.count) 题 · 建议 \(q.minutes) 分钟").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button { withAnimation(.snappy) { showAnswer.toggle() } } label: {
                            Label(showAnswer ? "隐藏参考答案" : "显示参考答案", systemImage: showAnswer ? "eye.slash" : "eye")
                                .font(.callout).foregroundStyle(Theme.brand)
                        }.buttonStyle(.plain)
                    }

                    Text(q.question).font(.system(size: 20, weight: .semibold)).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)

                    if q.source.type == "resume" {
                        HStack(alignment: .top, spacing: 8) {
                            Rectangle().fill(color).frame(width: 3)
                            Text("简历原文「\(q.source.quote)」").font(.callout).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    ResumeSnippets(lines: q.resumeLines(doubts: response.report.doubts), color: color, locate: false)

                    if !q.followUps.isEmpty {
                        Panel(title: "追问", symbol: "arrow.turn.down.right", color: .teal) {
                            ForEach(q.followUps, id: \.self) { Text($0) }
                        }
                    }

                    if showAnswer {
                        VStack(alignment: .leading, spacing: 12) {
                            Panel(title: "参考答案要点", symbol: "lightbulb.fill", color: Theme.brand) {
                                ForEach(Array(q.answerPoints.enumerated()), id: \.offset) { i, p in
                                    let key = q.keyPoints.contains(p)
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(key ? .white : Theme.brand)
                                            .frame(width: 18, height: 18).background(key ? Color.orange : Theme.brand.opacity(0.12), in: Circle())
                                        Text(p).fontWeight(key ? .semibold : .regular)
                                    }
                                }
                            }
                            if !q.redFlags.isEmpty {
                                Panel(title: "红旗信号", symbol: "flag.fill", color: .red) { ForEach(q.redFlags, id: \.self) { Text($0) } }
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            scoreBar(q)
        }
    }

    func scoreBar(_ q: Question) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ScoreOption(key: "excellent", label: "优秀", hint: q.rubric.excellent, symbol: "star.fill", color: .green,
                            selected: scores[q.id] == "excellent", shortcut: "1") { toggleScore(q, "excellent") }
                ScoreOption(key: "pass", label: "合格", hint: q.rubric.pass, symbol: "checkmark", color: Theme.brand,
                            selected: scores[q.id] == "pass", shortcut: "2") { toggleScore(q, "pass") }
                ScoreOption(key: "fail", label: "不合格", hint: q.rubric.fail, symbol: "xmark", color: .red,
                            selected: scores[q.id] == "fail", shortcut: "3") { toggleScore(q, "fail") }
            }
            .fixedSize(horizontal: false, vertical: true)
            .opacity(scores[q.id] == "skip" ? 0.35 : 1)
            .overlay {
                if scores[q.id] == "skip" {
                    Label("这题已跳过，不参与评价", systemImage: "forward.fill").font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.white, in: Capsule()).shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                NoteBox(text: Binding(get: { notes[q.id] ?? "" }, set: { notes[q.id] = $0 }),
                        placeholder: noting.contains(q.id) ? "AI 正在根据逐字稿总结本题…"
                            : tr.running || !tr.utterances.isEmpty ? "留空的话，切到下一题时 AI 会根据逐字稿自动写备注"
                            : "记录候选人的具体表现，例如讲到了哪些点、哪里卡住了")
                    .overlay(alignment: .bottomTrailing) {
                        if noting.contains(q.id) {
                            ProgressView().controlSize(.small).padding(12)
                        } else if (notes[q.id] ?? "").isEmpty && tr.utterances.contains(where: { $0.questionId == q.id }) {
                            Button { autoNote(q.id) } label: {
                                Label("AI 总结本题", systemImage: "sparkles").font(.caption.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Theme.brand.opacity(0.1), in: Capsule()).foregroundStyle(Theme.brand)
                            }.buttonStyle(.plain).padding(10)
                        }
                    }
                VStack(spacing: 8) {
                    PillButton(title: scores[q.id] == "skip" ? "取消跳过" : "跳过此题", symbol: "forward") { skip(q) }
                        .keyboardShortcut("4", modifiers: .command)
                        .help("这题没问，跳过，不参与评价（⌘4）")
                    PillButton(title: "上一题", symbol: "chevron.left") { move(-1) }
                        .opacity(index == 0 ? 0.4 : 1).disabled(index == 0)
                        .keyboardShortcut(.leftArrow, modifiers: .command)
                    PrimaryButton(title: index == questions.count - 1 ? "完成面试" : "下一题",
                                  symbol: index == questions.count - 1 ? "flag.checkered" : "chevron.right") { move(1) }
                        .keyboardShortcut(.rightArrow, modifiers: .command)
                }
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 18)
        .background(Theme.page.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1) }
    }

    /// 跳过：标记后直接去下一题；再点一次取消
    func skip(_ q: Question) {
        if scores[q.id] == "skip" {
            withAnimation(.spring(response: 0.3)) { scores[q.id] = "" }
        } else {
            withAnimation(.spring(response: 0.3)) { scores[q.id] = "skip" }
            move(1)
        }
    }

    func toggleScore(_ q: Question, _ k: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { scores[q.id] = scores[q.id] == k ? "" : k }
    }

    func jump(to i: Int) {
        if !finished { autoNote(questions[index].id) }
        Task { await saveScores() }
        finished = false
        index = i
        questionStartedAt = Date()
    }

    func move(_ d: Int) {
        autoNote(questions[index].id)
        Task { await saveScores() }
        if index + d >= questions.count { finished = true; return }
        index = max(0, index + d)
        questionStartedAt = Date()
    }

    // MARK: 结束页

    var summary: some View {
        let vals = questions.map { scores[$0.id] ?? "" }
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("面试结束").font(.system(size: 26, weight: .bold))
                    Text(tr.utterances.isEmpty ? L("补充整体印象后，一键生成可以直接贴进招聘系统的评价")
                         : String(format: L("已转写 %lld 段对话，会结合逐字稿逐题复盘并生成评价"), tr.utterances.count)).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    CountTile(title: "优秀", count: vals.filter { $0 == "excellent" }.count, color: .green)
                    CountTile(title: "合格", count: vals.filter { $0 == "pass" }.count, color: Theme.brand)
                    CountTile(title: "不合格", count: vals.filter { $0 == "fail" }.count, color: .red)
                    CountTile(title: "跳过", count: vals.filter { $0 == "skip" }.count, color: .secondary)
                    CountTile(title: "未打分", count: vals.filter { $0.isEmpty }.count, color: .gray)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("整体备注").font(.callout.weight(.semibold))
                    NoteBox(text: $overall, placeholder: "疑点核实结果、英语、期望薪资、到岗时间等", minHeight: 90)
                }
                HStack {
                    Spacer()
                    if generating { ProgressView().controlSize(.small).padding(.trailing, 6) }
                    PrimaryButton(title: evaluation == nil ? (tr.utterances.isEmpty ? "生成面试评价" : "生成面试总结") : "重新生成", symbol: "sparkles") { generate() }
                        .disabled(generating).opacity(generating ? 0.6 : 1)
                }
                if let e = evaluation {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Chip(text: String(format: L("建议：%@"), L(e.decision)), color: e.decision == "通过" ? .green : e.decision == "不通过" ? .red : .orange)
                            Spacer()
                            PillButton(title: copied ? "已复制" : "复制", symbol: copied ? "checkmark" : "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(e.comment, forType: .string)
                                withAnimation { copied = true }
                            }
                        }
                        Text(e.comment).font(.system(size: 14.5)).lineSpacing(5).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(18)
                    .background(Theme.page, in: RoundedRectangle(cornerRadius: 14))
                    .transition(.opacity.combined(with: .offset(y: 10)))
                }
                if let review {
                    SummaryReview(s: review, questions: questions)
                        .transition(.opacity.combined(with: .offset(y: 10)))
                }
            }
            .padding(36)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    func generate() {
        generating = true; copied = false
        Task {
            await saveScores()
            do {
                let cid = store.selectedCandidateID ?? ""
                if tr.utterances.isEmpty {
                    let e = try await backend.evaluate(cid, note: overall)
                    withAnimation(.spring(response: 0.4)) { evaluation = e }
                } else {
                    if tr.running { tr.stop(); try? await Task.sleep(for: .seconds(2)) }  // 等最后一句识别完
                    autoNote(questions[index].id)
                    while !noting.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                    await saveScores()
                    let s = try await backend.summarize(cid, transcript: tr.utterances, note: overall)
                    withAnimation(.spring(response: 0.4)) {
                        evaluation = EvaluationRow(round: 1, decision: s.decision, comment: s.comment)
                        review = s
                    }
                }
            } catch { store.errorMessage = error.localizedDescription }
            generating = false
        }
    }

    /// 备注留空时，根据这道题的逐字稿让 AI 补一条备注
    func autoNote(_ qid: String) {
        let lines = tr.utterances.filter { $0.questionId == qid }
        guard scores[qid] != "skip", (notes[qid] ?? "").isEmpty, !noting.contains(qid), lines.contains(where: { $0.speaker == "candidate" }) || lines.count >= 2 else { return }
        noting.insert(qid)
        Task {
            if let n = try? await backend.questionNote(store.selectedCandidateID ?? "", questionId: qid, transcript: lines),
               !n.isEmpty, (notes[qid] ?? "").isEmpty {
                withAnimation { notes[qid] = n }
                await saveScores()
            }
            noting.remove(qid)
        }
    }

    @State private var markFlash: String?

    func mark(_ kind: String) {
        tr.addMark(kind)
        withAnimation(.spring(response: 0.3)) { markFlash = kind }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { markFlash = nil } }
    }

    /// 剩余时间不够问完剩下的题：提示建议跳过哪几道（先跳软性要求和时间长的，背景核实最后才跳）
    @ViewBuilder func timeAlert(_ now: Date) -> some View {
        let left = Double(response.report.interviewMinutes) - now.timeIntervalSince(startedAt) / 60
        let rest = questions.enumerated().filter { $0.offset > index && (scores[$0.element.id] ?? "").isEmpty }.map(\.element)
        let need = Double(rest.reduce(0) { $0 + $1.minutes })
        if !finished, !rest.isEmpty, need > left + 3 {
            let order = ["软性要求": 0, "缺口场景": 1, "项目深挖": 2, "核心能力": 3, "背景核实": 4]
            let cand = rest.sorted { (order[$0.section] ?? 2, -$0.minutes) < (order[$1.section] ?? 2, -$1.minutes) }
            let drop: [Question] = {
                var over = need - max(left, 0), out: [Question] = []
                for q in cand where over > 0 { out.append(q); over -= Double(q.minutes) }
                return out
            }()
            HStack(spacing: 10) {
                Image(systemName: "timer").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L("还剩约 %lld 分钟，剩下的题要 %lld 分钟"), Int(max(left, 0)), Int(need))).font(.callout.weight(.semibold))
                    Text(L("建议跳过：") + drop.map { "\($0.id) \($0.section)" }.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                PillButton(title: "一键跳过这些题", symbol: "forward") {
                    withAnimation(.spring(response: 0.3)) { for q in drop { scores[q.id] = "skip" } }
                    Task { await saveScores() }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 10)
            .background(Color.orange.opacity(0.08))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    func refreshHint(force: Bool) {
        let qid = questions[index].id
        let lines = tr.utterances.filter { $0.questionId == qid }
        guard !hintBusy, lines.contains(where: { $0.speaker == "candidate" }),
              force || (lines.last?.speaker == "candidate" && lines.count - (hintedAt[qid] ?? 0) >= 2) else { return }
        hintBusy = true
        hintedAt[qid] = lines.count
        Task {
            defer { hintBusy = false }
            if let h = try? await backend.liveHint(store.selectedCandidateID ?? "", questionId: qid, transcript: lines) {
                withAnimation(.spring(response: 0.35)) { hints[qid] = h }
            }
        }
    }

    func startTranscribing() {
        Task {
            startError = await tr.start(locale: store.settings?.speechLocale ?? "zh-CN", silence: store.settings?.silenceSeconds ?? 1.5,
                                         captureApp: store.settings?.captureApp ?? "")
        }
    }

    func saveScores() async {
        let rows = questions.compactMap { q -> ScoreRow? in
            let s = scores[q.id].flatMap { $0.isEmpty ? nil : $0 }
            let n = notes[q.id] ?? ""
            return (s == nil && n.isEmpty) ? nil : ScoreRow(questionId: q.id, score: s, note: n)
        }
        if !rows.isEmpty { try? await backend.saveScores(response.id, rows) }
    }
}

// MARK: - 组件

struct RailRow: View {
    let q: Question
    let score: String?
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var scoreColor: Color? { ["excellent": .green, "pass": Theme.brand, "fail": .red, "skip": Color.gray.opacity(0.5)][score ?? ""] }

    var body: some View {
        let color = Theme.section[q.section] ?? Theme.brand
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Text(String(q.id.dropFirst())).font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(selected ? .white : color)
                    .frame(width: 24, height: 24)
                    .background(selected ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.12)), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(q.question).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(2)
                        .foregroundStyle(.primary).multilineTextAlignment(.leading)
                    Text(score == "skip" ? L("已跳过") : "\(L(q.section)) · \(q.minutes) \(L("分钟"))").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let c = scoreColor {
                    Circle().fill(c).frame(width: 8, height: 8).padding(.top, 8).transition(.scale)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background {
                if selected { RoundedRectangle(cornerRadius: 10).fill(.white).shadow(color: .black.opacity(0.06), radius: 5, y: 2) }
                else if hover { RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.04)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

struct RailFinishRow: View {
    let selected: Bool, scored: Int, total: Int
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "flag.checkered").frame(width: 24, height: 24)
                    .foregroundStyle(selected ? .white : Theme.brand)
                    .background(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.brand.opacity(0.12)), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text("结束并生成评价").font(.system(size: 12.5, weight: .semibold))
                    Text("已打分 \(scored) / \(total)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background { if selected { RoundedRectangle(cornerRadius: 10).fill(.white).shadow(color: .black.opacity(0.06), radius: 5, y: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ScoreOption: View {
    let key: String, label: String, hint: String, symbol: String, color: Color
    let selected: Bool
    let shortcut: KeyEquivalent
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                        .foregroundStyle(selected ? color : .white)
                        .frame(width: 22, height: 22)
                        .background(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(color), in: Circle())
                    Text(L(label)).font(.system(size: 15, weight: .semibold)).foregroundStyle(selected ? .white : .primary)
                    Spacer()
                    Text(String(shortcut.character)).font(.caption2.monospaced()).foregroundStyle(selected ? .white.opacity(0.7) : .secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? .white.opacity(0.4) : Color.black.opacity(0.12)))
                }
                Text(hint).font(.caption).foregroundStyle(selected ? .white.opacity(0.88) : .secondary)
                    .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? AnyShapeStyle(color.gradient) : AnyShapeStyle(Color.white), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? .clear : (hover ? color.opacity(0.5) : Color.black.opacity(0.08)), lineWidth: 1.5))
            .shadow(color: selected ? color.opacity(0.3) : .clear, radius: 8, y: 3)
            .scaleEffect(selected ? 1.0 : (hover ? 1.01 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help("⌘\(shortcut.character)")
    }
}

struct NoteBox: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 64
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(L(placeholder)).foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.top, 1).allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .focusEffectDisabled()
        }
        .font(.system(size: 13.5))
        .frame(minHeight: minHeight, maxHeight: minHeight)
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Theme.brand.opacity(0.6) : Color.black.opacity(0.08), lineWidth: focused ? 1.5 : 1))
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

struct TimeChip: View {
    let title: String, seconds: Int, limit: Int
    var over: Bool { seconds > limit }
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.black.opacity(0.08), lineWidth: 3)
                Circle().trim(from: 0, to: min(1, Double(seconds) / Double(max(limit, 1))))
                    .stroke(over ? Color.red : Theme.brand, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(L(title)).font(.caption2).foregroundStyle(.secondary)
                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(over ? .red : .primary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(over ? Color.red.opacity(0.08) : Theme.page, in: Capsule())
    }
}

struct CountTile: View {
    let title: String
    let count: Int
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(L(title)).font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
}
