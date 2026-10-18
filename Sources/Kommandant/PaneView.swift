import AppKit
import SwiftUI

struct PaneView: View {
    @ObservedObject var pane: PaneModel
    @EnvironmentObject private var app: AppModel
    var focus: FocusState<Side?>.Binding
    @State private var isDropTarget = false

    private var side: Side { pane.side }
    private var isActive: Bool { app.active == side }

    var body: some View {
        VStack(spacing: 0) {
            header
            DriveBar(pane: pane)
            Divider()
            PathBar(url: pane.url) { pane.navigate(to: $0) }
            Divider()
            table
            Divider()
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isDropTarget ? Color.accentColor : .clear, lineWidth: 3)
                .allowsHitTesting(false)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            let move = NSEvent.modifierFlags.contains(.command)
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = await provider.loadFileURL() { urls.append(url) }
                }
                app.dropped(urls, onto: side, move: move)
            }
            return true
        }
        .simultaneousGesture(TapGesture().onEnded { app.active = side })
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: side == .left ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            Text(pane.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            ControlGroup {
                Button { pane.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!pane.canGoBack).help("Zurück")
                Button { pane.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!pane.canGoForward).help("Vorwärts")
                Button { pane.goUp() } label: { Image(systemName: "arrow.up") }
                    .disabled(!pane.canGoUp).help("Übergeordneter Ordner")
            }
            .fixedSize()

            Button { app.requestNewFolder(in: side) } label: { Image(systemName: "folder.badge.plus") }
                .help("Neuer Ordner (F7)")

            placesMenu

            Toggle(isOn: $pane.showHidden) { Image(systemName: pane.showHidden ? "eye" : "eye.slash") }
                .toggleStyle(.button)
                .help("Unsichtbare Dateien anzeigen")

            TextField("Filtern", text: $pane.filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isActive ? Color.accentColor.opacity(0.14) : Color.clear)
        .animation(.easeOut(duration: 0.15), value: isActive)
    }

    private var placesMenu: some View {
        Menu {
            Section("Orte") {
                ForEach(Place.standard) { place in
                    Button { pane.navigate(to: place.url) } label: { Label(place.name, systemImage: place.symbol) }
                }
            }
            Section("Laufwerke") {
                ForEach(app.volumes.volumes) { volume in
                    Button { pane.navigate(to: volume.url) } label: { Label(volume.name, systemImage: volume.symbol) }
                }
            }
            Divider()
            Button("Gleicher Ordner wie andere Seite") { pane.navigate(to: app.pane(side.other).url) }
        } label: {
            Image(systemName: "star")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Orte")
    }

    // MARK: Table

    private var table: some View {
        Table(of: FileItem.self, selection: $pane.selection, sortOrder: $pane.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                NameCell(item: item)
            }
            .width(min: 160, ideal: 280)

            TableColumn("Größe", value: \.sortSize) { item in
                Text(item.isFolder ? "—" : Fmt.size(item.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Geändert", value: \.modified) { item in
                Text(Fmt.date(item.modified)).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 140)

            TableColumn("Art", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 110)
        } rows: {
            ForEach(pane.displayed) { item in
                TableRow(item)
                    .itemProvider { NSItemProvider(object: item.url as NSURL) }
            }
        }
        .focused(focus, equals: side)
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            pane.open(ids)
        }
        .onChange(of: pane.selection) { _, new in
            if !new.isEmpty { app.active = side }
        }
        .overlay {
            if let error = pane.loadError {
                ContentUnavailableView("Kein Zugriff", systemImage: "lock", description: Text(error))
            } else if pane.displayed.isEmpty {
                ContentUnavailableView(pane.filter.isEmpty ? t("Ordner ist leer") : t("Keine Treffer"),
                                       systemImage: pane.filter.isEmpty ? "folder" : "magnifyingglass")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<FileItem.ID>) -> some View {
        let urls = pane.displayed.filter { ids.contains($0.id) }.map(\.url)
        let arrow = side == .left ? "→" : "←"
        if urls.isEmpty {
            Button("Neuer Ordner") { app.requestNewFolder(in: side) }
            Button("Aktualisieren") { pane.reload() }
            AnalyzeStorageButton(title: "Speicherplatz hier analysieren", url: pane.url)
            SyncButton(title: "Mit anderer Seite synchronisieren …", left: pane.url, right: app.pane(side.other).url)
            Button("Im Finder zeigen") { NSWorkspace.shared.open(pane.url) }
        } else {
            Button("Öffnen") { pane.open(ids) }
            Button("Im Finder zeigen") { app.revealInFinder(urls) }
            Divider()
            Button(t("Kopieren %@", arrow)) { app.requestTransfer(.copy, urls: urls, from: side) }
            Button(t("Verschieben %@", arrow)) { app.requestTransfer(.move, urls: urls, from: side) }
            Button(t("Als ZIP archivieren %@ …", arrow)) { app.requestArchive(urls, from: side) }
            Divider()
            Button("Neuer Ordner") { app.requestNewFolder(in: side) }
            Button(t("Neuer Ordner mit Auswahl (%ld)", urls.count)) { app.requestNewFolderWithSelection(urls, in: side) }
            if urls.count == 1 {
                Button("Umbenennen …") { app.requestRename(urls[0]) }
            }
            Button("Pfad kopieren") { app.copyPaths(urls) }
            if urls.count == 1, pane.items.first(where: { $0.url == urls[0] })?.isFolder == true {
                AnalyzeStorageButton(title: "Speicherplatz analysieren", url: urls[0])
                SyncButton(title: "Ordner synchronisieren …", left: urls[0], right: app.pane(side.other).url)
            }
            Divider()
            Button("In den Papierkorb legen") { app.requestTrash(urls) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(summary)
            Spacer()
            if let free = pane.freeSpace {
                Text(t("%@ verfügbar", Fmt.size(free)))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var summary: String {
        let items = pane.displayed
        let selected = items.filter { pane.selection.contains($0.id) }
        guard !selected.isEmpty else { return Fmt.objects(items.count) }
        let bytes = selected.filter { !$0.isFolder }.reduce(Int64(0)) { $0 + $1.size }
        return t("%ld von %ld ausgewählt · %@", selected.count, items.count, Fmt.size(bytes))
    }
}

/// One button per mounted volume; external disks get an eject button.
private struct DriveBar: View {
    @ObservedObject var pane: PaneModel
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let current = app.volumes.volume(for: pane.url.path)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(app.volumes.volumes) { volume in
                    DriveButton(volume: volume, isCurrent: volume.id == current?.id,
                                open: { pane.navigate(to: volume.url) },
                                eject: { app.eject(volume) })
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

private struct DriveButton: View {
    let volume: Volume
    let isCurrent: Bool
    let open: () -> Void
    let eject: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Button(action: open) {
                HStack(spacing: 4) {
                    Image(nsImage: IconCache.icon(for: volume.url.path))
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text(volume.name).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            if volume.isEjectable {
                Button(action: eject) { Image(systemName: "eject.fill").font(.caption2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(t("„%@“ auswerfen", volume.name))
            }
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isCurrent ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05),
                    in: Capsule())
        .help(help)
        .contextMenu {
            Button("Öffnen", action: open)
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([volume.url]) }
            AnalyzeStorageButton(title: "Speicherplatz analysieren", url: volume.url)
            if volume.isEjectable {
                Divider()
                Button("Auswerfen", action: eject)
            }
        }
    }

    private var help: String {
        guard let total = volume.total, let free = volume.free else { return volume.url.path }
        return t("%@: %@ von %@ verfügbar", volume.name, Fmt.size(free), Fmt.size(total))
    }
}

private struct NameCell: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: IconCache.icon(for: item.url.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(item.isHidden ? 0.55 : 1)
            if item.isSymlink {
                Image(systemName: "arrow.turn.up.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PathBar: View {
    let url: URL
    let onSelect: (URL) -> Void

    private var crumbs: [(name: String, url: URL)] {
        var result: [(String, URL)] = []
        var current = url
        while true {
            let name = current.path == "/" ? (Place.volumes.first { $0.url.path == "/" }?.name ?? "/")
                : current.lastPathComponent
            result.insert((name, current), at: 0)
            if current.path == "/" { break }
            current = current.deletingLastPathComponent()
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                        }
                        Button(crumb.name) { onSelect(crumb.url) }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(index == crumbs.count - 1 ? Color.primary.opacity(0.08) : .clear,
                                        in: RoundedRectangle(cornerRadius: 4))
                            .id(index)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .onAppear { proxy.scrollTo(crumbs.count - 1, anchor: .trailing) }
            .onChange(of: url) { _, _ in proxy.scrollTo(crumbs.count - 1, anchor: .trailing) }
        }
    }
}

extension NSItemProvider {
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}
