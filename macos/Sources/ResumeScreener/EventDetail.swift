import AppKit
import SwiftUI

/// 点日程弹出的详情：时间、会议、对上的候选人；由你决定打开候选人还是直接开始面试
struct EventDetail: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backend: Backend
    let e: CalEvent
    @ObservedObject var r: InterviewReminder
    var close: () -> Void = {}
    @State private var cand: Candidate?
    @State private var copied = false

    var allMeetings: [Meeting] {
        e.meetings ?? ((e.meetingApp ?? "").isEmpty ? [] : [Meeting(app: e.meetingApp!, url: e.meetingUrl, code: e.meetingCode ?? "")])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题和时间
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    Text(e.startDate.map { $0.formatted(.dateTime.month(.abbreviated)) } ?? "").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 2).background(Theme.brand)
                    Text(e.startDate.map { "\(Calendar.current.component(.day, from: $0))" } ?? "").font(.system(size: 20, weight: .bold)).monospacedDigit()
                        .frame(maxHeight: .infinity)
                }
                .frame(width: 46, height: 50)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.08)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(e.title.isEmpty ? L("（无标题）") : e.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(timeText).font(.callout).foregroundStyle(.secondary)
                    if let c = countdown {
                        Text(c).font(.caption.weight(.semibold)).foregroundStyle(Theme.brand)
                            .padding(.horizontal, 8).padding(.vertical, 2).background(Theme.brand.opacity(0.1), in: Capsule())
                    }
                }
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 26, height: 26).background(Theme.page, in: Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).help(L("关闭"))
            }

            // 会议：说明里的会议都列出来
            section(L("会议"), "video.fill") {
                if allMeetings.isEmpty {
                    Text("日程里没有会议链接").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(allMeetings, id: \.self) { m in MeetingLine(m: m) }
            }

            // 候选人
            section(L("候选人"), "person.fill") {
                if e.candidateId != nil {
                    HStack(spacing: 12) {
                        Text(String((e.candidateName ?? "?").prefix(1))).font(.headline).foregroundStyle(.white)
                            .frame(width: 38, height: 38).background(decisionColor(cand?.decision).gradient, in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.candidateName ?? "").font(.callout.weight(.semibold))
                            HStack(spacing: 6) {
                                if let d = cand?.decision { Chip(text: Labels.decision[d] ?? d, color: decisionColor(d)) }
                                if let d = cand?.interviewDecision {
                                    Chip(text: String(format: L("面试：%@"), L(d)), color: d == "通过" ? .green : d == "不通过" ? .red : .orange)
                                }
                            }
                        }
                        Spacer()
                        if let s = cand?.score {
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(String(format: "%.1f", s)).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(decisionColor(cand?.decision))
                                Text("匹配分").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("这个日程没对上 App 里的候选人。标题、说明或参会人里写上候选人姓名就能自动对上。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if e.candidateId != nil {
                HStack(spacing: 10) {
                    PillButton(title: "打开候选人信息", symbol: "person.text.rectangle") { go(interview: false) }
                        .frame(maxWidth: .infinity)
                    PrimaryButton(title: "开始面试", symbol: "play.fill") { go(interview: true) }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Color.white)
        .task {
            guard let pid = e.positionId, let cid = e.candidateId else { return }
            cand = try? await backend.candidates(pid).first { $0.id == cid }
        }
    }

    func section<C: View>(_ title: String, _ symbol: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            c()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.page, in: RoundedRectangle(cornerRadius: 12))
    }

    var timeText: String {
        guard let s = e.startDate else { return "" }
        let end = e.endDate.map { " – " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return s.formatted(.dateTime.month().day().weekday(.wide).hour().minute()) + end
    }

    var countdown: String? {
        guard let s = e.startDate else { return nil }
        let m = Int(s.timeIntervalSinceNow / 60)
        if m > 0 && m < 24 * 60 { return m >= 60 ? String(format: L("%lld 小时 %lld 分钟后开始"), m / 60, m % 60) : String(format: L("%lld 分钟后开始"), m) }
        if m <= 0, (e.endDate ?? s) > Date() { return L("正在进行") }
        return nil
    }

    func go(interview: Bool) {
        close()
        guard let pid = e.positionId, let cid = e.candidateId else { return }
        // 等这个弹窗收起再跳转，避免紧接着弹出面试窗口时两个弹窗冲突
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { open(pid, cid, interview) }
    }

    func open(_ pid: String, _ cid: String, _ interview: Bool) {
        store.pendingInterview = interview
        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { store.openCandidate(pid, cid) }
        // 已经是当前候选人、报告已在：直接开始
        if interview, store.report?.report.candidate != nil, store.selectedCandidateID == cid, store.pendingCandidateID == nil {
            store.pendingInterview = false; store.interviewing = true
        }
    }
}

/// 给任何日程视图加「点一下弹出详情」
/// 自绘气泡：贴着被点的日程弹出，带白色小箭头；点外面、Esc、× 都关闭
struct EventDetailOverlay: View {
    @EnvironmentObject var store: Store
    let w: CGFloat = 440, gap: CGFloat = 12
    @State private var h: CGFloat = 400          // 卡片实际高度，量出来再定位
    @State private var openedAt = Date.distantPast

    var body: some View {
        // GeometryReader 常驻：第一次弹出时就有正确的窗口尺寸
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                if let e = store.detailEvent {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        // 打开的那一下点击不能马上被这层当成「点外面」把卡片关掉（之前要点两次的原因）
                        .onTapGesture { if Date().timeIntervalSince(openedAt) > 0.35 { dismiss() } }
                    let l = layout(g.size)
                    EventDetail(e: e, r: store.reminder) { dismiss() }
                        .id(e.id)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.black.opacity(0.08)))
                        .overlay(alignment: .topLeading) {
                            ArrowTip().fill(Color.white)
                                .overlay(ArrowTip(open: true).stroke(Color.black.opacity(0.08), lineWidth: 1))
                                .frame(width: 11, height: 22)
                                .rotationEffect(.degrees(l.side == .below ? 90 : l.side == .above ? -90 : l.side == .right ? 0 : 180))
                                .position(l.arrow)
                        }
                        .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h = $0 }
                        .offset(x: l.origin.x, y: l.origin.y)
                        .transition(.opacity.combined(with: .offset(y: -8)))   // 从上往下轻轻滑入、淡入
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(store.detailEvent != nil)
        .onChange(of: store.detailEvent?.id) { openedAt = Date() }
    }

    enum Side { case below, above, right, left }
    struct L { var side: Side; var origin: CGPoint; var arrow: CGPoint; var unit: UnitPoint }

    /// 宽的列表行：弹在点击位置下方；窄的（侧边栏、日历格子）：右边放得下放右边，否则左边
    func layout(_ size: CGSize) -> L {
        let a = store.detailAnchor, tap = store.detailTap
        let side: Side = a.width > 360 || (a.maxX + gap + w > size.width - 12 && a.minX - gap - w < 12) ? .below
            : a.maxX + gap + w <= size.width - 12 ? .right : .left
        switch side {
        case .below:
            let x = min(max(12, tap.x - w / 2), size.width - w - 12)
            let ax = min(max(tap.x - x, 28), w - 28)
            if a.maxY + gap + h <= size.height - 12 {
                return L(side: .below, origin: CGPoint(x: x, y: a.maxY + gap), arrow: CGPoint(x: ax, y: -5), unit: UnitPoint(x: ax / w, y: 0))
            }
            // 下方放不下：贴在这一行上方，箭头朝下指着它
            let y = max(12, a.minY - gap - h)
            return L(side: .above, origin: CGPoint(x: x, y: y), arrow: CGPoint(x: ax, y: h + 5), unit: UnitPoint(x: ax / w, y: 1))
        case .above:
            return L(side: .above, origin: .zero, arrow: .zero, unit: .center)
        case .right, .left:
            let x = side == .right ? a.maxX + gap : a.minX - gap - w
            let y = min(max(12, a.midY - 40), max(12, size.height - h - 12))
            let ay = min(max(a.midY - y, 24), h - 40)
            return L(side: side, origin: CGPoint(x: x, y: y), arrow: CGPoint(x: side == .right ? -5 : w + 5, y: ay),
                     unit: UnitPoint(x: side == .right ? 0 : 1, y: ay / h))
        }
    }

    func dismiss() { withAnimation(.easeIn(duration: 0.15)) { store.detailEvent = nil } }
}

struct EventPopover: ViewModifier {
    let e: CalEvent
    @ObservedObject var r: InterviewReminder
    var edge: Edge = .trailing
    @EnvironmentObject var store: Store
    @State private var frame: CGRect = .zero
    @State private var pointer: CGPoint?
    func body(content: Content) -> some View {
        // 用按钮响应点击（手势会和外层列表 / 月视图的双击抢事件，第一下容易被吞）
        Button {
            store.detailAnchor = frame
            let p = pointer ?? CGPoint(x: frame.width / 2, y: frame.height / 2)
            store.detailTap = CGPoint(x: frame.minX + p.x, y: frame.minY + p.y)
            withAnimation(.easeOut(duration: 0.2)) { store.detailEvent = e }
        } label: {
            content.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("main")) } action: { frame = $0 }
        .onContinuousHover { phase in
            if case .active(let p) = phase { pointer = p }
        }
    }
}

extension View {
    func eventPopover(_ e: CalEvent, _ r: InterviewReminder, edge: Edge = .trailing) -> some View {
        modifier(EventPopover(e: e, r: r, edge: edge))
    }
}

/// 一个会议：名称 + 会议号，右侧进入 / 复制
struct MeetingLine: View {
    let m: Meeting
    @State private var copied = false
    var joinURL: URL? {
        if !m.url.isEmpty { return URL(string: m.url) }
        if m.app == "腾讯会议", !m.code.isEmpty { return URL(string: "wemeet://page/inmeeting?meeting_code=\(m.code)") }
        return nil
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: m.app == "Google Meet" ? "video.circle.fill" : "video.fill")
                .foregroundStyle(m.app == "腾讯会议" ? Color.blue : m.app == "Google Meet" ? Color.green : Theme.brand)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(L(m.app)).font(.callout.weight(.medium))
                if !m.code.isEmpty { Text(m.code).font(.caption.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer()
            if !m.code.isEmpty {
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(m.code, forType: .string)
                    withAnimation { copied = true }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption).frame(width: 26, height: 26)
                        .background(Color.white, in: Circle())
                }.buttonStyle(.plain).help(L("复制会议号"))
            }
            if let u = joinURL { PrimaryButton(title: "进入", symbol: "arrow.up.right") { NSWorkspace.shared.open(u) } }
        }
    }
}

/// 弹出卡片的小箭头，尖朝左；open 时只画两条斜边（贴卡片那一侧不画线）
struct ArrowTip: Shape {
    var open = false
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX + 1, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX + 1, y: r.maxY))
        if !open { p.closeSubpath() }
        return p
    }
}
