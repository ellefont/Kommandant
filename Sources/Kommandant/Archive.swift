import AppKit
import Foundation

/// Creates ZIP archives with /usr/bin/zip (clean archives without .DS_Store or __MACOSX, readable everywhere).
enum Archiver {
    static let excluded = ["*.DS_Store", "*/__MACOSX/*", "*/.Trashes/*", "*/.Spotlight-V100/*", "*/.fseventsd/*"]

    /// Default archive name: date and time, e.g. "20261018-1540".
    static func defaultName(in directory: URL) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let base = formatter.string(from: Date())
        var name = base
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appending(path: name + ".zip").path) {
            name = "\(base)-\(counter)"
            counter += 1
        }
        return name
    }

    /// Size of every file below `items`, keyed by the path relative to their common parent (as zip prints it).
    static func inventory(_ items: [URL], flag: CancelFlag? = nil) -> (sizes: [String: Int64], total: Int64) {
        var sizes: [String: Int64] = [:]
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        for item in items {
            let parent = item.deletingLastPathComponent().path
            func add(_ url: URL) {
                guard let v = try? url.resourceValues(forKeys: keys), v.isDirectory != true || v.isSymbolicLink == true,
                      url.lastPathComponent != ".DS_Store" else { return }
                let size = Int64(v.fileSize ?? 0)
                sizes[String(url.path.dropFirst(parent.count + 1)).precomposedStringWithCanonicalMapping] = size
                total += size
            }
            add(item)
            let enumerator = FileManager.default.enumerator(at: item, includingPropertiesForKeys: Array(keys), options: [],
                                                            errorHandler: { _, _ in true })
            while let url = enumerator?.nextObject() as? URL {
                if flag?.isCancelled == true { break }
                add(url)
            }
        }
        return (sizes, total)
    }
}

/// The running zip process, so it can be interrupted from the main thread.
final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process?) { lock.withLock { self.process = process } }

    /// SIGINT lets zip delete its temporary file before exiting.
    func interrupt() { lock.withLock { if process?.isRunning == true { process?.interrupt() } } }
}

extension AppModel {
    func requestArchive(_ urls: [URL]? = nil, from side: Side? = nil) {
        let side = side ?? active
        let items = urls ?? pane(side).selectedURLs
        guard !items.isEmpty, !isBusy else { return NSSound.beep() }
        sheet = .archive(items, pane(side.other).url)
    }

    func archive(_ items: [URL], to directory: URL, name: String, compress: Bool) {
        let fileName = name.hasSuffix(".zip") ? name : name + ".zip"
        let target = directory.appending(path: fileName)
        do {
            try FileOps.validate(name: fileName)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw FileOpError(t("Ein Objekt mit dem Namen „%@“ existiert bereits.", fileName))
            }
        } catch {
            alert = AppAlert(title: t("Archivieren fehlgeschlagen"), message: error.localizedDescription)
            return
        }

        let flag = CancelFlag()
        let running = RunningProcess()
        startOperation(flag: flag, process: running,
                       progress: OperationProgress(title: t("Archiviere"), total: 0))
        let parent = items[0].deletingLastPathComponent()
        Task.detached(priority: .userInitiated) {
            let (sizes, totalBytes) = Archiver.inventory(items, flag: flag)
            await MainActor.run {
                self.updateProgress {
                    $0.total = sizes.count
                    $0.totalBytes = totalBytes
                }
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = parent
            process.arguments = ["-r", "-y", compress ? "-6" : "-0", target.path]
                + items.map(\.lastPathComponent) + ["-x"] + Archiver.excluded
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            var failure: String?
            var doneBytes: Int64 = 0, doneFiles = 0
            do {
                try process.run()
                running.set(process)
                if flag.isCancelled { running.interrupt() }
                // zip prints "  adding: path/to/file (deflated 42%)" for every entry.
                var buffer = Data()
                var lastReport = Date.distantPast
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = String(decoding: buffer[..<newline], as: UTF8.self)
                        buffer.removeSubrange(...newline)
                        guard let range = line.range(of: "adding: ") else { continue }
                        var path = String(line[range.upperBound...])
                        if let paren = path.range(of: " (", options: .backwards) { path = String(path[..<paren.lowerBound]) }
                        if let size = sizes[path.precomposedStringWithCanonicalMapping] {
                            doneBytes += size
                            doneFiles += 1
                        }
                        let now = Date()
                        if now.timeIntervalSince(lastReport) > 0.1 {
                            lastReport = now
                            let bytes = doneBytes, files = doneFiles, current = (path as NSString).lastPathComponent
                            await MainActor.run {
                                self.updateProgress {
                                    $0.doneBytes = bytes
                                    $0.done = files
                                    $0.current = current
                                }
                            }
                        }
                    }
                }
                process.waitUntilExit()
                running.set(nil)
                if process.terminationStatus != 0 && !flag.isCancelled {
                    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    failure = message.isEmpty ? t("zip wurde mit Fehler %ld beendet.", Int(process.terminationStatus)) : message
                }
            } catch {
                failure = error.localizedDescription
            }
            if flag.isCancelled || failure != nil { try? FileManager.default.removeItem(at: target) }

            let archiveSize = (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let cancelled = flag.isCancelled, error = failure, total = totalBytes, files = sizes.count
            await MainActor.run {
                self.finishOperation()
                self.left.reload()
                self.right.reload()
                if let error {
                    self.alert = AppAlert(title: t("Archivieren fehlgeschlagen"), message: error)
                } else if cancelled {
                    self.alert = AppAlert(title: t("Abgebrochen"), message: t("Das Archiv wurde nicht erstellt."))
                } else {
                    for pane in [self.left, self.right] where pane.url.path == directory.path {
                        pane.selection = [target.path]
                    }
                    let saved = total > 0 ? max(0, 1 - Double(archiveSize) / Double(total)) : 0
                    self.alert = AppAlert(
                        title: t("Archiv „%@“ erstellt", fileName),
                        message: t("%@ in %@ Dateien → %@ (%@ kleiner)\n%@", Fmt.size(total),
                                   files.formatted(.number.locale(Fmt.locale)), Fmt.size(Int64(archiveSize)),
                                   saved.formatted(.percent.precision(.fractionLength(0)).locale(Fmt.locale)),
                                   directory.path))
                }
            }
        }
    }
}
