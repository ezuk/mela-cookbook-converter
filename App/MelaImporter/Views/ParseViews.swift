import SwiftUI
import MelaCore

/// Confirm sheet: engine, model, how many at a time.
struct ParseSheet: View {
    @Bindable var book: BookModel
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var engine = AppSettings.shared.defaultEngine
    @State private var model = AppSettings.shared.model(for: AppSettings.shared.defaultEngine)
    @State private var concurrency = AppSettings.shared.concurrency
    @State private var info: [EngineKind: EngineInfo] = [:]
    @State private var checked = false
    @State private var error: String?

    private func engineLabel(_ k: EngineKind) -> String {
        if let v = info[k]?.version { return "\(k.displayName)  \(v)" }
        return checked && info[k] == nil ? "\(k.displayName)  (not installed)" : k.displayName
    }

    var body: some View {
        let recipes = book.toParse
        let alreadyParsed = book.tickedRecipes.count - recipes.count
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Parse \(recipes.count) recipes?").font(.system(.title2, design: .serif))
                if alreadyParsed > 0 {
                    Text("\(book.tickedRecipes.count) ticked. \(alreadyParsed) already parsed and won’t be sent again.")
                        .foregroundStyle(.secondary)
                }
            }
            Form {
                Picker("Engine", selection: $engine) {
                    ForEach(EngineKind.allCases) { k in
                        Text(engineLabel(k)).tag(k)
                    }
                }
                LabeledContent("Account") {
                    if let i = info[engine] {
                        Label(i.loggedIn ? "Logged in\(i.account.map { ", \($0)" } ?? "")" : "Not logged in",
                              systemImage: i.loggedIn ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(i.loggedIn ? Color.approvedGreen : Color.failedRed)
                    } else if checked {
                        Text("\(engine.displayName) isn’t installed").foregroundStyle(Color.failedRed)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                ModelPicker(engine: engine, models: info[engine]?.models ?? [], model: $model)
                Stepper("At a time: \(concurrency)", value: $concurrency, in: 1...20)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Text("Only the ticked recipes’ text is sent to \(engine.displayName). Photos stay on this Mac. Finished recipes can be reviewed while the rest are still running.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(Color.failedRed) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Parse \(recipes.count)") {
                    do {
                        AppSettings.shared.setModel(model, for: engine)
                        AppSettings.shared.concurrency = concurrency
                        try book.startParsing(recipes, engine: engine, model: model, concurrency: concurrency)
                        dismiss()
                        onStart()
                    } catch {
                        self.error = "\(error)"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.tomato)
                .disabled(recipes.isEmpty || info[engine] == nil || info[engine]?.loggedIn == false)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onChange(of: engine) { _, e in model = AppSettings.shared.model(for: e) }
        .task {
            for k in EngineKind.allCases {
                if let i = await EngineFactory.info(k) { info[k] = i }
            }
            checked = true
        }
    }
}

struct ModelPicker: View {
    let engine: EngineKind
    let models: [String]
    @Binding var model: String

    var body: some View {
        if models.isEmpty {
            TextField("Model", text: $model, prompt: Text("Default"))
        } else {
            Picker("Model", selection: $model) {
                ForEach(models, id: \.self) { m in Text(m.capitalized).tag(m) }
                if !model.isEmpty && !models.contains(model) { Text(model).tag(model) }
            }
        }
    }
}

/// The queue: per-recipe states, review while parsing, retry, and the paused-on-limit state.
struct QueueView: View {
    @Bindable var book: BookModel
    @Binding var review: ReviewTarget?

    var body: some View {
        VStack(spacing: 0) {
            if let paused = book.queuePaused {
                PausedBanner(book: book, reason: paused)
            }
            List(book.queueRows) { r in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title).font(.headline).lineLimit(1)
                        Text(detail(r)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    StatePill(state: book.rowState(r.id))
                    actions(r)
                }
                .padding(.vertical, 3)
            }
            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if book.isQueueRunning {
                    Button("Cancel Remaining") { book.cancelAll() }.controlSize(.small)
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func actions(_ r: RecipeCandidate) -> some View {
        switch book.rowState(r.id) {
        case .approved, .needsReview:
            Button("Review") { review = ReviewTarget(id: r.id) }.controlSize(.small)
        case .failed:
            Button("Retry") { book.reparse(r.id) }.controlSize(.small)
            Button("Retry with \(AppSettings.shared.defaultEngine.other.displayName)") {
                book.reparse(r.id, engine: AppSettings.shared.defaultEngine.other)
            }.controlSize(.small)
        case .waiting, .parsing:
            Button("Cancel") { book.cancel(r.id) }.controlSize(.small)
        case .none:
            EmptyView()
        }
    }

    private func detail(_ r: RecipeCandidate) -> String {
        guard let p = book.parsed[r.id] else { return book.rowState(r.id) == .parsing ? "Parsing…" : "Waiting" }
        if let e = p.error { return e }
        var parts: [String] = []
        if p.report.issues.isEmpty { parts.append("Every line found in the book") } else { parts.append(p.report.issues.first!.message) }
        if !p.report.fixes.isEmpty { parts.append("\(p.report.fixes.count) fixed from the book") }
        return parts.joined(separator: " · ")
    }

    private var summary: String {
        let states = book.queueRows.map { book.rowState($0.id) }
        let approved = states.filter { $0 == .approved }.count
        let review = states.filter { $0 == .needsReview }.count
        let failed = states.filter { if case .failed = $0 { return true } else { return false } }.count
        let waiting = states.filter { $0 == .waiting || $0 == .parsing }.count
        return "\(approved) approved · \(review) need review · \(failed) failed · \(waiting) waiting"
    }
}

struct PausedBanner: View {
    @Bindable var book: BookModel
    let reason: EngineError

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "pause.circle.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(reason.description).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Switch Remaining to \(AppSettings.shared.defaultEngine.other.displayName)") {
                        book.switchRemaining(to: AppSettings.shared.defaultEngine.other)
                    }
                    Button("Resume Now") { book.resumeQueue() }
                }
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .padding(10)
    }

    private var title: String {
        switch reason {
        case .usageLimit: return "Paused: usage limit reached. Nothing was lost."
        case .notLoggedIn: return "Paused: not logged in"
        case .notInstalled: return "Paused: engine not found"
        default: return "Paused"
        }
    }
}

extension BookModel {
    /// Moves recipes still waiting to the other engine.
    func switchRemaining(to engine: EngineKind) {
        let waiting = found.recipes.filter { [.waiting, .parsing].contains(rowState($0.id)) }
        queuePaused = nil
        try? startParsing(waiting, engine: engine, model: AppSettings.shared.model(for: engine), concurrency: AppSettings.shared.concurrency)
    }
}
