import AppKit
import Foundation

struct Volume: Identifiable, Hashable {
    static let resourceKeys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey,
        .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
    ]

    let url: URL
    let name: String
    let isEjectable: Bool
    let isRoot: Bool
    let isExternal: Bool
    let total: Int64?
    let free: Int64?

    var id: String { url.path }

    var symbol: String {
        if isRoot { return "internaldrive" }
        return isExternal || isEjectable ? "externaldrive" : "internaldrive"
    }

    /// Whether `path` lives on this volume.
    func contains(_ path: String) -> Bool {
        isRoot || path == url.path || path.hasPrefix(url.path + "/")
    }

    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: Set(Self.resourceKeys)),
              v.volumeIsBrowsable ?? true else { return nil }
        self.url = url.standardizedFileURL
        self.name = v.volumeLocalizedName ?? url.lastPathComponent
        self.isRoot = v.volumeIsRootFileSystem ?? (url.path == "/")
        self.isEjectable = !isRoot && ((v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false)
            || !(v.volumeIsInternal ?? true))
        self.isExternal = !(v.volumeIsInternal ?? true)
        self.total = v.volumeTotalCapacity.map(Int64.init)
        self.free = v.volumeAvailableCapacity.map(Int64.init)
    }
}

/// Keeps the list of mounted volumes current (USB sticks, external disks, network shares, …).
@MainActor
final class VolumeMonitor: ObservableObject {
    @Published private(set) var volumes: [Volume] = []
    var onUnmount: ((URL) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated {
                    if note.name == NSWorkspace.didUnmountNotification, let url { self?.onUnmount?(url) }
                    self?.refresh()
                }
            })
        }
    }

    func refresh() {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Volume.resourceKeys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap(Volume.init(url:)).sorted { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The volume a path lives on (most specific mount point wins).
    func volume(for path: String) -> Volume? {
        volumes.filter { $0.contains(path) }.max { $0.url.path.count < $1.url.path.count }
    }
}
