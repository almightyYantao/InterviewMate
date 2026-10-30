import SwiftUI

struct ReportView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if let r = store.report {
                ReportContent(resp: r)
            } else if let c = store.selectedCandidate {
                if c.status == "failed" {
                    ContentUnavailableView {
                        Label("生成失败", systemImage: "exclamationmark.octagon")
                    } description: { Text(c.error ?? "") } actions: {
                        Button("重试") { store.regenerate("all") }
                    }
                } else if c.status == "done" {
                    ProgressView()
                } else {
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text("正在生成一面准备材料").font(.title3)
                        Text(c.progress ?? "排队中").foregroundStyle(.secondary)
                        Text("通常需要 3～5 分钟，可以先去看别的候选人").font(.callout).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("选择一位候选人", systemImage: "person.crop.rectangle.stack",
                                       description: Text("在左侧列表中选择，查看筛选结论、疑点、匹配度和面试题"))
            }
        }
        .inspector(isPresented: Binding(get: { store.showResume && store.report != nil }, set: { store.showResume = $0 })) {
            if let r = store.report { ResumePane(lines: r.resumeLines) .inspectorColumnWidth(min: 280, ideal: 340, max: 480) }
        }
    }
}

struct ReportContent: View {
    @EnvironmentObject var store: Store
    let resp: ReportResponse
    var r: Report { resp.report }
    var reqs: [String: Requirement] {
        Dictionary((r.jd.requirements ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label("AI 生成，需人工复核。是否推进由面试官决定；出生日期仅用于时间线校验，年龄、性别、婚育、籍贯不参与评分和出题。",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)

                ConclusionCard(r: r, reqs: reqs)

                SectionHeader(title: "简历疑点", symbol: "exclamationmark.magnifyingglass", count: r.doubts.count)
                GroupBox {
                    VStack(spacing: 0) {
                        let order = ["high": 0, "medium": 1, "low": 2]
                        let ds = r.doubts.sorted { (order[$0.severity] ?? 3) < (order[$1.severity] ?? 3) }
                        ForEach(Array(ds.enumerated()), id: \.element.id) { i, d in
                            DoubtRow(d: d)
                            if i < ds.count - 1 { Divider() }
                        }
                    }
                }

                SectionHeader(title: "JD 匹配度", symbol: "checklist", count: r.match.count)
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(Array(r.match.enumerated()), id: \.element.id) { i, m in
                            MatchRow(m: m, req: reqs[m.reqId])
                            if i < r.match.count - 1 { Divider() }
                        }
                    }
                }

                SectionHeader(title: "面试题与参考答案", symbol: "list.bullet.rectangle",
                              count: r.questions.count, trailing: "共 \(r.questions.reduce(0) { $0 + $1.minutes }) 分钟")
                ForEach(Labels.sections, id: \.self) { sec in
                    let qs = r.questions.filter { $0.section == sec }
                    if !qs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("\(sec) · \(qs.reduce(0) { $0 + $1.minutes }) 分钟", systemImage: Labels.sectionSymbol[sec] ?? "circle")
                                .font(.headline).foregroundStyle(.secondary)
                            ForEach(qs) { LegacyQuestionCard(q: $0, reqs: reqs, doubts: r.doubts) }
                        }
                    }
                }

                SectionHeader(title: "评价建议", symbol: "text.bubble")
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        SignalList(title: "通过信号", symbol: "hand.thumbsup", color: .green, items: r.conclusion.passSignals)
                        Divider()
                        SignalList(title: "不通过信号", symbol: "hand.thumbsdown", color: .red, items: r.conclusion.failSignals)
                        ForEach(Array(resp.evaluations.enumerated()), id: \.offset) { _, e in
                            Divider()
                            Text("面试评价 · \(e.decision)").font(.headline)
                            Text(e.comment).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                if !r.validation.isEmpty {
                    DisclosureGroup("校验层日志（\(r.validation.count) 条）") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(r.validation, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(r.candidate)
        .navigationSubtitle("\(r.position) · 第 \(resp.version) 版")
        .toolbar {
            ToolbarItemGroup {
                Button { store.interviewing = true } label: { Label("开始面试", systemImage: "play.circle") }
                    .help("进入面试模式：逐题计时、打分、生成评价")
                Menu {
                    Button("一面准备（Word）") { store.export(format: "docx", answers: true) }
                    Button("一面准备（Markdown）") { store.export(format: "md", answers: true) }
                    Divider()
                    Button("面试记录表，不含答案（Word）") { store.export(format: "docx", answers: false) }
                } label: { Label("导出", systemImage: "square.and.arrow.up") }
                .help("导出")
                Menu {
                    Button("只重新出题") { store.regenerate("questions") }
                    Button("整份重新生成") { store.regenerate("all") }
                } label: { Label("重新生成", systemImage: "arrow.clockwise") }
                .help("重新生成")
                Button { store.showResume.toggle() } label: { Label("简历原文", systemImage: "sidebar.right") }
                    .help("显示 / 隐藏简历原文")
            }
        }
    }
}

// MARK: - 组件

struct SectionHeader: View {
    let title: String
    let symbol: String
    var count: Int? = nil
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: symbol).font(.title2.weight(.semibold))
            if let count { Text("\(count)").font(.title3).foregroundStyle(.secondary) }
            Spacer()
            if let trailing { Text(trailing).foregroundStyle(.secondary) }
        }
    }
}

struct ConclusionCard: View {
    let r: Report
    let reqs: [String: Requirement]
    var color: Color { ["advance": .green, "conditional": .orange, "reject": .red][r.conclusion.decision] ?? .gray }

    var body: some View {
        let c = r.conclusion
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("筛选结论").font(.caption).foregroundStyle(.secondary)
                        Text(Labels.decision[c.decision] ?? c.decision).font(.system(size: 26, weight: .bold)).foregroundStyle(color)
                    }
                    Divider().frame(height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("匹配分").font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(String(format: "%.1f", c.score)).font(.system(size: 26, weight: .bold)).monospacedDigit()
                            Text("/ 10").foregroundStyle(.secondary)
                        }
                    }
                    Gauge(value: c.score, in: 0...10) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity).tint(color).frame(maxWidth: 200)
                    Spacer()
                }
                Text(c.summary).font(.body).textSelection(.enabled)
                if !c.veto.isEmpty {
                    Label {
                        Text("一票否决：" + c.veto.map { "\($0) \(reqs[$0]?.text ?? "")" }.joined(separator: "；") + "（结论上限为「有条件推进」）")
                    } icon: { Image(systemName: "hand.raised.fill").foregroundStyle(.red) }
                    .font(.callout)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("必须核实").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    FlowTags(items: c.mustVerify)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FlowTags: View {
    let items: [String]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { tags }
            VStack(alignment: .leading, spacing: 4) { tags }
        }
    }
    @ViewBuilder var tags: some View {
        ForEach(items, id: \.self) {
            Text($0).font(.callout).padding(.horizontal, 8).padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

struct SeverityDot: View {
    let severity: String
    var color: Color { ["high": .red, "medium": .orange, "low": .gray][severity] ?? .gray }
    var body: some View {
        Text(Labels.severity[severity] ?? severity)
            .font(.caption.weight(.semibold)).foregroundStyle(.white)
            .frame(width: 22, height: 18)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct EvidenceLinks: View {
    @EnvironmentObject var store: Store
    let evidence: [Evidence]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(evidence.enumerated()), id: \.offset) { _, e in
                Button {
                    store.showResume = true
                    store.highlightedLine = e.line
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("L\(e.line)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text("「\(e.quote)」").font(.callout).multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.link)
                .help("在简历原文中定位")
            }
        }
    }
}

struct DoubtRow: View {
    let d: Doubt
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SeverityDot(severity: d.severity).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(d.title).font(.body.weight(.medium)).textSelection(.enabled)
                    Text(d.source == "rule" ? "规则" : "语义").font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).overlay(Capsule().stroke(.quaternary))
                }
                if !d.evidence.isEmpty { EvidenceLinks(evidence: d.evidence) }
                if !d.verifyQuestion.hasPrefix("（") {
                    Label(d.verifyQuestion, systemImage: "questionmark.bubble")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9).padding(.horizontal, 6)
    }
}

struct MatchRow: View {
    let m: MatchItem
    let req: Requirement?
    var color: Color { ["match": .green, "partial": .orange, "missing": .red, "unknown": .gray][m.verdict] ?? .gray }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Labels.verdictSymbol[m.verdict] ?? "circle").foregroundStyle(color).font(.title3)
                .help(Labels.verdict[m.verdict] ?? m.verdict)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(m.reqId).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(req?.text ?? "").font(req?.emphasized == true ? .body.weight(.bold) : .body)
                    Spacer()
                    if let req {
                        Text("\(Labels.level[req.level] ?? req.level) · 权重 \(req.weight)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(m.reason).font(.callout).foregroundStyle(.secondary)
                if !m.evidence.isEmpty { EvidenceLinks(evidence: m.evidence) }
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 6)
    }
}

struct LegacyQuestionCard: View {
    @EnvironmentObject var store: Store
    let q: Question
    let reqs: [String: Requirement]
    let doubts: [Doubt]
    @State private var expanded = false

    var sourceText: String {
        switch q.source.type {
        case "resume": return "简历原文「\(q.source.quote)」"
        case "jd": return "JD：" + (q.linkedRequirements.isEmpty ? q.source.quote
                                    : q.linkedRequirements.map { "\($0) \(reqs[$0]?.text ?? "")" }.joined(separator: "；"))
        default:
            let t = Dictionary(doubts.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
            return "疑点：" + (q.linkedDoubts.isEmpty ? q.source.quote : q.linkedDoubts.map { t[$0] ?? $0 }.joined(separator: "；"))
        }
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "quote.opening").foregroundStyle(.tertiary)
                        if q.source.type == "resume", let line = q.source.lines.first {
                            Button(sourceText) { store.showResume = true; store.highlightedLine = line }
                                .buttonStyle(.link).multilineTextAlignment(.leading)
                        } else {
                            Text(sourceText).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    Block(title: "参考答案要点", symbol: "lightbulb") {
                        ForEach(q.answerPoints, id: \.self) { p in
                            let key = q.keyPoints.contains(p)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: key ? "star.fill" : "circle.fill")
                                    .font(.system(size: key ? 9 : 5)).foregroundStyle(key ? .yellow : .secondary)
                                Text(p).fontWeight(key ? .semibold : .regular).textSelection(.enabled)
                            }
                        }
                    }
                    Block(title: "追问", symbol: "arrow.turn.down.right") { ForEach(q.followUps, id: \.self) { Text($0) } }
                    Block(title: "红旗信号", symbol: "flag.fill", tint: .red) { ForEach(q.redFlags, id: \.self) { Text($0) } }
                    Block(title: "评分标准", symbol: "chart.bar") {
                        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 4) {
                            GridRow { Text("优秀").foregroundStyle(.green); Text(q.rubric.excellent) }
                            GridRow { Text("合格").foregroundStyle(.orange); Text(q.rubric.pass) }
                            GridRow { Text("不合格").foregroundStyle(.red); Text(q.rubric.fail) }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("删除此题", role: .destructive) { store.deleteQuestion(q) }.controlSize(.small)
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(q.id).font(.callout.monospaced()).foregroundStyle(.secondary)
                    Text(q.question).font(.body.weight(.medium)).multilineTextAlignment(.leading)
                        .lineLimit(expanded ? nil : 2).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text("\(q.minutes) 分钟").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
            }
            .padding(4)
        }
    }
}

struct Block<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .secondary
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) { content }.font(.callout).padding(.leading, 4)
        }
    }
}

struct SignalList: View {
    let title: String
    let symbol: String
    let color: Color
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(color)
            ForEach(items, id: \.self) { Text("· \($0)") }
        }
    }
}

// MARK: - 简历原文

struct ResumePane: View {
    @EnvironmentObject var store: Store
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            .frame(width: 28, alignment: .trailing)
                        Text(l).font(.callout).textSelection(.enabled)
                    }
                    .listRowBackground(store.highlightedLine == i + 1 ? Color.yellow.opacity(0.35) : Color.clear)
                    .id(i + 1)
                }
            }
            .listStyle(.plain)
            .onChange(of: store.highlightedLine) {
                if let n = store.highlightedLine { withAnimation { proxy.scrollTo(n, anchor: .center) } }
            }
        }
        .navigationTitle("简历原文")
    }
}
