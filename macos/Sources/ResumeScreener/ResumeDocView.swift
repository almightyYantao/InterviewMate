import Quartz
import SwiftUI

struct LineMark: Decodable, Equatable {
    var line: Int
    var page: Int
    var x0: Double
    var top: Double
    var x1: Double
    var bottom: Double
    var pageWidth: Double
    var pageHeight: Double
}

/// 「简历原文」：原文（按页渲染的原始文件）和解析结果（结构化表格）两种看法。
struct ResumeDocView: View {
    @EnvironmentObject var store: Store
    let cid: String
    let resume: ResumeStruct?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Segmented(value: Binding(get: { store.resumeShowOriginal ? "o" : "s" },
                                         set: { store.resumeShowOriginal = $0 == "o" }),
                          options: [("o", L("原文")), ("s", L("解析结果"))])
                Spacer()
            }
            .padding(.horizontal, 28).padding(.vertical, 12)
            ZStack {
                if store.resumeShowOriginal {
                    OriginalResume(cid: cid).transition(.opacity.combined(with: .offset(x: -30)))
                } else {
                    ScrollView { ResumeStructView(r: resume).padding(28).frame(maxWidth: 960).frame(maxWidth: .infinity) }
                        .transition(.opacity.combined(with: .offset(x: 30)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.spring(response: 0.4, dampingFraction: 0.86), value: store.resumeShowOriginal)
        }
        .background(Theme.page)
    }
}

// MARK: - 原文

struct OriginalResume: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backend: Backend
    let cid: String
    @State private var pages: [PageSize]?
    @State private var fileURL: URL?
    @State private var marks: [LineMark] = []
    @State private var flash = false

    var body: some View {
        Group {
            if let pages, !pages.isEmpty {
                GeometryReader { g in
                    let w = min(g.size.width - 56, 780)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 18) {
                                ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                                    page(i + 1, p, width: w)
                                }
                            }
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                        }
                        .onChange(of: marks) {
                            guard !marks.isEmpty else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { proxy.scrollTo("mark-0", anchor: UnitPoint(x: 0.5, y: 0.3)) }
                                flash = false
                                withAnimation(.easeInOut(duration: 0.45).repeatCount(3, autoreverses: true)) { flash = true }
                            }
                        }
                    }
                }
            } else if let fileURL {
                QuickLookView(url: fileURL)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: cid) {
            pages = (try? await backend.pageSizes(cid)) ?? []
            if pages?.isEmpty == true { fileURL = try? await backend.resumeFile(cid) }
        }
        .task(id: store.resumeFocusToken) {
            guard !store.resumeMarks.isEmpty else { marks = []; return }
            marks = (try? await backend.locate(cid, lines: store.resumeMarks)) ?? []
        }
    }

    func page(_ n: Int, _ p: PageSize, width w: CGFloat) -> some View {
        let k = w / p.width
        return ZStack(alignment: .topLeading) {
            CachedImage(url: backend.pageURL(cid, n))
                .frame(width: w, height: p.height * k)
            ForEach(Array(marks.enumerated()).filter { $0.element.page == n }, id: \.offset) { i, m in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.yellow.opacity(flash ? 0.45 : 0.3))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.orange.opacity(0.9), lineWidth: 1.5))
                    .frame(width: (m.x1 - m.x0 + 8) * k, height: (m.bottom - m.top + 6) * k)
                    .padding(.leading, (m.x0 - 4) * k).padding(.top, (m.top - 3) * k)
                    .id("mark-\(i)")
                    .allowsHitTesting(false)
            }
        }
        .frame(width: w, height: p.height * k, alignment: .topLeading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }
}

struct CachedImage: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high) }
            else { Color.white.overlay(ProgressView().controlSize(.small)) }
        }
        .task(id: url) {
            if let img = SnippetImage.cache.object(forKey: url as NSURL) { image = img; return }
            for _ in 0..<3 {
                if let (d, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200,
                   let img = NSImage(data: d) {
                    SnippetImage.cache.setObject(img, forKey: url as NSURL)
                    withAnimation(.easeOut(duration: 0.2)) { image = img }
                    return
                }
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }
}

// MARK: - 解析结果

struct ResumeStructView: View {
    @EnvironmentObject var store: Store
    let r: ResumeStruct?

    var body: some View {
        if let r {
            VStack(alignment: .leading, spacing: 16) {
                section("基本信息", "person.text.rectangle") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 10) {
                        kv("姓名", r.basic.name)
                        kv("出生年月", r.basic.birth ?? "—")
                        GridRow {
                            Text("自述工作年限").foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                if r.basic.claimedYears.isEmpty { Text("—") }
                                ForEach(r.basic.claimedYears, id: \.self) { c in
                                    LineLink(text: String(format: L("%@ 年"), fmt(c.value)), lines: [c.evidenceLine])
                                }
                                if Set(r.basic.claimedYears.map(\.value)).count > 1 {
                                    Chip(text: "前后不一致", color: .red)
                                }
                            }
                        }
                        kv("工作经历合计", totalYears(r.jobs))
                    }
                }
                section("工作经历", "briefcase", count: r.jobs.count) {
                    table(["公司", "职位", "时间", "时长"]) {
                        ForEach(Array(r.jobs.enumerated()), id: \.offset) { i, j in
                            GridRow {
                                LineLink(text: j.company, lines: [j.line]).fontWeight(.medium)
                                Text(j.title)
                                Text("\(j.start) – \(j.end ?? L("至今"))").monospacedDigit()
                                Text(duration(j.start, j.end)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            if !j.duties.isEmpty {
                                GridRow {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(j.duties, id: \.self) { d in
                                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                                Circle().fill(Color.secondary.opacity(0.5)).frame(width: 4, height: 4)
                                                Text(d.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                    }
                                    .gridCellColumns(4).padding(.bottom, 4)
                                }
                            }
                            if i < r.jobs.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
                        }
                    }
                }
                section("教育经历", "graduationcap", count: r.education.count) {
                    if r.education.isEmpty { Text("简历未写教育经历").foregroundStyle(.secondary) }
                    else {
                        table(["学校", "学历", "专业", "时间"]) {
                            ForEach(r.education, id: \.self) { e in
                                GridRow {
                                    LineLink(text: e.school, lines: [e.line]).fontWeight(.medium)
                                    Text(e.degree); Text(e.major)
                                    Text("\(e.start ?? "?") – \(e.end ?? "?")").monospacedDigit()
                                }
                            }
                        }
                    }
                }
                section("项目经历", "hammer", count: r.projects.count) {
                    table(["项目", "所在公司", "自述角色", "要点"]) {
                        ForEach(Array(r.projects.enumerated()), id: \.offset) { i, p in
                            GridRow(alignment: .top) {
                                LineLink(text: p.name, lines: p.lines).fontWeight(.medium).frame(maxWidth: 220, alignment: .leading)
                                Text(p.company ?? "—").frame(maxWidth: 160, alignment: .leading)
                                Chip(text: p.claimedRole, color: ["主导": .green, "负责": Theme.brand, "参与": .orange][p.claimedRole] ?? .gray)
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(p.details, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                }
                            }
                            if i < r.projects.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    section("技能", "wrench.and.screwdriver", count: r.skills.count) { Tags(items: r.skills) }
                    section("证书", "rosette", count: r.certs.count) {
                        if r.certs.isEmpty { Text("未提及").foregroundStyle(.secondary) } else { Tags(items: r.certs) }
                    }
                }
                Label("点击带下划线的内容可以在原文里定位", systemImage: "hand.point.up.left").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView("这份报告没有解析结果", systemImage: "tablecells", description: Text("重新生成后会补上")).emptyStateLayout()
        }
    }

    func section<C: View>(_ title: String, _ symbol: String, count: Int? = nil, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Theme.brand)
                Text(LocalizedStringKey(title)).font(.headline)
                if let count { Text("\(count)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.page, in: Capsule()) }
            }
            c()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
    }

    func table<C: View>(_ headers: [String], @ViewBuilder _ rows: () -> C) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 10) {
            GridRow { ForEach(headers, id: \.self) { Text(LocalizedStringKey($0)).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
            Divider().gridCellUnsizedAxes(.horizontal)
            rows()
        }
        .font(.callout)
    }

    func kv(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(LocalizedStringKey(k)).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }

    func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    func months(_ a: String, _ b: String?) -> Int? {
        func parse(_ s: String) -> Int? {
            let p = s.split(separator: "-").compactMap { Int($0) }
            return p.count >= 2 ? p[0] * 12 + p[1] - 1 : nil
        }
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        guard let s = parse(a) else { return nil }
        let e = b.flatMap(parse) ?? (now.year! * 12 + now.month! - 1)
        return max(0, e - s + 1)
    }

    func duration(_ a: String, _ b: String?) -> String {
        guard let m = months(a, b) else { return "—" }
        let y = m / 12, r = m % 12
        if y == 0 { return String(format: L("%lld 个月"), r) }
        return r == 0 ? String(format: L("%lld 年"), y) : String(format: L("%lld 年 %lld 个月"), y, r)
    }

    func totalYears(_ jobs: [Job]) -> String {
        let total = jobs.compactMap { months($0.start, $0.end) }.reduce(0, +)
        return total == 0 ? "—" : String(format: L("约 %@ 年（按各段经历相加）"), String(format: "%.1f", Double(total) / 12))
    }
}

/// 可点击定位到原文的文字
struct LineLink: View {
    @EnvironmentObject var store: Store
    let text: String
    let lines: [Int]
    @State private var hover = false
    var body: some View {
        Text(text)
            .underline(hover, color: Theme.brand)
            .foregroundStyle(hover ? Theme.brand : .primary)
            .onHover { hover = $0 }
            .onTapGesture { store.locateInResume(lines) }
            .help("在原文中定位")
    }
}

struct Tags: View {
    let items: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) {
                Text($0).font(.callout).padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.page, in: Capsule())
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing; row = max(row, sz.height); maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, w), height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > b.maxX, x > b.minX { x = b.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing; row = max(row, sz.height)
        }
    }
}
