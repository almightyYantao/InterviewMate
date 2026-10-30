import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) { onTerminate?() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ResumeScreenerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var backend = Backend()
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup("面搭子") {
            RootView()
                .environmentObject(backend)
                .environmentObject(store)
                .frame(minWidth: 1100, minHeight: 680)
                .tint(Theme.brand)
                .preferredColorScheme(.light)
                .task {
                    delegate.onTerminate = { [backend] in MainActor.assumeIsolated { backend.stop() } }
                    store.backend = backend
                    if backend.state == .starting { backend.start() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建岗位…") { store.showNewPosition = true }.keyboardShortcut("n")
                Button("设置…") { store.showSettings = true }.keyboardShortcut(",")
                Button("上传简历…") { store.showImporter = true }
                    .keyboardShortcut("o")
                    .disabled(store.selectedPosition == nil)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var store: Store

    var body: some View {
        switch backend.state {
        case .starting:
            VStack(spacing: 12) {
                ProgressView()
                Text("正在启动…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let msg):
            ContentUnavailableView("无法启动", systemImage: "exclamationmark.triangle", description: Text(msg))
        case .ready:
            MainView().task { await store.loadPositions(); await store.applyDemo() }
        }
    }
}
