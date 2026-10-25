import SwiftUI
import AppKit
import MelaCore

struct SettingsView: View {
    var body: some View {
        TabView {
            LibrarySettings()
                .tabItem { Label("Library", systemImage: "books.vertical") }
            EngineSettings()
                .tabItem { Label("Engines", systemImage: "terminal") }
        }
        .frame(width: 640)
        .padding(.vertical, 8)
    }
}

/// Which Calibre library, which books count as cookbooks, and where exports go.
struct LibrarySettings: View {
    @Environment(AppModel.self) private var app
    @Bindable private var settings = AppSettings.shared
    @State private var bookCount: Int?
    @State private var matchCount: Int?
    @State private var excluded: [CalibreBook] = []

    var body: some View {
        Form {
            Section("Calibre library") {
                HStack {
                    Image(systemName: "folder")
                    VStack(alignment: .leading) {
                        Text(settings.calibreLibraryPath.isEmpty ? "Not chosen" : (settings.calibreLibraryPath as NSString).abbreviatingWithTildeInPath)
                            .fontWeight(.semibold)
                        if let bookCount { Text("\(bookCount) books · read only, Calibre can stay open").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Choose…", action: choose)
                }
            }
            Section("Which books are cookbooks") {
                LabeledContent("Has any of these tags") { ChipField(values: $settings.cookbookTags, placeholder: "Add tag") }
                LabeledContent("Or a title containing") { ChipField(values: $settings.titleWords, placeholder: "Add word") }
                if let matchCount {
                    Text("**\(matchCount) books match** · only books with an ePub are listed").font(.callout)
                }
            }
            if !excluded.isEmpty {
                Section("Excluded by hand") {
                    ForEach(excluded) { book in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(book.title)
                                Text(book.authors.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Include Again") { app.library.include(book.id) }
                        }
                    }
                }
            }
            Section("Exports") {
                Toggle(isOn: $settings.saveNextToEPUB) {
                    VStack(alignment: .leading) {
                        Text("Save each export next to its ePub")
                        Text("In the book’s Calibre folder, as “Title - Author.melarecipes”. A book counts as Processed once this file exists.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: "\(settings.calibreLibraryPath)|\(settings.cookbookTags)|\(settings.titleWords)|\(settings.excludedBookIDs.sorted())") { await refresh() }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the Calibre library folder (it holds metadata.db)"
        if panel.runModal() == .OK, let url = panel.url { settings.calibreLibraryPath = url.path }
    }

    private func refresh() async {
        let path = settings.calibreLibraryPath
        let filter = settings.filter
        guard !path.isEmpty else { bookCount = nil; matchCount = nil; excluded = []; return }
        let counts = await Task.detached { () -> (Int, Int, [CalibreBook])? in
            guard let lib = try? CalibreLibrary(root: URL(fileURLWithPath: path)) else { return nil }
            return (lib.bookCount, (try? lib.cookbooks(matching: filter).count) ?? 0, (try? lib.excludedBooks(filter)) ?? [])
        }.value
        bookCount = counts?.0
        matchCount = counts?.1
        excluded = counts?.2 ?? []
        app.library.reload()
    }
}

/// Which CLIs were found, login state, default engine and model, parses at a time.
struct EngineSettings: View {
    @Bindable private var settings = AppSettings.shared
    @State private var info: [EngineKind: EngineInfo] = [:]
    @State private var checked = false

    var body: some View {
        Form {
            Section("Command-line tools found on this Mac") {
                Picker("Default engine", selection: $settings.defaultEngine) {
                    ForEach(EngineKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                ForEach(EngineKind.allCases) { kind in
                    EngineRow(kind: kind, info: info[kind], checked: checked,
                              model: Binding(get: { settings.model(for: kind) }, set: { settings.setModel($0, for: kind) }))
                }
                Text("The default engine and its model start the Parse sheet. Each recipe can be retried with the other engine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if ToolLocator.hasAnthropicAPIKey {
                Section {
                    Label {
                        VStack(alignment: .leading) {
                            Text("An Anthropic API key is set in your shell").fontWeight(.semibold)
                            Text("Left in place, parses would be billed to that key instead of your subscription. The app removes it for every parse.")
                                .font(.caption)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
            Section {
                Stepper("Parses at a time: \(settings.concurrency)", value: $settings.concurrency, in: 1...20)
                HStack {
                    Text("Check both engines again")
                    Spacer()
                    Button("Refresh") { Task { await load() } }
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private func load() async {
        checked = false
        var found: [EngineKind: EngineInfo] = [:]
        for k in EngineKind.allCases { if let i = await EngineFactory.info(k) { found[k] = i } }
        info = found
        checked = true
    }
}

struct EngineRow: View {
    let kind: EngineKind
    let info: EngineInfo?
    let checked: Bool
    @Binding var model: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(kind.displayName).fontWeight(.semibold))\(Text(info?.version.map { "  \($0)" } ?? "").foregroundStyle(.secondary))")
                Text(info.map { ($0.executable.path as NSString).abbreviatingWithTildeInPath } ?? (checked ? "Not found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin" : "Looking…"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ModelPicker(engine: kind, models: info?.models ?? [], model: $model)
                .frame(width: 170)
                .labelsHidden()
            if let info {
                Label(info.loggedIn ? "Logged in" : "Not logged in", systemImage: info.loggedIn ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(info.loggedIn ? Color.approvedGreen : Color.failedRed)
                    .font(.caption)
            }
        }
    }
}
