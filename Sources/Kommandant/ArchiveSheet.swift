import AppKit
import SwiftUI

/// Confirmation for "Als ZIP archivieren": archive name, destination (usually another disk), compression.
struct ArchiveSheet: View {
    let items: [URL]
    @State var destination: URL
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var compress = true
    @State private var sourceSize: Int64?
    @FocusState private var nameFocused: Bool

    init(items: [URL], destination: URL) {
        self.items = items
        _destination = State(initialValue: destination)
    }

    private var sourceVolume: Volume? { app.volumes.volume(for: items[0].path) }
    private var targetVolume: Volume? { app.volumes.volume(for: destination.path) }
    private var sameDisk: Bool { sourceVolume?.id == targetVolume?.id }
    private var notEnoughSpace: Bool {
        guard let free = targetVolume?.free, let size = sourceSize else { return false }
        return size > free
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(items.count == 1 ? t("„%@“ als ZIP archivieren", items[0].lastPathComponent)
                         : t("%@ als ZIP archivieren", Fmt.objects(items.count)))
                        .font(.headline)
                        .lineLimit(2)
                    Text(sourceSize.map { t("Größe: %@", Fmt.size($0)) } ?? t("Größe wird berechnet …"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(t("Name des Archivs")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    TextField(t("Name"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit(start)
                    Text(".zip").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(t("Speichern in")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Image(nsImage: IconCache.icon(for: destination.path))
                        .resizable()
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(targetVolume?.name ?? destination.lastPathComponent).fontWeight(.medium)
                        Text(destination.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                    if let free = targetVolume?.free {
                        Text(t("%@ frei", Fmt.size(free)))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(notEnoughSpace ? .red : .secondary)
                    }
                    Menu {
                        Button(t("Linke Spalte: %@", app.left.title)) { setDestination(app.left.url) }
                        Button(t("Rechte Spalte: %@", app.right.title)) { setDestination(app.right.url) }
                        Section(t("Laufwerke")) {
                            ForEach(app.volumes.volumes) { volume in
                                Button(volume.name) { setDestination(volume.url) }
                            }
                        }
                        Divider()
                        Button(t("Ordner wählen …"), action: chooseFolder)
                    } label: {
                        Text(t("Ändern"))
                    }
                    .fixedSize()
                }
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

                if notEnoughSpace {
                    Label(t("Auf dem Ziel ist nicht genug Platz frei."), systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                } else if sameDisk {
                    Label(t("Das Ziel liegt auf demselben Laufwerk wie die Quelle – für ein Backup besser ein anderes Laufwerk wählen."),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(t("Komprimieren (aus = schneller, sinnvoll für Fotos und Videos)"), isOn: $compress)

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(t("Archivieren"), action: start)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            name = Archiver.defaultName(in: destination)
            nameFocused = true
        }
        .task {
            let items = items
            let total = await Task.detached { Archiver.inventory(items).total }.value
            sourceSize = total
        }
    }

    private func setDestination(_ url: URL) {
        let wasDefault = name == Archiver.defaultName(in: destination)
        destination = url
        if wasDefault { name = Archiver.defaultName(in: url) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        panel.prompt = t("Auswählen")
        if panel.runModal() == .OK, let url = panel.url { setDestination(url) }
    }

    private func start() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        dismiss()
        app.archive(items, to: destination, name: trimmed, compress: compress)
    }
}
