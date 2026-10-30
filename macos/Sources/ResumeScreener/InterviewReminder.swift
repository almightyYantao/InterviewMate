import AppKit
import EventKit
import SwiftUI
import UserNotifications

/// 日历里的面试：定时拉取，开始前 N 分钟发系统通知；点通知进入这位候选人
@MainActor
final class InterviewReminder: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var events: [CalEvent] = []
    @Published var error: String?
    @Published var syncedAt: Date?
    @Published var syncing = false
    @Published var source = ""          // 「Google 日历私密地址」或「Mac 日历」
    @Published var needsMacCalendar = false
    private let ek = EKEventStore()
    weak var store: Store?
    weak var backend: Backend?
    private var started = false

    func start(store: Store, backend: Backend) {
        self.store = store; self.backend = backend
        guard !started else { return }
        started = true
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task {
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func refresh() async {
        guard let backend else { return }
        syncing = true
        defer { syncing = false }
        do {
            let v: [CalEvent]
            if (store?.settings?.calendarUrlHint ?? "").isEmpty == false {
                source = L("Google 日历私密地址")
                v = try await backend.calendarEvents()
            } else {
                // 没配私密地址：读 Mac「日历」（在 系统设置 › 互联网账户 里加了 Google 账号就会有 Gmail 日历）
                source = L("Mac 日历")
                guard (try? await ek.requestFullAccessToEvents()) == true else {
                    needsMacCalendar = true
                    throw NSError(domain: "cal", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        L("没有日历权限：请在 系统设置 › 隐私与安全性 › 日历 里允许「面搭子」")])
                }
                let cals = ek.calendars(for: .event)
                needsMacCalendar = !cals.contains { $0.source.sourceType == .calDAV || $0.source.title.lowercased().contains("google") || $0.source.title.contains("@") }
                let now = Date()
                let pred = ek.predicateForEvents(withStart: now.addingTimeInterval(-35 * 86400), end: now.addingTimeInterval(60 * 86400), calendars: cals)
                let f = ISO8601DateFormatter()
                let local = ek.events(matching: pred).filter { !$0.isAllDay }.map { e in
                    Backend.LocalEvent(uid: e.calendarItemIdentifier, title: e.title ?? "", start: f.string(from: e.startDate),
                                       end: f.string(from: e.endDate), notes: e.notes ?? "", location: e.location ?? "",
                                       url: e.url?.absoluteString ?? "",
                                       attendees: (e.attendees ?? []).map { "\($0.name ?? "") \($0.url.absoluteString)" })
                }
                v = try await backend.calendarMatch(local)
            }
            withAnimation(.spring(response: 0.4)) { events = v }
            syncedAt = Date()
            error = nil
            schedule()
        } catch { self.error = error.localizedDescription }
    }

    /// 只给对上候选人的、还没开始的面试排提醒；每次重排，提前分钟数改了也能生效
    private func schedule() {
        let c = UNUserNotificationCenter.current()
        c.removeAllPendingNotificationRequests()
        let lead = Double(store?.settings?.remindMinutes ?? 15) * 60
        for e in events {
            guard let start = e.startDate, let name = e.candidateName else { continue }
            let fire = start.addingTimeInterval(-lead)
            guard fire > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = String(format: L("%lld 分钟后面试：%@"), Int(lead / 60), name)
            content.body = e.title + L("。点这里打开准备材料")
            content.sound = .default
            content.userInfo = ["cid": e.candidateId ?? "", "pid": e.positionId ?? "", "url": e.meetingUrl]
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
            c.add(UNNotificationRequest(identifier: e.id, content: content,
                                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }

    func open(_ e: CalEvent) {
        guard let store, let pid = e.positionId, let cid = e.candidateId else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { store.openCandidate(pid, cid) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let cid = info["cid"] as? String, pid = info["pid"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let cid, let pid, let e = self.events.first(where: { $0.candidateId == cid }) ?? Optional(CalEvent(uid: "", title: "", start: "", end: "", meetingUrl: "", candidateId: cid, candidateName: nil, positionId: pid)) {
                self.open(e)
            }
        }
        done()
    }
}

/// 侧边栏「即将面试」
struct UpcomingInterviews: View {
    @ObservedObject var r: InterviewReminder
    var body: some View {
        let soon = r.events.filter { $0.candidateId != nil && ($0.startDate ?? .distantPast) > Date().addingTimeInterval(-3600) }.prefix(4)
        if !soon.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("即将面试").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10)
                ForEach(Array(soon)) { e in
                    Group {
                        HStack(spacing: 10) {
                            VStack(spacing: 0) {
                                Text(e.startDate.map { $0.formatted(.dateTime.month(.defaultDigits).day()) } ?? "").font(.system(size: 9)).foregroundStyle(.secondary)
                                Text(e.startDate.map { $0.formatted(.dateTime.hour().minute()) } ?? "").font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                            }
                            .frame(width: 44)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.candidateName ?? e.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Text(e.candidateName == nil ? L("未对上候选人") : e.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.0001)))
                    }
                    .eventPopover(e, r)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }
}
