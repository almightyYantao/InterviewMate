import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var store: Store
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar()
            Rectangle().fill(Color.black.opacity(0.06)).frame(width: 1)
            DetailRoot()
        }
        .overlay(alignment: .bottomTrailing) { ResumeInbox(w: store.watcher) }
        .coordinateSpace(name: "main")
        .ignoresSafeArea()
        .background(Color.white)
        .fileImporter(isPresented: $store.showImporter,
                      allowedContentTypes: [.pdf, UTType(filenameExtension: "docx") ?? .data, .plainText,
                                            UTType(filenameExtension: "md") ?? .plainText],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.upload(urls) }
        }
        .sheet(isPresented: $store.showNewPosition) { PositionEditor(position: nil) }
        .sheet(isPresented: $store.showSettings) { SettingsView() }
        .sheet(item: $store.editingPosition) { PositionEditor(position: $0) }
        .sheet(isPresented: $store.interviewing) {
            if let r = store.report { InterviewView(response: r) }
        }
        .alert("删除岗位「\(store.deletingPosition?.title ?? "")」？",
               isPresented: Binding(get: { store.deletingPosition != nil }, set: { if !$0 { store.deletingPosition = nil } }),
               presenting: store.deletingPosition) { p in
            Button("删除", role: .destructive) { store.deletePosition(p) }
            Button("取消", role: .cancel) {}
        } message: { _ in Text("这个岗位下的所有候选人、简历文件、报告和面试记录都会一起删除，无法恢复。") }
        .alert("删除候选人「\(store.deletingCandidate?.name ?? "")」？",
               isPresented: Binding(get: { store.deletingCandidate != nil }, set: { if !$0 { store.deletingCandidate = nil } }),
               presenting: store.deletingCandidate) { c in
            Button("删除", role: .destructive) { store.deleteCandidate(c.id) }
            Button("取消", role: .cancel) {}
        } message: { _ in Text("简历文件、报告、面试打分、逐字稿和评价都会一起删除，无法恢复。") }
        .alert("出错了", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") {}
        } message: { Text(store.errorMessage ?? "") }
    }
}

// MARK: - 岗位

struct PositionSidebar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        List(selection: $store.selectedPositionID) {
            Section("岗位") {
                ForEach(store.positions) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).lineLimit(1)
                        Text(subtitle(p)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(p.id)
                    .contextMenu {
                        Button("编辑岗位…") { store.editingPosition = p }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.positions.isEmpty {
                ContentUnavailableView {
                    Label("还没有岗位", systemImage: "briefcase")
                } actions: {
                    Button("新建岗位") { store.showNewPosition = true }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { store.showNewPosition = true } label: { Label("新建岗位", systemImage: "plus") }
                    .help("新建岗位")
            }
        }
        .onChange(of: store.selectedPositionID) {
            store.selectedCandidateID = nil
            store.report = nil
            store.candidates = []
        }
    }

    func subtitle(_ p: Position) -> String {
        guard let js = p.jdStruct else { return "JD 解析中…" }
        if js.error != nil { return "JD 解析失败" }
        return "\(js.requirements?.count ?? 0) 条要求 · \(p.interviewMinutes ?? 60) 分钟"
    }
}

// MARK: - 候选人

struct CandidateList: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if store.selectedPosition == nil {
                ContentUnavailableView("选择一个岗位", systemImage: "sidebar.left")
            } else {
                List(store.candidates.sorted { $0.scoreSort > $1.scoreSort }, selection: $store.selectedCandidateID) { c in
                    CandidateRow(c: c).tag(c.id)
                }
                .listStyle(.inset)
                .overlay {
                    if store.candidates.isEmpty {
                        ContentUnavailableView {
                            Label("还没有简历", systemImage: "doc.text")
                        } description: {
                            Text("支持 PDF、Word、Markdown，可一次选多份")
                        } actions: {
                            Button("上传简历…") { store.showImporter = true }
                        }
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in store.upload(urls); return true }
            }
        }
        .navigationTitle(store.selectedPosition?.title ?? "面搭子")
        .toolbar {
            ToolbarItemGroup {
                Button { store.showImporter = true } label: { Label("上传简历", systemImage: "square.and.arrow.down") }
                    .help("上传简历（也可以直接把文件拖进列表）")
                    .disabled(store.selectedPosition == nil)
                Button { store.editingPosition = store.selectedPosition } label: { Label("岗位设置", systemImage: "slider.horizontal.3") }
                    .help("岗位设置")
                    .disabled(store.selectedPosition == nil)
            }
        }
        .task(id: store.selectedPositionID) {
            while !Task.isCancelled {
                await store.loadCandidates()
                try? await Task.sleep(for: .seconds(store.candidates.contains { $0.status != "done" && $0.status != "failed" } ? 3 : 15))
            }
        }
        .onChange(of: store.selectedCandidateID) { Task { await store.loadReport() } }
    }
}

struct StatusText: View {
    let c: Candidate
    var body: some View {
        switch c.status {
        case "failed":
            Label("生成失败", systemImage: "exclamationmark.octagon.fill")
                .font(.caption).foregroundStyle(.red).help(c.error ?? "")
        default:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(c.progress ?? "排队中").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct DecisionBadge: View {
    let decision: String
    var color: Color { ["advance": .green, "conditional": .orange, "reject": .red][decision] ?? .gray }
    var body: some View {
        Text(L(Labels.decision[decision] ?? decision))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct CandidateRow: View {
    let c: Candidate
    var color: Color { ["advance": .green, "conditional": .orange, "reject": .red][c.decision ?? ""] ?? .gray }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name ?? "—").font(.body.weight(.medium))
                if c.status == "done", let d = c.decision {
                    HStack(spacing: 4) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(L(Labels.decision[d] ?? d))
                        if let h = c.high, h > 0 { Text("· \(h) 个高风险疑点") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } else { StatusText(c: c) }
            }
            Spacer()
            if let s = c.score {
                Text(String(format: "%.1f", s)).font(.title3.weight(.semibold)).monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}
