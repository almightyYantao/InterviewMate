import AppKit
import SwiftUI

/// 个人 Bob 账号：我能看到的在招岗位和应聘人
struct BobPipelineView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backend: Backend
    @State private var error: String?
    @State private var loading = false
    @AppStorage("bobSort") private var sort = "applied"
    @AppStorage("bobShowClosed") private var showClosed = false
    @State private var waiting: String?      // 正在等这个应聘人的简历下载

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("我的 HiBob 招聘").font(.system(size: 30, weight: .bold))
                        Text("用你的 Bob 账号，显示你能看到的在招岗位和进行中的应聘人").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if loading { ProgressView().controlSize(.small).padding(.trailing, 6) }
                    PillButton(title: "刷新", symbol: "arrow.clockwise") { Task { await load() } }
                }
                HStack(spacing: 12) {
                    Text("排序").font(.callout).foregroundStyle(.secondary)
                    Segmented(value: $sort, options: [("applied", L("最新申请")), ("stage", L("阶段")), ("name", L("姓名"))])
                    Spacer()
                    Toggle("显示已淘汰 / 撤回", isOn: $showClosed.animation(.spring(response: 0.35))).toggleStyle(.switch).controlSize(.small)
                }
                if let list = store.bobPipeline { statusLine(list) }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                if let list = store.bobPipeline {
                    if list.isEmpty { ContentUnavailableView("没有在招岗位", systemImage: "briefcase").emptyStateLayout() }
                    ForEach(openings(list)) { opening($0).transition(.opacity) }
                } else if error == nil {
                    ProgressView().emptyStateLayout()
                }
            }
            // 排序、显示已淘汰切换时，岗位和人员都带动画重新排列
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: sort)
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: showClosed)
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 32)
            .frame(maxWidth: 1200, alignment: .leading).frame(maxWidth: .infinity)
        }
        .task {
            // 有缓存先显示，超过 5 分钟（或刚打开 App）再后台更新
            if Date().timeIntervalSince(store.bobLoadedAt ?? .distantPast) > 300 { await load() }
        }
    }

    func opening(_ o: BobOpening) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(store.bobExpanded.contains(o.id) ? 90 : 0))
                Image(systemName: "briefcase.fill").foregroundStyle(Theme.brand)
                    .frame(width: 32, height: 32).background(Theme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                Text(o.title).font(.headline)
                Text(String(format: L("%lld 人进行中"), o.applicants.filter(\.active).count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let pid = o.positionId {
                    PillButton(title: "打开本地岗位", symbol: "arrow.right") { openPosition(pid) }
                } else {
                    PrimaryButton(title: "新建同名岗位", symbol: "plus") { store.showNewPosition = true }
                        .help("App 里还没有这个岗位；Bob 接口拿不到 JD，需要粘贴 JD 新建")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(o.id) }
            if store.bobExpanded.contains(o.id) {
            ForEach(rows(o)) { a in
                HStack(spacing: 12) {
                    Text(String(a.name.prefix(1))).font(.callout.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 32, height: 32).background(Color.gray.gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.callout.weight(.semibold))
                        Text([a.source, a.applied].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Chip(text: a.stage, color: a.active ? Theme.brand : .gray)
                    if let d = a.localDecision {
                        Label(String(format: L("我的结论：%@"), L(d)), systemImage: d == "通过" ? "checkmark.seal.fill" : d == "不通过" ? "xmark.seal.fill" : "clock.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(tint(d).gradient, in: Capsule())
                    }
                    if !a.active, let st = a.statusLabel {
                        Chip(text: st, color: a.status == "rejected" ? .red : a.status == "hired" ? .green : .gray)
                    }
                    Spacer()
                    PillButton(title: "在 Bob 打开", symbol: "safari") { if let u = URL(string: a.url) { NSWorkspace.shared.open(u) } }
                    if let cid = a.candidateId, let pid = o.positionId {
                        PrimaryButton(title: "打开准备材料", symbol: "doc.text.magnifyingglass") { openCandidate(pid, cid) }
                    } else if let pid = o.positionId {
                        if waiting == a.id {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("在 Bob 里下载简历，会自动导入…").font(.caption).foregroundStyle(.secondary)
                                Button("取消") { waiting = nil }.buttonStyle(.plain).font(.caption).foregroundStyle(Theme.brand)
                            }
                        } else {
                            PrimaryButton(title: "从 Bob 导入简历", symbol: "arrow.down.doc") { importFromBob(a, pid) }
                                .help("打开 Bob 里的申请页，你点下载简历后自动导入")
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 12).fill(a.localDecision.map { tint($0).opacity(0.08) } ?? .clear)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(a.localDecision.map { tint($0).opacity(0.35) } ?? .clear))
                .opacity(a.active ? 1 : 0.6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            }
        }
        .clipped()
        .padding(16)
        .background(Theme.page, in: RoundedRectangle(cornerRadius: 16))
    }

    /// 状态说明：什么时候更新的、当前怎么排、显示 / 隐藏了多少人
    func statusLine(_ list: [BobOpening]) -> some View {
        let all = list.flatMap(\.applicants)
        let hidden = showClosed ? 0 : all.filter { !$0.active }.count
        let sortName = ["applied": L("最新申请"), "stage": L("阶段"), "name": L("姓名")][sort] ?? sort
        var parts = [loading ? L("正在从 Bob 更新…")
                     : store.bobLoadedAt.map { String(format: L("%@ 从 Bob 更新"), $0.formatted(date: .omitted, time: .shortened)) } ?? L("显示的是上次缓存的数据")]
        parts.append(String(format: L("岗位和人员都按「%@」排序"), sortName))
        parts.append(String(format: L("共 %lld 人"), all.count - hidden))
        if hidden > 0 { parts.append(String(format: L("隐藏了 %lld 个已淘汰 / 撤回"), hidden)) }
        return Label(parts.joined(separator: " · "), systemImage: loading ? "arrow.triangle.2.circlepath" : "clock")
            .font(.caption).foregroundStyle(.secondary)
            .contentTransition(.opacity)
    }

    /// 岗位也按同一个规则排：最新申请时间 / 最靠后的阶段 / 岗位名
    func openings(_ v: [BobOpening]) -> [BobOpening] {
        switch sort {
        case "stage": return v.sorted { (rows($0).first.map(rank) ?? -9) > (rows($1).first.map(rank) ?? -9) }
        case "name": return v.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        default: return v.sorted { (rows($0).first?.applied ?? "") > (rows($1).first?.applied ?? "") }
        }
    }

    func rank(_ a: BobApplicant) -> Int {
        let order = ["New", "Resume Review", "Recruiter Screen Call", "1st Interview", "2nd Interview", "Cross Interview",
                     "Executive Interview", "HR Interview", "Pre-Employment Check", "Offer", "Hired", "新建", "筛选", "面试"]
        return order.firstIndex(of: a.stage).map { $0 < 11 ? $0 : [-3, 1, 4][$0 - 11] } ?? -1
    }

    /// 排序 + 默认隐藏已淘汰、已撤回
    func rows(_ o: BobOpening) -> [BobApplicant] {
        let v = o.applicants.filter { showClosed || $0.active }
        switch sort {
        case "stage":
            return v.sorted { (rank($0), $0.applied) > (rank($1), $1.applied) }
        case "name": return v.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        default: return v.sorted { $0.applied > $1.applied }
        }
    }

    func tint(_ d: String) -> Color { d == "通过" ? .green : d == "不通过" ? .red : .orange }

    func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let v = try await backend.hibobPipeline()
            if store.bobExpanded.isEmpty { store.bobExpanded = Set(v.filter { $0.positionId != nil }.map(\.id)) }   // 首次：App 里建过的岗位展开
            withAnimation(.spring(response: 0.4)) { store.bobPipeline = v }
            store.bobLoadedAt = Date()
        } catch { withAnimation { self.error = error.localizedDescription } }
    }

    /// 打开 Bob 申请页，盯着「下载」文件夹，出现新的简历文件就导入到这个岗位
    func importFromBob(_ a: BobApplicant, _ pid: String) {
        guard let u = URL(string: a.url) else { return }
        let start = Date()
        waiting = a.id
        NSWorkspace.shared.open(u)
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        Task {
            for _ in 0..<180 where waiting == a.id {
                try? await Task.sleep(for: .seconds(1))
                let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
                if let f = files.first(where: { f in
                    ["pdf", "docx", "doc"].contains(f.pathExtension.lowercased()) &&
                    ((try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > start
                }) {
                    // 等浏览器写完文件
                    try? await Task.sleep(for: .seconds(1))
                    waiting = nil
                    store.selectedPositionID = pid
                    store.upload([f])
                    try? await Task.sleep(for: .seconds(2))
                    store.bobLoadedAt = nil
                    await load()
                    return
                }
            }
            if waiting == a.id { waiting = nil; error = L("3 分钟内没在「下载」文件夹里看到新的简历文件，可以再点一次，或者在岗位页手动上传") }
        }
    }

    func toggle(_ id: String) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            if store.bobExpanded.contains(id) { store.bobExpanded.remove(id) } else { store.bobExpanded.insert(id) }
        }
    }

    func openPosition(_ pid: String) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { store.showHiBob = false; store.selectedPositionID = pid }
    }

    func openCandidate(_ pid: String, _ cid: String) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { store.openCandidate(pid, cid) }
    }
}

/// 还没登录 Bob 时的页面
struct BobLoginView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backend: Backend
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.badge.key.fill").font(.system(size: 44)).foregroundStyle(Theme.brand)
                .frame(width: 88, height: 88).background(Theme.brand.opacity(0.1), in: Circle())
            Text("登录 Bob 查看你的招聘").font(.title2.weight(.bold))
            Text("用你自己的 Bob 账号在浏览器里授权一次，就能看到你能访问的在招岗位和应聘人。\n只读取你在 Bob 里本来就有权限看的内容，30 天内不用重复登录。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            HStack(spacing: 10) {
                if busy { ProgressView().controlSize(.small); Text("等待浏览器授权…").foregroundStyle(.secondary) }
                else { PrimaryButton(title: "用 Bob 账号登录", symbol: "person.crop.circle.badge.checkmark") { login() } }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func login() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                NSWorkspace.shared.open(try await backend.hibobLoginURL())
                for _ in 0..<90 {
                    try? await Task.sleep(for: .seconds(2))
                    if (try? await backend.hibobStatus().connected) == true {
                        withAnimation(.spring(response: 0.45)) { store.hibobConnected = true }
                        return
                    }
                }
                error = L("没有等到授权结果，可以再点一次")
            } catch { self.error = error.localizedDescription }
        }
    }
}
