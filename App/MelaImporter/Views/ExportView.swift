import SwiftUI
import AppKit
import MelaCore

/// Export: options, where to save (next to the ePub in Calibre by default), repeat warning, then success.
struct ExportSheet: View {
    @Bindable var book: BookModel
    @Environment(\.dismiss) private var dismiss
    @State private var options = ExportOptions()
    @State private var includeRepeats = false
    @State private var destination: URL?
    @State private var done: URL?
    @State private var error: String?
    @State private var exportedCount = 0

    var body: some View {
        let approved = book.exportable
        let repeats = approved.filter { book.exportedDate($0.id) != nil }
        let toExport = includeRepeats ? approved : approved.filter { book.exportedDate($0.id) == nil }
        let waiting = book.tickedRecipes.count - approved.count
        VStack(alignment: .leading, spacing: 16) {
            if let done {
                success(done, count: exportedCount)
            } else {
                Text("Export \(toExport.count) recipes for Mela").font(.system(.title2, design: .serif))
                if waiting > 0 {
                    Text("\(waiting) ticked recipes aren’t approved yet and are left out.").foregroundStyle(.secondary)
                }
                Toggle(isOn: $options.chapterAsCategory) {
                    VStack(alignment: .leading) {
                        Text("Chapter as category")
                        Text(Set(toExport.compactMap(\.chapter)).sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Toggle(isOn: $options.bookInSource) {
                    VStack(alignment: .leading) {
                        Text("Book and page in the source field")
                        Text("“\(MelaExporter.displayBookTitle(book.package.metadata.title)), \(book.author)\(toExport.first?.page.map { ", p. \($0)" } ?? "")”")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Toggle(isOn: $options.includeInferredTimes) {
                    VStack(alignment: .leading) {
                        Text("Include worked-out times")
                        Text("Times the book doesn’t print. Off keeps them empty.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $options.includePhotos) {
                    VStack(alignment: .leading) {
                        Text("Photos from the book")
                        Text("Up to 3 per recipe, resized to 512 px").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !repeats.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(repeats.count) recipe\(repeats.count == 1 ? " was" : "s were") exported before").font(.headline)
                        Text("\(repeats.prefix(3).map(\.title).joined(separator: ", ")). Mela may update them or add a second copy.")
                            .font(.callout).foregroundStyle(.secondary)
                        Toggle("Include them anyway", isOn: $includeRepeats)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack {
                    Image(systemName: "doc")
                    Text(target.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…", action: choose)
                }
                .font(.callout)
                Text(book.calibreBook != nil && destination == nil && AppSettings.shared.saveNextToEPUB
                     ? "Saved next to the ePub in your Calibre library."
                     : "Saved to \(target.deletingLastPathComponent().path).")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(Color.failedRed) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Export") { export(toExport) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(.tomato)
                        .disabled(toExport.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private var target: URL { destination ?? book.defaultExportURL }

    private func choose() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = target.lastPathComponent
        panel.directoryURL = target.deletingLastPathComponent()
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, var url = panel.url {
            if url.pathExtension != "melarecipes" { url = url.appendingPathExtension("melarecipes") }
            destination = url
            if book.calibreBook == nil { AppSettings.shared.lastExportFolder = url.deletingLastPathComponent().path }
        }
    }

    private func export(_ recipes: [RecipeCandidate]) {
        do {
            try book.export(recipes, options: options, to: target)
            exportedCount = recipes.count
            done = target
        } catch {
            self.error = "Couldn’t export: \(error.localizedDescription)"
        }
    }

    private func success(_ url: URL, count: Int) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.approvedGreen)
                .symbolEffect(.bounce, value: done)
            Text("\(count) recipes ready for Mela").font(.system(.title2, design: .serif))
            Text("Saved “\(url.lastPathComponent)”\(book.calibreBook != nil ? " next to the ePub. The book now shows as Processed." : ".")")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("On your iPhone, open the file from the Files app to import it into Mela.")
                .font(.callout)
                .padding(10)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Done") { dismiss() }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.borderedProminent)
                    .tint(.tomato)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
