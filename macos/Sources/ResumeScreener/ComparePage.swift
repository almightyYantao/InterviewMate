import SwiftUI

/// 候选人列表「对比」模式下卡片右下角的勾选框
struct CompareCheck: View {
    let on: Bool
    var body: some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(on ? Theme.brand : Color.secondary.opacity(0.5))
            .background(Circle().fill(.white).padding(2))
            .contentTransition(.symbolEffect(.replace))
    }
}

/// 同一岗位 2～4 位候选人并排对比，可让 AI 给出推荐顺序
struct ComparePage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backend: Backend
    @State private var data: CompareData?
    @State private var error: String?
    @State private var aiBusy = false
    @State private var onlyDiff = true
    let labelW: CGFloat = 200

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    PillButton(title: "返回候选人", symbol: "chevron.left") {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { store.showCompare = false }
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("候选人对比").font(.system(size: 30, weight: .bold))
                    Text(data?.position ?? store.selectedPosition?.title ?? "").foregroundStyle(.secondary)
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if let d = data {
                    aiCard(d)
                    table(d)
                } else if error == nil {
                    ProgressView().emptyStateLayout()
                }
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 32)
            .frame(maxWidth: 1300, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color.white)
        .task { await load(ai: false) }
    }

    func load(ai: Bool) async {
        do {
            let d = try await backend.compare(store.compareIDs, ai: ai)
            withAnimation(.spring(response: 0.4)) { data = d }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: AI 建议

    func aiCard(_ d: CompareData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI 建议", systemImage: "sparkles").font(.headline).foregroundStyle(Theme.brand)
                Spacer()
                if aiBusy { ProgressView().controlSize(.small) }
                PillButton(title: d.ai == nil ? "生成建议" : "重新生成", symbol: "sparkles") {
                    aiBusy = true
                    Task { await load(ai: true); aiBusy = false }
                }
                .disabled(aiBusy)
            }
            if let ai = d.ai {
                Text(ai.recommendation).font(.system(size: 14.5)).lineSpacing(5).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(Array(ai.ranking.enumerated()), id: \.offset) { i, n in
                        HStack(spacing: 6) {
                            Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 20, height: 20).background(i == 0 ? Color.green : Color.gray, in: Circle())
                            Text(n).font(.callout.weight(.semibold))
                        }
                        if i < ai.ranking.count - 1 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                    }
                }
            } else {
                Text("综合简历匹配、面试打分、评价和你的整体反馈，给出推荐顺序和关键差异").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(Theme.brand.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.brand.opacity(0.2)))
    }

    // MARK: 对比表

    func table(_ d: CompareData) -> some View {
        let cs = d.candidates
        let best = cs.map(\.score).max()
        let per = Dictionary((d.ai?.perCandidate ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let reqs = d.requirements.filter { r in
            !onlyDiff || Set(cs.map { $0.verdicts[r.id] ?? "unknown" }).count > 1
        }.sorted { ($0.level == "must" ? 0 : 1, -$0.weight) < ($1.level == "must" ? 0 : 1, -$1.weight) }

        return VStack(alignment: .leading, spacing: 0) {
            // 表头：每人一列
            row(L("候选人"), header: true) { c in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(String(c.name.prefix(1))).font(.callout.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(decisionColor(c.decision).gradient, in: Circle())
                        Text(c.name).font(.headline).lineLimit(1)
                    }
                    Button(L("打开报告")) {
                        if let pid = store.selectedPositionID { withAnimation { store.openCandidate(pid, c.id) } }
                    }.buttonStyle(.plain).font(.caption).foregroundStyle(Theme.brand)
                }
            }
            section("综合")
            row(L("匹配分")) { c in
                HStack(spacing: 8) {
                    Text(String(format: "%.1f", c.score)).font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(c.score == best ? .green : .primary)
                    if c.score == best { Text("最高").font(.caption2.weight(.bold)).foregroundStyle(.green) }
                }
            }
            row(L("筛选结论")) { c in Chip(text: Labels.decision[c.decision] ?? c.decision, color: decisionColor(c.decision)) }
            row(L("高风险疑点")) { c in Text("\(c.highDoubts)").foregroundStyle(c.highDoubts > 0 ? .red : .secondary).fontWeight(.semibold) }
            row(L("面试结论")) { c in
                if let d = c.interviewDecision {
                    Chip(text: L(d), color: d == "通过" ? .green : d == "不通过" ? .red : .orange)
                } else { Text("尚未面试").foregroundStyle(.secondary) }
            }
            row(L("面试打分")) { c in
                HStack(spacing: 6) {
                    countDot(c.scoreCounts["excellent"] ?? 0, .green, L("优秀"))
                    countDot(c.scoreCounts["pass"] ?? 0, Theme.brand, L("合格"))
                    countDot(c.scoreCounts["fail"] ?? 0, .red, L("不合格"))
                }
            }
            row(L("亮点")) { c in bullets((per[c.name]?.strengths ?? []) + c.highlights, .green) }
            row(L("风险 / 不足")) { c in bullets((per[c.name]?.risks ?? []) + c.concerns, .red) }
            row(L("面试评价")) { c in
                Text(c.interviewComment.isEmpty ? (c.note.isEmpty ? "—" : c.note) : c.interviewComment)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                section("JD 要求")
                Spacer()
                Toggle("只看有差异的", isOn: $onlyDiff.animation(.spring(response: 0.35))).toggleStyle(.switch).controlSize(.small)
            }
            if reqs.isEmpty { Text("这几位在所有 JD 要求上的匹配结果都一样").font(.callout).foregroundStyle(.secondary).padding(.vertical, 10) }
            ForEach(reqs, id: \.id) { r in
                row(r.text, sub: "\(Labels.level[r.level] ?? r.level) · \(L("权重")) \(r.weight)") { c in
                    let v = c.verdicts[r.id] ?? "unknown"
                    Label(Labels.verdict[v] ?? v, systemImage: Labels.verdictSymbol[v] ?? "circle")
                        .font(.callout).foregroundStyle(["match": Color.green, "partial": .orange, "missing": .red][v] ?? .gray)
                }
            }
        }
        .padding(18)
        .background(Theme.page, in: RoundedRectangle(cornerRadius: 14))
    }

    func row<C: View>(_ label: String, sub: String? = nil, header: Bool = false, @ViewBuilder _ cell: @escaping (CmpCandidate) -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(header ? .caption.weight(.semibold) : .callout.weight(.medium))
                    .foregroundStyle(header ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
                if let sub { Text(sub).font(.caption2).foregroundStyle(.tertiary) }
            }
            .frame(width: labelW, alignment: .leading)
            ForEach(data?.candidates ?? []) { c in
                cell(c).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.05)).frame(height: 1) }
    }

    func section(_ t: String) -> some View {
        Text(LocalizedStringKey(t)).font(.caption.weight(.bold)).foregroundStyle(Theme.brand).padding(.top, 16).padding(.bottom, 2)
    }

    func countDot(_ n: Int, _ c: Color, _ t: String) -> some View {
        Text("\(t) \(n)").font(.caption.weight(.semibold)).foregroundStyle(n > 0 ? c : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 3).background((n > 0 ? c : .gray).opacity(0.1), in: Capsule())
    }

    @ViewBuilder func bullets(_ items: [String], _ c: Color) -> some View {
        if items.isEmpty { Text("—").foregroundStyle(.secondary) }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { _, t in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(c).frame(width: 5, height: 5)
                    Text(t).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
