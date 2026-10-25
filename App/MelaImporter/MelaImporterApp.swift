import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MelaCore

@main
struct MelaImporterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared

    var body: some Scene {
        WindowGroup("Mela Importer", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { AppCommands(app: app) }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

/// Opens books handed to the app by Finder (Open With, drop on the Dock icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "epub" }) else { return }
        Task { @MainActor in AppModel.shared.open(url: url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// App-wide state: the library, the open book, and errors to show.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()
    let library = LibraryModel()
    var book: BookModel?
    var isOpening = false
    var openError: String?
    var openErrorTitle = ""

    func open(url: URL, calibreBook: CalibreBook? = nil) {
        isOpening = true
        Task {
            do {
                let calibre = calibreBook ?? library.books.first { $0.epub.standardizedFileURL == url.standardizedFileURL }
                let model = try await BookModel.open(url: url, calibreBook: calibre)
                book = model
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            } catch {
                openErrorTitle = "“\(url.deletingPathExtension().lastPathComponent)” can’t be used"
                openError = error.localizedDescription
            }
            isOpening = false
        }
    }

    func closeBook() {
        book = nil
        library.reload()
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a DRM-free cookbook ePub"
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if let book = app.book {
                BookView(book: book)
                    .id(book.url)
            } else {
                HomeView()
            }
        }
        .overlay {
            if app.isOpening {
                ProgressView("Reading the book…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert(app.openErrorTitle, isPresented: Binding(get: { app.openError != nil }, set: { if !$0 { app.openError = nil } })) {
            Button("Open Another…") { app.showOpenPanel() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.openError ?? "")
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "epub" }) else { return false }
            app.open(url: url)
            return true
        }
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "epub" { app.open(url: url) }
        }
    }
}

struct AppCommands: Commands {
    let app: AppModel
    @FocusedValue(\.bookModel) private var book: BookModel?
    @FocusedValue(\.reviewActions) private var review: ReviewActions?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open ePub…") { app.showOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(RecentBooks.shared.recent, id: \.path) { s in
                    Button(s.title) { app.open(url: URL(fileURLWithPath: s.path)) }
                }
                Divider()
                Button("Clear Menu") { RecentBooks.shared.clear() }
            }
            Divider()
            Button("Back to Cookbooks") { app.closeBook() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(app.book == nil)
        }
        CommandMenu("Book") {
            Button("Outline") { book?.state.mode = .outline }
                .keyboardShortcut("1")
                .disabled(book == nil)
            Button("Gallery") { book?.state.mode = .gallery }
                .keyboardShortcut("2")
                .disabled(book == nil)
            Divider()
            Button("Approve Recipe") { review?.approve() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(review == nil)
            Button("Re-parse Recipe") { review?.reparse() }
                .keyboardShortcut("r")
                .disabled(review == nil)
            Divider()
            Button("Forget This Book…") { book.map { b in ForgetBook.confirm(b, app: app) } }
                .disabled(book == nil)
        }
    }
}

enum ForgetBook {
    @MainActor static func confirm(_ book: BookModel, app: AppModel) {
        let alert = NSAlert()
        alert.messageText = "Forget “\(book.title)”?"
        alert.informativeText = "Deletes ticks, parse results, edits and export history for this book. Exported files stay where they are."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? book.forget()
        app.closeBook()
    }
}

struct ReviewActions {
    let approve: () -> Void
    let reparse: () -> Void
}

struct BookModelKey: FocusedValueKey { typealias Value = BookModel }
struct ReviewActionsKey: FocusedValueKey { typealias Value = ReviewActions }

extension FocusedValues {
    var bookModel: BookModel? {
        get { self[BookModelKey.self] }
        set { self[BookModelKey.self] = newValue }
    }
    var reviewActions: ReviewActions? {
        get { self[ReviewActionsKey.self] }
        set { self[ReviewActionsKey.self] = newValue }
    }
}
