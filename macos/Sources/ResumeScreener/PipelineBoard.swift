import SwiftUI
import UniformTypeIdentifiers

/// 岗位看板：顶部漏斗 + 按阶段分列；把卡片拖到「通过 / 待定 / 不通过」直接改面试结论
struct PipelineBoard: View {
    @EnvironmentObject var store: Store
    @State private var target: String?

    struct Col { let key: String; let title: String; let symbol: String; let color: Color }
    let cols = [Col(key: "gen", title: "生成中", symbol: "sparkles", color: .purple),
                Col(key: "todo", title: "待面试", symbol: "clock", color: .gray),
                Col(key: "待定", title: "待定", symbol: "clock.fill", color: .orange),
                Col(key: "通过", title: "通过", symbol: "checkmark.seal.fill", color: .green),
                Col(key: "不通过", title: "不通过", symbol: "xmark.seal.fill", color: .red)]

    func column(_ c: Candidate) -> String {
        if c.status != "done" { return "gen" }
        if let d = c.interviewDecision { return d }
        return c.interviewed == true ? "待定" : "todo"
    }

    var body: some View {
        let all = store.candidates
        VStack(alignment: .leading, spacing: 18) {
            funnel(all)
            HStack(alignment: .top, spacing: 12) {
                ForEach(cols, id: \.key) { col in
                    let items = all.filter { column($0) == col.key }.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: col.symbol).foregroundStyle(col.color)
                            Text(LocalizedStringKey(col.title)).font(.callout.weight(.semibold))
                            Text("\(items.count)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1).background(Color.white, in: Capsule())
                        }
                        .padding(.bottom, 2)
                        ForEach(items) { c in
                            BoardCard(c: c)
                                .onTapGesture { store.selectedCandidateID = c.id }
                                .draggable(c.id)
                                .transition(.scale(scale: 0.95).combined(with: .opacity))
                        }
                        if items.isEmpty {
                            Text(["通过", "待定", "不通过"].contains(col.key) ? "把候选人拖到这里" : "—")
                                .font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 18)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .top)
                    .background(target == col.key ? col.color.opacity(0.12) : Theme.page, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(target == col.key ? col.color.opacity(0.6) : .clear, lineWidth: 1.5))
                    .dropDestination(for: String.self) { ids, _ in
                        guard ["通过", "待定", "不通过"].contains(col.key) else { return false }
                        for id in ids where all.first(where: { $0.id == id })?.status == "done" { store.setDecision(id, col.key) }
                        return true
                    } isTargeted: { on in withAnimation(.easeOut(duration: 0.15)) { target = on ? col.key : (target == col.key ? nil : target) } }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.86), value: all.map { column($0) })
        }
    }

    /// 漏斗：上传 → 报告完成 → 已面试 → 通过
    func funnel(_ all: [Candidate]) -> some View {
        let steps: [(String, Int, Color)] = [
            (L("上传"), all.count, .blue),
            (L("报告完成"), all.filter { $0.status == "done" }.count, .purple),
            (L("已面试"), all.filter { $0.interviewed == true }.count, .teal),
            (L("通过"), all.filter { $0.interviewDecision == "通过" }.count, .green)]
        let top = max(steps.first?.1 ?? 1, 1)
        return HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, st in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(st.1)").font(.system(size: 22, weight: .bold, design: .rounded))
                        Text(st.0).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if i > 0, steps[i - 1].1 > 0 {
                            Text("\(Int(Double(st.1) / Double(steps[i - 1].1) * 100))%").font(.caption.weight(.semibold)).foregroundStyle(st.2)
                        }
                    }
                    GeometryReader { g in
                        Capsule().fill(Color.black.opacity(0.05))
                            .overlay(alignment: .leading) { Capsule().fill(st.2.gradient).frame(width: g.size.width * CGFloat(st.1) / CGFloat(top)) }
                    }
                    .frame(height: 8)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(st.2.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                if i < steps.count - 1 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
        }
    }
}

struct BoardCard: View {
    let c: Candidate
    @State private var hover = false
    var body: some View {
        let color = decisionColor(c.decision)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(String((c.name ?? "?").prefix(1))).font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(color.gradient, in: Circle())
                Text(c.name ?? "—").font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if let s = c.score { Text(String(format: "%.1f", s)).font(.callout.weight(.bold)).monospacedDigit().foregroundStyle(color) }
            }
            if c.status == "done" {
                HStack(spacing: 6) {
                    if let d = c.decision { Chip(text: Labels.decision[d] ?? d, color: color) }
                    if let h = c.high, h > 0 { Text(String(format: L("%lld 个高风险"), h)).font(.caption2).foregroundStyle(.secondary) }
                }
            } else {
                Text(c.progress ?? L("排队中")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(hover ? 0.1 : 0.03), radius: hover ? 8 : 2, y: hover ? 3 : 1)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}
