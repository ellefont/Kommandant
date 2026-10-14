import AppKit
import Foundation

@MainActor
final class PaneModel: ObservableObject {
    let side: Side
    @Published private(set) var url: URL
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var loadError: String?
    @Published private(set) var freeSpace: Int64?
    @Published var selection = Set<FileItem.ID>()
    @Published var filter = ""
    @Published var showHidden = false { didSet { reload() } }
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\.name, comparator: .localizedStandard)] {
        didSet { items = sorted(items) }
    }

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var watcher: DirectoryWatcher?
    private var defaultsKey: String { side == .left ? "pfadLinks" : "pfadRechts" }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { url.path != "/" }

    var displayed: [FileItem] {
        filter.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    /// Selected URLs in display order.
    var selectedURLs: [URL] { displayed.filter { selection.contains($0.id) }.map(\.url) }

    var title: String {
        url.path == "/" ? (Place.volumes.first { $0.url.path == "/" }?.name ?? "/") : url.lastPathComponent
    }

    init(side: Side) {
        self.side = side
        let fm = FileManager.default
        let fallback = side == .left ? fm.homeDirectoryForCurrentUser
            : fm.homeDirectoryForCurrentUser.appending(path: "Downloads")
        var start = fallback
        if let saved = UserDefaults.standard.string(forKey: side == .left ? "pfadLinks" : "pfadRechts"),
           fm.fileExists(atPath: saved) {
            start = URL(fileURLWithPath: saved)
        }
        self.url = start.standardizedFileURL
        reload()
        watch()
    }

    // MARK: Navigation

    func navigate(to newURL: URL, recordHistory: Bool = true, select: String? = nil) {
        let target = newURL.standardizedFileURL
        if recordHistory, target.path != url.path {
            backStack.append(url)
            forwardStack.removeAll()
        }
        url = target
        filter = ""
        selection = select.map { [$0] } ?? []
        reload()
        watch()
        UserDefaults.standard.set(target.path, forKey: defaultsKey)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(url)
        navigate(to: previous, recordHistory: false, select: url.path)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(url)
        navigate(to: next, recordHistory: false)
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: url.deletingLastPathComponent(), select: url.path)
    }

    func open(_ ids: Set<FileItem.ID>) {
        let targets = items.filter { ids.contains($0.id) }
        if targets.count == 1, let target = targets.first, target.isFolder {
            navigate(to: target.url)
            return
        }
        for target in targets {
            if target.isFolder { continue }
            NSWorkspace.shared.open(target.url)
        }
    }

    // MARK: Loading

    func reload() {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: FileItem.resourceKeys,
                options: showHidden ? [] : [.skipsHiddenFiles])
            items = sorted(urls.compactMap(FileItem.init(url:)))
            loadError = nil
        } catch {
            items = []
            loadError = error.localizedDescription
        }
        let ids = Set(items.map(\.id))
        selection = selection.filter { ids.contains($0) }
        freeSpace = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private func sorted(_ list: [FileItem]) -> [FileItem] {
        let s = list.sorted(using: sortOrder)
        return s.filter(\.isFolder) + s.filter { !$0.isFolder }
    }

    private func watch() {
        watcher = DirectoryWatcher(url: url) { [weak self] in self?.reload() }
    }
}
