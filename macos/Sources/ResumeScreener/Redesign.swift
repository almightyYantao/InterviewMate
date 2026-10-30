import AppKit
import SwiftUI
import UniformTypeIdentifiers

func decisionColor(_ d: String?) -> Color {
    ["advance": .green, "conditional": .orange, "reject": .red][d ?? ""] ?? .gray
}

// MARK: - 详情区路由：候选人画廊 ⇄ 报告

struct DetailRoot: View {
    @EnvironmentObject var store: Store
    @Namespace private var ns

    var body: some View {
        ZStack {
            if let ev = store.detailEvent {
                EventDetailPage(e: ev).id(ev.id).transition(.move(edge: .trailing).combined(with: .opacity))
            } else if store.showInsights {
                InsightsPage().transition(.opacity.combined(with: .offset(y: 18)))
            } else if store.showCompare {
                ComparePage().transition(.move(edge: .trailing).combined(with: .opacity))
            } else if store.showCalendar {
                CalendarPage(r: store.reminder).transition(.opacity.combined(with: .offset(y: 18)))
            } else if store.showHiBob {
                Group {
                    if store.hibobConnected { BobPipelineView() }
                    else if !(store.settings?.hibobUserId ?? "").isEmpty { HiBobView() }
                    else { BobLoginView() }
                }
                    .transition(.opacity.combined(with: .offset(y: 18)))
            } else if store.selectedPosition == nil {
                ContentUnavailableView("选择一个岗位", systemImage: "briefcase")
            } else if store.selectedCandidateID == nil {
                CandidateGallery(ns: ns)
                    .id(store.selectedPositionID)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 18)), removal: .opacity))
            } else {
                CandidateDetail(ns: ns)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: store.selectedCandidateID)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: store.selectedPositionID)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: store.showHiBob)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: store.showCalendar)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: store.showCompare)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: store.showInsights)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: store.detailEvent?.id)
        .task(id: store.selectedPositionID) {
            while !Task.isCancelled {
                await store.loadCandidates()
                let busy = store.candidates.contains { $0.status != "done" && $0.status != "failed" }
                try? await Task.sleep(for: .seconds(busy ? 3 : 15))
            }
        }
        .onChange(of: store.selectedCandidateID) { store.reportTab = 0; store.expandedQuestions = []; store.resumeMarks = []; store.resumeShowOriginal = false; Task { await store.loadReport() } }
    }
}

// MARK: - 候选人画廊

struct CandidateGallery: View {
    @EnvironmentObject var store: Store
    let ns: Namespace.ID
    @State private var dropping = false
    @AppStorage("galleryMode") private var mode = "cards"

    func toggleCompare(_ c: Candidate) {
        guard c.status == "done" else { return }
        withAnimation(.spring(response: 0.3)) {
            if let i = store.compareIDs.firstIndex(of: c.id) { store.compareIDs.remove(at: i) }
            else if store.compareIDs.count < 4 { store.compareIDs.append(c.id) }
        }
    }

    var done: [Candidate] { store.candidates.filter { $0.status == "done" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.selectedPosition?.title ?? "").font(.system(size: 30, weight: .bold))
                    Text("\(store.selectedPosition?.jdStruct?.requirements?.count ?? 0) 条 JD 要求 · 面试 \(store.selectedPosition?.interviewMinutes ?? 60) 分钟").lineLimit(1).fixedSize()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Segmented(value: $mode.animation(.spring(response: 0.4, dampingFraction: 0.86)), options: [("cards", L("卡片")), ("board", L("看板"))])
                PillButton(title: store.compareMode ? "取消对比" : "对比候选人", symbol: store.compareMode ? "xmark" : "rectangle.split.3x1") {
                    withAnimation(.spring(response: 0.35)) { store.compareMode.toggle(); store.compareIDs = [] }
                }
                .disabled(done.count < 2).opacity(done.count < 2 ? 0.5 : 1)
                .help(done.count < 2 ? L("至少要有 2 位已生成报告的候选人") : L("勾选 2～4 人并排对比"))
                PillButton(title: "岗位设置", symbol: "slider.horizontal.3") { store.editingPosition = store.selectedPosition }
                PrimaryButton(title: "上传简历", symbol: "plus") { store.showImporter = true }
                }
                HStack(spacing: 14) {
                    StatTile(value: "\(store.candidates.count)", title: "候选人", symbol: "person.2.fill", tint: .blue)
                    StatTile(value: "\(done.filter { $0.decision != "reject" }.count)", title: "可推进", symbol: "arrow.up.forward.circle.fill", tint: .green)
                    StatTile(value: done.isEmpty ? "—" : String(format: "%.1f", done.compactMap(\.score).reduce(0, +) / Double(max(done.count, 1))),
                             title: "平均匹配分", symbol: "gauge.with.dots.needle.67percent", tint: .purple)
                    StatTile(value: "\(store.candidates.filter { $0.interviewed == true }.count)", title: "已面试", symbol: "checkmark.bubble.fill", tint: .teal)
                    StatTile(value: "\(store.candidates.count - done.count)", title: "生成中", symbol: "sparkles", tint: .orange)
                }
                if store.candidates.isEmpty {
                    if store.candidatesLoaded { dropZone.transition(.opacity) }
                } else if mode == "board" {
                    PipelineBoard().transition(.opacity.combined(with: .offset(y: 12)))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                        ForEach(store.candidates.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }) { c in  // 最新上传的在前
                            CandidateCard(c: c, ns: ns)
                                .overlay(alignment: .bottomTrailing) { if store.compareMode && c.status == "done" { CompareCheck(on: store.compareIDs.contains(c.id)).padding(14) } }
                                .opacity(store.compareMode && c.status != "done" ? 0.4 : 1)
                                .onTapGesture {
                                    if store.compareMode { toggleCompare(c) } else { store.selectedCandidateID = c.id }
                                }
                                .contextMenu {
                                    Button("打开") { store.selectedCandidateID = c.id }
                                    Menu("面试结果") {
                                        ForEach(["通过", "待定", "不通过"], id: \.self) { d in
                                            Button { store.setDecision(c.id, d) } label: {
                                                if c.interviewDecision == d { Label(L(d), systemImage: "checkmark") } else { Text(L(d)) }
                                            }
                                        }
                                    }
                                    Divider()
                                    Button("删除候选人…", role: .destructive) { store.deletingCandidate = c }
                                }
                                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                        }
                        uploadCard
                    }
                }
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 32)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.white)
        .overlay(alignment: .bottom) {
            if store.compareMode {
                HStack(spacing: 14) {
                    Text(String(format: L("已选 %lld 人（最多 4 人）"), store.compareIDs.count)).font(.callout.weight(.medium))
                    PrimaryButton(title: "开始对比", symbol: "rectangle.split.3x1") {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { store.showCompare = true }
                    }
                    .disabled(store.compareIDs.count < 2).opacity(store.compareIDs.count < 2 ? 0.5 : 1)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.white, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
                .padding(.bottom, 28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in store.upload(urls); return true } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    .padding(12).allowsHitTesting(false)
                    .overlay(Label("松开以上传简历", systemImage: "arrow.down.doc.fill").font(.title2.weight(.semibold)).foregroundStyle(Color.accentColor))
            }
        }
        .animation(.easeOut(duration: 0.18), value: dropping)
        .navigationTitle("")
        
    }

    var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.viewfinder").font(.system(size: 54, weight: .light)).foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
            Text("把简历拖到这里").font(.title2.weight(.semibold))
            Text("支持 PDF、Word、Markdown，可一次放多份。每份约 3～5 分钟生成一面准备材料。").foregroundStyle(.secondary)
            Button("选择文件…") { store.showImporter = true }.buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
        .background(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
    }

    var uploadCard: some View {
        Button { store.showImporter = true } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 28, weight: .light))
                Text("上传简历")
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 196, maxHeight: 196)
            .background(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StatTile: View {
    let value: String, title: String, symbol: String, tint: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
                .frame(width: 42, height: 42).background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 22, weight: .bold)).monospacedDigit().contentTransition(.numericText())
                Text(L(title)).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)   // 不换行，英文长一点就缩小
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72)   // 所有统计卡同高
        .background(Theme.page, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct CandidateCard: View {
    let c: Candidate
    let ns: Namespace.ID
    @State private var hover = false
    var resultTint: Color? {
        switch c.interviewDecision { case "通过": .green; case "不通过": .red; case "待定": .orange; default: nil }
    }

    var body: some View {
        let color = decisionColor(c.decision)
        VStack(alignment: .leading, spacing: 14) {
            // 头像 + 姓名 / 筛选结论；右上角留给面试结论标签
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [color.opacity(0.8), color], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(String((c.name ?? "?").prefix(1))).font(.title3.weight(.semibold)).foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(c.name ?? "—").font(.title3.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: resultTint == nil ? 0 : 76)
            }
            // 筛选结论和风险单独一行，占满宽度，不被右上角标签挤压换行
            if c.status == "done" {
                HStack(spacing: 8) {
                    if let d = c.decision { Chip(text: Labels.decision[d] ?? d, color: color).fixedSize() }
                    if let h = c.high, h > 0 {
                        Label("\(h) 个高风险", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                    }
                }
            }
            if c.status == "done" {
                if let s = c.score { ScoreBar(score: s, color: color).matchedGeometryEffect(id: "ring-\(c.id)", in: ns) }
                InterviewBadge(c: c)
            } else if c.status == "failed" {
                Label("生成失败", systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(c.progress ?? "排队中").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 196, maxHeight: 196, alignment: .topLeading)
        .background {
            // 面试结论决定卡片底色：通过绿、待定橙、不通过红；没面过保持灰底
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(hover && resultTint == nil ? Color.white : (resultTint == nil ? Theme.page : Color.white))
                if let t = resultTint {
                    RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [t.opacity(hover ? 0.16 : 0.12), t.opacity(0.04)],
                                                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let t = resultTint, let d = c.interviewDecision {
                HStack(spacing: 4) {
                    Image(systemName: d == "通过" ? "checkmark.seal.fill" : d == "不通过" ? "xmark.seal.fill" : "clock.fill")
                    Text(L(d))
                }
                .font(.system(size: 12.5, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(t.gradient, in: UnevenRoundedRectangle(bottomLeadingRadius: 12, topTrailingRadius: 16))
                .shadow(color: t.opacity(0.3), radius: 4, y: 2)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(resultTint?.opacity(hover ? 0.6 : 0.35) ?? (hover ? color.opacity(0.5) : Color.clear),
                                                                 lineWidth: resultTint == nil ? 1.5 : 1.2))
        .shadow(color: .black.opacity(hover ? 0.1 : 0), radius: 16, y: 8)
        .scaleEffect(hover ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
        .onHover { hover = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// 卡片里的匹配分：数字 + 横向进度条
struct ScoreBar: View {
    let score: Double
    let color: Color
    @State private var shown = false
    var body: some View {
        HStack(spacing: 10) {
            Text("匹配分").font(.caption).foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.06))
                    Capsule().fill(color.gradient).frame(width: shown ? g.size.width * min(1, score / 10) : 0)
                }
            }
            .frame(height: 6)
            Text(String(format: "%.1f", score)).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.85).delay(0.1)) { shown = true } }
    }
}

/// 卡片底部的面试状态：待面试 / 已面试（+ 面试结论）
struct InterviewBadge: View {
    let c: Candidate
    var body: some View {
        if c.interviewed == true {
            let d = c.interviewDecision
            let color: Color = d == "通过" ? .green : d == "不通过" ? .red : d == "待定" ? .orange : .teal
            HStack(spacing: 6) {
                Image(systemName: "checkmark.bubble.fill")
                Text(d.map { String(format: L("已面试 · %@"), L($0)) } ?? L("已面试 · 待写评价"))
                if let t = c.interviewedAt { Text(String(t.prefix(10))).foregroundStyle(.secondary) }
            }
            .font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Label("待面试", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 空白提示统一样式：在靠左排列的内容区里也占满整行、居中显示
extension View {
    func emptyStateLayout() -> some View { frame(maxWidth: .infinity).padding(.vertical, 48) }
}

struct Chip: View {
    let text: String, color: Color
    var body: some View {
        Text(L(text)).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct ScoreRing: View {
    let score: Double
    let color: Color
    var size: CGFloat = 100
    var lineWidth: CGFloat = 10
    @State private var progress = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle().trim(from: 0, to: progress / 10)
                .stroke(AngularGradient(colors: [color.opacity(0.6), color], center: .center), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(String(format: "%.1f", progress)).font(.system(size: size * 0.28, weight: .bold, design: .rounded))
                .monospacedDigit().contentTransition(.numericText(value: progress))
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.easeOut(duration: 1.0).delay(0.15)) { progress = score } }
        .onChange(of: score) { withAnimation(.easeOut(duration: 0.6)) { progress = score } }
    }
}

// MARK: - 候选人详情

struct CandidateDetail: View {
    @EnvironmentObject var store: Store
    let ns: Namespace.ID

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PillButton(title: "全部候选人", symbol: "chevron.left") { store.selectedCandidateID = nil }
                Spacer()
                if store.report != nil {
                    PopoverMenu(title: "重新生成", symbol: "arrow.clockwise", items: [
                        ("只重新出题", "list.bullet.rectangle", { store.regenerate("questions") }),
                        ("整份重新生成", "sparkles", { store.regenerate("all") })])
                    PopoverMenu(title: "导出", symbol: "square.and.arrow.up", items: [
                        ("一面准备 · 网页（HTML）", "safari", { store.export(format: "html", answers: true) }),
                        ("一面准备 · Word", "doc.richtext", { store.export(format: "docx", answers: true) }),
                        ("一面准备 · Markdown", "doc.plaintext", { store.export(format: "md", answers: true) }),
                        ("面试记录表 · 不含答案", "doc.on.clipboard", { store.export(format: "docx", answers: false) }),
                        ("面试记录表 · 网页（HTML）", "safari", { store.export(format: "html", answers: false) })])
                    PrimaryButton(title: "开始面试", symbol: "play.fill") { store.interviewing = true }
                }
            }
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 4)
            .background(Color.white)
        Group {
            if let r = store.report, r.report.candidate == store.selectedCandidate?.name || store.selectedCandidate?.name == nil {
                ReportPage(resp: r, ns: ns)
            } else if let c = store.selectedCandidate, c.status == "failed" {
                ContentUnavailableView {
                    Label("生成失败", systemImage: "exclamationmark.octagon")
                } description: { Text(c.error ?? "") } actions: { Button("重试") { store.regenerate("all") } }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                    Text(store.selectedCandidate?.status == "done" ? "加载中…" : "正在生成一面准备材料").font(.title3.weight(.semibold))
                    if let p = store.selectedCandidate?.progress { Text(p).foregroundStyle(.secondary).contentTransition(.opacity) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        }
        .background(Color.white)
    }
}

struct ReportPage: View {
    @EnvironmentObject var store: Store
    let resp: ReportResponse
    let ns: Namespace.ID
    @Namespace private var tabNS
    @State private var forward = true
    @State private var verdictFilter: String?
    var r: Report { resp.report }
    var reqs: [String: Requirement] { Dictionary((r.jd.requirements ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    let tabs = [("概览", "square.grid.2x2"), ("疑点", "exclamationmark.magnifyingglass"), ("JD 匹配", "checklist"),
                ("面试题", "list.bullet.rectangle"), ("面试反馈", "text.bubble"), ("简历原文", "doc.text")]

    var body: some View {
        VStack(spacing: 0) {
            hero
            HStack(spacing: 4) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                    TabButton(title: t.0, symbol: t.1, selected: store.reportTab == i, badge: badge(i), ns: tabNS) {
                        forward = i > store.reportTab
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { store.reportTab = i }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 28).padding(.bottom, 12)
            .background(Color.white)
            Divider().opacity(0.5)
            ZStack {
                Group {
                switch store.reportTab {
                case 0: scroll { overview }
                case 1: scroll { doubts }
                case 2: scroll { matches }
                case 3: scroll { questions }
                case 4: scroll { FeedbackPage(resp: resp) }
                    default: ResumeDocView(cid: store.selectedCandidateID ?? "", resume: r.resume)
                    }
                }
                .id(store.reportTab)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 40 : -40)),
                                        removal: .opacity.combined(with: .offset(x: forward ? -40 : 40))))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .onChange(of: store.highlightedLine) {
            if let n = store.highlightedLine { forward = true; store.locateInResume([n]); store.highlightedLine = nil }
        }
        .navigationTitle("")
        
    }

    func badge(_ i: Int) -> String? {
        switch i {
        case 1: let h = r.doubts.filter { $0.severity == "high" }.count; return h > 0 ? "\(h)" : nil
        case 3: return "\(r.questions.count)"
        case 4: return resp.summary != nil || !resp.evaluations.isEmpty ? "✓" : nil
        default: return nil
        }
    }

    func scroll<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) { c() }.padding(28).frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity) }
            .background(Color.white)
    }

    var hero: some View {
        let c = r.conclusion, color = decisionColor(c.decision)
        return HStack(alignment: .center, spacing: 26) {
            ScoreRing(score: c.score, color: color, size: 108, lineWidth: 11)
                .matchedGeometryEffect(id: "ring-\(store.selectedCandidateID ?? "")", in: ns)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(r.candidate).font(.system(size: 30, weight: .bold))
                    Chip(text: Labels.decision[c.decision] ?? c.decision, color: color)
                    Text("\(r.position) · " + ((r.round ?? 1) > 1 ? String(format: L("第 %lld 轮面试"), r.round!) + " · " : "") + String(format: L("第 %lld 版"), resp.version)).foregroundStyle(.secondary)
                }
                Text(c.summary).font(.body).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                HStack(spacing: 18) {
                    MiniStat(value: "\(r.doubts.filter { $0.severity == "high" }.count)", title: "高风险疑点", color: .red)
                    MiniStat(value: "\(r.match.filter { $0.verdict == "match" }.count)/\(r.match.count)", title: "JD 具备", color: .green)
                    MiniStat(value: "\(r.questions.count) 题", title: "\(r.questions.reduce(0) { $0 + $1.minutes }) 分钟", color: .blue)
                    if !c.veto.isEmpty { MiniStat(value: "\(c.veto.count)", title: "一票否决", color: .orange) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 18)
        .background(Color.white)
    }

    @ViewBuilder var overview: some View {
        let c = r.conclusion
        if !c.veto.isEmpty {
            Card {
                Label("一票否决：" + c.veto.map { "\($0) \(reqs[$0]?.text ?? "")" }.joined(separator: "；") + "（结论上限为「有条件推进」）",
                      systemImage: "hand.raised.fill").foregroundStyle(.red)
            }
        }
        Card(title: "必须核实", symbol: "checkmark.shield") { FlowTags(items: c.mustVerify) }
        Card(title: "匹配分布", symbol: "chart.bar.fill") { VerdictBar(match: r.match, filter: Binding(get: { nil }, set: { k in forward = true; verdictFilter = k; withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { store.reportTab = 2 } })) }
        HStack(alignment: .top, spacing: 16) {
            Card { SignalList(title: "通过信号", symbol: "hand.thumbsup.fill", color: .green, items: c.passSignals) }
            Card { SignalList(title: "不通过信号", symbol: "hand.thumbsdown.fill", color: .red, items: c.failSignals) }
        }
        ForEach(Array(resp.evaluations.enumerated()), id: \.offset) { _, e in
            Card(title: String(format: L("面试评价 · %@"), L(e.decision)), symbol: "text.bubble.fill") { Text(e.comment).textSelection(.enabled) }
        }
        Label("AI 生成，需人工复核。出生日期仅用于时间线校验，年龄、性别、婚育、籍贯不参与评分和出题。", systemImage: "info.circle")
            .font(.caption).foregroundStyle(.tertiary)
    }

    @ViewBuilder var doubts: some View {
        let order = ["high": 0, "medium": 1, "low": 2]
        ForEach(r.doubts.sorted { (order[$0.severity] ?? 3) < (order[$1.severity] ?? 3) }) { d in
            Card(accent: decisionColor(["high": "reject", "medium": "conditional"][d.severity])) { DoubtRow(d: d) }
        }
    }

    @ViewBuilder var matches: some View {
        let items = r.match.filter { verdictFilter == nil || $0.verdict == verdictFilter }
        Card { VerdictBar(match: r.match, filter: $verdictFilter) }
        Card {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, m in
                    MatchRow(m: m, req: reqs[m.reqId])
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    if i < items.count - 1 { Divider() }
                }
            }
            .clipped()
        }
    }

    @ViewBuilder var questions: some View {
        if let carry = r.carryOver, !carry.isEmpty {
            Card(title: String(format: L("上一轮遗留 · 本轮重点核实（第 %lld 轮）"), r.round ?? 2), symbol: "arrow.triangle.turn.up.right.diamond.fill", accent: .orange) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(carry, id: \.self) { t in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                            Text(t).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        ForEach(Labels.sections, id: \.self) { sec in
            let qs = r.questions.filter { $0.section == sec }
            if !qs.isEmpty {
                Label("\(sec) · \(qs.reduce(0) { $0 + $1.minutes }) 分钟", systemImage: Labels.sectionSymbol[sec] ?? "circle")
                    .font(.headline).foregroundStyle(.secondary).padding(.top, 6)
                ForEach(qs) { QuestionCard(q: $0, reqs: reqs, doubts: r.doubts) }
            }
        }
    }
}

struct TabButton: View {
    let title: String, symbol: String, selected: Bool, badge: String?
    var ns: Namespace.ID? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(L(title))
                if let badge { Text(badge).font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(selected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.18), in: Capsule()) }
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background {
                if selected {
                    if let ns { Capsule().fill(Theme.brand).matchedGeometryEffect(id: "tab-pill", in: ns) }
                    else { Capsule().fill(Theme.brand) }
                }
                else if hover { Capsule().fill(Color.primary.opacity(0.07)) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct MiniStat: View {
    let value: String, title: String, color: Color
    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.headline).monospacedDigit()
                Text(L(title)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    var accent: Color? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Label(L(title), systemImage: symbol ?? "circle").font(.headline) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.page, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            if let accent { UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14).fill(accent).frame(width: 4) }
        }
    }
}

struct VerdictBar: View {
    let match: [MatchItem]
    @Binding var filter: String?
    @State private var shown = false
    let kinds = [("match", Color.green), ("partial", Color.orange), ("missing", Color.red), ("unknown", Color.gray)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { g in
                HStack(spacing: 3) {
                    ForEach(kinds, id: \.0) { k, color in
                        let n = match.filter { $0.verdict == k }.count
                        if n > 0 {
                            RoundedRectangle(cornerRadius: 5).fill(color.gradient)
                                .frame(width: shown ? max(0, (g.size.width - 9) * CGFloat(n) / CGFloat(max(match.count, 1))) : 0)
                                .opacity(filter == nil || filter == k ? 1 : 0.25)
                                .scaleEffect(y: filter == k ? 1.35 : 1)
                                .contentShape(Rectangle())
                                .onTapGesture { toggle(k) }
                                .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                                .help("只看「\(Labels.verdict[k] ?? k)」")
                        }
                    }
                }
            }
            .frame(height: 14)
            HStack(spacing: 16) {
                ForEach(kinds, id: \.0) { k, color in
                    Button { toggle(k) } label: {
                        Label { Text("\(Labels.verdict[k] ?? k) \(match.filter { $0.verdict == k }.count)") }
                            icon: { Circle().fill(color).frame(width: 8, height: 8) }
                            .font(.callout.weight(filter == k ? .semibold : .regular))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(filter == k ? color.opacity(0.14) : .clear, in: Capsule())
                            .opacity(filter == nil || filter == k ? 1 : 0.45)
                            .contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer()
                if filter != nil {
                    Button { toggle(filter!) } label: {
                        Label("显示全部", systemImage: "xmark.circle.fill").font(.callout).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).transition(.opacity)
                }
            }
            .padding(.leading, -9)
        }
        .onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.8).delay(0.1)) { shown = true } }
    }

    func toggle(_ k: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { filter = filter == k ? nil : k }
    }
}

enum Theme {
    static let brand = Color(red: 0.22, green: 0.42, blue: 0.98)
    static let page = Color(red: 0.957, green: 0.965, blue: 0.984)
    static let section: [String: Color] = ["背景核实": .purple, "项目深挖": Color(red: 0.22, green: 0.42, blue: 0.98),
                                          "核心能力": .teal, "缺口场景": .orange, "软性要求": .pink]
}

struct QuestionCard: View {
    @EnvironmentObject var store: Store
    let q: Question
    let reqs: [String: Requirement]
    let doubts: [Doubt]
    @State private var hover = false
    var color: Color { Theme.section[q.section] ?? Theme.brand }
    var expanded: Bool { store.expandedQuestions.contains(q.id) }

    var sourceTag: (String, String) {
        switch q.source.type {
        case "resume": return ("简历原文", "doc.text")
        case "jd": return ("JD 缺口", "target")
        default: return ("疑点核实", "exclamationmark.magnifyingglass")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Text(String(q.id.dropFirst()))
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(color)
                    .frame(width: 32, height: 32).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 8) {
                    Text(q.question).font(.system(size: 14.5, weight: .medium)).lineSpacing(3)
                        .lineLimit(expanded ? nil : 2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Pill(text: "\(q.minutes) 分钟", symbol: "clock", color: .secondary)
                        Pill(text: sourceTag.0, symbol: sourceTag.1, color: color)
                        if !q.keyPoints.isEmpty { Pill(text: "\(q.keyPoints.count) 个关键点", symbol: "star.fill", color: .orange) }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0)).padding(.top, 9)
            }
            .padding(18)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    if expanded { store.expandedQuestions.remove(q.id) } else { store.expandedQuestions.insert(q.id) }
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    if q.source.type == "resume" {
                        Button { store.locateInResume(q.source.lines) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Rectangle().fill(color).frame(width: 3)
                                Text("「\(q.source.quote)」").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(color)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }.buttonStyle(.plain).help("在简历原文中定位")
                    }
                    ResumeSnippets(lines: q.resumeLines(doubts: doubts), color: color)
                    Panel(title: "参考答案要点", symbol: "lightbulb.fill", color: Theme.brand) {
                        ForEach(Array(q.answerPoints.enumerated()), id: \.offset) { i, p in
                            let key = q.keyPoints.contains(p)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(key ? .white : Theme.brand)
                                    .frame(width: 18, height: 18).background(key ? Color.orange : Theme.brand.opacity(0.12), in: Circle())
                                Text(p).fontWeight(key ? .semibold : .regular).textSelection(.enabled)
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Panel(title: "追问", symbol: "arrow.turn.down.right", color: .teal) { ForEach(q.followUps, id: \.self) { Text($0) } }
                        Panel(title: "红旗信号", symbol: "flag.fill", color: .red) { ForEach(q.redFlags, id: \.self) { Text($0) } }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 10) {
                        RubricTile(label: "优秀", text: q.rubric.excellent, color: .green)
                        RubricTile(label: "合格", text: q.rubric.pass, color: Theme.brand)
                        RubricTile(label: "不合格", text: q.rubric.fail, color: .red)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    HStack { Spacer(); Button { store.deleteQuestion(q) } label: { Label("删除此题", systemImage: "trash").font(.callout).foregroundStyle(.red.opacity(0.8)) }.buttonStyle(.plain) }
                }
                .padding(.horizontal, 18).padding(.bottom, 18).padding(.leading, 46)
                .transition(.opacity)
            }
        }
        .background(hover || expanded ? Color.white : Theme.page)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hover || expanded ? color.opacity(0.45) : Color.clear))
        .shadow(color: .black.opacity(hover || expanded ? 0.07 : 0), radius: 14, y: 4)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

struct Pill: View {
    let text: String, symbol: String, color: Color
    var body: some View {
        Label(L(text), systemImage: symbol).font(.caption).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }
}

struct Panel<C: View>: View {
    let title: String, symbol: String, color: Color
    @ViewBuilder let content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(L(title), systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 6) { content }.font(.callout)
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct RubricTile: View {
    let label: String, text: String, color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(label)).font(.caption.weight(.bold)).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(0.25)))
    }
}

// MARK: - 自绘控件

struct PillButton: View {
    let title: String, symbol: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(L(title), systemImage: symbol).font(.callout.weight(.medium))
                .lineLimit(1).fixedSize()   // 按钮文字不换行、不压缩
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(hover ? Theme.page : Color.white, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct PrimaryButton: View {
    let title: String, symbol: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(L(title), systemImage: symbol).font(.callout.weight(.semibold)).foregroundStyle(.white)
                .lineLimit(1).fixedSize()   // 按钮文字不换行、不压缩
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Theme.brand.gradient, in: Capsule())
                .shadow(color: Theme.brand.opacity(hover ? 0.45 : 0.25), radius: hover ? 10 : 5, y: 3)
                .scaleEffect(hover ? 1.03 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .animation(.spring(response: 0.25), value: hover)
    }
}

struct PopoverMenu: View {
    let title: String, symbol: String
    let items: [(String, String, () -> Void)]
    @State private var open = false
    var body: some View {
        PillButton(title: title, symbol: symbol) { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                        MenuRow(title: it.0, symbol: it.1) { open = false; it.2() }
                    }
                }
                .padding(6).frame(minWidth: 220)
            }
    }
}

struct MenuRow: View {
    let title: String, symbol: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(hover ? .white : Theme.brand)
                Text(L(title)).foregroundStyle(hover ? .white : .primary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(hover ? Theme.brand : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

// MARK: - 自绘侧边栏

struct AppSidebar: View {
    @EnvironmentObject var store: Store
    @Namespace private var selNS

    var page: String? {
        store.showInsights ? "insights" : store.showCalendar ? "calendar" : store.showHiBob ? "hibob" : nil
    }

    func navRow(_ key: String, _ title: String, _ symbol: String) -> some View {
        let on = page == key
        return Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                store.showCalendar = key == "calendar"; store.showHiBob = key == "hibob"; store.showInsights = key == "insights"
                store.showCompare = false; store.selectedCandidateID = nil; store.detailEvent = nil
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.brand : .secondary).frame(width: 20)
                Text(title).font(.system(size: 14, weight: on ? .semibold : .regular)).foregroundStyle(on ? Theme.brand : .primary)
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 10).fill(.white).shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "sidebar-selection", in: selNS)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(Theme.brand.gradient, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(color: Theme.brand.opacity(0.3), radius: 6, y: 3)
                Text("面搭子").font(.system(size: 18, weight: .bold))
            }
            .padding(.horizontal, 20).padding(.top, 54).padding(.bottom, 24)

            // 顶部导航：三项同一个样式、同样间距
            VStack(spacing: 2) {
                navRow("calendar", L("面试日历"), "calendar")
                navRow("hibob", L("我的 HiBob 招聘"), "person.2.badge.gearshape")
                navRow("insights", L("我的复盘"), "chart.bar.xaxis")
            }
            .padding(.horizontal, 12).padding(.bottom, 22)

            UpcomingInterviews(r: store.reminder)
                .padding(.bottom, 10)

            HStack {
                Text("岗位").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { store.showNewPosition = true } label: {
                    Image(systemName: "plus").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).background(Color.black.opacity(0.05), in: Circle())
                }.buttonStyle(.plain).help("新建岗位")
            }
            .padding(.horizontal, 22).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.positions) { p in
                        SidebarRow(p: p, selected: !store.showHiBob && !store.showCalendar && !store.showInsights && store.selectedPositionID == p.id, ns: selNS) {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { store.showHiBob = false; store.showCalendar = false; store.showInsights = false; store.detailEvent = nil; store.selectedPositionID = p.id }
                        }
                        .contextMenu {
                            Button("岗位设置…") { store.editingPosition = p }
                            Divider()
                            Button("删除岗位…", role: .destructive) { store.deletingPosition = p }
                        }
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                    Button { store.showNewPosition = true } label: {
                        Label("新建岗位", systemImage: "plus.circle").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Text(initials).font(.callout.weight(.bold)).foregroundStyle(Theme.brand)
                    .frame(width: 34, height: 34).background(Theme.brand.opacity(0.12), in: Circle())
                Text(NSFullUserName()).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Button { store.showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("设置（AI 接口）")
            }
            .padding(20)
        }
        .frame(width: 240)
        .frame(maxHeight: .infinity)
        .background(Theme.page)
        .onChange(of: store.selectedPositionID) {
            // 从日历 / HiBob 直接打开某个候选人时，换岗位后直接进他的报告，不经过候选人列表
            store.selectedCandidateID = store.pendingCandidateID; store.pendingCandidateID = nil
            store.report = nil; store.candidates = []; store.candidatesLoaded = false
            store.compareMode = false; store.compareIDs = []; store.showCompare = false
        }
    }

    var initials: String {
        let parts = NSFullUserName().split(separator: " ")
        return parts.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

struct SidebarRow: View {
    let p: Position
    let selected: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "briefcase").font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.brand : .secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.brand : .primary).lineLimit(1)
                    Text(p.jdStruct == nil ? "JD 解析中…" : "\(p.jdStruct?.requirements?.count ?? 0) 条要求")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if selected { Circle().fill(.green).frame(width: 7, height: 7) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11).fill(.white).shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "sidebar-selection", in: ns)
                } else if hover { RoundedRectangle(cornerRadius: 11).fill(Color.black.opacity(0.04)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}
