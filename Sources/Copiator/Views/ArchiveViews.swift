// SPDX-License-Identifier: GPL-3.0-only
import CopiatorCore
import SwiftUI
import UniformTypeIdentifiers

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
    @Environment(AppModel.self) private var model
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
                Button(settings.t(.menuSaveFolderTree), systemImage: "list.bullet.indent") { saveTree() }
                    .disabled(model.savingFolderTree)
                if model.savingFolderTree { ProgressView().controlSize(.small) }
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

    /// Klasör ağacını Markdown olarak kaydetme yeri sorulur; ağaç arka planda çıkarılır.
    private func saveTree() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = settings.t(.folderTreeFileName, request.destination.lastPathComponent)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.saveFolderTree(of: request.destination, to: url) }
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
                if summary.isEncrypted == false { UnencryptedDiskNote() }
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

/// Yapay zekâ önerilerinin dil uyarısı: Apple'ın cihaz üstü modeli en iyi İngilizcede çalışır, başka dillerdeki adlarda
/// zayıflayabilir. Apple Intelligence kullanılabilecekken (seçiliyken ya da Otomatik sıradayken) gösterilir; yalnızca yerel
/// sunucu (Ollama, LM Studio) kullanılıyorsa gösterilmez.
struct AILanguageWarning: View {
    @Environment(AppSettings.self) private var settings

    static func applies(to providers: [SuggestionProvider]) -> Bool { providers.contains(.apple) }

    var body: some View {
        if Self.applies(to: settings.activeProviders) {
            Label(settings.t(.aiLanguageWarning), systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("copiator.ai.languageWarning")
        }
    }
}

/// Rota hedefinin içinde, bir dosya adına (ya da anahtar kelimeye) en uygun klasörleri önerir; seçilen klasör rotanın
/// hedefi olur.
struct FolderSuggestionButton: View {
    @Binding var destination: URL?
    /// Rutin sayfasının "Dene" alanındaki yol (açılışta sorgu olarak kullanılır).
    let sample: String
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var ranking = false
    @State private var rankedByAI = false
    /// Yapay zekâ sıralayamadıysa nedeni: geçerli öneri yok ya da öneri motoru kullanılamıyor.
    @State private var aiFailure: LKey?
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
                ForEach(suggestions.prefix(5), id: \.path) { suggestion in
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
            if model.canSuggestWithAI, suggestions.count > 1 {
                HStack {
                    Button(settings.t(.aiRankFolders), systemImage: "sparkles") { rankWithAI() }
                        .disabled(ranking || rankedByAI)
                        .accessibilityIdentifier("copiator.suggest.ai")
                    if ranking { ProgressView().controlSize(.small) }
                    if rankedByAI {
                        Text(settings.t(.aiRanked, model.suggestionSourceName)).font(.caption).foregroundStyle(.secondary)
                    } else if let aiFailure {
                        Text(settings.t(aiFailure))
                            .font(.caption)
                            .foregroundStyle(aiFailure == .aiEngineUnavailable ? Color.orange : Color.secondary)
                    }
                }
                AILanguageWarning()
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
    /// Yapay zekâ sıralaması için ilk 10 aday tutulur, 5'i gösterilir.
    private func refresh() async {
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let text = query
        let candidates = folders
        let found = await Task.detached(priority: .userInitiated) {
            FolderSuggester.suggestions(for: text, folders: candidates, limit: Suggestions.maxCandidates)
        }.value
        guard !Task.isCancelled else { return }
        suggestions = found
        rankedByAI = false
        aiFailure = nil
    }

    /// Kural tabanlı adayları cihaz üstü modelle sıralar (yalnızca var olan adaylar arasından).
    private func rankWithAI() {
        let text = query
        let current = suggestions
        let suggestionModel = model.suggestionModel
        ranking = true
        Task {
            let result = await Suggestions.rankFolders(current, for: text, content: nil, model: suggestionModel)
            ranking = false
            switch result {
            case .value(let ranked):
                guard query == text else { return }
                suggestions = ranked
                rankedByAI = true
            case .noSuggestion:
                aiFailure = .aiNoAnswer
            case .unavailable:
                aiFailure = .aiEngineUnavailable
            }
        }
    }
}

// MARK: - Arşivlenmiş kaynakları temizleme

/// Kaynakta olup hedefte (herhangi bir yerde, herhangi bir adla) aynı içerikte kopyası bulunan dosyaları listeler ve
/// onaylanınca Çöp Sepeti'ne taşır. Kalıcı silme yoktur.
struct CleanupSheet: View {
    let request: CleanupRequest
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var source: URL?
    @State private var destination: URL?
    @State private var found: [URL]?
    @State private var bytes: Int64 = 0
    @State private var scanning = false
    @State private var confirm = false
    @State private var message: String?

    static let maxListed = 500

    init(request: CleanupRequest) {
        self.request = request
        _source = State(initialValue: request.source)
        _destination = State(initialValue: request.destination)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(settings.t(.cleanupTitle), systemImage: "trash.circle")
                .font(.headline)
            Form {
                FolderChooserRow(title: settings.t(.newJobSource), url: $source, systemImage: "folder",
                                 panelMessage: settings.t(.panelChooseSource))
                FolderChooserRow(title: settings.t(.newJobDestination), url: $destination, systemImage: "externaldrive",
                                 panelMessage: settings.t(.panelChooseDestination))
            }
            .formStyle(.grouped)
            .frame(height: 220)
            Text(settings.t(.cleanupNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if scanning {
                ProgressView(settings.t(.cleanupScanning)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let found {
                if found.isEmpty {
                    ContentUnavailableView(settings.t(.cleanupNone), systemImage: "checkmark.circle")
                } else {
                    Text(settings.t(.cleanupFound, found.count, settings.bytes(bytes))).font(.callout.weight(.semibold))
                    List {
                        ForEach(found.prefix(Self.maxListed), id: \.self) { url in
                            Text(OpenSafety.visibleName(relative(url)))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if found.count > Self.maxListed {
                            Text(settings.t(.cleanupMore, found.count - Self.maxListed)).foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.inset)
                }
            } else {
                Spacer()
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(settings.t(.buttonClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.t(.cleanupScan)) { scan() }
                    .disabled(source == nil || destination == nil || scanning)
                    .accessibilityIdentifier("copiator.cleanup.scan")
                Button(settings.t(.cleanupMove), role: .destructive) { confirm = true }
                    .buttonStyle(.glassProminent)
                    .disabled(found?.isEmpty ?? true)
                    .accessibilityIdentifier("copiator.cleanup.move")
            }
        }
        .padding(20)
        .frame(width: 620, height: 600)
        .onChange(of: source) { found = nil }
        .onChange(of: destination) { found = nil }
        .confirmationDialog(settings.t(.cleanupConfirmTitle, found?.count ?? 0), isPresented: $confirm, titleVisibility: .visible) {
            Button(settings.t(.trashConfirmButton), role: .destructive) { move() }
            Button(settings.t(.buttonCancel), role: .cancel) {}
        } message: {
            Text(settings.t(.cleanupConfirmMessage))
        }
    }

    private func relative(_ url: URL) -> String {
        guard let source else { return url.path }
        let base = source.standardizedFileURL.path
        return url.path.hasPrefix(base + "/") ? String(url.path.dropFirst(base.count + 1)) : url.lastPathComponent
    }

    private func scan() {
        guard let source, let destination else { return }
        message = nil
        if JobValidation.check(source: source, destination: destination, copyMode: .contents) == .overlapping {
            message = settings.t(.cleanupOverlap)
            return
        }
        scanning = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([URL], Int64)? in
                guard let urls = try? SourceTrash.archivedFiles(in: source, destination: destination) else { return nil }
                return (urls, DiskSpace.totalSize(of: urls))
            }.value
            found = result?.0 ?? []
            bytes = result?.1 ?? 0
            scanning = false
        }
    }

    private func move() {
        guard let source, let found else { return }
        let outcome = SourceTrash.move(found, root: source)
        message = settings.t(.cleanupDone, outcome.moved, settings.bytes(outcome.bytes), outcome.failed.count)
        self.found = nil
    }
}
