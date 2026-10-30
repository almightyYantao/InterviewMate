import AppKit
import SwiftUI

/// 「面试反馈」：面试结束后的评价、逐题复盘、打分备注和逐字稿，随时回来看。
struct FeedbackPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backend: Backend
    let resp: ReportResponse
    @State private var copied = false
    @State private var copiedHiBob = false
    @State private var askLark = false
    @State private var larkState: String?        // nil / sending / sent
    @State private var generating = false
    @State private var showTranscript = false
    @State private var note = ""
    @State private var noteSaved = true

    var questions: [Question] { resp.report.questions }
    var round: Int { resp.report.round ?? 1 }
    /// 只看这一轮的评价
    var evaluation: EvaluationRow? { resp.evaluations.last { ($0.round ?? 1) == round } }
    var scores: [String: ScoreRow] { Dictionary(resp.scores.map { ($0.questionId, $0) }, uniquingKeysWith: { _, b in b }) }
    var transcript: [Utterance] { resp.transcript ?? [] }

    var body: some View {
        if evaluation == nil && resp.scores.isEmpty && transcript.isEmpty && (resp.overallNote ?? "").isEmpty {
            ContentUnavailableView {
                Label("还没有面试记录", systemImage: "text.bubble")
            } description: {
                Text("面试时逐题打分、记备注，结束后生成评价，都会显示在这里")
            } actions: {
                PrimaryButton(title: "开始面试", symbol: "play.fill") { store.interviewing = true }
            }
            .emptyStateLayout()
        } else {
            VStack(alignment: .leading, spacing: 16) {
                verdict
                noteCard
                scoreTiles
                if let s = resp.summary { SummaryReview(s: s, questions: questions) }
                scoreTable
                if !transcript.isEmpty { transcriptCard }
            }
        }
    }

    // MARK: 结论与评价

    @ViewBuilder var verdict: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(["通过", "待定", "不通过"], id: \.self) { d in
                        Button { store.setDecision(store.selectedCandidateID ?? "", d) } label: {
                            if evaluation?.decision == d { Label(L(d), systemImage: "checkmark") } else { Text(L(d)) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(evaluation.map { String(format: L("结论：%@"), L($0.decision)) } ?? L("设置结论"))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(decisionTint)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(decisionTint.opacity(0.12), in: Capsule())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("点击修改面试结论")
                if let t = resp.interviewedAt { Text(String(t.prefix(16)).replacingOccurrences(of: "T", with: " ")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if generating { ProgressView().controlSize(.small) }
                PillButton(title: evaluation == nil ? "生成评价" : "重新生成", symbol: "sparkles") { regenerate() }
                    .disabled(generating)
                if evaluation != nil {
                    PillButton(title: copiedHiBob ? "已复制" : "复制到 HiBob", symbol: copiedHiBob ? "checkmark" : "arrow.up.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hibobText, forType: .string)
                        withAnimation { copiedHiBob = true }
                    }
                    .help("按 HiBob 面试反馈的格式复制：推荐结论、评价、逐题打分、整体反馈")
                }
                if evaluation != nil {
                    PillButton(title: larkState == "sent" ? "已发到 Lark" : larkState == "sending" ? "发送中…" : "发到 Lark",
                               symbol: larkState == "sent" ? "checkmark" : "paperplane") { askLark = true }
                        .disabled(larkState == "sending")
                        .help(L("把结论、评价、亮点和不足、打分统计以卡片发到设置里的 Lark 群"))
                    PrimaryButton(title: String(format: L("生成第 %lld 轮准备"), round + 1), symbol: "arrow.right.circle") { store.nextRound() }
                        .help(L("带着这一轮仍存疑、没问到、答得不好的地方，重新出下一轮的面试题"))
                }
                if let e = evaluation {
                    PillButton(title: copied ? "已复制" : "复制", symbol: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(e.comment, forType: .string)
                        withAnimation { copied = true }
                    }
                }
            }
            // 前几轮的结论，方便对照
            ForEach(Array(resp.evaluations.filter { ($0.round ?? 1) < round }.enumerated()), id: \.offset) { _, p in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(format: L("第 %lld 轮"), p.round ?? 1)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Chip(text: L(p.decision), color: p.decision == "通过" ? .green : p.decision == "不通过" ? .red : .orange)
                    Text(p.comment).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let e = evaluation {
                Text(e.comment).font(.system(size: 14.5)).lineSpacing(5).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.page, in: RoundedRectangle(cornerRadius: 14))
        .alert("发到 Lark 群？", isPresented: $askLark) {
            Button("发送") { sendLark() }
            Button("取消", role: .cancel) {}
        } message: { Text("会把这一轮的结论、评价、亮点和不足、打分统计和你的整体反馈，以卡片发到设置里配置的 Lark 群，群里所有人都能看到。") }
    }

    /// 整体反馈：自己写的，改完自动保存；重新生成评价时会带上
    var noteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("我的整体反馈").font(.headline)
                Spacer()
                Text(noteSaved ? "已保存" : "保存中…").font(.caption).foregroundStyle(.secondary)
            }
            NoteBox(text: $note, placeholder: "疑点核实结果、英语、期望薪资、到岗时间、整体印象等", minHeight: 90)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.page, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { note = store.report?.overallNote ?? resp.overallNote ?? "" }
        .onChange(of: note) { noteSaved = false }
        .task(id: note) {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, !noteSaved else { return }
            do {
                try await backend.saveNote(store.selectedCandidateID ?? "", note)
                store.report?.overallNote = note    // 切 Tab 回来时用的是内存里的报告，同步一下
                noteSaved = true
            } catch { store.errorMessage = error.localizedDescription }
        }
    }

    func sendLark() {
        larkState = "sending"
        Task {
            do { try await backend.shareLark(store.selectedCandidateID ?? ""); withAnimation { larkState = "sent" } }
            catch { larkState = nil; store.errorMessage = error.localizedDescription }
        }
    }

    var decisionTint: Color {
        switch evaluation?.decision { case "通过": .green; case "不通过": .red; case "待定": .orange; default: .gray }
    }

    var scoreTiles: some View {
        let vals = questions.map { scores[$0.id]?.score ?? "" }
        return HStack(spacing: 12) {
            CountTile(title: "优秀", count: vals.filter { $0 == "excellent" }.count, color: .green)
            CountTile(title: "合格", count: vals.filter { $0 == "pass" }.count, color: Theme.brand)
            CountTile(title: "不合格", count: vals.filter { $0 == "fail" }.count, color: .red)
            CountTile(title: "跳过", count: vals.filter { $0 == "skip" }.count, color: .secondary)
            CountTile(title: "未打分", count: vals.filter { $0.isEmpty }.count, color: .gray)
        }
    }

    // MARK: 我的打分和备注

    var scoreTable: some View {
        let rows = questions.filter { scores[$0.id] != nil }
        return VStack(alignment: .leading, spacing: 10) {
            Text("我的打分和备注").font(.headline)
            if rows.isEmpty { Text("面试时没有打分或记备注").foregroundStyle(.secondary).font(.callout) }
            ForEach(rows) { q in
                let s = scores[q.id]!
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(q.id).font(.caption.monospaced().weight(.semibold)).foregroundStyle(Theme.brand).frame(width: 30, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(q.question).font(.callout.weight(.medium)).lineLimit(2)
                        if let n = s.note, !n.isEmpty { Text(n).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    Spacer(minLength: 8)
                    if let v = s.score, !v.isEmpty {
                        Chip(text: Labels.score[v] ?? v, color: ["excellent": .green, "pass": Theme.brand, "fail": .red][v] ?? .gray)
                    }
                }
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.page, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: 逐字稿

    var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { showTranscript.toggle() } } label: {
                HStack {
                    Label(String(format: L("逐字稿 · %lld 句"), transcript.count), systemImage: "text.quote").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.down").foregroundStyle(.tertiary).rotationEffect(.degrees(showTranscript ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showTranscript {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(transcript.enumerated()), id: \.offset) { i, u in
                        if i == 0 || transcript[i - 1].questionId != u.questionId,
                           let q = questions.first(where: { $0.id == u.questionId }) {
                            Text("\(q.id) · \(q.question)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .lineLimit(1).padding(.top, 6)
                        }
                        Bubble(speaker: u.speaker, text: u.text, at: u.at)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.page, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// 粘贴到 HiBob 面试反馈里的文字（HiBob 接口不能写入，只能手动粘贴）
    var hibobText: String {
        var t: [String] = []
        if let e = evaluation {
            let rec = ["通过": "推荐（Yes）", "待定": "待定（Maybe）", "不通过": "不推荐（No）"][e.decision] ?? e.decision
            t.append("推荐结论：\(rec)")
            t.append("")
            t.append("面试评价：\n\(e.comment)")
        }
        let rows = questions.compactMap { q -> String? in
            guard let sc = scores[q.id], let v = sc.score, !v.isEmpty, v != "skip" else { return nil }
            let note = (sc.note ?? "").isEmpty ? "" : "——\(sc.note!)"
            return "· \(q.question)：\(Labels.score[v] ?? v)\(note)"
        }
        if !rows.isEmpty { t.append(""); t.append("逐题表现："); t += rows }
        if let s = resp.summary {
            if !s.highlights.isEmpty { t.append(""); t.append("亮点：" + s.highlights.joined(separator: "；")) }
            if !s.concerns.isEmpty { t.append("不足：" + s.concerns.joined(separator: "；")) }
        }
        if !note.isEmpty { t.append(""); t.append("整体反馈：\n\(note)") }
        return t.joined(separator: "\n")
    }

    func regenerate() {
        generating = true
        Task {
            let cid = store.selectedCandidateID ?? ""
            do {
                if transcript.isEmpty { _ = try await backend.evaluate(cid, note: note) }
                else { _ = try await backend.summarize(cid, transcript: transcript, note: note) }
                await store.loadReport()
            } catch { store.errorMessage = error.localizedDescription }
            generating = false
        }
    }
}
