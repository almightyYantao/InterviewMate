import AppKit
import SwiftUI

/// 面试日历：列表 / 日 / 周 / 月 四种看法，默认只显示对上候选人的面试
struct CalendarPage: View {
    @EnvironmentObject var store: Store
    @ObservedObject var r: InterviewReminder
    @AppStorage("calMode") private var mode = "week"
    @AppStorage("calShowAll") private var showAll = false
    @State private var anchor = Date()
    @State private var forward = true
    private var cal: Calendar { var c = Calendar.current; c.firstWeekday = 2; return c }

    var events: [CalEvent] { r.events.filter { showAll || $0.candidateId != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            toolbar
            status
            ZStack {
                content
                    .id("\(mode)-\(Int(anchor.timeIntervalSince1970 / 86400))")
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 40 : -40)),
                                            removal: .opacity.combined(with: .offset(x: forward ? -40 : 40))))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: mode)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: anchor)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: showAll)
        .task { if r.syncedAt == nil { await r.refresh() } }
    }

    // MARK: 顶部

    var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("面试日历").font(.system(size: 30, weight: .bold))
                Text(String(format: L("来源：%@ · 面试开始前 %lld 分钟提醒"), r.source.isEmpty ? L("日历") : r.source,
                            store.settings?.remindMinutes ?? 15)).foregroundStyle(.secondary)
            }
            Spacer()
            if r.syncing { ProgressView().controlSize(.small).padding(.trailing, 6) }
            PillButton(title: "设置", symbol: "gearshape") { store.showSettings = true }
            PillButton(title: "立即同步", symbol: "arrow.clockwise") { Task { await r.refresh() } }
        }
    }

    var toolbar: some View {
        HStack(spacing: 10) {
            Segmented(value: $mode, options: [("list", L("列表")), ("day", L("日")), ("week", L("周")), ("month", L("月"))])
            if mode != "list" {
                HStack(spacing: 2) {
                    iconButton("chevron.left") { step(-1) }
                    Button("今天") { forward = anchor < Date(); anchor = Date() }
                        .buttonStyle(.plain).font(.callout.weight(.medium)).padding(.horizontal, 10)
                    iconButton("chevron.right") { step(1) }
                }
                .padding(3).background(Theme.page, in: Capsule())
                Text(rangeTitle).font(.headline).padding(.leading, 6).contentTransition(.opacity)
            }
            Spacer()
            Toggle("显示其他日程", isOn: $showAll).toggleStyle(.switch).controlSize(.small)
        }
    }

    func iconButton(_ sym: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: sym).font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    var status: some View {
        let matched = r.events.filter { $0.candidateId != nil }.count
        var t = r.syncing ? L("正在同步…")
            : r.syncedAt.map { String(format: L("%@ 同步"), $0.formatted(date: .omitted, time: .shortened)) } ?? L("还没同步")
        if !r.events.isEmpty { t += " · " + String(format: L("%lld 个日程，%lld 个已对上候选人"), r.events.count, matched) }
        if !showAll && r.events.count > matched { t += " · " + L("其他日程已隐藏") }
        return VStack(alignment: .leading, spacing: 6) {
            Label(t, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
            if let e = r.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    var rangeTitle: String {
        switch mode {
        case "day": return anchor.formatted(.dateTime.year().month().day().weekday(.wide))
        case "month": return anchor.formatted(.dateTime.year().month(.wide))
        default:
            let d = weekDays
            return "\(d.first!.formatted(.dateTime.month().day())) – \(d.last!.formatted(.dateTime.month().day()))"
        }
    }

    func step(_ n: Int) {
        forward = n > 0
        let unit: Calendar.Component = mode == "day" ? .day : mode == "month" ? .month : .weekOfYear
        anchor = cal.date(byAdding: unit, value: n, to: anchor) ?? anchor
    }

    // MARK: 内容

    @ViewBuilder var content: some View {
        if r.needsMacCalendar && r.events.isEmpty {
            ContentUnavailableView {
                Label("把 Gmail 日历加到 Mac", systemImage: "calendar.badge.plus")
            } description: {
                Text("公司 Google 账号不提供私密地址时，用这种方式：\n系统设置 › 互联网账户 › 添加账户 › Google，登录后勾选「日历」。\n加好后回来点「立即同步」。")
            } actions: {
                PrimaryButton(title: "打开互联网账户", symbol: "person.crop.circle.badge.plus") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
                }
            }
            .emptyStateLayout()
        } else {
            switch mode {
            case "list": listView
            case "day": TimeGrid(days: [cal.startOfDay(for: anchor)], events: events, r: r)
            case "month": MonthGrid(anchor: anchor, cal: cal, events: events, r: r) { d in forward = d > anchor; anchor = d; mode = "day" }
            default: TimeGrid(days: weekDays, events: events, r: r)
            }
        }
    }

    var weekDays: [Date] {
        let start = cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? cal.startOfDay(for: anchor)
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    var listView: some View {
        let upcoming = events.filter { ($0.endDate ?? .distantPast) > cal.startOfDay(for: Date()) }
        let g = Dictionary(grouping: upcoming) { cal.startOfDay(for: $0.startDate ?? .distantPast) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if upcoming.isEmpty {
                    ContentUnavailableView(showAll ? "近期没有日程" : "近期没有对上候选人的面试", systemImage: "calendar").emptyStateLayout()
                }
                ForEach(g.keys.sorted(), id: \.self) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(dayTitle(day)).font(.headline).foregroundStyle(cal.isDateInToday(day) ? Theme.brand : .secondary)
                        ForEach(g[day]!.sorted { $0.start < $1.start }) { EventRow(e: $0, r: r) }
                    }
                }
            }
            .frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    func dayTitle(_ d: Date) -> String {
        let base = d.formatted(.dateTime.month().day().weekday(.wide))
        if cal.isDateInToday(d) { return L("今天") + " · " + base }
        if cal.isDateInTomorrow(d) { return L("明天") + " · " + base }
        return base
    }
}

// MARK: - 日 / 周：按时间排的格子

struct TimeGrid: View {
    let days: [Date]
    let events: [CalEvent]
    @ObservedObject var r: InterviewReminder
    let hours = Array(7...22)
    let rowH: CGFloat = 52
    private var cal: Calendar { Calendar.current }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 52, height: 1)
                ForEach(days, id: \.self) { d in
                    VStack(spacing: 2) {
                        Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.caption).foregroundStyle(.secondary)
                        Text("\(cal.component(.day, from: d))").font(.system(size: 18, weight: .semibold)).monospacedDigit().fixedSize()
                            .foregroundStyle(cal.isDateInToday(d) ? .white : .primary)
                            .frame(width: 36, height: 36)
                            .background(cal.isDateInToday(d) ? Theme.brand : .clear, in: Circle())
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ForEach(hours, id: \.self) { h in
                                HStack(alignment: .top, spacing: 0) {
                                    Text(String(format: "%02d:00", h)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                        .frame(width: 52, alignment: .leading).offset(y: -6)
                                    Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1).frame(maxWidth: .infinity, alignment: .top)
                                }
                                .frame(height: rowH, alignment: .top).id(h)
                            }
                        }
                        GeometryReader { g in
                            let colW = (g.size.width - 52) / CGFloat(days.count)
                            ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                                if cal.isDateInToday(d) { nowLine(width: colW).offset(x: 52 + CGFloat(i) * colW, y: y(Date())) }
                                ForEach(events.filter { $0.startDate.map { cal.isDate($0, inSameDayAs: d) } ?? false }) { e in
                                    let top = y(e.startDate!), bottom = y(e.endDate ?? e.startDate!.addingTimeInterval(3600))
                                    EventBlock(e: e, r: r)
                                        .frame(width: colW - 6, height: max(26, bottom - top - 2))
                                        .offset(x: 52 + CGFloat(i) * colW + 3, y: top + 1)
                                }
                            }
                        }
                    }
                    .frame(height: CGFloat(hours.count) * rowH)
                }
                .onAppear { proxy.scrollTo(9, anchor: .top) }
            }
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.06)))
    }

    func y(_ d: Date) -> CGFloat {
        let c = cal.dateComponents([.hour, .minute], from: d)
        let h = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 - Double(hours.first!)
        return CGFloat(max(0, min(Double(hours.count), h))) * rowH
    }

    func nowLine(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Rectangle().fill(Color.red).frame(height: 1.5)
        }
        .frame(width: width).offset(y: -4)
    }
}

/// 格子里的一个日程
struct EventBlock: View {
    let e: CalEvent
    @ObservedObject var r: InterviewReminder
    @State private var hover = false
    var color: Color { e.candidateId != nil ? Theme.brand : .gray }

    var body: some View {
        Group {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.candidateName.map { $0.replacingOccurrences(of: #"\s*\d+年$"#, with: "", options: .regularExpression) } ?? e.title)
                        .font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Text([e.startDate?.formatted(.dateTime.hour().minute()), e.meetingApp].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(color.opacity(hover ? 0.2 : 0.12), in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .eventPopover(e, r)
        .onHover { hover = $0 }
        .help(e.title + (e.candidateName.map { "\n" + String(format: L("已对上候选人：%@"), $0) } ?? ""))
        .contextMenu {
            if e.candidateId != nil { Button("打开准备材料") { r.open(e) } }
            MeetingMenuItems(e: e)
        }
    }
}

// MARK: - 月

struct MonthGrid: View {
    let anchor: Date
    let cal: Calendar
    let events: [CalEvent]
    @ObservedObject var r: InterviewReminder
    let pickDay: (Date) -> Void

    var days: [Date] {
        guard let m = cal.dateInterval(of: .month, for: anchor),
              let start = cal.dateInterval(of: .weekOfYear, for: m.start)?.start else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days.prefix(7), id: \.self) { d in
                    Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(days, id: \.self) { d in cell(d) }
            }
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.06)))
    }

    func cell(_ d: Date) -> some View {
        let inMonth = cal.isDate(d, equalTo: anchor, toGranularity: .month)
        let items = events.filter { $0.startDate.map { cal.isDate($0, inSameDayAs: d) } ?? false }.sorted { $0.start < $1.start }
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(cal.component(.day, from: d))").font(.system(size: 12, weight: .semibold)).monospacedDigit().fixedSize()
                .foregroundStyle(cal.isDateInToday(d) ? .white : inMonth ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(cal.isDateInToday(d) ? Theme.brand : .clear, in: Circle())
            ForEach(items.prefix(3)) { e in
                Group {
                    HStack(spacing: 4) {
                        Circle().fill(e.candidateId != nil ? Theme.brand : .gray).frame(width: 5, height: 5)
                        Text("\(e.startDate?.formatted(.dateTime.hour().minute()) ?? "") \(e.candidateName ?? e.title)")
                            .font(.system(size: 10.5)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .eventPopover(e, r)
                .help(e.title)
            }
            if items.count > 3 { Text(String(format: L("还有 %lld 个"), items.count - 3)).font(.system(size: 10)).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(inMonth ? Color.clear : Theme.page.opacity(0.6))
        .overlay(Rectangle().strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { pickDay(d) }
        .opacity(inMonth ? 1 : 0.6)
    }
}

// MARK: - 列表行

struct EventRow: View {
    let e: CalEvent
    @ObservedObject var r: InterviewReminder
    @State private var hover = false
    var past: Bool { (e.endDate ?? e.startDate ?? .distantFuture) < Date() }

    var body: some View {
        HStack(spacing: 14) {
            Text(e.startDate.map { $0.formatted(.dateTime.hour().minute()) } ?? "")
                .font(.system(size: 15, weight: .semibold)).monospacedDigit().frame(width: 56, alignment: .leading)
            Rectangle().fill(e.candidateId != nil ? Theme.brand : Color.gray.opacity(0.4)).frame(width: 3).clipShape(Capsule())
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title.isEmpty ? L("（无标题）") : e.title).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 10) {
                    if let n = e.candidateName {
                        Label(String(format: L("已对上候选人：%@"), n), systemImage: "person.crop.circle.badge.checkmark")
                            .font(.caption).foregroundStyle(Theme.brand)
                    }
                    if let app = e.meetingApp, !app.isEmpty {
                        Label(app + ((e.meetingCode ?? "").isEmpty ? "" : " " + (e.meetingCode ?? "")), systemImage: "video")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 10)
            MeetingButton(e: e)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
        .padding(12)
        .background(hover ? Color.white : Theme.page, in: RoundedRectangle(cornerRadius: 12))
        .opacity(past ? 0.55 : 1)
        .eventPopover(e, r, edge: .bottom)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

/// 进入会议：有链接直接打开；腾讯会议只有会议号时用 wemeet 协议拉起客户端；其他只有会议号时复制
enum MeetingAction {
    static func url(_ e: CalEvent) -> URL? {
        if !e.meetingUrl.isEmpty { return URL(string: e.meetingUrl) }
        if e.meetingApp == "腾讯会议", let c = e.meetingCode, !c.isEmpty { return URL(string: "wemeet://page/inmeeting?meeting_code=\(c)") }
        return nil
    }
    static func copyCode(_ e: CalEvent) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.meetingCode ?? "", forType: .string)
    }
}

struct MeetingButton: View {
    let e: CalEvent
    @State private var copied = false
    var body: some View {
        let app = (e.meetingApp ?? "").isEmpty ? L("会议") : L(e.meetingApp!)
        if let u = MeetingAction.url(e) {
            PillButton(title: String(format: L("进入%@"), app), symbol: "video.fill") { NSWorkspace.shared.open(u) }
        } else if let c = e.meetingCode, !c.isEmpty {
            PillButton(title: copied ? L("已复制会议号") : String(format: L("复制%@会议号"), app), symbol: "doc.on.doc") {
                MeetingAction.copyCode(e); withAnimation { copied = true }
            }
        }
    }
}

struct MeetingMenuItems: View {
    let e: CalEvent
    var body: some View {
        if let u = MeetingAction.url(e) { Button(String(format: L("进入%@"), L(e.meetingApp ?? "会议"))) { NSWorkspace.shared.open(u) } }
        if let c = e.meetingCode, !c.isEmpty { Button(String(format: L("复制会议号 %@"), c)) { MeetingAction.copyCode(e) } }
    }
}
