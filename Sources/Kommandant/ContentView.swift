import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppModel
    @FocusState private var focus: Side?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                PaneView(pane: app.left, focus: $focus)
                    .frame(minWidth: 380)
                PaneView(pane: app.right, focus: $focus)
                    .frame(minWidth: 380)
            }
            Divider()
            ActionBar()
        }
        .frame(minWidth: 820, minHeight: 480)
        .onAppear { focus = app.active }
        .onChange(of: app.active) { _, new in focus = new }
        .onChange(of: focus) { _, new in if let new { app.active = new } }
        .sheet(item: $app.sheet) { sheet in
            switch sheet {
            case .transfer(let transfer):
                TransferSheet(transfer: transfer)
            case .rename(let url):
                NameSheet(title: "Umbenennen", message: "Neuer Name für „\(url.lastPathComponent)“:",
                          initial: url.lastPathComponent, confirm: "Umbenennen") { app.rename(url, to: $0) }
            case .newFolder(let dir):
                NameSheet(title: "Neuer Ordner", message: "Ordner erstellen in „\(dir.lastPathComponent)“:",
                          initial: "Neuer Ordner", confirm: "Erstellen") { app.createFolder(in: dir, named: $0) }
            case .trash(let urls):
                TrashSheet(urls: urls)
            }
        }
        .alert(item: $app.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }
}

struct ActionBar: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 6) {
            FKeyButton(key: "F2", title: "Umbenennen", symbol: "pencil") { app.requestRename() }
            FKeyButton(key: "F5", title: "Kopieren", symbol: "doc.on.doc") { app.requestTransfer(.copy) }
            FKeyButton(key: "F6", title: "Verschieben", symbol: "arrow.right.doc.on.clipboard") {
                app.requestTransfer(.move)
            }
            FKeyButton(key: "F7", title: "Neuer Ordner", symbol: "folder.badge.plus") { app.requestNewFolder() }
            FKeyButton(key: "F8", title: "Papierkorb", symbol: "trash") { app.requestTrash() }
            FKeyButton(key: "F9", title: "Speicherplatz", symbol: "chart.pie") {
                app.storage.analyze(app.activePane.url)
                openWindow(id: "storage")
            }

            Spacer(minLength: 12)

            if let progress = app.progress {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(progress.title) \(progress.done + 1) von \(progress.total): \(progress.current)")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                }
                .frame(maxWidth: 260)
                Button("Abbrechen") { app.cancelOperation() }
                    .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Text("Ziel")
                        .foregroundStyle(.secondary)
                    Image(systemName: app.active == .left ? "arrow.right" : "arrow.left")
                        .foregroundStyle(Color.accentColor)
                    Text(app.targetPane.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout)
                .help("Kopieren und Verschieben gehen in den Ordner der anderen Seite. ⇥ wechselt die Seite.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

private struct FKeyButton: View {
    let key: String
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(key)
                    .font(.caption2.weight(.bold).monospaced())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                Label(title, systemImage: symbol)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

// MARK: Sheets

struct TransferSheet: View {
    let transfer: PendingTransfer
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var policy: ConflictPolicy = .keepBoth

    private var subject: String {
        transfer.sources.count == 1 ? "„\(transfer.sources[0].lastPathComponent)“" : Fmt.objects(transfer.sources.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: transfer.kind.symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(subject) \(transfer.kind == .copy ? "kopieren" : "verschieben")")
                        .font(.headline)
                        .lineLimit(2)
                    Text("nach \(transfer.destination.path)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            if transfer.sources.count > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(transfer.sources, id: \.self) { url in
                            Label(url.lastPathComponent, systemImage: "doc")
                                .labelStyle(IconOnlyIfNeeded(url: url))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }

            if !transfer.conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(transfer.conflicts.count == 1
                          ? "„\(transfer.conflicts[0])“ existiert bereits am Ziel."
                          : "\(transfer.conflicts.count) Objekte existieren bereits am Ziel.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Picker("Vorhandene Objekte:", selection: $policy) {
                        Text("Beide behalten").tag(ConflictPolicy.keepBoth)
                        Text("Ersetzen (alte in den Papierkorb)").tag(ConflictPolicy.replace)
                        Text("Überspringen").tag(ConflictPolicy.skip)
                    }
                    .pickerStyle(.radioGroup)
                }
            }

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(transfer.kind.verb) {
                    dismiss()
                    app.run(transfer, policy: policy)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct IconOnlyIfNeeded: LabelStyle {
    let url: URL

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: IconCache.icon(for: url.path)).resizable().frame(width: 16, height: 16)
            configuration.title.lineLimit(1).truncationMode(.middle)
        }
    }
}

struct NameSheet: View {
    let title: String
    let message: String
    let initial: String
    let confirm: String
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary).lineLimit(2)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirm, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            name = initial
            focused = true
        }
    }

    private func submit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        dismiss()
        if name != initial || confirm != "Umbenennen" { onConfirm(name) }
    }
}

struct TrashSheet: View {
    let urls: [URL]
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(urls.count == 1 ? "„\(urls[0].lastPathComponent)“ in den Papierkorb legen?"
                         : "\(Fmt.objects(urls.count)) in den Papierkorb legen?")
                        .font(.headline)
                        .lineLimit(2)
                    Text("Du kannst sie im Papierkorb wiederherstellen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("In den Papierkorb", role: .destructive) {
                    dismiss()
                    app.trash(urls)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
