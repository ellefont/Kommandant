import AppKit
import Foundation

enum Side: Hashable {
    case left, right

    var other: Side { self == .left ? .right : .left }
}

struct FileItem: Identifiable, Hashable {
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey,
    ]

    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let isSymlink: Bool
    let size: Int64
    let modified: Date
    let kind: String

    var id: String { url.path }
    /// A folder the user can navigate into (packages like .app behave like files).
    var isFolder: Bool { isDirectory && !isPackage }
    var sortSize: Int64 { isFolder ? -1 : size }

    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { return nil }
        var isDir = v.isDirectory ?? false
        if v.isSymbolicLink == true {
            var d: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &d) { isDir = d.boolValue }
        }
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDir
        self.isPackage = v.isPackage ?? false
        self.isHidden = v.isHidden ?? false
        self.isSymlink = v.isSymbolicLink ?? false
        self.size = Int64(v.fileSize ?? 0)
        self.modified = v.contentModificationDate ?? .distantPast
        self.kind = v.localizedTypeDescription ?? (isDir ? t("Ordner") : t("Dokument"))
    }
}

enum Fmt {
    /// Locale of the language the app's UI is shown in, so dates and numbers match the text.
    static let locale: Locale = {
        let language = Bundle.main.preferredLocalizations.first ?? "de"
        let region = Locale.current.region?.identifier
        return Locale(identifier: region.map { "\(language)_\($0)" } ?? language)
    }()

    static func size(_ bytes: Int64) -> String {
        bytes.formatted(ByteCountFormatStyle(style: .file, allowedUnits: .all, spellsOutZero: true,
                                             includesActualByteCount: false, locale: locale))
    }

    static func date(_ date: Date) -> String {
        guard date != .distantPast else { return "—" }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
    }

    static func objects(_ n: Int) -> String { n == 1 ? t("1 Objekt") : t("%ld Objekte", n) }
}

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let icon = cache[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}

/// Watches a single directory and calls back on the main queue when its contents change.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

struct Place: Identifiable {
    let name: String
    let symbol: String
    let url: URL
    var id: String { url.path }

    static var standard: [Place] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var places = [
            Place(name: t("Benutzerordner"), symbol: "house", url: home),
            Place(name: t("Schreibtisch"), symbol: "menubar.dock.rectangle", url: home.appending(path: "Desktop")),
            Place(name: t("Dokumente"), symbol: "doc", url: home.appending(path: "Documents")),
            Place(name: t("Downloads"), symbol: "arrow.down.circle", url: home.appending(path: "Downloads")),
            Place(name: t("Programme"), symbol: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications")),
            Place(name: t("Bilder"), symbol: "photo", url: home.appending(path: "Pictures")),
            Place(name: t("Musik"), symbol: "music.note", url: home.appending(path: "Music")),
            Place(name: t("Filme"), symbol: "film", url: home.appending(path: "Movies")),
        ]
        let icloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: icloud.path) {
            places.append(Place(name: "iCloud Drive", symbol: "icloud", url: icloud))
        }
        return places.filter { fm.fileExists(atPath: $0.url.path) }
    }

    static var volumes: [Place] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeLocalizedNameKey], options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            return Place(name: name ?? url.lastPathComponent, symbol: url.path == "/" ? "internaldrive" : "externaldrive",
                         url: url)
        }
    }
}
