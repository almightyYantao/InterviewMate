import AppKit
import SwiftUI

/// 界面语言：写进 AppleLanguages，重启 App 后生效
enum UILanguage {
    static var current: String {
        (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first.map { $0.hasPrefix("en") ? "en" : "zh" }
            ?? (Locale.preferredLanguages.first?.hasPrefix("en") == true ? "en" : "zh")
    }
    static func set(_ code: String) {
        UserDefaults.standard.set([code == "en" ? "en" : "zh-Hans"], forKey: "AppleLanguages")
    }
    /// 等当前进程退出后再打开 App；直接 terminate 在有弹窗时可能不退出
    @MainActor static func relaunch(_ backend: Backend) {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"\(path)\""]
        try? p.run()
        backend.stop()
        exit(0)
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backend: Backend
    @Environment(\.dismiss) private var dismiss

    @State private var s = AppSettings()
    @State private var loaded: AppSettings?
    @State private var section = 0
    @State private var forward = true
    @State private var apiKey = ""
    @State private var clearKey = false
    @State private var uiLang = UILanguage.current
    @State private var saving = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var askRelaunch = false
    @State private var hibobToken = ""
    @State private var calendarURL = ""
    @State private var larkHook = ""
    @State private var larkSecret = ""
    @AppStorage("watchDownloads") private var watchDownloads = true
    @State private var bob: Backend.MCPStatus?
    @State private var bobBusy = false
    @State private var hibobTesting = false
    @State private var hibobResult: (ok: Bool, text: String)?
    @Namespace private var navNS

    let sections = [("通用", "globe"), ("AI 接口", "sparkles"), ("岗位默认", "briefcase"), ("打分规则", "gauge.with.dots.needle.67percent"), ("HiBob", "person.badge.key"), ("数据", "externaldrive")]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                nav
                Rectangle().fill(Color.black.opacity(0.06)).frame(width: 1)
                ZStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) { page }
                            .padding(28).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(section)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: forward ? 24 : -24)),
                                            removal: .opacity.combined(with: .offset(y: forward ? -24 : 24))))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .background(Theme.page)
            }
            Divider().opacity(0.5)
            HStack {
                if s != loaded && loaded != nil || !apiKey.isEmpty || clearKey || !hibobToken.isEmpty || !calendarURL.isEmpty || !larkHook.isEmpty || !larkSecret.isEmpty {
                    Label("有未保存的修改", systemImage: "circle.fill").font(.callout).foregroundStyle(.orange)
                        .labelStyle(DotLabel()).transition(.opacity)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button { Task { if await save() { finish() } } } label: {
                    HStack(spacing: 6) {
                        if saving { ProgressView().controlSize(.small) }
                        Text("保存").frame(minWidth: 64)
                    }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large).disabled(saving)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(Color.white)
            .animation(.easeOut(duration: 0.2), value: s)
        }
        .frame(width: 820, height: 600)
        .tint(Theme.brand)
        .task {
            guard let v = try? await backend.settings() else { return }
            s = v; loaded = v
        }
        .alert("重启后切换界面语言", isPresented: $askRelaunch) {
            Button("立即重启") { UILanguage.relaunch(backend) }
            Button("稍后", role: .cancel) { dismiss() }
        } message: { Text("设置已保存。界面语言需要重新打开 App 才会生效。") }
    }

    // MARK: 左侧栏目

    var nav: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("设置").font(.title2.weight(.bold)).padding(.horizontal, 12).padding(.top, 22).padding(.bottom, 14)
            ForEach(Array(sections.enumerated()), id: \.offset) { i, t in
                Button {
                    forward = i > section
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { section = i }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.1).frame(width: 18)
                        Text(LocalizedStringKey(t.0))
                        Spacer()
                    }
                    .font(.system(size: 13.5, weight: section == i ? .semibold : .regular))
                    .foregroundStyle(section == i ? Theme.brand : .primary)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background {
                        if section == i {
                            RoundedRectangle(cornerRadius: 9).fill(Color.white).shadow(color: .black.opacity(0.06), radius: 5, y: 2)
                                .matchedGeometryEffect(id: "nav", in: navNS)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(width: 200)
        .background(Theme.page.opacity(0.6))
    }

    @ViewBuilder var page: some View {
        switch section {
        case 0: general
        case 1: ai
        case 2: positionDefaults
        case 3: scoring
        case 4: hibobPage
        default: data
        }
    }

    // MARK: 通用

    @ViewBuilder var general: some View {
        header("通用", "界面、AI 输出和语音转写使用的语言")
        group {
            row("界面语言", hint: "切换后需要重新打开 App") {
                Segmented(value: $uiLang, options: [("zh", "中文"), ("en", "English")])
            }
            Divider()
            row("AI 输出语言", hint: "结论、疑点、面试题、评价用哪种语言生成；之后新生成的内容生效") {
                Segmented(value: $s.aiLanguage, options: [("zh", "中文"), ("en", "English")])
            }
        }
        group {
            row("语音转写语言", hint: "需要在系统「键盘 › 听写」里下载对应语言的离线模型") {
                Picker("", selection: $s.speechLocale) {
                    Text("普通话").tag("zh-CN")
                    Text("粤语").tag("zh-HK")
                    Text("English").tag("en-US")
                    Text("日本語").tag("ja-JP")
                }
                .labelsHidden().frame(width: 140)
            }
            Divider()
            row("候选人声音来源", hint: "只监听这个 App 发出的声音，其他提示音不会混进来") {
                Picker("", selection: $s.captureApp) {
                    Text("自动（会议软件）").tag("")
                    ForEach(captureCandidates, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(width: 180)
            }
            Divider()
            row("停顿多久算一句", hint: "说话停顿超过这个时间就切成一句话") {
                HStack(spacing: 10) {
                    Slider(value: $s.silenceSeconds, in: 0.8...3, step: 0.1).frame(width: 160)
                    Text(String(format: "%.1f s", s.silenceSeconds)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
        }
            calendarGroup
        larkGroup
    }

    @ViewBuilder var larkGroup: some View {
        group {
            row("自动发现下载的简历", hint: "「下载」文件夹里出现文件名像简历的 PDF / Word（含「简历」「resume」「【」等），右下角提示导入到哪个岗位") {
                Toggle("", isOn: $watchDownloads).labelsHidden().toggleStyle(.switch)
            }
        }
        group {
            field("Lark 群机器人 Webhook", hint: s.larkWebhookHint.isEmpty ? L("未设置") : s.larkWebhookHint) {
                box(SecureField("", text: $larkHook, prompt: Text(s.larkWebhookHint.isEmpty ? "https://open.larksuite.com/open-apis/bot/v2/hook/…" : L("已保存，留空不修改"))).textFieldStyle(.plain))
            }
            field("签名密钥", hint: "机器人开了「签名校验」才需要填") {
                box(SecureField("", text: $larkSecret, prompt: Text(L("可选，留空不修改"))).textFieldStyle(.plain))
            }
            Text("在要接收面试评价的 Lark 群里：设置 › 群机器人 › 添加机器人 › 自定义机器人，复制 Webhook 地址。之后「面试反馈」页可以一键把评价发到这个群。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder var calendarGroup: some View {
        group {
            field("Google 日历私密地址", hint: s.calendarUrlHint.isEmpty ? L("未设置") : s.calendarUrlHint) {
                box(SecureField("", text: $calendarURL, prompt: Text(s.calendarUrlHint.isEmpty ? "https://calendar.google.com/calendar/ical/…/basic.ics" : L("已保存，留空不修改"))).textFieldStyle(.plain))
            }
            Text("Google 日历网页 › 设置 › 左侧选你的日历 › 集成日历 › 「iCal 格式的私密地址」。只读取日程，不会修改。标题、说明或参会人里有候选人姓名的日程会自动对上。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            row("面试前提醒", hint: "开始前多少分钟发系统通知，点通知直接打开准备材料") {
                Stepper(value: $s.remindMinutes, in: 1...120, step: 5) { Text(String(format: L("提前 %lld 分钟"), s.remindMinutes)).monospacedDigit() }
            }
        }
    }

    // MARK: AI 接口

    @ViewBuilder var ai: some View {
        header("AI 接口", "用于解析 JD、简历、出题和面试总结")
        group {
            field("Anthropic API Key", hint: keyHint) {
                HStack(spacing: 8) {
                    box(SecureField("", text: $apiKey, prompt: Text(s.apiKeyHint.isEmpty ? "sk-ant-…" : "已保存，留空不修改")).textFieldStyle(.plain))
                    if !s.apiKeyHint.isEmpty {
                        Button(clearKey ? "撤销清除" : "清除") { withAnimation(.snappy) { clearKey.toggle(); apiKey = "" } }
                            .buttonStyle(.plain).foregroundStyle(clearKey ? Theme.brand : .red).font(.callout)
                    }
                }
            }
            field("接口地址", hint: "可选，用代理或网关时填写") {
                box(TextField("", text: $s.baseUrl, prompt: Text("https://api.anthropic.com")).textFieldStyle(.plain))
            }
            HStack(alignment: .top, spacing: 14) {
                field("快速模型", hint: "JD、简历、匹配、评价") {
                    box(TextField("", text: $s.modelFast, prompt: Text(s.defaultFast)).textFieldStyle(.plain))
                }
                field("强模型", hint: "疑点、出题、面试总结") {
                    box(TextField("", text: $s.modelStrong, prompt: Text(s.defaultStrong)).textFieldStyle(.plain))
                }
            }
        }
        HStack {
            Button { test() } label: {
                HStack(spacing: 6) {
                    if testing { ProgressView().controlSize(.small) }
                    Text("保存并测试连接")
                }
            }
            .disabled(testing || saving)
            Spacer()
        }
        if let t = testResult {
            Label(t.text, systemImage: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.callout).foregroundStyle(t.ok ? .green : .red)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background((t.ok ? Color.green : Color.red).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
        Label("API Key 只保存在本机项目的 data/settings.json（仅自己可读）。不填时沿用环境变量或 ant 命令行的默认配置。",
              systemImage: "lock.fill")
            .font(.callout).foregroundStyle(.secondary)
    }

    // MARK: 岗位默认

    @ViewBuilder var positionDefaults: some View {
        header("岗位默认", "新建岗位时自动带入，之后可在每个岗位里单独修改")
        group {
            field("公司环境描述", hint: "用于生成贴近实际工作的场景题") {
                box(TextEditor(text: $s.companyCtx).font(.system(size: 13.5)).lineSpacing(3)
                    .scrollContentBackground(.hidden).frame(minHeight: 90))
            }
            Divider()
            row("默认面试时长", hint: nil) {
                Stepper(value: $s.interviewMinutes, in: 15...180, step: 15) {
                    Text("\(s.interviewMinutes) 分钟").monospacedDigit()
                }
            }
        }
        group {
            Text("JD 要求的默认权重").font(.callout.weight(.semibold))
            Text("解析 JD 时按要求类型给权重，原文加粗的条目再加上「加粗加成」").font(.caption).foregroundStyle(.secondary)
            intRow("必须", $s.weights.must)
            intRow("加分", $s.weights.plus)
            intRow("职责", $s.weights.duty)
            intRow("加粗加成", $s.weights.emphasis)
        }
    }

    // MARK: 打分规则

    @ViewBuilder var scoring: some View {
        header("打分规则", "匹配分 = Σ(权重 × 系数) ÷ Σ权重 × 10，结论由下面的分数线决定")
        group {
            Text("各匹配结果的系数").font(.callout.weight(.semibold))
            ratioRow("具备", $s.scoring.match, .green)
            ratioRow("部分", $s.scoring.partial, .orange)
            ratioRow("缺失", $s.scoring.missing, .red)
            ratioRow("无法判断", $s.scoring.unknown, .gray)
        }
        group {
            Text("结论").font(.callout.weight(.semibold))
            row("推进", hint: "匹配分不低于这个值，且没有一票否决") {
                Stepper(value: $s.scoring.advance, in: 0...10, step: 0.5) { Text(String(format: "≥ %.1f", s.scoring.advance)).monospacedDigit() }
            }
            row("不推荐", hint: "匹配分低于这个值") {
                Stepper(value: $s.scoring.reject, in: 0...10, step: 0.5) { Text(String(format: "< %.1f", s.scoring.reject)).monospacedDigit() }
            }
            row("推进时最多允许的高风险疑点", hint: nil) {
                Stepper(value: $s.scoring.maxHighDoubts, in: 0...10) { Text("\(s.scoring.maxHighDoubts)").monospacedDigit() }
            }
            row("一票否决", hint: "「必须」类要求权重达到这个值且缺失时，结论最高为有条件推进") {
                Stepper(value: $s.scoring.vetoWeight, in: 1...20) { Text("权重 ≥ \(s.scoring.vetoWeight)").monospacedDigit() }
            }
        }
        if s.scoring.reject > s.scoring.advance {
            Label("「不推荐」分数线高于「推进」，请检查", systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
        }
        Text("修改后对之后新生成的报告生效。").font(.caption).foregroundStyle(.secondary)
    }

    // MARK: HiBob

    @ViewBuilder var hibobPage: some View {
        header("HiBob", "用你自己的 Bob 账号登录，拉取你参与的面试")
        group {
            HStack(spacing: 12) {
                Image(systemName: bob?.connected == true ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                    .font(.title2).foregroundStyle(bob?.connected == true ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bob?.connected == true ? "已用 Bob 账号登录" : "未登录").font(.callout.weight(.semibold))
                    Text(bob?.connected == true ? "只能看到你本人在 Bob 里有权限看的内容；30 天后需要重新登录"
                                                : "点右边按钮，在浏览器里用 Bob 账号登录授权").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if bobBusy { ProgressView().controlSize(.small) }
                if bob?.connected == true {
                    Button("退出登录") { Task { try? await backend.hibobLogout(); await refreshBob() } }
                } else {
                    Button("用 Bob 账号登录") { loginBob() }.buttonStyle(.borderedProminent).disabled(bobBusy)
                }
            }
        }
        .task { await refreshBob() }
        DisclosureGroup("高级：Service User 方式（需要 Bob 管理员）") { VStack(alignment: .leading, spacing: 14) {
        group {
            field("Service User ID", hint: "HiBob 后台 › 设置 › 集成 › Service Users") {
                box(TextField("", text: $s.hibobUserId, prompt: Text("SERVICE-xxxx")).textFieldStyle(.plain))
            }
            field("Token", hint: s.hibobTokenHint.isEmpty ? L("未设置") : L("当前：") + s.hibobTokenHint) {
                box(SecureField("", text: $hibobToken, prompt: Text(s.hibobTokenHint.isEmpty ? "" : L("已保存，留空不修改"))).textFieldStyle(.plain))
            }
            HStack(alignment: .top, spacing: 14) {
                field("我的 HiBob 邮箱", hint: "只显示你是面试官的面试") {
                    box(TextField("", text: $s.hibobEmail, prompt: Text("name@company.com")).textFieldStyle(.plain))
                }
                field("员工 ID", hint: "按邮箱自动查，查不到可手填") {
                    box(TextField("", text: $s.hibobEmployeeId, prompt: Text("自动")).textFieldStyle(.plain))
                }
            }
            row("使用沙箱环境", hint: "测试用，正式使用请关闭") { Toggle("", isOn: $s.hibobSandbox).labelsHidden().toggleStyle(.switch) }
        }
        HStack {
            Button { testHiBob() } label: {
                HStack(spacing: 6) {
                    if hibobTesting { ProgressView().controlSize(.small) }
                    Text("保存并测试连接")
                }
            }
            .disabled(hibobTesting || saving)
            Spacer()
        }
        if let t = hibobResult {
            Label(t.text, systemImage: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.callout).foregroundStyle(t.ok ? .green : .red)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background((t.ok ? Color.green : Color.red).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
        Label("HiBob 的招聘接口只能读取，面试反馈没法自动写回。面试反馈页提供「复制到 HiBob」，按格式复制后粘贴即可。Service User 需要「Manage all job openings」权限；用邮箱查员工 ID 还需要能查看员工基本信息。",
              systemImage: "info.circle")
            .font(.callout).foregroundStyle(.secondary)
        }.padding(.top, 8) }
        .font(.callout)
    }

    func refreshBob() async {
        bob = try? await backend.hibobStatus()
        store.hibobConnected = bob?.connected ?? false
    }

    /// 打开浏览器登录，等回调写入令牌（最多 3 分钟）
    func loginBob() {
        bobBusy = true
        Task {
            defer { bobBusy = false }
            do {
                NSWorkspace.shared.open(try await backend.hibobLoginURL())
                for _ in 0..<90 {
                    try? await Task.sleep(for: .seconds(2))
                    await refreshBob()
                    if bob?.connected == true { return }
                }
            } catch { withAnimation { hibobResult = (false, error.localizedDescription) } }
        }
    }

    func testHiBob() {
        hibobTesting = true
        Task {
            if await save() {
                do {
                    let r = try await backend.hibobTest()
                    withAnimation { hibobResult = (true, String(format: L("连接正常：员工 ID %@，你参与的面试 %lld 场"), r.employeeId, r.interviews)) }
                    s.hibobEmployeeId = r.employeeId
                } catch {
                    withAnimation { hibobResult = (false, error.localizedDescription) }
                }
            }
            hibobTesting = false
        }
    }

    // MARK: 数据

    @ViewBuilder var data: some View {
        header("数据", "简历文件、报告、打分、逐字稿都只存在本机")
        group {
            row("保留天数", hint: "超过后自动删除简历和全部面试记录；对之后上传的简历生效") {
                HStack(spacing: 6) {
                    ForEach([30, 90, 180, 365], id: \.self) { d in
                        Button { withAnimation(.snappy) { s.retentionDays = d } } label: {
                            Text("\(d) 天").font(.callout.weight(s.retentionDays == d ? .semibold : .regular))
                                .foregroundStyle(s.retentionDays == d ? .white : .primary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(s.retentionDays == d ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.page), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Divider()
            row("数据目录", hint: Backend.projectDir.appending(path: "data").path) {
                Button("在访达中显示") { NSWorkspace.shared.open(Backend.projectDir.appending(path: "data")) }
            }
        }
    }

    // MARK: 组件

    func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title)).font(.title3.weight(.semibold))
            Text(LocalizedStringKey(sub)).font(.callout).foregroundStyle(.secondary)
        }
    }

    func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) { c() }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
    }

    func row<C: View>(_ label: String, hint: String?, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(label)).font(.callout.weight(.medium))
                if let hint { Text(LocalizedStringKey(hint)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            c()
        }
    }

    func intRow(_ label: String, _ v: Binding<Int>) -> some View {
        row(label, hint: nil) {
            Stepper(value: v, in: 0...10) { Text("\(v.wrappedValue)").monospacedDigit().frame(width: 24) }
        }
    }

    func ratioRow(_ label: String, _ v: Binding<Double>, _ color: Color) -> some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(LocalizedStringKey(label)).font(.callout).frame(width: 80, alignment: .leading)
            Slider(value: v, in: 0...1, step: 0.05)
            Text(String(format: "%.2f", v.wrappedValue)).monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }

    func field<C: View>(_ label: String, hint: String? = nil, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(LocalizedStringKey(label)).font(.callout.weight(.semibold))
                Spacer()
                if let hint { Text(LocalizedStringKey(hint)).font(.caption).foregroundStyle(.tertiary) }
            }
            c()
        }
    }

    func box<C: View>(_ c: C) -> some View {
        c.font(.body).padding(11)
            .background(Theme.page, in: RoundedRectangle(cornerRadius: 10))
    }

    /// 可选的声音来源：现在有音频的进程归到它所属的前台 App（子进程、输入法、系统服务都去掉），按 App 去重
    var captureCandidates: [(String, String)] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a in a.bundleIdentifier.map { ($0, a.localizedName ?? $0) } }
        var seen = Set<String>(), out: [(String, String)] = []
        for p in ProcessTap.audioProcesses() {
            // 子进程（如 com.tencent.xinWeChat.WeChatAppEx）归到 Bundle ID 是它前缀的那个 App
            guard let app = apps.filter({ p.bundleID == $0.0 || p.bundleID.hasPrefix($0.0 + ".") })
                .max(by: { $0.0.count < $1.0.count }) else { continue }
            if seen.insert(app.0).inserted { out.append(app) }
        }
        if !s.captureApp.isEmpty, !seen.contains(s.captureApp) { out.append((s.captureApp, ProcessTap.appName(s.captureApp))) }
        return out.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    var keyHint: String {
        if clearKey { return L("保存后清除，改用默认配置") }
        if !s.apiKeyHint.isEmpty { return L("当前：") + s.apiKeyHint }
        return L("未设置，使用默认配置")
    }

    // MARK: 保存

    func save() async -> Bool {
        saving = true
        defer { saving = false }
        let key: String? = clearKey ? "" : (apiKey.trimmingCharacters(in: .whitespaces).isEmpty ? nil : apiKey)
        do {
            let v = try await backend.saveSettings({ var b = AppSettingsIn(s, apiKey: key, hibobToken: hibobToken.isEmpty ? nil : hibobToken)
                b.calendarIcsUrl = calendarURL.isEmpty ? nil : calendarURL.trimmingCharacters(in: .whitespacesAndNewlines)
                b.larkWebhook = larkHook.isEmpty ? nil : larkHook.trimmingCharacters(in: .whitespacesAndNewlines)
                b.larkSecret = larkSecret.isEmpty ? nil : larkSecret.trimmingCharacters(in: .whitespacesAndNewlines); return b }())
            s = v; loaded = v
            apiKey = ""; clearKey = false; hibobToken = ""; calendarURL = ""; larkHook = ""; larkSecret = ""
            Task { await store.reminder.refresh() }
            store.settings = v
            return true
        } catch {
            withAnimation { testResult = (false, error.localizedDescription) }
            return false
        }
    }

    func finish() {
        if uiLang != UILanguage.current { UILanguage.set(uiLang); askRelaunch = true } else { dismiss() }
    }

    func test() {
        testing = true
        Task {
            if await save() {
                do {
                    let m = try await backend.testSettings()
                    withAnimation { testResult = (true, L("连接正常，使用模型 ") + m) }
                } catch {
                    withAnimation { testResult = (false, error.localizedDescription) }
                }
            }
            testing = false
        }
    }
}

struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon.font(.system(size: 6)); configuration.title }
    }
}

struct Segmented: View {
    @Binding var value: String
    let options: [(String, String)]
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { k, t in
                Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { value = k } } label: {
                    Text(t).font(.callout.weight(value == k ? .semibold : .regular))
                        .foregroundStyle(value == k ? .white : .primary)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background { if value == k { Capsule().fill(Theme.brand).matchedGeometryEffect(id: "seg", in: ns) } }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(3).background(Theme.page, in: Capsule())
    }
}

/// 代码里的字符串（不是直接写在 Text 里的）走这个函数翻译。
/// 查不到原文时，再按带 %@ 的条目做模式匹配，例如「3 分钟」匹配「%@ 分钟」。
func L(_ s: String) -> String {
    let v = Bundle.main.localizedString(forKey: s, value: s, table: nil)
    guard v == s, isEnglishUI, s.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return v }
    let ns = s as NSString
    for (re, tpl) in localizedPatterns {
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
        let args: [CVarArg] = (1..<m.numberOfRanges).map { L(ns.substring(with: m.range(at: $0))) as NSString }
        return String(format: tpl, arguments: args)
    }
    return s
}

private let isEnglishUI = Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true

private let localizedPatterns: [(NSRegularExpression, String)] = {
    guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings"),
          let dict = NSDictionary(contentsOf: url) as? [String: String] else { return [] }
    return dict.filter { $0.key.contains("%@") && !$0.key.contains("%lld") }
        .sorted { $0.key.count > $1.key.count }
        .compactMap { k, v in
            let pattern = "^" + NSRegularExpression.escapedPattern(for: k).replacingOccurrences(of: "%@", with: "(.+?)") + "$"
            return (try? NSRegularExpression(pattern: pattern)).map { ($0, v) }
        }
}()
