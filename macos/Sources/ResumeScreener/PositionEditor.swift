import SwiftUI


struct PositionEditor: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backend: Backend
    @Environment(\.dismiss) private var dismiss

    let position: Position?
    @State private var title = ""
    @State private var jd = ""
    @State private var ctx = ""
    @State private var confirmDelete = false
    @State private var minutes = 60
    @State private var reqs: [Requirement] = []
    @State private var tab = 0
    @State private var saving = false
    @Namespace private var tabNS

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "briefcase.fill").font(.title3).foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(Theme.brand.gradient, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 1) {
                    Text(position == nil ? "新建岗位" : "岗位设置").font(.title3.weight(.semibold))
                    Text(position == nil ? "粘贴 JD，系统会自动拆成可逐条匹配的要求" : title).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if position != nil {
                    HStack(spacing: 4) {
                        TabButton(title: "基本信息", symbol: "doc.text", selected: tab == 0, badge: nil, ns: tabNS) { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { tab = 0 } }
                        TabButton(title: "要求与权重", symbol: "slider.horizontal.3", selected: tab == 1, badge: reqs.isEmpty ? nil : "\(reqs.count)", ns: tabNS) { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { tab = 1 } }
                    }
                    .padding(3).background(Theme.page, in: Capsule())
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            .background(Color.white)
            Divider().opacity(0.5)
            ZStack {
                if tab == 0 {
                    basicForm.transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: -40)),
                                                     removal: .opacity.combined(with: .offset(x: -40))))
                } else {
                    weightTable.transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 40)),
                                                       removal: .opacity.combined(with: .offset(x: 40))))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            Divider().opacity(0.5)
            HStack {
                if position != nil {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("删除岗位", systemImage: "trash").foregroundStyle(.red)
                    }.buttonStyle(.plain).padding(.trailing, 12)
                }
                if tab == 0 {
                    Label("需要提高权重的条目用 **加粗** 标出", systemImage: "lightbulb").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button { save() } label: {
                    HStack(spacing: 6) {
                        if saving { ProgressView().controlSize(.small) }
                        Text(position == nil ? "创建岗位" : "保存").frame(minWidth: 64)
                    }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || jd.isEmpty || saving)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .background(Color.white)
        }
        .frame(width: 780, height: 700)
        .background(Theme.page)
        .tint(Theme.brand)
        .alert("删除岗位「\(title)」？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { delete() }
            Button("取消", role: .cancel) {}
        } message: { Text("这个岗位下的所有候选人、简历文件、报告和面试记录都会一起删除，无法恢复。") }
        .onAppear {
            ctx = store.settings?.companyCtx ?? ""
            minutes = store.settings?.interviewMinutes ?? 60
            if let p = position {
                title = p.title; jd = p.jdRaw; ctx = p.companyCtx ?? ctx
                minutes = p.interviewMinutes ?? minutes; reqs = p.jdStruct?.requirements ?? []
            }
        }
    }

    func field<C: View>(_ label: String, hint: String? = nil, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L(label)).font(.callout.weight(.semibold))
                Spacer()
                if let hint { Text(L(hint)).font(.caption).foregroundStyle(.tertiary) }
            }
            c()
        }
    }

    func box<C: View>(_ c: C) -> some View {
        c.padding(12)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.08)))
    }

    var basicForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    field("岗位名称") {
                        box(TextField("", text: $title, prompt: Text("例如：网络工程师（杭州）")).textFieldStyle(.plain).font(.body))
                    }
                    field("面试时长") {
                        HStack(spacing: 6) {
                            ForEach([30, 45, 60, 90], id: \.self) { m in
                                Button { withAnimation(.snappy) { minutes = m } } label: {
                                    Text("\(m) 分钟").font(.callout.weight(minutes == m ? .semibold : .regular))
                                        .foregroundStyle(minutes == m ? .white : .primary)
                                        .padding(.horizontal, 12).padding(.vertical, 9)
                                        .background(minutes == m ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.white), in: RoundedRectangle(cornerRadius: 9))
                                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.black.opacity(minutes == m ? 0 : 0.08)))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    .fixedSize()
                }
                field("JD 原文", hint: "\(jd.count) 字") {
                    box(TextEditor(text: $jd).font(.system(size: 13.5)).lineSpacing(4).scrollContentBackground(.hidden).frame(minHeight: 280))
                }
                field("公司环境描述", hint: "用于生成贴近实际工作的场景题") {
                    box(TextEditor(text: $ctx).font(.system(size: 13.5)).lineSpacing(3).scrollContentBackground(.hidden).frame(minHeight: 70))
                }
            }
            .padding(24)
        }
    }

    var weightTable: some View {
        Group {
            if reqs.isEmpty {
                ContentUnavailableView("JD 还在解析", systemImage: "hourglass")
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($reqs) { $r in
                            HStack(spacing: 12) {
                                Text(r.id).font(.caption.monospaced().weight(.semibold)).foregroundStyle(Theme.brand)
                                    .frame(width: 44, height: 24).background(Theme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                                Text(r.text).font(.callout.weight(r.emphasized ? .semibold : .regular)).lineLimit(2)
                                Spacer(minLength: 8)
                                HStack(spacing: 2) {
                                    ForEach([("must", "必须"), ("plus", "加分"), ("duty", "职责")], id: \.0) { k, t in
                                        Button { withAnimation(.snappy) { r.level = k } } label: {
                                            Text(L(t)).font(.caption.weight(r.level == k ? .semibold : .regular))
                                                .foregroundStyle(r.level == k ? .white : .secondary)
                                                .padding(.horizontal, 9).padding(.vertical, 4)
                                                .background(r.level == k ? Theme.brand : .clear, in: Capsule())
                                        }.buttonStyle(.plain)
                                    }
                                }
                                .padding(2).background(Theme.page, in: Capsule())
                                HStack(spacing: 0) {
                                    Button { if r.weight > 0 { r.weight -= 1 } } label: { Image(systemName: "minus").frame(width: 24, height: 24) }.buttonStyle(.plain)
                                    Text("\(r.weight)").font(.callout.weight(.semibold)).monospacedDigit().frame(width: 22)
                                        .contentTransition(.numericText(value: Double(r.weight)))
                                    Button { if r.weight < 10 { r.weight += 1 } } label: { Image(systemName: "plus").frame(width: 24, height: 24) }.buttonStyle(.plain)
                                }
                                .foregroundStyle(.secondary)
                                .background(Theme.page, in: Capsule())
                                .animation(.snappy, value: r.weight)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.06)))
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    func delete() {
        guard let p = position else { return }
        Task {
            do {
                try await backend.deletePosition(p.id)
                if store.selectedPositionID == p.id { store.selectedPositionID = nil }
                await store.loadPositions()
                dismiss()
            } catch { store.errorMessage = error.localizedDescription }
        }
    }

    func save() {
        saving = true
        Task {
            do {
                if let p = position {
                    let jdChanged = jd != p.jdRaw
                    var js = p.jdStruct
                    js?.requirements = reqs
                    try await backend.updatePosition(p.id, .init(title: title, jdRaw: jdChanged ? jd : nil,
                                                                 jdStruct: jdChanged ? nil : js,
                                                                 companyCtx: ctx, interviewMinutes: minutes))
                } else {
                    let id = try await backend.createPosition(.init(title: title, jdRaw: jd, companyCtx: ctx, interviewMinutes: minutes))
                    store.selectedPositionID = id
                }
                await store.loadPositions()
                dismiss()
            } catch {
                store.errorMessage = error.localizedDescription
            }
            saving = false
        }
    }
}
