import Darwin
import Foundation

enum SyncMode: String, Codable, CaseIterable, Identifiable {
    /// Right becomes an exact copy of left (extra files on the right are deleted).
    case mirror
    /// New and changed files go from left to right; nothing is deleted.
    case update
    /// Changes go both ways; the newer file wins.
    case twoWay

    var id: String { rawValue }
}

enum CompareMethod: String, Codable, CaseIterable, Identifiable {
    case dateSize, content
    var id: String { rawValue }
}

enum SyncCategory {
    case leftOnly, rightOnly, leftNewer, rightNewer, conflict
}

enum SyncAction: Hashable {
    case none, copyToRight, copyToLeft, deleteRight, deleteLeft

    var isDelete: Bool { self == .deleteRight || self == .deleteLeft }
}

struct SyncFileInfo {
    let size: Int64
    let modified: Date
    let isDirectory: Bool
    /// Number of files (1 for a file, the whole tree for a folder that exists on one side only).
    var fileCount = 1
}

struct SyncEntry: Identifiable {
    let id = UUID()
    let path: String
    let category: SyncCategory
    var action: SyncAction
    let left: SyncFileInfo?
    let right: SyncFileInfo?

    var name: String { (path as NSString).lastPathComponent }
    var isDirectory: Bool { left?.isDirectory ?? right?.isDirectory ?? false }

    /// Bytes this entry moves or frees with its current action.
    var bytes: Int64 {
        switch action {
        case .copyToRight, .deleteLeft: left?.size ?? 0
        case .copyToLeft, .deleteRight: right?.size ?? 0
        case .none: max(left?.size ?? 0, right?.size ?? 0)
        }
    }

    var fileCount: Int {
        switch action {
        case .copyToRight, .deleteLeft: left?.fileCount ?? 1
        case .copyToLeft, .deleteRight: right?.fileCount ?? 1
        case .none: max(left?.fileCount ?? 1, right?.fileCount ?? 1)
        }
    }

    static func defaultAction(for category: SyncCategory, mode: SyncMode) -> SyncAction {
        switch (mode, category) {
        case (_, .leftOnly): .copyToRight
        case (.mirror, .rightOnly): .deleteRight
        case (.twoWay, .rightOnly): .copyToLeft
        case (.update, .rightOnly): .none
        case (_, .leftNewer): .copyToRight
        case (.mirror, .rightNewer), (.mirror, .conflict): .copyToRight
        case (.twoWay, .rightNewer): .copyToLeft
        case (.update, .rightNewer), (_, .conflict): .none
        }
    }
}

struct SyncResult {
    var copiedFiles = 0
    var deletedItems = 0
    var bytes: Int64 = 0
    var errors: [String] = []
    var cancelled = false
    var duration: TimeInterval = 0
}

/// Shell-style exclude patterns ("*.tmp, node_modules, .DS_Store"), matched against name and relative path.
struct ExcludeFilter: Sendable {
    let patterns: [String]

    init(_ text: String) {
        patterns = text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func excludes(name: String, path: String) -> Bool {
        patterns.contains { fnmatch($0, name, 0) == 0 || fnmatch($0, path, 0) == 0 }
    }
}

// MARK: - Compare

/// Walks both folders and lists every difference. Runs on a background thread.
final class SyncComparer: @unchecked Sendable {
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]
    /// FAT/exFAT disks store times with 2 s precision.
    private static let timeTolerance: TimeInterval = 2

    private let leftRoot: URL
    private let rightRoot: URL
    private let method: CompareMethod
    private let filter: ExcludeFilter
    private let flag: CancelFlag
    private let onProgress: @Sendable (Int, String) -> Void
    private(set) var scanned = 0
    private(set) var equalFiles = 0
    private(set) var equalBytes: Int64 = 0

    init(left: URL, right: URL, method: CompareMethod, filter: ExcludeFilter, flag: CancelFlag,
         onProgress: @escaping @Sendable (Int, String) -> Void) {
        leftRoot = left
        rightRoot = right
        self.method = method
        self.filter = filter
        self.flag = flag
        self.onProgress = onProgress
    }

    func compare() throws -> [SyncEntry] {
        for root in [leftRoot, rightRoot] {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
                throw FileOpError(t("Der Ordner „%@“ ist nicht verfügbar.", root.path))
            }
        }
        var result: [SyncEntry] = []
        try compareDirectory("", into: &result)
        return result
    }

    private func compareDirectory(_ relative: String, into result: inout [SyncEntry]) throws {
        if flag.isCancelled { return }
        let leftDir = relative.isEmpty ? leftRoot : leftRoot.appending(path: relative)
        let rightDir = relative.isEmpty ? rightRoot : rightRoot.appending(path: relative)
        let leftItems = try list(leftDir, relative: relative)
        let rightItems = try list(rightDir, relative: relative)
        onProgress(scanned, relative)

        let names = Set(leftItems.keys).union(rightItems.keys)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in names {
            if flag.isCancelled { return }
            let path = relative.isEmpty ? name : relative + "/" + name
            let l = leftItems[name], r = rightItems[name]
            switch (l, r) {
            case (var l?, nil):
                if l.isDirectory { l = treeInfo(leftDir.appending(path: name), relative: path) }
                result.append(entry(path, .leftOnly, l, nil))
            case (nil, var r?):
                if r.isDirectory { r = treeInfo(rightDir.appending(path: name), relative: path) }
                result.append(entry(path, .rightOnly, nil, r))
            case (let l?, let r?):
                if l.isDirectory && r.isDirectory {
                    try compareDirectory(path, into: &result)
                } else if l.isDirectory != r.isDirectory {
                    result.append(entry(path, .conflict, l, r))
                } else if let category = compareFiles(l, r, leftDir.appending(path: name), rightDir.appending(path: name)) {
                    result.append(entry(path, category, l, r))
                } else {
                    equalFiles += 1
                    equalBytes += l.size
                }
            case (nil, nil):
                break
            }
        }
    }

    /// nil when the files are considered equal.
    private func compareFiles(_ l: SyncFileInfo, _ r: SyncFileInfo, _ lURL: URL, _ rURL: URL) -> SyncCategory? {
        let dt = l.modified.timeIntervalSince(r.modified)
        if l.size == r.size {
            switch method {
            case .dateSize:
                if abs(dt) <= Self.timeTolerance { return nil }
            case .content:
                if FileManager.default.contentsEqual(atPath: lURL.path, andPath: rURL.path) { return nil }
            }
        }
        if abs(dt) <= Self.timeTolerance { return .conflict }
        return dt > 0 ? .leftNewer : .rightNewer
    }

    private func entry(_ path: String, _ category: SyncCategory, _ l: SyncFileInfo?, _ r: SyncFileInfo?) -> SyncEntry {
        SyncEntry(path: path, category: category, action: .none, left: l, right: r)
    }

    private func list(_ dir: URL, relative: String) throws -> [String: SyncFileInfo] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(Self.keys), options: [])
        var result: [String: SyncFileInfo] = [:]
        for url in urls {
            let name = url.lastPathComponent
            let path = relative.isEmpty ? name : relative + "/" + name
            if filter.excludes(name: name, path: path) { continue }
            guard let v = try? url.resourceValues(forKeys: Self.keys) else { continue }
            let isDir = v.isDirectory == true && v.isSymbolicLink != true
            result[name] = SyncFileInfo(size: Int64(isDir ? 0 : v.fileSize ?? 0),
                                        modified: v.contentModificationDate ?? .distantPast, isDirectory: isDir)
            scanned += 1
        }
        return result
    }

    /// Size and file count of a folder that exists on one side only.
    private func treeInfo(_ url: URL, relative: String) -> SyncFileInfo {
        var size: Int64 = 0, count = 0
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(Self.keys), options: [], errorHandler: { _, _ in true })
        while let item = enumerator?.nextObject() as? URL {
            if flag.isCancelled { break }
            let sub = relative + "/" + String(item.path.dropFirst(url.path.count + 1))
            if filter.excludes(name: item.lastPathComponent, path: sub) {
                enumerator?.skipDescendants()
                continue
            }
            guard let v = try? item.resourceValues(forKeys: Self.keys) else { continue }
            if v.isDirectory == true && v.isSymbolicLink != true { continue }
            size += Int64(v.fileSize ?? 0)
            count += 1
        }
        scanned += count
        return SyncFileInfo(size: size, modified: .distantPast, isDirectory: true, fileCount: count)
    }
}

// MARK: - Execute

/// Receives copyfile progress callbacks for the file currently being copied.
private final class CopyContext {
    let flag: CancelFlag
    let onBytes: (Int64) -> Void

    init(flag: CancelFlag, onBytes: @escaping (Int64) -> Void) {
        self.flag = flag
        self.onBytes = onBytes
    }
}

private let copyProgressCallback: copyfile_callback_t = { what, stage, state, _, _, ctx in
    guard let ctx else { return COPYFILE_CONTINUE }
    let context = Unmanaged<CopyContext>.fromOpaque(ctx).takeUnretainedValue()
    if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
        var copied: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        context.onBytes(Int64(copied))
    }
    return context.flag.isCancelled ? COPYFILE_QUIT : COPYFILE_CONTINUE
}

/// Applies the actions of the compared entries. Runs on a background thread.
final class SyncExecutor: @unchecked Sendable {
    // copyfile flags: ACL | STAT | XATTR | DATA (= COPYFILE_ALL), NOFOLLOW_SRC | NOFOLLOW_DST
    private static let copyFlags = copyfile_flags_t(0x0F | 1 << 18 | 1 << 19)

    private let leftRoot: URL
    private let rightRoot: URL
    private let useTrash: Bool
    private let filter: ExcludeFilter
    private let flag: CancelFlag
    private let onProgress: @Sendable (Int64, Int, String) -> Void
    private var doneBytes: Int64 = 0
    private var doneFiles = 0
    private var lastReport = Date.distantPast
    private var result = SyncResult()

    init(left: URL, right: URL, useTrash: Bool, filter: ExcludeFilter, flag: CancelFlag,
         onProgress: @escaping @Sendable (Int64, Int, String) -> Void) {
        leftRoot = left
        rightRoot = right
        self.useTrash = useTrash
        self.filter = filter
        self.flag = flag
        self.onProgress = onProgress
    }

    func run(_ entries: [SyncEntry]) -> SyncResult {
        let began = Date()
        // Deletions first, so space is freed before copying onto the same disk.
        let ordered = entries.filter { $0.action.isDelete } + entries.filter { !$0.action.isDelete && $0.action != .none }
        for entry in ordered {
            if flag.isCancelled { break }
            do {
                switch entry.action {
                case .copyToRight: try copy(entry.path, from: leftRoot, to: rightRoot)
                case .copyToLeft: try copy(entry.path, from: rightRoot, to: leftRoot)
                case .deleteRight: try delete(rightRoot.appending(path: entry.path))
                case .deleteLeft: try delete(leftRoot.appending(path: entry.path))
                case .none: break
                }
            } catch {
                if flag.isCancelled { break }
                result.errors.append(t("„%@“: %@", entry.path, error.localizedDescription))
            }
        }
        result.cancelled = flag.isCancelled
        result.duration = Date().timeIntervalSince(began)
        result.bytes = doneBytes
        onProgress(doneBytes, doneFiles, "")
        return result
    }

    private func delete(_ url: URL) throws {
        if useTrash {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: url)
        }
        result.deletedItems += 1
    }

    private func copy(_ relative: String, from sourceRoot: URL, to targetRoot: URL) throws {
        let fm = FileManager.default
        let source = sourceRoot.appending(path: relative)
        let target = targetRoot.appending(path: relative)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? target.checkResourceIsReachable()) == true || fm.fileExists(atPath: target.path) {
            // The replaced version goes to the trash (if enabled), so nothing is lost by mistake.
            if useTrash {
                try fm.trashItem(at: target, resultingItemURL: nil)
            } else {
                try fm.removeItem(at: target)
            }
        }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isDirectory == true && values.isSymbolicLink != true {
            try copyTree(source, to: target, relative: relative)
        } else {
            try copyFile(source, to: target)
        }
    }

    private func copyTree(_ source: URL, to target: URL, relative: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: keys, options: [],
                                             errorHandler: { _, _ in true }) else { return }
        while let item = enumerator.nextObject() as? URL {
            if flag.isCancelled { return }
            let sub = String(item.path.dropFirst(source.path.count + 1))
            if filter.excludes(name: item.lastPathComponent, path: relative + "/" + sub) {
                enumerator.skipDescendants()
                continue
            }
            let destination = target.appending(path: sub)
            let v = try? item.resourceValues(forKeys: Set(keys))
            do {
                if v?.isDirectory == true && v?.isSymbolicLink != true {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                } else {
                    try copyFile(item, to: destination)
                }
            } catch {
                if flag.isCancelled { return }
                result.errors.append(t("„%@“: %@", relative + "/" + sub, error.localizedDescription))
            }
        }
    }

    private func copyFile(_ source: URL, to target: URL) throws {
        let base = doneBytes
        let context = CopyContext(flag: flag) { [unowned self] copied in
            self.report(base + copied, current: source.lastPathComponent)
        }
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyProgressCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())

        let status = withExtendedLifetime(context) { copyfile(source.path, target.path, state, Self.copyFlags) }
        if status != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: target) // no half-copied files
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        doneBytes = base + Int64(size)
        doneFiles += 1
        result.copiedFiles += 1
        report(doneBytes, current: source.lastPathComponent, force: true)
    }

    private func report(_ bytes: Int64, current: String, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 0.1 else { return }
        lastReport = now
        onProgress(bytes, doneFiles, current)
    }
}
