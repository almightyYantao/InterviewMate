import AppKit
import SwiftUI

/// 盯着「下载」文件夹：出现像简历的新文件，就在右下角问要导入到哪个岗位
@MainActor
final class ResumeWatcher: ObservableObject {
    @Published var pending: [URL] = []
    var handled = Set<String>()                 // 已导入 / 已忽略 / App 自己上传过的文件
    private var since = Date()
    private var started = false
    static let pattern = try! NSRegularExpression(pattern: "简历|履历|求职|应聘|resume|\\bcv\\b|【", options: [.caseInsensitive])

    func start() {
        guard !started else { return }
        started = true
        since = Date()
        Task {
            while true {
                if UserDefaults.standard.object(forKey: "watchDownloads") as? Bool ?? true { scan() }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func scan() {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for f in files where ["pdf", "docx"].contains(f.pathExtension.lowercased()) {
            let name = f.deletingPathExtension().lastPathComponent
            guard !handled.contains(f.path), !pending.contains(f),
                  let made = try? f.resourceValues(forKeys: [.creationDateKey]).creationDate, made > since,
                  // 等 6 秒：浏览器写完文件；「从 Bob 导入简历」那条流程也会先把它处理掉，避免重复导入
                  Date().timeIntervalSince(made) > 6,
                  Self.pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else { continue }
            withAnimation(.spring(response: 0.4)) { pending.append(f) }
        }
    }

    func done(_ f: URL) {
        handled.insert(f.path)
        withAnimation(.spring(response: 0.35)) { pending.removeAll { $0 == f } }
    }
}

/// 右下角的「发现新简历」提示
struct ResumeInbox: View {
    @EnvironmentObject var store: Store
    @ObservedObject var w: ResumeWatcher

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(w.pending, id: \.self) { f in
                HStack(spacing: 12) {
                    Image(systemName: "doc.badge.plus").font(.title3).foregroundStyle(Theme.brand)
                        .frame(width: 38, height: 38).background(Theme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("发现新简历").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(f.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).frame(maxWidth: 260, alignment: .leading)
                    }
                    Menu {
                        ForEach(store.positions) { p in Button(p.title) { importTo(f, p.id) } }
                    } label: {
                        Text(store.selectedPosition.map { String(format: L("导入到「%@」"), $0.title) } ?? L("导入到…"))
                    } primaryAction: {
                        if let pid = store.selectedPositionID ?? store.positions.first?.id { importTo(f, pid) }
                    }
                    .menuStyle(.borderedButton).fixedSize()
                    .help(L("直接点导入到当前岗位；点右侧箭头选别的岗位"))
                    Button { w.done(f) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 24, height: 24).background(Theme.page, in: Circle())
                    }.buttonStyle(.plain).help(L("忽略"))
                }
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(20)
    }

    func importTo(_ f: URL, _ pid: String) {
        w.done(f)
        store.upload([f], to: pid)
    }
}
