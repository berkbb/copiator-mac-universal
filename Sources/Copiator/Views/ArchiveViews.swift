// SPDX-License-Identifier: GPL-3.0-or-later
import CopiatorCore
import SwiftUI

// MARK: - Seçili öğeleri bir rutine gönderme

/// Finder'da seçilen (ya da kenar çubuğuna bırakılan) öğeler için rutin seçimi: rutinin her rotası bu öğelere kurallarını
/// ve yerleşimini uygular.
struct RoutinePickerSheet: View {
    let request: RoutinePickerRequest
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Routine.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.t(.sendToRoutineTitle, request.items.count)).font(.headline)
                    Text(request.items.map { OpenSafety.visibleName($0.lastPathComponent) }.joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            if model.routines.isEmpty {
                ContentUnavailableView(settings.t(.sendToRoutineNone), systemImage: "wand.and.stars",
                                       description: Text(settings.t(.sendToRoutineNoneNote)))
            } else {
                List(model.routines, selection: $selection) { routine in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(OpenSafety.visibleName(routine.name))
                        Text(destinations(routine))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .tag(routine.id)
                }
                .listStyle(.inset)
                .accessibilityIdentifier("copiator.sendToRoutine.list")
            }
            Text(settings.t(.sendToRoutineNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.routines.isEmpty {
                    Button(settings.t(.menuNewRoutine), systemImage: "plus") {
                        dismiss()
                        model.beginNewRoutine()
                    }
                }
                Spacer()
                Button(settings.t(.buttonCancel)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.t(.routineRun)) {
                    guard let selection else { return }
                    dismiss()
                    model.runRoutine(selection, on: request.items)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(selection == nil)
                .accessibilityIdentifier("copiator.sendToRoutine.run")
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
        .onAppear { selection = model.routines.count == 1 ? model.routines.first?.id : nil }
    }

    private func destinations(_ routine: Routine) -> String {
        routine.routes.compactMap { $0.destination.map { OpenSafety.visibleName($0.lastPathComponent) } }.joined(separator: ", ")
    }
}

// MARK: - Hedef özeti

/// Hedef klasörün özeti: birimin doluluğu, dosya ve klasör sayısı, üst klasörlere ve uzantılara göre boyut.
struct DestinationSummarySheet: View {
    let request: DestinationSummaryRequest
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var summary: DestinationSummary?
    @State private var failed = false

    /// - Parameter summary: Önceden hesaplanmış özet (yoksa sayfa açılınca hedef taranır).
    init(request: DestinationSummaryRequest, summary: DestinationSummary? = nil) {
        self.request = request
        _summary = State(initialValue: summary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(OpenSafety.visibleName(request.destination.path), systemImage: "externaldrive")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.head)
            if let summary {
                content(summary)
            } else if failed {
                ContentUnavailableView(settings.t(.summaryFailed), systemImage: "exclamationmark.triangle")
            } else {
                ProgressView(settings.t(.summaryScanning))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button(settings.t(.buttonClose)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .task {
            guard summary == nil else { return }
            let destination = request.destination
            do {
                summary = try await Task.detached(priority: .userInitiated) { try DestinationSummary.compute(at: destination) }.value
            } catch {
                failed = true
            }
        }
    }

    private func content(_ summary: DestinationSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let total = summary.totalCapacity, let available = summary.availableCapacity, total > 0 {
                    let used = max(0, total - available)
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(used), total: Double(total))
                            .tint(Double(used) / Double(total) > 0.9 ? .red : .accentColor)
                        Text(settings.t(.summaryVolume, settings.bytes(used), settings.bytes(total), settings.bytes(available),
                                        settings.percent(Double(used) / Double(total))))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(settings.t(.summaryCounts, summary.files, summary.folders, settings.bytes(summary.bytes)))
                if !summary.topFolders.isEmpty {
                    Text(settings.t(.summaryFolders)).font(.headline)
                    shares(Array(summary.topFolders.prefix(12)), empty: settings.t(.summaryRootFiles), prefix: "")
                }
                if !summary.topExtensions.isEmpty {
                    Text(settings.t(.summaryExtensions, DestinationSummary.maxExtensions)).font(.headline)
                    shares(summary.topExtensions, empty: settings.t(.summaryNoExtension), prefix: ".")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func shares(_ shares: [DestinationSummary.Share], empty: String, prefix: String) -> some View {
        let largest = Double(max(shares.map(\.bytes).max() ?? 1, 1))
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(Array(shares.enumerated()), id: \.offset) { _, share in
                GridRow {
                    Text(share.name.isEmpty ? empty : prefix + OpenSafety.visibleName(share.name))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ProgressView(value: Double(share.bytes), total: largest)
                        .frame(width: 140)
                    Text(settings.bytes(share.bytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                }
            }
        }
    }
}

// MARK: - Klasör önerisi

/// Rota hedefinin içinde, bir dosya adına (ya da anahtar kelimeye) en uygun klasörleri önerir; seçilen klasör rotanın
/// hedefi olur.
struct FolderSuggestionButton: View {
    @Binding var destination: URL?
    /// Rutin sayfasının "Dene" alanındaki yol (açılışta sorgu olarak kullanılır).
    let sample: String
    @Environment(AppSettings.self) private var settings
    @State private var shown = false
    @State private var root: URL?
    @State private var query = ""
    @State private var folders: [String] = []
    @State private var loading = false
    @State private var suggestions: [FolderSuggester.Suggestion] = []

    var body: some View {
        Button(settings.t(.suggestFolders), systemImage: "sparkle.magnifyingglass") { open() }
            .buttonStyle(.borderless)
            .disabled(destination == nil)
            .popover(isPresented: $shown, arrowEdge: .bottom) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(settings.t(.suggestFoldersQuery), text: $query, prompt: Text(settings.t(.suggestFoldersPrompt)))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("copiator.suggest.query")
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if suggestions.isEmpty {
                Text(settings.t(query.trimmingCharacters(in: .whitespaces).isEmpty ? .suggestFoldersEmpty : .suggestFoldersNone))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(suggestions, id: \.path) { suggestion in
                    Button {
                        if let root { destination = root.appendingPathComponent(suggestion.path, isDirectory: true) }
                        shown = false
                    } label: {
                        Label(OpenSafety.visibleName(suggestion.path), systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text(settings.t(.suggestFoldersNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 440)
        .task(id: query) { await refresh() }
    }

    private func open() {
        guard let destination else { return }
        root = destination
        let trimmed = sample.trimmingCharacters(in: .whitespaces)
        query = trimmed.isEmpty ? "" : ((trimmed as NSString).lastPathComponent as NSString).deletingPathExtension
        folders = []
        suggestions = []
        shown = true
        loading = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { FolderSuggester.folders(in: destination) }.value
            folders = found
            loading = false
            await refresh()
        }
    }

    /// Yazarken her harfte değil, kısa bir duraksamadan sonra hesaplanır (binlerce klasörde ana iş parçacığı boğulmasın).
    private func refresh() async {
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let text = query
        let candidates = folders
        let found = await Task.detached(priority: .userInitiated) { FolderSuggester.suggestions(for: text, folders: candidates) }.value
        guard !Task.isCancelled else { return }
        suggestions = found
    }
}
