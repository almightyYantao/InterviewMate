import AppKit
import SwiftUI

// MARK: - 顶栏的录音控件

struct RecordControl: View {
    @ObservedObject var tr: Transcriber
    let onStart: () -> Void
    @State private var pulse = false

    var body: some View {
        if tr.running {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                    .opacity(pulse ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                Text("转写中 · \(tr.utterances.count) 句").font(.callout.weight(.medium)).monospacedDigit()
                Button { withAnimation(.snappy) { tr.stop() } } label: {
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Color.red, in: Circle())
                }
                .buttonStyle(.plain).help("停止转写")
            }
            .padding(.leading, 12).padding(.trailing, 5).padding(.vertical, 5)
            .background(Color.red.opacity(0.08), in: Capsule())
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else {
            PillButton(title: tr.starting ? "启动中…" : (tr.utterances.isEmpty ? "开始转写" : "继续转写"), symbol: "waveform") { onStart() }
                .disabled(tr.starting)
                .help("用本机语音识别转写麦克风（我）和电脑播放的声音（候选人），音频不离开本机")
        }
    }
}

// MARK: - 右侧逐字稿

struct TranscriptPane: View {
    @ObservedObject var tr: Transcriber
    let questionId: String
    var hint: LiveHint? = nil
    var hintBusy = false
    var refreshHint: () -> Void = {}
    @State private var onlyCurrent = true

    var items: [Utterance] { onlyCurrent ? tr.utterances.filter { $0.questionId == questionId } : tr.utterances }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("逐字稿", systemImage: "text.bubble").font(.callout.weight(.semibold))
                Spacer()
                HStack(spacing: 2) {
                    seg("本题", true)
                    seg("全部", false)
                }
                .padding(2).background(Color.white, in: Capsule())
            }
            .padding(.horizontal, 14).padding(.vertical, 12)

            if let src = tr.source, tr.running {
                Label(String(format: L("候选人：监听 %@"), src), systemImage: "speaker.wave.2.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 6)
            }
            HintCard(hint: hint, busy: hintBusy, refresh: refreshHint)
                .padding(.horizontal, 12).padding(.bottom, 8)
            if let w = tr.warning {
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if items.isEmpty && tr.live.isEmpty {
                            Text(tr.running ? "正在听…" : "这道题还没有转写内容").font(.callout).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity).padding(.top, 40)
                        }
                        ForEach(items) { Bubble(speaker: $0.speaker, text: $0.text, at: $0.at) }
                        ForEach(["me", "candidate"], id: \.self) { sp in
                            if let t = tr.live[sp] { Bubble(speaker: sp, text: t, at: nil).opacity(0.55) }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: tr.utterances.count) { withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: tr.live) { proxy.scrollTo("bottom") }
            }
        }
        .frame(width: 320)
        .background(Theme.page)
    }

    func seg(_ t: String, _ v: Bool) -> some View {
        Button { withAnimation(.snappy) { onlyCurrent = v } } label: {
            Text(L(t)).font(.caption.weight(onlyCurrent == v ? .semibold : .regular))
                .foregroundStyle(onlyCurrent == v ? .white : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(onlyCurrent == v ? Theme.brand : .clear, in: Capsule())
        }.buttonStyle(.plain)
    }
}

struct Bubble: View {
    let speaker: String
    let text: String
    let at: Double?
    var me: Bool { speaker == "me" }

    var body: some View {
        if speaker.hasPrefix("mark_") { markView } else { bubble }
    }

    /// 面试官的标记：一条带颜色的小横幅，引用被标记的那句话
    var markView: some View {
        let good = speaker == "mark_good"
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: good ? "hand.thumbsup.fill" : "questionmark.diamond.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(good ? "标记为亮点" : "标记为存疑").font(.caption2.weight(.bold))
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .foregroundStyle(good ? Color.green : Color.orange)
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background((good ? Color.green : Color.orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    var bubble: some View {
        VStack(alignment: me ? .trailing : .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(me ? "我" : "候选人").font(.caption2.weight(.semibold)).foregroundStyle(me ? Theme.brand : .orange)
                if let at { Text(String(format: "%02d:%02d", Int(at) / 60, Int(at) % 60)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
            }
            Text(text).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(me ? Theme.brand.opacity(0.1) : Color.white, in: RoundedRectangle(cornerRadius: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: me ? .trailing : .leading)
        .padding(me ? .leading : .trailing, 28)
    }
}

// MARK: - 结束页的逐题复盘

struct SummaryReview: View {
    let s: InterviewSummary
    let questions: [Question]

    var body: some View {
        let byId = Dictionary(s.questions.map { ($0.questionId, $0) }, uniquingKeysWith: { a, _ in a })
        let asked = questions.filter { (byId[$0.id]?.suggestedScore ?? "not_asked") != "not_asked" }
        let skipped = questions.filter { (byId[$0.id]?.suggestedScore ?? "not_asked") == "not_asked" }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Panel(title: "亮点", symbol: "hand.thumbsup.fill", color: .green) { ForEach(s.highlights, id: \.self) { Text($0) } }
                Panel(title: "不足", symbol: "hand.thumbsdown.fill", color: .red) { ForEach(s.concerns, id: \.self) { Text($0) } }
            }
            .fixedSize(horizontal: false, vertical: true)
            if !s.doubts.isEmpty {
                Panel(title: "疑点核实", symbol: "exclamationmark.magnifyingglass", color: .orange) {
                    ForEach(s.doubts, id: \.self) { d in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Chip(text: d.result, color: d.result == "已澄清" ? .green : d.result == "仍存疑" ? .red : .gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.doubt).fontWeight(.medium)
                                Text(d.note).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Text("逐题复盘").font(.headline).padding(.top, 6)
            ForEach(Array(asked.enumerated()), id: \.element.id) { _, q in
                if let r = byId[q.id] { ReviewRow(q: q, r: r) }
            }
            if !skipped.isEmpty {
                Text("没问到：" + skipped.map(\.id).joined(separator: "、")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct ReviewRow: View {
    let q: Question
    let r: QuestionReview
    @State private var expanded = false
    var color: Color { ["excellent": .green, "pass": Theme.brand, "fail": .red][r.suggestedScore] ?? .gray }
    var label: String { ["excellent": "优秀", "pass": "合格", "fail": "不合格"][r.suggestedScore] ?? "—" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(q.id).font(.caption.monospaced().weight(.semibold)).foregroundStyle(Theme.brand)
                Text(q.question).font(.callout.weight(.medium)).lineLimit(expanded ? nil : 1)
                Spacer(minLength: 8)
                Chip(text: String(format: L("建议 %@"), L(label)), color: color)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    line("checkmark.circle.fill", .green, r.covered)
                    line("circle.dashed", .orange, r.missed)
                    line("flag.fill", .red, r.redFlagsHit)
                    if !r.evidence.isEmpty {
                        Text("「\(r.evidence)」").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .background(Theme.page, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
    }

    @ViewBuilder func line(_ sym: String, _ c: Color, _ items: [String]) -> some View {
        ForEach(items, id: \.self) { t in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: sym).font(.caption).foregroundStyle(c)
                Text(t).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 简历原文截图

extension Question {
    /// 题目涉及的简历行：出处行 + 关联疑点的证据行 + 题干里写的「第 N 行」
    func resumeLines(doubts: [Doubt]) -> [Int] {
        var s = Set(source.type == "resume" ? source.lines : [])
        for d in doubts where linkedDoubts.contains(d.id) { s.formUnion(d.evidence.map(\.line)) }
        let re = try! NSRegularExpression(pattern: "第\\s*(\\d+)\\s*行")
        let ns = question as NSString
        for m in re.matches(in: question, range: NSRange(location: 0, length: ns.length)) {
            if let n = Int(ns.substring(with: m.range(at: 1))) { s.insert(n) }
        }
        return s.sorted()
    }
}

/// 相隔不超过 4 行的合成一张图
func groupLines(_ lines: [Int]) -> [[Int]] {
    var out: [[Int]] = []
    for n in lines.sorted() {
        if let last = out.last?.last, n - last <= 4 { out[out.count - 1].append(n) } else { out.append([n]) }
    }
    return out
}

struct ResumeSnippets: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backend: Backend
    let lines: [Int]
    var color: Color = Theme.brand
    var locate = true

    var body: some View {
        if !lines.isEmpty, let cid = store.selectedCandidateID {
            VStack(alignment: .leading, spacing: 8) {
                Label("简历原文", systemImage: "doc.viewfinder").font(.caption.weight(.semibold)).foregroundStyle(color)
                ForEach(groupLines(lines), id: \.self) { g in
                    SnippetImage(url: backend.snippetURL(cid, lines: g), lines: g, color: color) {
                        if locate { store.locateInResume(g) }
                    }
                }
            }
        }
    }
}

struct SnippetImage: View {
    let url: URL
    let lines: [Int]
    let color: Color
    let action: () -> Void
    @State private var image: NSImage?
    @State private var failed = false
    static let cache = NSCache<NSURL, NSImage>()
    @State private var hover = false

    var body: some View {
        Group {
            if let image {
                Button(action: action) {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(image.size.width / 2.4 * 1.25, 900), alignment: .leading)
                        .padding(10)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hover ? color.opacity(0.6) : Color.black.opacity(0.08)))
                        .overlay(alignment: .topTrailing) {
                            Text(lines.count == 1 ? "L\(lines[0])" : "L\(lines.first!)–\(lines.last!)")
                                .font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(color, in: Capsule()).padding(6)
                        }
                        .shadow(color: .black.opacity(hover ? 0.08 : 0), radius: 8, y: 3)
                }
                .buttonStyle(.plain).onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
                .help("在简历原文中定位")
                .transition(.opacity)
            } else if !failed {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.04)).frame(height: 64)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: url) {
            if let img = Self.cache.object(forKey: url as NSURL) { image = img; return }
            // 展开动画期间视图可能被重建、请求被取消；取消不算失败，重试一次
            for _ in 0..<3 {
                do {
                    let (data, resp) = try await URLSession.shared.data(from: url)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: data) else { failed = true; return }
                    Self.cache.setObject(img, forKey: url as NSURL)
                    withAnimation(.easeOut(duration: 0.2)) { image = img }
                    return
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            failed = true
        }
    }
}


// MARK: - 实时追问提示

struct HintCard: View {
    let hint: LiveHint?
    let busy: Bool
    let refresh: () -> Void
    @State private var showDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Theme.brand)
                Text("实时提示").font(.caption.weight(.semibold))
                Spacer()
                if busy { ProgressView().controlSize(.mini) }
                Button(action: refresh) { Image(systemName: "arrow.clockwise").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(busy).help(L("立即根据逐字稿更新"))
            }
            if let h = hint {
                if !h.followUp.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("可以追问").font(.caption2.weight(.semibold)).foregroundStyle(Theme.brand)
                        Text(h.followUp).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                ForEach(h.flags, id: \.self) { f in
                    Label(f, systemImage: "flag.fill").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if !h.missing.isEmpty {
                    Text("还没答到").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    ForEach(h.missing.prefix(3), id: \.self) { m in
                        Label(m.replacingOccurrences(of: "★ ", with: ""), systemImage: m.hasPrefix("★") ? "star.fill" : "circle.dashed")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                if !h.covered.isEmpty {
                    Button { withAnimation(.snappy) { showDone.toggle() } } label: {
                        Text(String(format: L("已答到 %lld 点"), h.covered.count) + (showDone ? " ▾" : " ▸"))
                            .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    }.buttonStyle(.plain)
                    if showDone {
                        ForEach(h.covered, id: \.self) { Label($0, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            } else {
                Text(busy ? "正在分析…" : "候选人开始回答后，会根据参考答案提示还没问到的点和下一句追问")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.brand.opacity(0.25)))
    }
}
