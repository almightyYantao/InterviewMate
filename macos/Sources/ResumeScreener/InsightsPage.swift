import SwiftUI

/// 我的复盘：从所有面试记录里统计你的面试习惯
struct InsightsPage: View {
    @EnvironmentObject var backend: Backend
    @State private var d: Insights?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("我的复盘").font(.system(size: 30, weight: .bold))
                    Text("从你所有的面试记录里统计：打分习惯、和 AI 建议的差别、哪些环节常问不到").foregroundStyle(.secondary)
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if let d {
                    if d.interviewed == 0 {
                        ContentUnavailableView("还没有面试记录", systemImage: "chart.bar", description: Text("面试打分、生成评价后，这里会出现统计")).emptyStateLayout()
                    } else { content(d) }
                } else if error == nil { ProgressView().emptyStateLayout() }
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 32)
            .frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color.white)
        .task {
            do { let v = try await backend.insights(); withAnimation(.spring(response: 0.4)) { d = v } }
            catch { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder func content(_ d: Insights) -> some View {
        HStack(spacing: 14) {
            StatTile(value: "\(d.interviewed)", title: "面过的人", symbol: "person.2.fill", tint: .blue)
            StatTile(value: "\(d.decisions["通过"] ?? 0)", title: "通过", symbol: "checkmark.seal.fill", tint: .green)
            StatTile(value: "\(d.decisions["不通过"] ?? 0)", title: "不通过", symbol: "xmark.seal.fill", tint: .red)
            StatTile(value: d.avgMinutes.map { String(format: "%.0f", $0) } ?? "—", title: "平均时长（分钟）", symbol: "timer", tint: .orange)
        }
        if !d.tips.isEmpty {
            Card(title: L("建议"), symbol: "lightbulb.fill", accent: Theme.brand) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(d.tips, id: \.self) { t in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Theme.brand).frame(width: 6, height: 6)
                            Text(t).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        HStack(alignment: .top, spacing: 14) {
            Card(title: L("我的打分分布"), symbol: "chart.bar.fill") {
                let order: [(String, String, Color)] = [("excellent", L("优秀"), .green), ("pass", L("合格"), Theme.brand), ("fail", L("不合格"), .red), ("skip", L("跳过"), .gray)]
                let top = max(order.map { d.scoreDist[$0.0] ?? 0 }.max() ?? 1, 1)
                VStack(spacing: 8) {
                    ForEach(order, id: \.0) { k, t, c in bar(t, d.scoreDist[k] ?? 0, top, c) }
                }
            }
            Card(title: L("和 AI 建议对比"), symbol: "scalemass.fill") {
                let total = (d.agree["same"] ?? 0) + (d.agree["looser"] ?? 0) + (d.agree["stricter"] ?? 0)
                if total == 0 {
                    Text("开着转写面试并生成总结后，才能对比你的打分和 AI 依据逐字稿给的建议").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        bar(L("一致"), d.agree["same"] ?? 0, total, .green)
                        bar(L("比 AI 宽"), d.agree["looser"] ?? 0, total, .orange)
                        bar(L("比 AI 严"), d.agree["stricter"] ?? 0, total, .purple)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        Card(title: L("各环节问到 / 跳过"), symbol: "list.bullet.rectangle") {
            VStack(spacing: 10) {
                ForEach(d.sections.sorted { (Labels.sections.firstIndex(of: $0.section) ?? 9) < (Labels.sections.firstIndex(of: $1.section) ?? 9) }, id: \.section) { s in
                    HStack(spacing: 12) {
                        Text(L(s.section)).font(.callout).frame(width: 90, alignment: .leading)
                        GeometryReader { g in
                            HStack(spacing: 2) {
                                Rectangle().fill(Theme.brand.gradient).frame(width: g.size.width * CGFloat(s.asked) / CGFloat(max(s.total, 1)))
                                Rectangle().fill(Color.gray.opacity(0.5)).frame(width: g.size.width * CGFloat(s.skipped) / CGFloat(max(s.total, 1)))
                                Spacer(minLength: 0)
                            }
                            .background(Color.black.opacity(0.05)).clipShape(Capsule())
                        }
                        .frame(height: 10)
                        Text(String(format: L("问了 %lld · 跳过 %lld · 共 %lld"), s.asked, s.skipped, s.total)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 170, alignment: .trailing)
                    }
                }
                if let (k, n) = d.missedBySection.max(by: { $0.value < $1.value }).map({ ($0.key, $0.value) }) {
                    Text(String(format: L("候选人没答到的要点最多在「%@」（%lld 处）"), L(k), n)).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        if !d.looserExamples.isEmpty || !d.stricterExamples.isEmpty {
            Card(title: L("打分和 AI 不一致的题"), symbol: "exclamationmark.bubble") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(d.looserExamples, id: \.self) { Label($0, systemImage: "arrow.up.circle").font(.callout).foregroundStyle(.orange) }
                    ForEach(d.stricterExamples, id: \.self) { Label($0, systemImage: "arrow.down.circle").font(.callout).foregroundStyle(.purple) }
                }
            }
        }
    }

    func bar(_ t: String, _ n: Int, _ top: Int, _ c: Color) -> some View {
        HStack(spacing: 10) {
            Text(t).font(.callout).frame(width: 70, alignment: .leading)
            GeometryReader { g in
                Capsule().fill(Color.black.opacity(0.05))
                    .overlay(alignment: .leading) { Capsule().fill(c.gradient).frame(width: g.size.width * CGFloat(n) / CGFloat(max(top, 1))) }
            }
            .frame(height: 10)
            Text("\(n)").font(.callout.weight(.semibold)).monospacedDigit().frame(width: 30, alignment: .trailing)
        }
    }
}
