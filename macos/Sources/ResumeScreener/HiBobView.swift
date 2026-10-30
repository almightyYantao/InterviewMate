import AppKit
import SwiftUI

/// 「我的 HiBob 面试」：只显示我当面试官的面试，以及相关岗位；可一键导入岗位、跳到候选人。
struct HiBobView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backend: Backend
    @State private var tab = "i"
    @State private var interviews: [HiBobInterview]?
    @State private var openings: [HiBobOpening]?
    @State private var error: String?
    @State private var loading = false
    @State private var importing: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("我的 HiBob 面试").font(.system(size: 30, weight: .bold))
                        Text(store.hibobConnected ? "用你的 Bob 账号，只显示你是面试官的面试" : "只显示你是面试官的面试，以及这些面试所属的岗位").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if loading { ProgressView().controlSize(.small).padding(.trailing, 6) }
                    PillButton(title: "刷新", symbol: "arrow.clockwise") { Task { await load() } }
                }
                if !store.hibobConnected { Segmented(value: $tab, options: [("i", L("面试安排")), ("o", L("岗位"))]) }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                ZStack(alignment: .top) {
                    if tab == "i" { interviewList.transition(.opacity.combined(with: .offset(x: -30))) }
                    else { openingList.transition(.opacity.combined(with: .offset(x: 30))) }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.86), value: tab)
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 32)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await load() }
    }

    // MARK: 面试安排

    @ViewBuilder var interviewList: some View {
        if let list = interviews {
            let now = Date()
            let cal = Calendar.current
            let today = list.filter { $0.start.map { cal.isDateInToday($0) } ?? false }
            let later = list.filter { ($0.start ?? .distantPast) > now && !(($0.start.map { cal.isDateInToday($0) }) ?? false) }
            let past = list.filter { ($0.start ?? .distantPast) < now && !(($0.start.map { cal.isDateInToday($0) }) ?? false) }.reversed()
            VStack(alignment: .leading, spacing: 18) {
                if list.isEmpty {
                    ContentUnavailableView("Bob 里没有你的面试", systemImage: "calendar",
                                           description: Text("已用你的账号查过：你还没有被安排为面试官，或者你的 Bob 权限看不到招聘数据。面试排上后点「刷新」"))
                        .emptyStateLayout()
                }
                group("今天", today)
                group("之后", Array(later))
                group("已结束", Array(past.prefix(30)))
            }
        } else if error == nil {
            ProgressView().emptyStateLayout()
        }
    }

    @ViewBuilder func group(_ title: String, _ items: [HiBobInterview]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(LocalizedStringKey(title)).font(.headline).foregroundStyle(.secondary)
                ForEach(items) { InterviewRow(i: $0, opening: openingTitle($0), importing: importing == $0.jobOpeningId) { act($0) } }
            }
        }
    }

    func openingTitle(_ i: HiBobInterview) -> String {
        openings?.first { $0.id == i.jobOpeningId }?.title ?? i.jobTitle ?? ""
    }

    // MARK: 岗位

    @ViewBuilder var openingList: some View {
        if let list = openings {
            VStack(spacing: 10) {
                if list.isEmpty { ContentUnavailableView("没有相关岗位", systemImage: "briefcase").emptyStateLayout() }
                ForEach(list) { o in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "briefcase.fill").foregroundStyle(Theme.brand)
                            .frame(width: 36, height: 36).background(Theme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(o.title).font(.headline)
                                if !o.status.isEmpty { Chip(text: o.status, color: .gray) }
                            }
                            Text(o.jd.isEmpty ? L("HiBob 里没有招聘广告，拿不到 JD") : o.jd)
                                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 12)
                        if let pid = o.positionId {
                            PillButton(title: "打开", symbol: "arrow.right") { openPosition(pid) }
                        } else {
                            PrimaryButton(title: importing == o.id ? "导入中…" : "导入岗位", symbol: "square.and.arrow.down") {
                                Task { await importOpening(o) }
                            }
                            .disabled(o.jd.isEmpty || importing != nil).opacity(o.jd.isEmpty ? 0.4 : 1)
                        }
                    }
                    .padding(16)
                    .background(Theme.page, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        } else if error == nil {
            ProgressView().emptyStateLayout()
        }
    }

    // MARK: 动作

    func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            async let iv = backend.hibobInterviews()
            async let op = backend.hibobOpenings()
            let (a, b) = try await (iv, op)
            withAnimation(.spring(response: 0.4)) { interviews = a; openings = b }
        } catch {
            withAnimation { self.error = error.localizedDescription }
        }
    }

    /// 面试行的主按钮：有候选人就打开；有岗位就去上传简历；都没有先导入岗位
    func act(_ i: HiBobInterview) {
        if let cid = i.candidateId, let pid = i.positionId {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { store.openCandidate(pid, cid) }
        } else if let pid = i.positionId {
            openPosition(pid)
            store.showImporter = true
        } else if let o = openings?.first(where: { $0.id == i.jobOpeningId }) {
            Task { if let pid = await importOpening(o) { openPosition(pid); store.showImporter = true } }
        } else {
            error = L("这场面试对应的岗位不在你的岗位列表里，请先手动新建岗位")
        }
    }

    @discardableResult
    func importOpening(_ o: HiBobOpening) async -> String? {
        importing = o.id
        defer { importing = nil }
        do {
            let pid = try await backend.hibobImport(o)
            await store.loadPositions()
            await load()
            return pid
        } catch {
            store.errorMessage = error.localizedDescription
            return nil
        }
    }

    func openPosition(_ pid: String) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
            store.showHiBob = false; store.selectedPositionID = pid
        }
    }
}

struct InterviewRow: View {
    let i: HiBobInterview
    let opening: String
    let importing: Bool
    let action: (HiBobInterview) -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 2) {
                Text(i.start.map { $0.formatted(.dateTime.month().day()) } ?? "—").font(.caption).foregroundStyle(.secondary)
                Text(i.start.map { $0.formatted(.dateTime.hour().minute()) } ?? "").font(.system(size: 17, weight: .semibold)).monospacedDigit()
            }
            .frame(width: 70)
            .padding(.vertical, 8)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(i.candidateName.isEmpty ? L("（未知候选人）") : i.candidateName).font(.headline)
                    if i.hasEvaluation { Chip(text: "已在 HiBob 提交反馈", color: .green) }
                    if i.candidateId != nil { Chip(text: "准备材料已生成", color: Theme.brand) }
                }
                Text([opening, i.title].filter { !$0.isEmpty }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let u = i.meetingUrl, !u.isEmpty, let url = URL(string: u) {
                PillButton(title: "进入会议", symbol: "video.fill") { NSWorkspace.shared.open(url) }
            }
            if i.candidateId != nil {
                PrimaryButton(title: "打开", symbol: "arrow.right") { action(i) }
            } else {
                PillButton(title: importing ? "导入中…" : (i.positionId == nil ? "导入岗位并上传简历" : "上传简历"), symbol: "doc.badge.plus") { action(i) }
                    .disabled(importing)
            }
        }
        .padding(14)
        .background(hover ? Color.white : Theme.page, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hover ? Theme.brand.opacity(0.35) : .clear))
        .shadow(color: .black.opacity(hover ? 0.06 : 0), radius: 10, y: 4)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}
