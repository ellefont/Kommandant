import AppKit
import SwiftUI

private enum StorageTab: Hashable {
    case folders, largest, cleanup
}

private enum AgeFilter: Hashable, CaseIterable {
    case all, sixMonths, oneYear, twoYears

    var title: String {
        switch self {
        case .all: "Alle"
        case .sixMonths: "Älter als 6 Monate"
        case .oneYear: "Älter als 1 Jahr"
        case .twoYears: "Älter als 2 Jahre"
        }
    }

    var cutoff: Date? {
        let months = [AgeFilter.sixMonths: 6, .oneYear: 12, .twoYears: 24][self]
        return months.flatMap { Calendar.current.date(byAdding: .month, value: -$0, to: .now) }
    }
}

private let barColors: [Color] = [.blue, .purple, .pink, .orange, .yellow, .green, .teal, .indigo]

/// Window for finding out what takes up disk space and what could be deleted.
struct StorageView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var storage: StorageAnalyzer
    @State private var tab: StorageTab = .folders
    @State private var pendingTrash: [StorageNode] = []
    @State private var pendingCleanup: CleanupSuggestion?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            VolumeUsageBar(storage: storage)
            Divider()
            Picker("", selection: $tab) {
                Text("Ordner").tag(StorageTab.folders)
                Text("Größte Dateien").tag(StorageTab.largest)
                Text("Aufräumen").tag(StorageTab.cleanup)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .padding(.vertical, 8)

            Group {
                switch tab {
                case .folders: foldersTab
                case .largest: LargestFilesView(storage: storage, onTrash: { pendingTrash = $0 })
                case .cleanup: CleanupView(storage: storage, onTrash: { pendingTrash = $0 },
                                           onCleanup: { pendingCleanup = $0 })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .environment(\.locale, Fmt.locale)
        .onAppear {
            if storage.root == nil, !storage.isScanning { storage.start() }
        }
        .alert(trashTitle, isPresented: Binding(get: { !pendingTrash.isEmpty }, set: { if !$0 { pendingTrash = [] } })) {
            Button("Abbrechen", role: .cancel) { pendingTrash = [] }
            Button("In den Papierkorb", role: .destructive) {
                storage.moveToTrash(pendingTrash)
                pendingTrash = []
            }
        } message: {
            Text("\(Fmt.size(pendingTrash.reduce(0) { $0 + $1.size })) – der Platz wird erst frei, wenn du den Papierkorb leerst.")
        }
        .alert(cleanupTitle, isPresented: Binding(get: { pendingCleanup != nil }, set: { if !$0 { pendingCleanup = nil } })) {
            Button("Abbrechen", role: .cancel) { pendingCleanup = nil }
            Button(pendingCleanup?.action == .emptyTrash ? "Papierkorb leeren" : "Endgültig löschen", role: .destructive) {
                if let suggestion = pendingCleanup { storage.perform(suggestion) }
                pendingCleanup = nil
            }
        } message: {
            Text("Dadurch werden \(Fmt.size(pendingCleanup?.size ?? 0)) frei. Dieser Vorgang kann nicht widerrufen werden.")
        }
        .alert(item: $storage.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    private var trashTitle: String {
        pendingTrash.count == 1 ? "„\(pendingTrash[0].name)“ in den Papierkorb legen?"
            : "\(Fmt.objects(pendingTrash.count)) in den Papierkorb legen?"
    }

    private var cleanupTitle: String {
        guard let s = pendingCleanup else { return "" }
        return s.action == .emptyTrash ? "Papierkorb leeren?" : "Inhalt von „\(s.title)“ endgültig löschen?"
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.pie.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Speicherplatz").font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Menu {
                Section("Laufwerke") {
                    ForEach(app.volumes.volumes) { volume in
                        Button { storage.analyze(volume.url) } label: { Label(volume.name, systemImage: volume.symbol) }
                    }
                }
                Section("Ordner") {
                    Button("Benutzerordner") { storage.analyze(FileManager.default.homeDirectoryForCurrentUser) }
                    Button("Linke Spalte: \(app.left.title)") { storage.analyze(app.left.url) }
                    Button("Rechte Spalte: \(app.right.title)") { storage.analyze(app.right.url) }
                    Button("Ordner wählen …", action: chooseFolder)
                }
            } label: {
                Label(storage.rootName, systemImage: "scope")
            }
            .fixedSize()
            .help("Was soll analysiert werden?")

            if storage.isScanning {
                Button("Abbrechen") { storage.cancel() }
            } else {
                Button { storage.start() } label: { Label("Analysieren", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        if storage.isScanning {
            return "\(storage.scannedFiles.formatted(.number.locale(Fmt.locale))) Dateien … \(storage.scanningPath)"
        }
        guard let root = storage.root else { return "Noch nicht analysiert" }
        var text = "\(Fmt.size(root.size)) in \(root.fileCount.formatted(.number.locale(Fmt.locale))) Dateien"
        text += " · \(String(format: "%.1f", storage.duration)) s"
        if storage.inaccessible > 0 { text += " · \(storage.inaccessible) Ordner ohne Zugriff" }
        return text
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Analysieren"
        if panel.runModal() == .OK, let url = panel.url { storage.analyze(url) }
    }

    // MARK: Folders tab

    @ViewBuilder
    private var foldersTab: some View {
        if let current = storage.current {
            FolderBrowser(storage: storage, node: current, onTrash: { pendingTrash = $0 })
        } else if storage.isScanning {
            VStack(spacing: 12) {
                ProgressView()
                Text("Analysiere „\(storage.rootName)“ …").font(.headline)
                Text("\(storage.scannedFiles.formatted(.number.locale(Fmt.locale))) Dateien gezählt")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            ContentUnavailableView {
                Label("Noch keine Analyse", systemImage: "chart.pie")
            } actions: {
                Button("Analysieren") { storage.start() }
            }
        }
    }
}

// MARK: - Volume usage

private struct VolumeUsageBar: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var storage: StorageAnalyzer

    var body: some View {
        if let volume = app.volumes.volume(for: storage.rootURL.path), let total = volume.total, let free = volume.free,
           total > 0 {
            let used = total - free
            let analyzed = min(storage.root?.size ?? 0, used)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(volume.name, systemImage: volume.symbol).font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(Fmt.size(used)) von \(Fmt.size(total)) belegt · ")
                        .foregroundStyle(.secondary)
                    + Text("\(Fmt.size(free)) frei").foregroundStyle(free < total / 10 ? .red : .green).bold()
                }
                .font(.callout)
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.accentColor.opacity(0.35))
                            .frame(width: w * CGFloat(used) / CGFloat(total))
                        Capsule().fill(Color.accentColor)
                            .frame(width: w * CGFloat(analyzed) / CGFloat(total))
                    }
                }
                .frame(height: 10)
                if storage.root != nil {
                    HStack(spacing: 14) {
                        legend(Color.accentColor, "„\(storage.rootName)“: \(Fmt.size(analyzed))")
                        legend(Color.accentColor.opacity(0.35), "Rest belegt: \(Fmt.size(used - analyzed))")
                        legend(Color.primary.opacity(0.08), "Frei")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}

// MARK: - Folder browser

private struct FolderBrowser: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var storage: StorageAnalyzer
    let node: StorageNode
    let onTrash: ([StorageNode]) -> Void
    @State private var selection = Set<StorageNode.ID>()

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            StackedBar(node: node)
                .frame(height: 22)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            Divider()
            List(selection: $selection) {
                ForEach(node.children) { child in
                    StorageRow(node: child, parentSize: node.size, color: color(for: child))
                        .tag(child.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: StorageNode.ID.self) { ids in
                NodeMenu(nodes: nodes(ids), storage: storage, onTrash: onTrash)
            } primaryAction: { ids in
                if let child = nodes(ids).first, child.isDirectory, !child.children.isEmpty {
                    storage.current = child
                    selection = []
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting(nodes(ids).map(\.url))
                }
            }
            Divider()
            HStack {
                Text("Doppelklick öffnet einen Ordner. Rechtsklick für weitere Aktionen.")
                    .foregroundStyle(.secondary)
                Spacer()
                let selected = nodes(selection).filter { !$0.isAggregate }
                if !selected.isEmpty {
                    Text("\(Fmt.objects(selected.count)) · \(Fmt.size(selected.reduce(0) { $0 + $1.size }))")
                    Button("In den Papierkorb …", role: .destructive) { onTrash(selected) }
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func nodes(_ ids: Set<StorageNode.ID>) -> [StorageNode] {
        node.children.filter { ids.contains($0.id) }
    }

    private func color(for child: StorageNode) -> Color {
        guard let index = node.children.prefix(barColors.count).firstIndex(where: { $0 === child }) else {
            return .gray
        }
        return barColors[index]
    }

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            Button { storage.current = node.parent ?? node } label: { Image(systemName: "chevron.left") }
                .disabled(node.parent == nil)
                .keyboardShortcut(.upArrow, modifiers: .command)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(node.ancestors.enumerated()), id: \.offset) { index, ancestor in
                        if index > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                        Button(ancestor.name) {
                            storage.current = ancestor
                            selection = []
                        }
                        .buttonStyle(.plain)
                        .fontWeight(ancestor === node ? .semibold : .regular)
                    }
                }
            }
            Spacer()
            Text(Fmt.size(node.size)).font(.headline).monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// Horizontal bar split by the largest children of a folder.
private struct StackedBar: View {
    let node: StorageNode

    var body: some View {
        GeometryReader { geo in
            let total = max(node.size, 1)
            let top = Array(node.children.prefix(barColors.count))
            let rest = node.size - top.reduce(0) { $0 + $1.size }
            HStack(spacing: 1) {
                ForEach(Array(top.enumerated()), id: \.offset) { index, child in
                    Rectangle()
                        .fill(barColors[index].gradient)
                        .frame(width: max(0, geo.size.width * CGFloat(child.size) / CGFloat(total) - 1))
                        .help("\(child.name): \(Fmt.size(child.size))")
                }
                if rest > 0 {
                    Rectangle().fill(Color.gray.opacity(0.4))
                        .help("Sonstiges: \(Fmt.size(rest))")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

private struct StorageRow: View {
    let node: StorageNode
    let parentSize: Int64
    let color: Color

    private var fraction: Double { parentSize > 0 ? Double(node.size) / Double(parentSize) : 0 }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if node.isAggregate {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                } else {
                    Image(nsImage: IconCache.icon(for: node.url.path)).resizable()
                }
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 180, alignment: .leading)

            Spacer(minLength: 12)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color.gradient).frame(width: geo.size.width * fraction)
                }
            }
            .frame(width: 160, height: 7)

            Text(fraction.formatted(.percent.precision(.fractionLength(1)).locale(Fmt.locale)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
            Text(Fmt.size(node.size))
                .monospacedDigit()
                .fontWeight(fraction > 0.2 ? .semibold : .regular)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if node.isDirectory || node.isAggregate {
            parts.append("\(node.fileCount.formatted(.number.locale(Fmt.locale))) Dateien")
        }
        if node.modified != .distantPast {
            parts.append("geändert \(node.modified.formatted(.relative(presentation: .named).locale(Fmt.locale)))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct NodeMenu: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow
    let nodes: [StorageNode]
    @ObservedObject var storage: StorageAnalyzer
    let onTrash: ([StorageNode]) -> Void

    var body: some View {
        let real = nodes.filter { !$0.isAggregate }
        if let first = real.first {
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting(real.map(\.url)) }
            Button("Im Kommandant zeigen") { show(first, in: app.activePane, reveal: true) }
            Button("In linker Spalte zeigen") { show(first, in: app.left) }
            Button("In rechter Spalte zeigen") { show(first, in: app.right) }
            if first.isDirectory {
                Button("Diesen Ordner analysieren") { storage.analyze(first.url) }
            }
            Button("Pfad kopieren") { app.copyPaths(real.map(\.url)) }
            Divider()
            Button("In den Papierkorb …") { onTrash(real) }
        }
    }

    /// `reveal` opens the enclosing folder with the item selected (like "Im Finder zeigen").
    private func show(_ node: StorageNode, in pane: PaneModel, reveal: Bool = false) {
        if node.isDirectory, !reveal {
            pane.navigate(to: node.url)
        } else {
            pane.navigate(to: node.url.deletingLastPathComponent(), select: node.url.path)
        }
        app.active = pane.side
        openWindow(id: "main")
    }
}

// MARK: - Largest files

private struct LargestFilesView: View {
    @ObservedObject var storage: StorageAnalyzer
    let onTrash: ([StorageNode]) -> Void
    @State private var age: AgeFilter = .all
    @State private var selection = Set<StorageNode.ID>()

    private var files: [StorageNode] {
        guard let cutoff = age.cutoff else { return storage.largestFiles }
        return storage.largestFiles.filter { $0.modified < cutoff }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Zeitraum", selection: $age) {
                    ForEach(AgeFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Spacer()
                Text("\(Fmt.objects(files.count)) · zusammen \(Fmt.size(files.reduce(0) { $0 + $1.size }))")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            Table(files, selection: $selection) {
                TableColumn("Name") { node in
                    HStack(spacing: 6) {
                        Image(nsImage: IconCache.icon(for: node.url.path)).resizable().frame(width: 16, height: 16)
                        Text(node.name).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("Größe") { node in
                    Text(Fmt.size(node.size)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 90)
                TableColumn("Geändert") { node in
                    Text(node.modified.formatted(.relative(presentation: .named).locale(Fmt.locale)))
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 120)
                TableColumn("Ordner") { node in
                    Text(abbreviate(node.url.deletingLastPathComponent().path))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .contextMenu(forSelectionType: StorageNode.ID.self) { ids in
                NodeMenu(nodes: files.filter { ids.contains($0.id) }, storage: storage, onTrash: onTrash)
            } primaryAction: { ids in
                NSWorkspace.shared.activateFileViewerSelecting(files.filter { ids.contains($0.id) }.map(\.url))
            }
            .overlay {
                if files.isEmpty, !storage.isScanning {
                    ContentUnavailableView("Keine großen Dateien gefunden", systemImage: "doc")
                } else if storage.isScanning {
                    ProgressView("Analysiere …")
                }
            }

            Divider()
            HStack {
                Text("Doppelklick zeigt die Datei im Finder.").foregroundStyle(.secondary)
                Spacer()
                let selected = files.filter { selection.contains($0.id) }
                if !selected.isEmpty {
                    Text("\(Fmt.objects(selected.count)) · \(Fmt.size(selected.reduce(0) { $0 + $1.size }))")
                    Button("In den Papierkorb …", role: .destructive) { onTrash(selected) }
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

private func abbreviate(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

// MARK: - Cleanup

private struct CleanupView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var storage: StorageAnalyzer
    let onTrash: ([StorageNode]) -> Void
    let onCleanup: (CleanupSuggestion) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Vorschläge", subtitle: "Bekannte Orte, an denen sich oft Platz gewinnen lässt.") {
                    if storage.isLoadingSuggestions && storage.suggestions.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(storage.suggestions) { suggestion in
                        SuggestionCard(suggestion: suggestion, onCleanup: onCleanup) {
                            app.activePane.navigate(to: suggestion.url)
                            openWindow(id: "main")
                        }
                    }
                }

                if !storage.devFolders.isEmpty {
                    section("Entwickler-Ordner",
                            subtitle: "Abhängigkeiten und Build-Ordner in „\(storage.rootName)“. Lassen sich jederzeit neu erzeugen (npm install, swift build, …).") {
                        ForEach(storage.devFolders.prefix(50)) { folder in
                            HStack(spacing: 10) {
                                Image(systemName: "shippingbox").foregroundStyle(.orange).frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(folder.name).fontWeight(.medium)
                                    Text(abbreviate(folder.url.deletingLastPathComponent().path))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                                Spacer()
                                Text(Fmt.size(folder.size)).monospacedDigit()
                                Button("In den Papierkorb …") { onTrash([folder]) }
                                    .controlSize(.small)
                            }
                            .padding(10)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                            .contextMenu { NodeMenu(nodes: [folder], storage: storage, onTrash: onTrash) }
                        }
                    }
                }
            }
            .padding(14)
        }
        .onAppear { if storage.suggestions.isEmpty { storage.loadSuggestions() } }
    }

    private func section<Content: View>(_ title: String, subtitle: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            content()
        }
    }
}

private struct SuggestionCard: View {
    let suggestion: CleanupSuggestion
    let onCleanup: (CleanupSuggestion) -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: suggestion.symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(suggestion.title).font(.headline)
                    Spacer()
                    Text(Fmt.size(suggestion.size))
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(suggestion.size > 1_000_000_000 ? .orange : .primary)
                }
                Text(suggestion.detail).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Im Kommandant zeigen", action: onReveal)
                    Button("Im Finder zeigen") { NSWorkspace.shared.open(suggestion.url) }
                    switch suggestion.action {
                    case .emptyTrash:
                        Button("Papierkorb leeren …", role: .destructive) { onCleanup(suggestion) }
                    case .deleteContents:
                        Button("Inhalt löschen …", role: .destructive) { onCleanup(suggestion) }
                    case .review:
                        EmptyView()
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
