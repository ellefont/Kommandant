import AppKit
import Foundation

/// One entry in the analyzed tree. Directories keep their largest children; the rest is aggregated.
final class StorageNode: Identifiable, @unchecked Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isAggregate: Bool
    var size: Int64
    var fileCount: Int
    var modified: Date
    var children: [StorageNode] = []
    weak var parent: StorageNode?

    init(url: URL, name: String, isDirectory: Bool, size: Int64 = 0, fileCount: Int = 0,
         modified: Date = .distantPast, isAggregate: Bool = false) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.fileCount = fileCount
        self.modified = modified
        self.isAggregate = isAggregate
    }

    var ancestors: [StorageNode] {
        var result: [StorageNode] = []
        var node: StorageNode? = self
        while let n = node {
            result.insert(n, at: 0)
            node = n.parent
        }
        return result
    }

    func contains(_ other: StorageNode) -> Bool {
        other === self || other.url.path.hasPrefix(url.path + "/")
    }
}

/// Walks a directory tree on a background thread. Never follows symlinks or crosses into other volumes.
final class StorageScanner: @unchecked Sendable {
    static let devFolderNames: Set<String> = [
        "node_modules", ".build", "DerivedData", "Pods", ".venv", "venv", "__pycache__", ".gradle", ".next",
    ]
    private static let keepChildren = 300
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .fileSizeKey, .contentModificationDateKey,
    ]

    /// Entries of "/" that alias the whole file system or other volumes and would be counted twice.
    /// (macOS reports some of them with a trailing slash, so they are matched by name.)
    private static let rootAliases: Set<String> = [".nofollow", ".resolve", ".vol", "Volumes", "dev", "net", "home"]

    private let flag: CancelFlag
    private let allowedDevices: Set<dev_t>
    private let onProgress: @Sendable (Int, String) -> Void
    private(set) var files = 0
    private(set) var inaccessible = 0
    private(set) var largest: [StorageNode] = []
    private(set) var devFolders: [StorageNode] = []
    private var largestThreshold: Int64 = 1_000_000

    /// Only directories on the same device as `root` are scanned, so one disk is analyzed at a time.
    init(root: URL, flag: CancelFlag, onProgress: @escaping @Sendable (Int, String) -> Void) {
        self.flag = flag
        self.onProgress = onProgress
        var devices = Set<dev_t>()
        if let dev = Self.device(of: root.path) { devices.insert(dev) }
        // On APFS "Macintosh HD" is a read-only system volume plus a data volume joined by firmlinks
        // (/Users, /Applications, …). Both belong to the same disk as far as the user is concerned.
        if root.path == "/", let data = Self.device(of: "/System/Volumes/Data") { devices.insert(data) }
        allowedDevices = devices
    }

    private static func device(of path: String) -> dev_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_dev : nil
    }

    func scan(_ url: URL, name: String) -> StorageNode {
        let root = scanDirectory(url.standardizedFileURL, name: name, insideDevFolder: false)
        largest.sort { $0.size > $1.size }
        if largest.count > 300 { largest.removeLast(largest.count - 300) }
        devFolders.sort { $0.size > $1.size }
        return root
    }

    private func scanDirectory(_ url: URL, name: String, insideDevFolder: Bool) -> StorageNode {
        let node = StorageNode(url: url, name: name, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Self.keys, options: []) else {
            inaccessible += 1
            return node
        }
        var children: [StorageNode] = []
        children.reserveCapacity(contents.count)

        for child in contents {
            if flag.isCancelled { break }
            let values = try? child.resourceValues(forKeys: Set(Self.keys))
            let isDir = values?.isDirectory == true && values?.isSymbolicLink != true
            let childNode: StorageNode
            if isDir {
                if url.path == "/", Self.rootAliases.contains(child.lastPathComponent) { continue }
                if child.path.hasPrefix("/System/Volumes") { continue }
                guard let dev = Self.device(of: child.path), allowedDevices.contains(dev) else { continue }
                let isDev = Self.devFolderNames.contains(child.lastPathComponent)
                childNode = scanDirectory(child, name: child.lastPathComponent,
                                          insideDevFolder: insideDevFolder || isDev)
                if isDev, !insideDevFolder { devFolders.append(childNode) }
            } else {
                // exFAT/FAT (USB sticks, cameras) report 0 as allocated size.
                let allocated = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
                let size = Int64(allocated > 0 ? allocated : values?.fileSize ?? 0)
                childNode = StorageNode(url: child, name: child.lastPathComponent, isDirectory: false, size: size,
                                        fileCount: 1, modified: values?.contentModificationDate ?? .distantPast)
                files += 1
                if files % 1500 == 0 { onProgress(files, url.path) }
                considerLargest(childNode)
            }
            childNode.parent = node
            node.size += childNode.size
            node.fileCount += childNode.fileCount
            node.modified = max(node.modified, childNode.modified)
            children.append(childNode)
        }

        children.sort { $0.size > $1.size }
        if children.count > Self.keepChildren {
            let rest = children[Self.keepChildren...]
            let other = StorageNode(url: url, name: t("%ld weitere Objekte", rest.count), isDirectory: false,
                                    size: rest.reduce(0) { $0 + $1.size },
                                    fileCount: rest.reduce(0) { $0 + $1.fileCount }, isAggregate: true)
            other.parent = node
            children = Array(children[..<Self.keepChildren]) + [other]
        }
        node.children = children
        return node
    }

    private func considerLargest(_ node: StorageNode) {
        guard node.size >= largestThreshold else { return }
        largest.append(node)
        if largest.count >= 2000 {
            largest.sort { $0.size > $1.size }
            largest.removeLast(largest.count - 500)
            largestThreshold = largest.last?.size ?? largestThreshold
        }
    }

    /// Total allocated size of a folder (used for the cleanup suggestions).
    static func folderSize(_ url: URL, olderThan cutoff: Date? = nil) -> (total: Int64, old: Int64) {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        else { return (0, 0) }
        var total: Int64 = 0, old: Int64 = 0
        for case let file as URL in enumerator {
            guard let v = try? file.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            let allocated = v.totalFileAllocatedSize ?? 0
            let size = Int64(allocated > 0 ? allocated : v.fileSize ?? 0)
            total += size
            if let cutoff, let date = v.contentModificationDate, date < cutoff { old += size }
        }
        return (total, old)
    }
}

enum CleanupAction {
    case emptyTrash
    /// Permanently deletes the folder's contents (caches, build products, …).
    case deleteContents
    /// Nothing automatic: the user should look through it.
    case review
}

struct CleanupSuggestion: Identifiable {
    let title: String
    let detail: String
    let symbol: String
    let url: URL
    let size: Int64
    let action: CleanupAction
    var id: String { url.path }

    static func compute() -> [CleanupSuggestion] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let lib = home.appending(path: "Library")
        let candidates: [(String, String, String, URL, CleanupAction)] = [
            ("Papierkorb", "Gelöschte Dateien belegen Platz, bis der Papierkorb geleert wird.", "trash",
             home.appending(path: ".Trash"), .emptyTrash),
            ("Benutzer-Caches", "Zwischenspeicher von Apps. Werden bei Bedarf neu angelegt. Am besten vorher Apps beenden.",
             "archivebox", lib.appending(path: "Caches"), .deleteContents),
            ("Protokolle", "Alte Protokolldateien von Apps und System-Diensten.", "list.bullet.rectangle",
             lib.appending(path: "Logs"), .deleteContents),
            ("Xcode DerivedData", "Build-Zwischenstände – Xcode erzeugt sie beim nächsten Build neu.", "hammer",
             lib.appending(path: "Developer/Xcode/DerivedData"), .deleteContents),
            ("Xcode Geräte-Support", "Symboldateien für iOS-Versionen, die du evtl. nicht mehr testest.",
             "iphone", lib.appending(path: "Developer/Xcode/iOS DeviceSupport"), .deleteContents),
            ("Xcode-Archive", "Archivierte App-Builds. Prüfe, ob du alte Versionen noch brauchst.", "shippingbox",
             lib.appending(path: "Developer/Xcode/Archives"), .review),
            ("iOS-Simulatoren", "Simulator-Geräte und ihre Daten. Unbenutzte lassen sich in Xcode entfernen.",
             "ipad.and.iphone", lib.appending(path: "Developer/CoreSimulator/Devices"), .review),
            ("iPhone- und iPad-Backups", "Lokale Gerätesicherungen – prüfe, ob du alte noch brauchst.",
             "externaldrive.badge.timemachine", lib.appending(path: "Application Support/MobileSync/Backup"), .review),
            ("npm-Cache", "Heruntergeladene Pakete – npm lädt sie bei Bedarf erneut.", "shippingbox.circle",
             home.appending(path: ".npm"), .deleteContents),
            ("Downloads", "Heruntergeladene Dateien werden oft vergessen.", "arrow.down.circle",
             home.appending(path: "Downloads"), .review),
        ]
        let cutoff = Calendar.current.date(byAdding: .month, value: -3, to: .now)
        return candidates.compactMap { title, detail, symbol, url, action in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let isDownloads = url.lastPathComponent == "Downloads"
            let (size, old) = StorageScanner.folderSize(url, olderThan: isDownloads ? cutoff : nil)
            guard size > 0 else { return nil }
            let detail = t(detail)
            let text = isDownloads && old > 0 ? detail + " " + t("Davon %@ älter als 3 Monate.", Fmt.size(old)) : detail
            return CleanupSuggestion(title: t(title), detail: text, symbol: symbol, url: url, size: size, action: action)
        }
        .sorted { $0.size > $1.size }
    }
}

@MainActor
final class StorageAnalyzer: ObservableObject {
    @Published var rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published private(set) var root: StorageNode?
    @Published var current: StorageNode?
    @Published private(set) var isScanning = false
    @Published private(set) var scannedFiles = 0
    @Published private(set) var scanningPath = ""
    @Published private(set) var largestFiles: [StorageNode] = []
    @Published private(set) var devFolders: [StorageNode] = []
    @Published private(set) var inaccessible = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var suggestions: [CleanupSuggestion] = []
    @Published private(set) var isLoadingSuggestions = false
    @Published var alert: AppAlert?
    private var flag: CancelFlag?

    var rootName: String {
        if let volume = Place.volumes.first(where: { $0.url.path == rootURL.path }) { return volume.name }
        return rootURL.path == FileManager.default.homeDirectoryForCurrentUser.path ? t("Benutzerordner")
            : rootURL.lastPathComponent
    }

    func analyze(_ url: URL) {
        rootURL = url.standardizedFileURL
        start()
    }

    func start() {
        flag?.cancel()
        let flag = CancelFlag()
        self.flag = flag
        isScanning = true
        scannedFiles = 0
        scanningPath = rootURL.path
        root = nil
        current = nil
        let url = rootURL, name = rootName
        let began = Date()
        Task.detached(priority: .userInitiated) {
            let scanner = StorageScanner(root: url, flag: flag) { count, path in
                Task { @MainActor [weak self] in
                    guard let self, self.flag === flag else { return }
                    self.scannedFiles = count
                    self.scanningPath = path
                }
            }
            let tree = scanner.scan(url, name: name)
            let largest = scanner.largest, dev = scanner.devFolders, denied = scanner.inaccessible
            let files = scanner.files
            await MainActor.run {
                guard self.flag === flag else { return }
                self.isScanning = false
                self.flag = nil
                guard !flag.isCancelled else { return }
                self.root = tree
                self.current = tree
                self.largestFiles = largest
                self.devFolders = dev
                self.inaccessible = denied
                self.scannedFiles = files
                self.duration = Date().timeIntervalSince(began)
            }
        }
        loadSuggestions()
    }

    func cancel() {
        flag?.cancel()
        flag = nil
        isScanning = false
    }

    func loadSuggestions() {
        guard !isLoadingSuggestions else { return }
        isLoadingSuggestions = true
        Task.detached(priority: .utility) {
            let result = CleanupSuggestion.compute()
            await MainActor.run {
                self.suggestions = result
                self.isLoadingSuggestions = false
            }
        }
    }

    // MARK: Actions

    func moveToTrash(_ nodes: [StorageNode]) {
        var failed: [String] = []
        for node in nodes where !node.isAggregate {
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                remove(node)
            } catch {
                failed.append(t("„%@“: %@", node.name, error.localizedDescription))
            }
        }
        if !failed.isEmpty {
            alert = AppAlert(title: t("Nicht alles konnte verschoben werden"), message: failed.joined(separator: "\n"))
        }
        objectWillChange.send()
        loadSuggestions()
    }

    func perform(_ suggestion: CleanupSuggestion) {
        switch suggestion.action {
        case .emptyTrash:
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
            if let error {
                alert = AppAlert(title: t("Papierkorb konnte nicht geleert werden"),
                                 message: error[NSAppleScript.errorMessage] as? String ?? t("Unbekannter Fehler"))
            }
        case .deleteContents:
            let items = (try? FileManager.default.contentsOfDirectory(at: suggestion.url, includingPropertiesForKeys: nil)) ?? []
            var failed = 0
            for item in items {
                do { try FileManager.default.removeItem(at: item) } catch { failed += 1 }
            }
            if failed > 0 {
                alert = AppAlert(title: t("%@ teilweise gelöscht", suggestion.title),
                                 message: t("%@ konnten nicht gelöscht werden (in Benutzung oder geschützt).", Fmt.objects(failed)))
            }
        case .review:
            break
        }
        loadSuggestions()
    }

    /// Removes a node from the tree and the lists, keeping the ancestors' totals correct.
    private func remove(_ node: StorageNode) {
        var ancestor = node.parent
        while let a = ancestor {
            a.size -= node.size
            a.fileCount -= node.fileCount
            ancestor = a.parent
        }
        node.parent?.children.removeAll { $0 === node }
        largestFiles.removeAll { node.contains($0) }
        devFolders.removeAll { node.contains($0) }
        if let current, node.contains(current) { self.current = node.parent ?? root }
    }
}
