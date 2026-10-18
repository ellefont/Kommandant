import AppKit
import Combine
import Foundation

enum TransferKind {
    case copy, move

    var verb: String { self == .copy ? "Kopieren" : "Verschieben" }
    var progressTitle: String { self == .copy ? "Kopiere" : "Verschiebe" }
    var symbol: String { self == .copy ? "doc.on.doc" : "arrow.right.doc.on.clipboard" }
}

enum ConflictPolicy: Hashable {
    case replace, skip, keepBoth
}

struct PendingTransfer {
    let kind: TransferKind
    let sources: [URL]
    let destination: URL
    let conflicts: [String]
}

enum ActiveSheet: Identifiable {
    case transfer(PendingTransfer)
    case rename(URL)
    /// Directory to create the folder in, plus items to move into it (may be empty).
    case newFolder(URL, [URL])
    case trash([URL])

    var id: String {
        switch self {
        case .transfer: "transfer"
        case .rename: "rename"
        case .newFolder: "newFolder"
        case .trash: "trash"
        }
    }
}

struct OperationProgress {
    var title: String
    var total: Int
    var done = 0
    var current = ""
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

struct FileOpError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor
final class AppModel: ObservableObject {
    let left = PaneModel(side: .left)
    let right = PaneModel(side: .right)
    @Published var active: Side = .left
    @Published var sheet: ActiveSheet?
    @Published var alert: AppAlert?
    @Published private(set) var progress: OperationProgress?
    private var cancelFlag: CancelFlag?
    let volumes = VolumeMonitor()
    let storage = StorageAnalyzer()
    private var volumesSubscription: AnyCancellable?

    init() {
        volumes.onUnmount = { [weak self] url in self?.leaveVolume(at: url) }
        // Re-render views (drive bars, places menu) when disks are mounted or ejected.
        volumesSubscription = volumes.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    func pane(_ side: Side) -> PaneModel { side == .left ? left : right }
    var activePane: PaneModel { pane(active) }
    var targetPane: PaneModel { pane(active.other) }
    var isBusy: Bool { progress != nil }

    // MARK: Requests (open confirmation sheets)

    func requestTransfer(_ kind: TransferKind, urls: [URL]? = nil, from side: Side? = nil) {
        let side = side ?? active
        let sources = urls ?? pane(side).selectedURLs
        guard !sources.isEmpty, !isBusy else { return NSSound.beep() }
        sheet = .transfer(makeTransfer(kind, sources: sources, destination: pane(side.other).url))
    }

    /// Drag & drop: runs immediately unless there are name conflicts.
    func dropped(_ urls: [URL], onto side: Side, move: Bool) {
        let destination = pane(side).url
        let sources = urls.filter { $0.deletingLastPathComponent().standardizedFileURL.path != destination.path }
        guard !sources.isEmpty, !isBusy else { return }
        active = side
        let transfer = makeTransfer(move ? .move : .copy, sources: sources, destination: destination)
        if transfer.conflicts.isEmpty {
            run(transfer, policy: .keepBoth)
        } else {
            sheet = .transfer(transfer)
        }
    }

    func requestRename(_ url: URL? = nil) {
        guard let target = url ?? activePane.selectedURLs.first else { return NSSound.beep() }
        sheet = .rename(target)
    }

    func requestNewFolder(in side: Side? = nil) {
        sheet = .newFolder(pane(side ?? active).url, [])
    }

    /// Like Finder's "Neuer Ordner mit Auswahl": creates a folder and moves the items into it.
    func requestNewFolderWithSelection(_ urls: [URL]? = nil, in side: Side? = nil) {
        let side = side ?? active
        let items = urls ?? pane(side).selectedURLs
        guard !items.isEmpty, !isBusy else { return NSSound.beep() }
        sheet = .newFolder(pane(side).url, items)
    }

    /// "Neuer Ordner", "Neuer Ordner 2", … – the first name not yet used in `directory`.
    func suggestedFolderName(in directory: URL) -> String {
        let fm = FileManager.default
        var name = "Neuer Ordner"
        var counter = 2
        while fm.fileExists(atPath: directory.appending(path: name).path) {
            name = "Neuer Ordner \(counter)"
            counter += 1
        }
        return name
    }

    func requestTrash(_ urls: [URL]? = nil) {
        let targets = urls ?? activePane.selectedURLs
        guard !targets.isEmpty else { return NSSound.beep() }
        sheet = .trash(targets)
    }

    private func makeTransfer(_ kind: TransferKind, sources: [URL], destination: URL) -> PendingTransfer {
        let fm = FileManager.default
        let conflicts = sources.compactMap { src -> String? in
            let target = destination.appending(path: src.lastPathComponent)
            guard target.standardizedFileURL.path != src.standardizedFileURL.path,
                  fm.fileExists(atPath: target.path) else { return nil }
            return src.lastPathComponent
        }
        return PendingTransfer(kind: kind, sources: sources, destination: destination, conflicts: conflicts)
    }

    // MARK: Execution

    func run(_ transfer: PendingTransfer, policy: ConflictPolicy) {
        let flag = CancelFlag()
        cancelFlag = flag
        progress = OperationProgress(title: transfer.kind.progressTitle, total: transfer.sources.count)
        Task.detached(priority: .userInitiated) {
            var errors: [String] = []
            var lastResult: URL?
            for (index, source) in transfer.sources.enumerated() {
                if flag.isCancelled { break }
                await MainActor.run {
                    self.progress?.done = index
                    self.progress?.current = source.lastPathComponent
                }
                do {
                    lastResult = try FileOps.transfer(source, to: transfer.destination, kind: transfer.kind, policy: policy)
                } catch {
                    errors.append("„\(source.lastPathComponent)“: \(error.localizedDescription)")
                }
            }
            let cancelled = flag.isCancelled
            let finalErrors = errors, finalResult = lastResult
            await MainActor.run {
                self.progress = nil
                self.cancelFlag = nil
                self.left.reload()
                self.right.reload()
                if let lastResult = finalResult {
                    let pane = self.left.url.path == transfer.destination.path ? self.left : self.right
                    pane.selection = [lastResult.path]
                }
                if !finalErrors.isEmpty {
                    self.alert = AppAlert(title: "\(transfer.kind.verb) fehlgeschlagen",
                                          message: finalErrors.joined(separator: "\n"))
                } else if cancelled {
                    self.alert = AppAlert(title: "Abgebrochen", message: "Der Vorgang wurde abgebrochen.")
                }
            }
        }
    }

    func cancelOperation() { cancelFlag?.cancel() }

    func rename(_ url: URL, to newName: String) {
        let target = url.deletingLastPathComponent().appending(path: newName)
        perform("Umbenennen fehlgeschlagen") {
            try FileOps.validate(name: newName)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw FileOpError("Ein Objekt mit dem Namen „\(newName)“ existiert bereits.")
            }
            try FileManager.default.moveItem(at: url, to: target)
        }
        activePane.reload()
        activePane.selection = [target.path]
    }

    func createFolder(in directory: URL, named name: String, moving items: [URL] = []) {
        let target = directory.appending(path: name)
        let created = perform("Ordner konnte nicht erstellt werden") {
            try FileOps.validate(name: name)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw FileOpError("Ein Objekt mit dem Namen „\(name)“ existiert bereits.")
            }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        }
        if created, !items.isEmpty {
            var failed: [String] = []
            for item in items {
                do {
                    try FileManager.default.moveItem(at: item, to: target.appending(path: item.lastPathComponent))
                } catch {
                    failed.append("„\(item.lastPathComponent)“: \(error.localizedDescription)")
                }
            }
            if !failed.isEmpty {
                alert = AppAlert(title: "Nicht alles konnte verschoben werden", message: failed.joined(separator: "\n"))
            }
        }
        for pane in [left, right] where pane.url.path == directory.path {
            pane.reload()
            pane.selection = [target.path]
        }
    }

    func trash(_ urls: [URL]) {
        perform("In den Papierkorb legen fehlgeschlagen") {
            for url in urls { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        }
        left.reload()
        right.reload()
    }

    @discardableResult
    private func perform(_ title: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            return true
        } catch {
            alert = AppAlert(title: title, message: error.localizedDescription)
            return false
        }
    }

    // MARK: Volumes

    func eject(_ volume: Volume) {
        leaveVolume(at: volume.url)
        Task.detached {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.alert = AppAlert(title: "„\(volume.name)“ konnte nicht ausgeworfen werden",
                                          message: message)
                }
            }
            await MainActor.run { self.volumes.refresh() }
        }
    }

    /// Moves any pane showing a folder on this volume back to the home folder.
    private func leaveVolume(at url: URL) {
        let root = url.standardizedFileURL.path
        for pane in [left, right] where pane.url.path == root || pane.url.path.hasPrefix(root + "/") {
            pane.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    // MARK: Pane helpers

    func toggleActive() { active = active.other }

    func swapSides() {
        let l = left.url
        left.navigate(to: right.url)
        right.navigate(to: l)
    }

    func mirrorActive() { targetPane.navigate(to: activePane.url) }

    func revealInFinder(_ urls: [URL]? = nil) {
        let targets = urls ?? activePane.selectedURLs
        NSWorkspace.shared.activateFileViewerSelecting(targets.isEmpty ? [activePane.url] : targets)
    }

    func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }
}

enum FileOps {
    /// Copies or moves one item into `directory` and returns the resulting URL (nil when skipped).
    @discardableResult
    static func transfer(_ source: URL, to directory: URL, kind: TransferKind, policy: ConflictPolicy) throws -> URL? {
        let fm = FileManager.default
        let src = source.standardizedFileURL
        let dir = directory.standardizedFileURL
        var target = dir.appending(path: src.lastPathComponent)

        if dir.path == src.path || dir.path.hasPrefix(src.path + "/") {
            throw FileOpError("Ein Ordner kann nicht in sich selbst kopiert oder verschoben werden.")
        }
        if target.path == src.path {
            if kind == .move { return nil }
            target = uniqueURL(for: target)
        } else if fm.fileExists(atPath: target.path) {
            switch policy {
            case .skip: return nil
            case .keepBoth: target = uniqueURL(for: target)
            case .replace: try fm.trashItem(at: target, resultingItemURL: nil)
            }
        }

        switch kind {
        case .copy: try fm.copyItem(at: src, to: target)
        case .move: try fm.moveItem(at: src, to: target)
        }
        return target
    }

    /// "Datei.txt" → "Datei Kopie.txt", "Datei Kopie 2.txt", …
    static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var counter = 1
        while true {
            let suffix = counter == 1 ? " Kopie" : " Kopie \(counter)"
            let name = base + suffix + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = dir.appending(path: name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    static func validate(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw FileOpError("Der Name darf nicht leer sein.") }
        guard !name.contains("/"), !name.contains(":") else {
            throw FileOpError("Der Name darf keine „/“ oder „:“ enthalten.")
        }
        guard name != ".", name != ".." else { throw FileOpError("Dieser Name ist nicht erlaubt.") }
    }
}
