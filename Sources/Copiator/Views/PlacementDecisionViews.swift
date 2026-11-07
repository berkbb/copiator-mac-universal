// SPDX-License-Identifier: GPL-3.0-only
import CopiatorCore
import SwiftUI
import UniformTypeIdentifiers

/// "Klasörü sor" kararı: her dosya için hedefte önerilen klasörler (en uygunu seçili), hedefin kökü, yeni klasör ya da
/// atla; "Hatırla" seçimi rotanın öğrenilmiş klasörü yapar. Her dosyaya isteğe bağlı yeni bir ad yazılabilir; "Ad Öner"
/// seçilen klasördeki adlara bakarak öneri yazar. "Uygula"ya basılmadan hiçbir şey kopyalanmaz; yapay zekâ yalnızca
/// önerir.
struct PlacementDecisionView: View {
    let job: TransferJob
    let report: PlacementReport
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// Yol → seçilen klasör (göreli; "" hedefin kökü) ya da `Self.skip` / `Self.new`.
    @State private var selection: [String: String] = [:]
    /// Yol → "Yeni Klasör…" için yazılan klasör.
    @State private var custom: [String: String] = [:]
    @State private var remember: Set<String> = []
    /// Yapay zekânın yeniden sıraladığı öneriler ve (hiçbiri uymadığında) önerdiği yeni klasör.
    @State private var ordered: [String: [String]] = [:]
    @State private var proposed: [String: String] = [:]
    @State private var dates: [String: DateComponents] = [:]
    @State private var ranking = false
    @State private var rankedByAI = false
    /// Yapay zekâ hiçbir dosya için öneri veremediyse nedeni.
    @State private var aiNote: LKey?
    /// Yol → yazılan ya da önerilen yeni ad (uzantısız; boşsa rotanın ad şablonu).
    @State private var names: [String: String] = [:]
    @State private var naming = false
    @State private var namingNote: LKey?

    private static let skip = "\u{0}skip"
    private static let new = "\u{0}new"
    /// Klasörü bilinen (yalnızca adı sorulan) dosya kopyalanacak.
    private static let keep = "\u{0}keep"
    /// Yapay zekânın sıraladığı en çok dosya (her dosya bir model çağrısı).
    private static let maxRanked = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.t(report.items.contains(where: \.needsFolder) ? .placementSheetTitle : .placementNameSheetTitle, report.total))
                        .font(.headline)
                    Text(settings.t(.conflictSubtitle, OpenSafety.visibleName(job.source.lastPathComponent), OpenSafety.visibleName(job.destination.path)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            if model.canSuggestWithAI {
                HStack {
                    Button(settings.t(.placementRankAll), systemImage: "sparkles") { rankWithAI() }
                        .disabled(ranking || rankedByAI)
                        .accessibilityIdentifier("copiator.placement.rankAll")
                    if ranking { ProgressView().controlSize(.small) }
                    if rankedByAI {
                        Text(settings.t(.placementAISuggested, model.suggestionSourceName)).font(.caption).foregroundStyle(.secondary)
                    } else if let aiNote {
                        Text(settings.t(aiNote))
                            .font(.caption)
                            .foregroundStyle(aiNote == .aiEngineUnavailable ? Color.orange : Color.secondary)
                    }
                }
                AILanguageWarning()
            }

            HStack {
                Button(settings.t(.placementSuggestNames), systemImage: "wand.and.stars") { suggestNames() }
                    .disabled(naming)
                    .accessibilityIdentifier("copiator.placement.suggestNames")
                if naming { ProgressView().controlSize(.small) }
                if let namingNote {
                    Text(settings.t(namingNote)).font(.caption).foregroundStyle(.secondary)
                }
            }

            List(report.items, id: \.path) { item in
                row(item)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            VStack(alignment: .leading, spacing: 4) {
                if report.total > report.items.count {
                    Text(settings.t(.placementMore, report.total - report.items.count))
                }
                Text(settings.t(.placementSheetNote))
                if report.items.contains(where: \.needsFolder) { Text(settings.t(.placementRememberNote)) }
                Text(settings.t(.placementNameNote))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(settings.t(.conflictLater)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.t(.placementApply)) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!isComplete)
                    .accessibilityIdentifier("copiator.placement.apply")
            }
        }
        .padding(20)
        .onAppear(perform: preselect)
        .task {
            await model.refreshLocalModels()
            await loadDates()
        }
    }

    private func row(_ item: PlacementReport.Item) -> some View {
        let choice = selection[item.path] ?? Self.skip
        let folder = folder(for: item)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(OpenSafety.visibleName((item.path as NSString).lastPathComponent), systemImage: "doc")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(OpenSafety.visibleName(item.path))
                Spacer()
                if item.needsFolder {
                    folderPicker(item, folder: folder)
                } else {
                    Toggle(settings.t(.placementSkip), isOn: Binding(get: { choice == Self.skip },
                                                                    set: { selection[item.path] = $0 ? Self.skip : Self.keep }))
                        .toggleStyle(.checkbox)
                }
            }
            if choice == Self.new {
                TextField(settings.t(.placementNewFolder), text: customBinding(for: item), prompt: Text(settings.t(.placementNewFolderPrompt)))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }
            if !item.missingFields.isEmpty {
                Text(settings.t(.placementMissingFields, item.missingFields.map { "{c:\($0)}" }.joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let folder {
                TextField(settings.t(.placementNewName), text: nameBinding(for: item),
                          prompt: Text(OpenSafety.visibleName(defaultName(item, folder: folder))))
                    .textFieldStyle(.roundedBorder)
                    .help(settings.t(.placementNameNote))
            }
            if item.needsFolder, item.suggestions.isEmpty {
                Text(settings.t(.placementNoSuggestion)).font(.caption).foregroundStyle(.orange)
            }
            if let folder {
                Text(settings.t(.placementWillBe, OpenSafety.visibleName(target(item, folder: folder))))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    /// "Klasörü sor": önerilen klasörler, hedefin kökü, yeni klasör ya da atla; "Hatırla".
    @ViewBuilder private func folderPicker(_ item: PlacementReport.Item, folder: String?) -> some View {
        Picker(OpenSafety.visibleName(item.path), selection: binding(for: item)) {
            if let folder = proposed[item.path], !suggestions(for: item).contains(folder) {
                Text(settings.t(.placementAINewFolder, OpenSafety.visibleName(folder))).tag(folder)
            }
            ForEach(suggestions(for: item), id: \.self) { path in
                Text(OpenSafety.visibleName(path)).tag(path)
            }
            if !suggestions(for: item).contains("") {
                Text(settings.t(.placementRoot)).tag("")
            }
            Divider()
            Text(settings.t(.placementNewFolder)).tag(Self.new)
            Text(settings.t(.placementSkip)).tag(Self.skip)
        }
        .labelsHidden()
        .frame(maxWidth: 300)
        Toggle(settings.t(.placementRemember), isOn: rememberBinding(for: item))
            .toggleStyle(.checkbox)
            .disabled(folder == nil || PlacementMemory.key(for: item.path) == nil)
    }

    private func suggestions(for item: PlacementReport.Item) -> [String] { ordered[item.path] ?? item.suggestions }

    /// Seçimin klasörü; atla ya da boş "yeni klasör" için nil. Klasörü bilinen dosyada bilinen klasör (yoksa "": klasör
    /// şablondan gelir).
    private func folder(for item: PlacementReport.Item) -> String? {
        switch selection[item.path] ?? Self.skip {
        case Self.skip: return nil
        case Self.keep: return item.folder ?? ""
        case Self.new:
            let clean = PlacementResolution.clean(custom[item.path] ?? "")
            return clean.isEmpty ? nil : clean
        case let path: return path
        }
    }

    /// Dosyanın seçilen klasördeki hedef yolu (şablon, düzeltmeler, hedef belirteçleri ve yazılan yeni adla).
    private func target(_ item: PlacementReport.Item, folder: String, useName: Bool = true) -> String {
        let placement = job.options.placement ?? RoutePlacement(askFolder: true)
        let name = useName ? names[item.path].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } : nil
        // Bulunamayan içerik değerleri yer tutucuyla gösterilir ("‹abone›").
        var content = item.contentValues
        for field in item.missingFields { content[field] = "‹\(field)›" }
        return placement.target(for: item.path, date: date(for: item), destination: job.destination.path,
                                folder: item.needsFolder ? folder : item.folder, name: name, content: content)
    }

    /// Yeni ad yazıldı (güvenli bir ada dönüşüyor).
    private func hasName(_ item: PlacementReport.Item) -> Bool {
        !RoutePlacement.component(names[item.path] ?? "").isEmpty
    }

    /// Yeni ad yazılmazsa dosyanın alacağı ad (uzantısız; ad alanının yer tutucusu).
    private func defaultName(_ item: PlacementReport.Item, folder: String) -> String {
        ((target(item, folder: folder, useName: false) as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Dosyanın tarihi (rotanın tarih kaynağından); bulunamazsa addaki tarih ya da bugün.
    private func date(for item: PlacementReport.Item) -> DateComponents {
        let name = ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension
        return dates[item.path] ?? TextDate.find(in: name) ?? Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
    }

    private func nameBinding(for item: PlacementReport.Item) -> Binding<String> {
        Binding(get: { names[item.path] ?? "" }, set: { names[item.path] = $0 })
    }

    /// Adı boş olan ve klasörü seçilmiş her dosyaya, o klasördeki adlara bakarak bir ad önerir (önce kurallar; yapay zekâ
    /// açıksa kurallar çözemediğinde model). Önerilen ad yalnızca alana yazılır; "Uygula"ya basılmadan kullanılmaz.
    private func suggestNames() {
        let suggestionModel = model.canSuggestWithAI ? model.suggestionModel : nil
        let destination = job.destination
        // Örnek adlar dosyanın düşeceği klasörden okunur (alt klasör şablonu dahil).
        let items = report.items.compactMap { item in
            folder(for: item).map { (item, (target(item, folder: $0, useName: false) as NSString).deletingLastPathComponent) }
        }
        naming = true
        namingNote = nil
        Task {
            var found = false
            for (item, folder) in items where (names[item.path] ?? "").isEmpty {
                let result = await PlacementNaming.suggest(for: item.path, in: destination.appendingPathComponent(folder),
                                                           date: date(for: item), model: suggestionModel)
                if let value = result.value, (names[item.path] ?? "").isEmpty {
                    names[item.path] = value
                    found = true
                }
            }
            naming = false
            namingNote = found ? .placementNamesSuggested : .placementNoNameSuggestion
        }
    }

    /// Her dosya atlandı ya da klasörü belli ve (içerikten bir değeri bulunamadıysa) yeni adı yazıldı.
    private var isComplete: Bool {
        report.items.allSatisfy { item in
            selection[item.path] == Self.skip || (folder(for: item) != nil && (item.missingFields.isEmpty || hasName(item)))
        }
    }

    private func binding(for item: PlacementReport.Item) -> Binding<String> {
        Binding(get: { selection[item.path] ?? Self.skip }, set: { selection[item.path] = $0 })
    }

    private func customBinding(for item: PlacementReport.Item) -> Binding<String> {
        Binding(get: { custom[item.path] ?? "" }, set: { custom[item.path] = $0 })
    }

    private func rememberBinding(for item: PlacementReport.Item) -> Binding<Bool> {
        Binding(
            get: { remember.contains(item.path) && folder(for: item) != nil },
            set: { if $0 { remember.insert(item.path) } else { remember.remove(item.path) } }
        )
    }

    /// Her dosyanın ilk önerisi seçili gelir (öneri yoksa atla); kullanıcı onaylamadan uygulanmaz.
    private func preselect() {
        guard selection.isEmpty else { return }
        for item in report.items { selection[item.path] = item.needsFolder ? item.suggestions.first ?? Self.skip : Self.keep }
    }

    /// Tarih belirteçleri için dosyaların tarihi (rotanın tarih kaynağından); bulunamazsa addaki tarih ya da bugün.
    private func loadDates() async {
        guard let placement = job.options.placement, placement.usesDate else { return }
        for item in report.items {
            let url = job.source.appendingPathComponent(item.path)
            dates[item.path] = await PlacementDate.resolve(url, relativePath: item.path, source: placement.dateSource)
        }
    }

    /// Seçilen modele (bu Mac'te) her dosyanın yerini sorar (ilk `maxRanked` dosya): model adayları sıralar ya da hiçbiri
    /// uymuyorsa hedefte yeni bir klasör yolu önerir. Kullanıcının değiştirmediği seçim modelin ilk önerisine geçer;
    /// hiçbir şey "Uygula"ya basılmadan uygulanmaz.
    private func rankWithAI() {
        let suggestionModel = model.suggestionModel
        let source = job.source
        let items = Array(report.items.filter(\.needsFolder).prefix(Self.maxRanked))
        ranking = true
        aiNote = nil
        Task {
            var answered = false
            var reached = false
            for item in items {
                let current = suggestions(for: item)
                let url = source.appendingPathComponent(item.path)
                let content = await Task.detached(priority: .userInitiated) {
                    ContentReader.canRead(UTType(filenameExtension: url.pathExtension)) ? ContentReader.text(of: url) : nil
                }.value
                let name = (item.path as NSString).lastPathComponent
                let result = await Suggestions.placeFile(name, content: content, candidates: current, model: suggestionModel)
                if result != .unavailable { reached = true }
                guard let answer = result.value else { continue }
                answered = true
                let untouched = selection[item.path] == (current.first ?? Self.skip)
                ordered[item.path] = answer.order + current.filter { !answer.order.contains($0) }
                if let folder = answer.newFolder { proposed[item.path] = folder }
                if untouched, let first = answer.order.first ?? answer.newFolder { selection[item.path] = first }
            }
            ranking = false
            // Hiçbir model yanıt veremediyse motor kullanılamıyor; yanıt verip öneri çıkmadıysa kural tabanlı öneriler kalır.
            rankedByAI = answered
            if !answered { aiNote = reached ? .aiNoAnswer : .aiEngineUnavailable }
        }
    }

    private func submit() {
        guard isComplete else { return }
        var resolution = PlacementResolution()
        var remembered: [String: String] = [:]
        for item in report.items {
            guard let folder = folder(for: item) else {
                resolution.skipped.insert(item.path)
                continue
            }
            if let chosen = item.needsFolder ? folder : item.folder { resolution.folders[item.path] = chosen }
            if let name = names[item.path]?.trimmingCharacters(in: .whitespaces), !RoutePlacement.component(name).isEmpty {
                resolution.names[item.path] = name
            }
            if item.needsFolder, remember.contains(item.path) { remembered[item.path] = folder }
        }
        model.resolvePlacements(job.id, resolution: resolution, remember: remembered)
        dismiss()
    }
}
