import AppKit
import Foundation

/// A saved folder pair with its settings (e.g. "Fotos → USB-Backup").
struct SyncJob: Codable, Identifiable, Hashable {
    static let defaultExcludes =
        ".DS_Store, .Trashes, .Spotlight-V100, .fseventsd, .TemporaryItems, .DocumentRevisions-V100"

    var id = UUID()
    var name: String
    var leftPath: String
    var rightPath: String
    var mode: SyncMode = .update
    var compare: CompareMethod = .dateSize
    var excludes: String = SyncJob.defaultExcludes
    var useTrash = true
    var colorIndex = 0
    var lastRun: Date?

    var leftURL: URL { URL(fileURLWithPath: leftPath) }
    var rightURL: URL { URL(fileURLWithPath: rightPath) }
}

struct SyncProgress {
    var totalBytes: Int64
    var totalFiles: Int
    var doneBytes: Int64 = 0
    var doneFiles = 0
    var current = ""
    let started = Date()

    var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
    var bytesPerSecond: Double {
        let elapsed = Date().timeIntervalSince(started)
        return elapsed > 0.5 ? Double(doneBytes) / elapsed : 0
    }
}

/// Which actions the difference list shows.
enum SyncFilter: Hashable {
    case all, toRight, toLeft, delete, conflict

    func matches(_ entry: SyncEntry) -> Bool {
        switch self {
        case .all: true
        case .toRight: entry.action == .copyToRight
        case .toLeft: entry.action == .copyToLeft
        case .delete: entry.action.isDelete
        case .conflict: entry.action == .none
        }
    }
}

@MainActor
final class SyncModel: ObservableObject {
    enum Phase: Equatable {
        case idle, comparing, compared, syncing, finished
    }

    @Published private(set) var jobs: [SyncJob] = []
    /// The saved job being edited, nil for an unsaved ad-hoc pair.
    @Published private(set) var selectedJobID: UUID?
    @Published var job: SyncJob {
        didSet { jobChanged(from: oldValue) }
    }
    @Published private(set) var phase: Phase = .idle
    @Published var entries: [SyncEntry] = []
    @Published private(set) var equalFiles = 0
    @Published private(set) var scanned = 0
    @Published private(set) var scanningPath = ""
    @Published private(set) var progress: SyncProgress?
    @Published private(set) var result: SyncResult?
    @Published var filter: SyncFilter = .all
    @Published var alert: AppAlert?
    private var flag: CancelFlag?
    private static let defaultsKey = "syncAufgaben"

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        job = SyncJob(name: t("Neue Aufgabe"), leftPath: home.path, rightPath: home.path)
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([SyncJob].self, from: data) {
            jobs = saved
        }
    }

    var isBusy: Bool { phase == .comparing || phase == .syncing }
    var isSaved: Bool { selectedJobID != nil }
    var visibleEntries: [SyncEntry] { entries.filter(filter.matches) }

    func summary(_ filter: SyncFilter) -> (count: Int, bytes: Int64) {
        let matching = entries.filter(filter.matches)
        return (matching.reduce(0) { $0 + $1.fileCount }, matching.reduce(0) { $0 + $1.bytes })
    }

    // MARK: Jobs

    /// Starts an unsaved pair, e.g. from the two panes of the main window.
    func prepare(left: URL, right: URL) {
        guard !isBusy else { return }
        selectedJobID = nil
        job = SyncJob(name: "\(left.lastPathComponent) → \(right.lastPathComponent)",
                      leftPath: left.path, rightPath: right.path, colorIndex: jobs.count)
    }

    func select(_ saved: SyncJob) {
        guard !isBusy else { return }
        selectedJobID = saved.id
        job = saved
    }

    func saveCurrent() {
        if selectedJobID == nil {
            job.id = UUID()
            job.colorIndex = jobs.count
            jobs.append(job)
            selectedJobID = job.id
        }
        persist()
    }

    func delete(_ saved: SyncJob) {
        jobs.removeAll { $0.id == saved.id }
        if selectedJobID == saved.id { selectedJobID = nil }
        persist()
    }

    func duplicate(_ saved: SyncJob) {
        var copy = saved
        copy.id = UUID()
        copy.name = t("%@ (Kopie)", saved.name)
        copy.lastRun = nil
        copy.colorIndex = jobs.count
        jobs.append(copy)
        persist()
    }

    func swapSides() {
        let left = job.leftPath
        job.leftPath = job.rightPath
        job.rightPath = left
    }

    private func jobChanged(from old: SyncJob) {
        if old.leftPath != job.leftPath || old.rightPath != job.rightPath || old.compare != job.compare
            || old.excludes != job.excludes || old.id != job.id {
            reset()
        } else if old.mode != job.mode {
            applyDefaultActions()
        }
        if let id = selectedJobID, let index = jobs.firstIndex(where: { $0.id == id }), jobs[index] != job {
            jobs[index] = job
            persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(jobs) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func reset() {
        guard !isBusy else { return }
        entries = []
        equalFiles = 0
        result = nil
        phase = .idle
        filter = .all
    }

    private func applyDefaultActions() {
        for index in entries.indices {
            entries[index].action = SyncEntry.defaultAction(for: entries[index].category, mode: job.mode)
        }
    }

    func setAction(_ action: SyncAction, for ids: Set<SyncEntry.ID>) {
        for index in entries.indices where ids.contains(entries[index].id) {
            let entry = entries[index]
            // Only offer what is possible: copying needs a source, deleting needs a target.
            switch action {
            case .copyToRight, .deleteLeft: if entry.left == nil { continue }
            case .copyToLeft, .deleteRight: if entry.right == nil { continue }
            case .none: break
            }
            entries[index].action = action
        }
    }

    // MARK: Compare & sync

    func compare(thenSync: Bool = false, keepResult: Bool = false) {
        guard !isBusy else { return }
        guard job.leftPath != job.rightPath else {
            alert = AppAlert(title: t("Gleicher Ordner"), message: t("Links und rechts ist derselbe Ordner ausgewählt."))
            return
        }
        let flag = CancelFlag()
        self.flag = flag
        phase = .comparing
        if !keepResult { result = nil }
        scanned = 0
        let current = job
        Task.detached(priority: .userInitiated) {
            let comparer = SyncComparer(left: current.leftURL, right: current.rightURL, method: current.compare,
                                        filter: ExcludeFilter(current.excludes), flag: flag) { count, path in
                Task { @MainActor [weak self] in
                    guard let self, self.flag === flag else { return }
                    self.scanned = count
                    self.scanningPath = path
                }
            }
            let outcome = Result { try comparer.compare() }
            let equal = comparer.equalFiles
            await MainActor.run {
                guard self.flag === flag else { return }
                self.flag = nil
                switch outcome {
                case .success(var found) where !flag.isCancelled:
                    for index in found.indices {
                        found[index].action = SyncEntry.defaultAction(for: found[index].category, mode: current.mode)
                    }
                    self.entries = found
                    self.equalFiles = equal
                    self.phase = .compared
                    if thenSync { self.synchronize() }
                case .success:
                    self.phase = .idle
                case .failure(let error):
                    self.phase = .idle
                    self.alert = AppAlert(title: t("Vergleich fehlgeschlagen"), message: error.localizedDescription)
                }
            }
        }
    }

    func synchronize() {
        guard !isBusy else { return }
        guard phase == .compared else { return compare(thenSync: true) }
        let work = entries.filter { $0.action != .none }
        guard !work.isEmpty else {
            result = SyncResult()
            phase = .finished
            return
        }
        let flag = CancelFlag()
        self.flag = flag
        phase = .syncing
        let copies = work.filter { !$0.action.isDelete }
        progress = SyncProgress(totalBytes: copies.reduce(0) { $0 + $1.bytes },
                                totalFiles: copies.reduce(0) { $0 + $1.fileCount })
        let current = job
        Task.detached(priority: .userInitiated) {
            let executor = SyncExecutor(left: current.leftURL, right: current.rightURL, useTrash: current.useTrash,
                                        filter: ExcludeFilter(current.excludes), flag: flag) { bytes, files, name in
                Task { @MainActor [weak self] in
                    guard let self, self.flag === flag else { return }
                    self.progress?.doneBytes = bytes
                    self.progress?.doneFiles = files
                    if !name.isEmpty { self.progress?.current = name }
                }
            }
            let result = executor.run(work)
            await MainActor.run {
                self.flag = nil
                self.progress = nil
                self.phase = .idle
                self.result = result
                self.job.lastRun = Date()
                // Compare again so the list shows what (if anything) is still different.
                self.compare(keepResult: true)
            }
        }
    }

    func cancel() {
        flag?.cancel()
    }
}
