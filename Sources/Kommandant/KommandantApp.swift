import AppKit
import SwiftUI

@main
struct KommandantApp: App {
    @StateObject private var app = AppModel()

    init() {
        // Also works when launched as a bare binary via `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Kommandant \(appVersion)", id: "main") {
            ContentView()
                .environmentObject(app)
                .environment(\.locale, Fmt.locale)
                .onAppear { NSApplication.shared.activate() }
                .toolbar { ToolbarItem(placement: .principal) { WindowTitle(title: "Kommandant \(appVersion)") } }
        }
        .defaultSize(width: 1180, height: 720)
        .windowToolbarStyle(.unified(showsTitle: false))

        Window("Speicherplatz – Kommandant \(appVersion)", id: "storage") {
            StorageView(storage: app.storage)
                .environmentObject(app)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        WindowTitle(title: "Speicherplatz – Kommandant \(appVersion)")
                    }
                }
        }
        .defaultSize(width: 980, height: 720)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neuer Ordner") { app.requestNewFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("Dateien") {
                Button("Öffnen") { app.activePane.open(app.activePane.selection) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Im Finder zeigen") { app.revealInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Umbenennen …") { app.requestRename() }
                    .keyboardShortcut(fKey(2), modifiers: [])
                Button("Kopieren auf andere Seite") { app.requestTransfer(.copy) }
                    .keyboardShortcut(fKey(5), modifiers: [])
                Button("Verschieben auf andere Seite") { app.requestTransfer(.move) }
                    .keyboardShortcut(fKey(6), modifiers: [])
                Button("Neuer Ordner …") { app.requestNewFolder() }
                    .keyboardShortcut(fKey(7), modifiers: [])
                Button("Neuer Ordner mit Auswahl …") { app.requestNewFolderWithSelection() }
                    .keyboardShortcut("n", modifiers: [.command, .control])
                Button("In den Papierkorb legen") { app.requestTrash() }
                    .keyboardShortcut(fKey(8), modifiers: [])
                AnalyzeStorageButton(title: "Speicherplatz analysieren", url: nil)
                    .environmentObject(app)
                    .keyboardShortcut(fKey(9), modifiers: [])
                Divider()
                Button("Pfad kopieren") { app.copyPaths(app.activePane.selectedURLs) }
                    .keyboardShortcut("c", modifiers: [.command, .option])
            }

            CommandMenu("Gehe zu") {
                Button("Zurück") { app.activePane.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Vorwärts") { app.activePane.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Übergeordneter Ordner") { app.activePane.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                ForEach(Place.standard.prefix(5)) { place in
                    Button(place.name) { app.activePane.navigate(to: place.url) }
                }
                Divider()
                Button("Andere Seite aktivieren") { app.toggleActive() }
                    .keyboardShortcut(.tab, modifiers: [])
                Button("Seiten tauschen") { app.swapSides() }
                    .keyboardShortcut("u", modifiers: .command)
                Button("Gleicher Ordner auf beiden Seiten") { app.mirrorActive() }
                    .keyboardShortcut("=", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Aktualisieren") {
                    app.left.reload()
                    app.right.reload()
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Unsichtbare Dateien ein/aus") { app.activePane.showHidden.toggle() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Divider()
            }
        }
    }
}

/// Opens the storage window and analyzes `url` (or the active pane's folder).
struct AnalyzeStorageButton: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow
    let title: String
    let url: URL?

    var body: some View {
        Button(title) {
            app.storage.analyze(url ?? app.activePane.url)
            openWindow(id: "storage")
        }
    }
}

/// App icon followed by the window title, shown centered in the title bar.
private struct WindowTitle: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            Text(title)
                .font(.headline)
        }
        .fixedSize()
    }
}

/// Version from Info.plist (set by build.sh from the VERSION file).
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

func fKey(_ n: Int) -> KeyEquivalent {
    KeyEquivalent(Character(UnicodeScalar(NSF1FunctionKey + n - 1)!))
}
