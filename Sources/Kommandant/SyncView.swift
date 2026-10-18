import AppKit
import SwiftUI

// MARK: - Colors

private let jobColors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .mint]

private extension SyncMode {
    var color: Color {
        switch self {
        case .mirror: .purple
        case .update: .green
        case .twoWay: .blue
        }
    }

    var symbol: String {
        switch self {
        case .mirror: "rectangle.on.rectangle"
        case .update: "arrow.right.circle.fill"
        case .twoWay: "arrow.left.arrow.right.circle.fill"
        }
    }

    var arrow: String {
        switch self {
        case .mirror, .update: "arrow.right"
        case .twoWay: "arrow.left.arrow.right"
        }
    }

    var title: String {
        switch self {
        case .mirror: t("Spiegeln")
        case .update: t("Aktualisieren")
        case .twoWay: t("Zwei-Wege")
        }
    }

    var explanation: String {
        switch self {
        case .mirror: t("Rechts wird eine exakte Kopie von links. Was nur rechts existiert, wird gelöscht.")
        case .update: t("Neue und geänderte Dateien nach rechts kopieren. Es wird nichts gelöscht.")
        case .twoWay: t("Änderungen in beide Richtungen übernehmen. Die neuere Datei gewinnt.")
        }
    }
}

private extension SyncAction {
    var color: Color {
        switch self {
        case .copyToRight: .green
        case .copyToLeft: .blue
        case .deleteLeft, .deleteRight: .red
        case .none: .orange
        }
    }

    var symbol: String {
        switch self {
        case .copyToRight: "arrow.right"
        case .copyToLeft: "arrow.left"
        case .deleteLeft, .deleteRight: "trash"
        case .none: "pause"
        }
    }
}

private extension SyncEntry {
    var actionLabel: String {
        switch action {
        case .copyToRight: left?.isDirectory == true ? t("Ordner nach rechts") : t("Nach rechts")
        case .copyToLeft: right?.isDirectory == true ? t("Ordner nach links") : t("Nach links")
        case .deleteRight: t("Rechts löschen")
        case .deleteLeft: t("Links löschen")
        case .none: category == .conflict ? t("Konflikt") : t("Übersprungen")
        }
    }
}

/// Window for comparing and synchronizing two folders (backups to other disks, mirrors, …).
struct SyncView: View {
    @ObservedObject var model: SyncModel
    @EnvironmentObject private var app: AppModel
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 0) {
            JobSidebar(model: model)
                .frame(width: 230)
            Divider()
            VStack(spacing: 14) {
                header
                FolderPairView(model: model)
                ModePicker(mode: $model.job.mode)
                    .disabled(model.isBusy)
                optionsBar
                StatusArea(model: model)
                SummaryTiles(model: model)
                DifferenceTable(model: model)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1060, minHeight: 720)
        .background(
            LinearGradient(colors: [model.job.mode.color.opacity(0.08), Color.clear], startPoint: .top, endPoint: .center)
        )
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .alert(t("Dateien löschen?"), isPresented: $confirmDelete) {
            Button("Abbrechen", role: .cancel) {}
            Button(t("Synchronisieren"), role: .destructive) { model.synchronize() }
        } message: {
            let deletes = model.summary(.delete)
            Text(model.job.useTrash
                 ? t("%@ werden in den Papierkorb gelegt (%@).", Fmt.objects(deletes.count), Fmt.size(deletes.bytes))
                 : t("%@ werden endgültig gelöscht (%@).", Fmt.objects(deletes.count), Fmt.size(deletes.bytes)))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [jobColor, jobColor.opacity(0.6)], startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                TextField(t("Name der Aufgabe"), text: $model.job.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                Text(lastRunText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.isSaved {
                Button { model.saveCurrent() } label: { Label(t("Als Aufgabe speichern"), systemImage: "star") }
                    .help(t("Speichert Ordner und Einstellungen, um die Synchronisierung später erneut auszuführen."))
            }
        }
    }

    private var jobColor: Color { jobColors[model.job.colorIndex % jobColors.count] }

    private var lastRunText: String {
        guard let last = model.job.lastRun else {
            return model.isSaved ? t("Noch nie ausgeführt") : t("Nicht gespeichert")
        }
        return t("Zuletzt ausgeführt %@", last.formatted(.relative(presentation: .named).locale(Fmt.locale)))
    }

    private var optionsBar: some View {
        HStack(spacing: 14) {
            Picker(t("Vergleich:"), selection: $model.job.compare) {
                Text(t("Datum und Größe")).tag(CompareMethod.dateSize)
                Text(t("Inhalt (langsam)")).tag(CompareMethod.content)
            }
            .fixedSize()
            Toggle(t("Papierkorb statt endgültig löschen"), isOn: $model.job.useTrash)
                .help(t("Gelöschte und ersetzte Dateien landen im Papierkorb des jeweiligen Laufwerks."))
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                TextField(t("Ausschließen, z. B. *.tmp, node_modules"), text: $model.job.excludes)
                    .textFieldStyle(.roundedBorder)
                    .help(t("Muster durch Komma getrennt. * steht für beliebige Zeichen."))
            }
            Spacer(minLength: 0)
            if model.isBusy {
                Button(role: .cancel) { model.cancel() } label: { Label(t("Abbrechen"), systemImage: "stop.fill") }
                    .controlSize(.large)
            } else {
                Button { model.compare() } label: { Label(t("Vergleichen"), systemImage: "magnifyingglass") }
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: .command)
                Button {
                    if model.phase == .compared, model.summary(.delete).count > 0 {
                        confirmDelete = true
                    } else {
                        model.synchronize()
                    }
                } label: {
                    Label(t("Synchronisieren"), systemImage: "arrow.triangle.2.circlepath")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.job.mode.color)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .disabled(false)
    }
}

// MARK: - Sidebar

private struct JobSidebar: View {
    @ObservedObject var model: SyncModel
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(t("Aufgaben")).font(.headline)
                Spacer()
                Button { model.prepare(left: app.activePane.url, right: app.targetPane.url) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(t("Neue Aufgabe aus den beiden Spalten"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 4) {
                    if !model.isSaved {
                        JobRow(name: model.job.name, subtitle: t("Nicht gespeichert"), mode: model.job.mode,
                               color: .gray, selected: true)
                    }
                    ForEach(model.jobs) { job in
                        JobRow(name: job.name, subtitle: subtitle(job), mode: job.mode,
                               color: jobColors[job.colorIndex % jobColors.count],
                               selected: model.selectedJobID == job.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.select(job) }
                            .contextMenu {
                                Button(t("Duplizieren")) { model.duplicate(job) }
                                Button(t("Im Finder zeigen")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([job.leftURL, job.rightURL])
                                }
                                Divider()
                                Button(t("Aufgabe löschen"), role: .destructive) { model.delete(job) }
                            }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
            Text(t("Tipp: Speichere Backups auf externe Laufwerke als Aufgabe und starte sie mit einem Klick."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .disabled(model.isBusy)
    }

    private func subtitle(_ job: SyncJob) -> String {
        guard let last = job.lastRun else { return t("Noch nie ausgeführt") }
        return last.formatted(.relative(presentation: .named).locale(Fmt.locale))
    }
}

private struct JobRow: View {
    let name: String
    let subtitle: String
    let mode: SyncMode
    let color: Color
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(colors: [color, color.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                Image(systemName: mode.arrow)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).fontWeight(selected ? .semibold : .regular)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .background(selected ? color.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Folder pair

private struct FolderPairView: View {
    @ObservedObject var model: SyncModel
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 10) {
            FolderCard(title: t("Quelle (links)"), path: $model.job.leftPath,
                       colors: [Color(red: 0.05, green: 0.6, blue: 0.7), Color(red: 0.1, green: 0.4, blue: 0.85)])
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [model.job.mode.color, model.job.mode.color.opacity(0.6)],
                                             startPoint: .top, endPoint: .bottom))
                        .shadow(color: model.job.mode.color.opacity(0.5), radius: 6)
                    Image(systemName: model.job.mode.arrow)
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(.white)
                }
                .frame(width: 52, height: 52)
                Button { model.swapSides() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.borderless)
                    .help(t("Seiten tauschen"))
            }
            .disabled(model.isBusy)
            FolderCard(title: t("Ziel (rechts)"), path: $model.job.rightPath,
                       colors: [Color(red: 0.55, green: 0.25, blue: 0.85), Color(red: 0.85, green: 0.3, blue: 0.6)])
        }
        .disabled(model.isBusy)
    }
}

private struct FolderCard: View {
    let title: String
    @Binding var path: String
    let colors: [Color]
    @EnvironmentObject private var app: AppModel

    private var url: URL { URL(fileURLWithPath: path) }
    private var exists: Bool { FileManager.default.fileExists(atPath: path) }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: IconCache.icon(for: exists ? path : "/System/Library"))
                .resizable()
                .frame(width: 44, height: 44)
                .shadow(radius: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .opacity(0.8)
                Text(url.lastPathComponent.isEmpty ? path : url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                Text(path)
                    .font(.caption)
                    .opacity(0.85)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(volumeText)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.2), in: Capsule())
            }
            Spacer(minLength: 0)
            Menu {
                Button(t("Ordner wählen …"), action: choose)
                Divider()
                Button(t("Linke Spalte: %@", app.left.title)) { path = app.left.url.path }
                Button(t("Rechte Spalte: %@", app.right.title)) { path = app.right.url.path }
                Section(t("Laufwerke")) {
                    ForEach(app.volumes.volumes) { volume in
                        Button(volume.name) { path = volume.url.path }
                    }
                }
            } label: {
                Image(systemName: "folder.badge.gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tint(.white)
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            if !exists {
                RoundedRectangle(cornerRadius: 14).strokeBorder(.red, lineWidth: 3)
            }
        }
        .shadow(color: colors[0].opacity(0.3), radius: 8, y: 3)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            path = url.path
            return true
        }
    }

    private var volumeText: String {
        guard exists else { return t("Nicht verfügbar") }
        guard let volume = app.volumes.volume(for: path) else { return "" }
        if let free = volume.free { return t("%@ · %@ frei", volume.name, Fmt.size(free)) }
        return volume.name
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = exists ? url : nil
        panel.prompt = t("Auswählen")
        if panel.runModal() == .OK, let chosen = panel.url { path = chosen.path }
    }
}

// MARK: - Mode

private struct ModePicker: View {
    @Binding var mode: SyncMode

    var body: some View {
        HStack(spacing: 10) {
            ForEach(SyncMode.allCases) { option in
                let selected = option == mode
                Button { mode = option } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: option.symbol)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title).font(.headline)
                            Text(option.explanation)
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .opacity(0.85)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selected ? .white : option.color)
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(selected ? AnyShapeStyle(LinearGradient(colors: [option.color, option.color.opacity(0.7)],
                                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                  : AnyShapeStyle(option.color.opacity(0.1)))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(option.color.opacity(selected ? 0 : 0.35))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .animation(.easeOut(duration: 0.15), value: selected)
            }
        }
    }
}

// MARK: - Status

private struct StatusArea: View {
    @ObservedObject var model: SyncModel

    var body: some View {
        if let progress = model.progress {
            progressCard(progress)
        } else if model.phase == .comparing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(t("Vergleiche … %@ Objekte geprüft", model.scanned.formatted(.number.locale(Fmt.locale))))
                    .monospacedDigit()
                Text(model.scanningPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .font(.callout)
        } else if let result = model.result {
            resultBanner(result)
        }
    }

    private func progressCard(_ p: SyncProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t("Synchronisiere …")).font(.headline)
                Spacer()
                Text(p.fraction.formatted(.percent.precision(.fractionLength(0)).locale(Fmt.locale)))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .teal, .blue, .purple], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(14, geo.size.width * p.fraction))
                        .animation(.linear(duration: 0.2), value: p.fraction)
                }
            }
            .frame(height: 14)
            HStack(spacing: 14) {
                Label(t("%@ von %@", Fmt.size(p.doneBytes), Fmt.size(p.totalBytes)), systemImage: "externaldrive")
                Label(t("%ld von %ld Dateien", p.doneFiles, p.totalFiles), systemImage: "doc.on.doc")
                if p.bytesPerSecond > 0 {
                    Label(t("%@/s", Fmt.size(Int64(p.bytesPerSecond))), systemImage: "speedometer")
                    if let remaining = remaining(p) { Label(remaining, systemImage: "clock") }
                }
                Spacer()
                Text(p.current).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            .font(.caption)
            .monospacedDigit()
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func remaining(_ p: SyncProgress) -> String? {
        let seconds = Double(p.totalBytes - p.doneBytes) / p.bytesPerSecond
        guard seconds.isFinite, seconds > 1 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds > 3600 ? [.hour, .minute] : [.minute, .second]
        var calendar = Calendar.current
        calendar.locale = Fmt.locale
        formatter.calendar = calendar
        return formatter.string(from: seconds).map { t("noch %@", $0) }
    }

    private func resultBanner(_ r: SyncResult) -> some View {
        let ok = r.errors.isEmpty && !r.cancelled
        let color: Color = ok ? .green : (r.cancelled ? .gray : .orange)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.seal.fill" : (r.cancelled ? "stop.circle.fill" : "exclamationmark.triangle.fill"))
                .font(.title)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.cancelled ? t("Synchronisierung abgebrochen")
                     : ok ? t("Synchronisierung abgeschlossen") : t("Abgeschlossen mit %ld Fehlern", r.errors.count))
                    .font(.headline)
                Text(t("%ld Dateien kopiert · %ld gelöscht · %@ in %@ s", r.copiedFiles, r.deletedItems, Fmt.size(r.bytes),
                       r.duration.formatted(.number.precision(.fractionLength(1)).locale(Fmt.locale))))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !r.errors.isEmpty {
                    DisclosureGroup(t("Fehler anzeigen")) {
                        ScrollView {
                            Text(r.errors.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 90)
                    }
                    .font(.callout)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.35)))
    }
}

// MARK: - Summary tiles

private struct SummaryTiles: View {
    @ObservedObject var model: SyncModel

    var body: some View {
        HStack(spacing: 10) {
            tile(.all, t("Alle Änderungen"), "list.bullet", .gray)
            tile(.toRight, t("Nach rechts"), "arrow.right.circle.fill", .green)
            tile(.toLeft, t("Nach links"), "arrow.left.circle.fill", .blue)
            tile(.delete, t("Löschen"), "trash.circle.fill", .red)
            tile(.conflict, t("Konflikte / übersprungen"), "exclamationmark.circle.fill", .orange)
            VStack(alignment: .leading, spacing: 2) {
                Label(t("Identisch"), systemImage: "equal.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
                Text(model.equalFiles.formatted(.number.locale(Fmt.locale)))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                Text(t("Dateien")).font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
        .opacity(model.phase == .idle && model.entries.isEmpty ? 0.5 : 1)
    }

    private func tile(_ filter: SyncFilter, _ title: String, _ symbol: String, _ color: Color) -> some View {
        let summary = model.summary(filter)
        let selected = model.filter == filter
        return Button { model.filter = filter } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(selected ? .white : color)
                Text(summary.count.formatted(.number.locale(Fmt.locale)))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                Text(Fmt.size(summary.bytes))
                    .font(.caption)
                    .opacity(0.8)
            }
            .foregroundStyle(selected ? .white : .primary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.1)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Difference list

private struct DifferenceTable: View {
    @ObservedObject var model: SyncModel
    @State private var selection = Set<SyncEntry.ID>()

    var body: some View {
        VStack(spacing: 0) {
            Table(model.visibleEntries, selection: $selection) {
                TableColumn(t("Aktion")) { entry in
                    Label(entry.actionLabel, systemImage: entry.action.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(entry.action.color.gradient, in: Capsule())
                }
                .width(min: 120, ideal: 140, max: 170)
                TableColumn(t("Pfad")) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                        Text(entry.name).lineLimit(1)
                        let folder = (entry.path as NSString).deletingLastPathComponent
                        if !folder.isEmpty {
                            Text(folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                }
                .width(min: 220, ideal: 380)
                TableColumn(t("Links")) { entry in SideCell(info: entry.left, highlight: entry.category == .leftNewer) }
                    .width(min: 120, ideal: 170)
                TableColumn(t("Rechts")) { entry in SideCell(info: entry.right, highlight: entry.category == .rightNewer) }
                    .width(min: 120, ideal: 170)
            }
            .contextMenu(forSelectionType: SyncEntry.ID.self) { ids in
                Button { model.setAction(.copyToRight, for: ids) } label: { Label(t("Nach rechts kopieren"), systemImage: "arrow.right") }
                Button { model.setAction(.copyToLeft, for: ids) } label: { Label(t("Nach links kopieren"), systemImage: "arrow.left") }
                Divider()
                Button { model.setAction(.deleteRight, for: ids) } label: { Label(t("Rechts löschen"), systemImage: "trash") }
                Button { model.setAction(.deleteLeft, for: ids) } label: { Label(t("Links löschen"), systemImage: "trash") }
                Divider()
                Button { model.setAction(.none, for: ids) } label: { Label(t("Ignorieren"), systemImage: "pause") }
            }
            .disabled(model.isBusy)
            .overlay { emptyState }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))

            if !selection.isEmpty, !model.isBusy {
                HStack(spacing: 8) {
                    Text(t("%ld ausgewählt:", selection.count)).foregroundStyle(.secondary)
                    actionButton(.copyToRight, t("Nach rechts"))
                    actionButton(.copyToLeft, t("Nach links"))
                    actionButton(.deleteRight, t("Rechts löschen"))
                    actionButton(.none, t("Ignorieren"))
                    Spacer()
                }
                .font(.callout)
                .padding(.top, 8)
            }
        }
    }

    private func actionButton(_ action: SyncAction, _ title: String) -> some View {
        Button { model.setAction(action, for: selection) } label: {
            Label(title, systemImage: action.symbol)
        }
        .tint(action.color)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.phase == .idle && model.entries.isEmpty && model.result == nil {
            ContentUnavailableView {
                Label(t("Noch nicht verglichen"), systemImage: "magnifyingglass")
            } description: {
                Text(t("Wähle zwei Ordner und klicke auf „Vergleichen“, um die Unterschiede zu sehen."))
            }
        } else if model.phase == .compared && model.entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(LinearGradient(colors: [.green, .teal], startPoint: .top, endPoint: .bottom))
                Text(t("Alles synchron")).font(.title2.weight(.semibold))
                Text(t("%ld identische Dateien", model.equalFiles)).foregroundStyle(.secondary)
            }
        } else if model.phase == .compared && model.visibleEntries.isEmpty {
            ContentUnavailableView(t("Keine Einträge in dieser Kategorie"), systemImage: "line.3.horizontal.decrease.circle")
        }
    }
}

private struct SideCell: View {
    let info: SyncFileInfo?
    let highlight: Bool

    var body: some View {
        if let info {
            VStack(alignment: .leading, spacing: 0) {
                Text(info.isDirectory ? t("%@ · %@", Fmt.size(info.size), Fmt.objects(info.fileCount)) : Fmt.size(info.size))
                    .monospacedDigit()
                if info.modified != .distantPast {
                    Text(Fmt.date(info.modified))
                        .font(.caption)
                        .foregroundStyle(highlight ? Color.green : .secondary)
                        .fontWeight(highlight ? .semibold : .regular)
                }
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}
