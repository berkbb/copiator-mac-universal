// SPDX-License-Identifier: GPL-3.0-only
import CopiatorCore
import SwiftUI

extension AppSettings {
    func title(_ token: PlacementToken) -> String {
        switch token {
        case .name: t(.placementTokenName)
        case .folder: t(.placementTokenFolder)
        case .year: t(.placementTokenYear)
        case .yy: t(.placementTokenYY)
        case .month: t(.placementTokenMonth)
        case .monthName: t(.placementTokenMonthName)
        case .day: t(.placementTokenDay)
        case .targetFolder: t(.placementTokenTargetFolder)
        case .targetNumber: t(.placementTokenTargetNumber)
        }
    }

    func title(_ source: PlacementDateSource) -> String {
        switch source {
        case .automatic: t(.placementDateAutomatic)
        case .fileName: t(.placementDateFileName)
        case .contents: t(.placementDateContents)
        case .captureDate: t(.placementDateCapture)
        case .modified: t(.placementDateModified)
        case .created: t(.placementDateCreated)
        }
    }

    func placementProblem(_ problem: RoutePlacement.Problem) -> String {
        switch problem {
        case .unknownToken(let token): t(.problemPlacementToken, OpenSafety.visibleName(token))
        case .slashInName: t(.problemPlacementSlash)
        case .parentFolder: t(.problemPlacementParent)
        case .invalidFix(let pattern): t(.problemPlacementFix, OpenSafety.visibleName(pattern))
        case .fixReplacement(let part): t(.problemPlacementFixReplacement, OpenSafety.visibleName(part))
        case .contentFieldName(let name): t(.problemContentFieldName, OpenSafety.visibleName(name))
        case .contentFieldPattern(let pattern): t(.problemContentFieldPattern, OpenSafety.visibleName(pattern))
        case .contentTokenInFolder(let token): t(.problemContentTokenInFolder, OpenSafety.visibleName(token))
        }
    }

    /// Yerleşimin kısa özeti ("{year}/{month}-{monthName} / {name}_{yy}"); şablon yoksa nil.
    func describe(_ placement: RoutePlacement) -> String? {
        guard placement.isActive else { return nil }
        let folder = placement.folderTemplate.trimmingCharacters(in: .whitespaces)
        let name = placement.nameTemplate.trimmingCharacters(in: .whitespaces)
        let parts = [folder, name.isEmpty ? t(.placementSameName) : name].filter { !$0.isEmpty }
        let fixes = placement.nameFixes.filter { !$0.pattern.isEmpty }.count
        let fields = placement.referencedFields.count
        return (placement.askFolder ? t(.placementAskSummary) + " / " : "") + parts.joined(separator: " / ")
            + (fixes > 0 ? " • " + t(.placementFixesSummary, fixes) : "") + (fields > 0 ? " • " + t(.placementFieldsSummary, fields) : "")
            + " • " + title(placement.dateSource)
    }
}

/// Rotanın hedefte yerleşimi: alt klasör şablonu (tarih klasörleri), ad şablonu, tarih kaynağı ve örnek.
struct PlacementEditor: View {
    @Binding var placement: RoutePlacement
    /// Rutin sayfasının "Dene" alanındaki yol (örnek için).
    let sample: String
    /// Rotanın hedefi (ad şablonu önerisi oradaki dosya adlarından çıkarılır).
    var destination: URL?
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var expanded = false
    /// Son şablon önerisinin örnekleri (ay adı dilini bulmak için) ve dilin öneriden geldiği.
    @State private var nameExamples: [String] = []
    @State private var folderExamples: [String] = []
    @State private var keepLanguage = false
    /// İçerik alanlarını denemek için yapıştırılan metin (kaydedilmez).
    @State private var sampleText = ""

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(settings.t(.placementAskFolder), isOn: $placement.askFolder)
                        .accessibilityIdentifier("copiator.placement.askFolder")
                    if placement.askFolder {
                        Text(settings.t(.placementAskFolderNote))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !placement.learnedFolders.isEmpty {
                            HStack {
                                Text(settings.t(.placementLearned, placement.learnedFolders.count))
                                    .font(.callout)
                                    .help(placement.learnedFolders.sorted { $0.key < $1.key }
                                        .map { "\(OpenSafety.visibleName($0.key)) → \(OpenSafety.visibleName($0.value.isEmpty ? "/" : $0.value))" }
                                        .joined(separator: "\n"))
                                Button(settings.t(.placementForget)) { placement.learnedFolders = [:] }
                                    .accessibilityIdentifier("copiator.placement.forget")
                            }
                        }
                    }
                }
                LabeledContent(settings.t(.placementFolder)) {
                    HStack {
                        TextField(settings.t(.placementFolder), text: $placement.folderTemplate,
                                  prompt: Text(settings.t(.placementFolderPrompt)))
                            .labelsHidden()
                            .font(.body.monospaced())
                            .accessibilityIdentifier("copiator.placement.folder")
                        Menu(settings.t(.placementPresets)) {
                            ForEach(RoutePlacement.folderPresets, id: \.self) { preset in
                                Button(presetTitle(preset)) { placement.folderTemplate = preset }
                            }
                        }
                        .fixedSize()
                        tokenMenu(content: false) { placement.folderTemplate += $0 }
                    }
                }
                Toggle(settings.t(.placementKeepStructure), isOn: $placement.keepStructure)
                    .disabled(placement.folderTemplate.trimmingCharacters(in: .whitespaces).isEmpty && !placement.askFolder)
                LabeledContent(settings.t(.placementName)) {
                    HStack {
                        TextField(settings.t(.placementName), text: $placement.nameTemplate, prompt: Text(settings.t(.placementNamePrompt)))
                            .labelsHidden()
                            .font(.body.monospaced())
                            .accessibilityIdentifier("copiator.placement.name")
                        tokenMenu(content: true) { placement.nameTemplate += $0 }
                    }
                }
                fieldsEditor
                // Şablonlar önce kurala bağlı çıkarılır (yapay zekâ kapalıyken de); yapay zekâ yalnızca kural çözemezse sorulur.
                if let destination {
                    AITemplateSuggestionRow(title: .aiSuggestFolderTemplate, failure: .aiNoFolderTemplate,
                                            identifier: "copiator.placement.aiFolderTemplate",
                                            fetch: { await folderTemplate(in: destination) }) { template in
                        useLanguage(Suggestions.folderLanguage(template, examples: folderExamples), for: template)
                        placement.folderTemplate = template
                    }
                    AITemplateSuggestionRow(title: .aiSuggestTemplate, failure: .aiNoTemplate, identifier: "copiator.placement.aiTemplate",
                                            fetch: { await nameTemplate(in: destination) }) { template in
                        useLanguage(Suggestions.nameLanguage(template, examples: nameExamples), for: template)
                        placement.nameTemplate = template
                    }
                    if model.canSuggestWithAI { AILanguageWarning() }
                }
                fixesEditor
                Picker(settings.t(.placementDateSource), selection: $placement.dateSource) {
                    ForEach(PlacementDateSource.allCases) { Text(settings.title($0)).tag($0) }
                }
                .disabled(!placement.usesDate)
                if placement.isActive {
                    Text(settings.t(.placementExample, OpenSafety.visibleName(example)))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(placement.problems().enumerated()), id: \.offset) { _, problem in
                    Label(settings.placementProblem(problem), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Text(settings.t(.placementNote))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text(settings.t(.placementTitle)).font(.headline)
                if let summary = settings.describe(placement) {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .onAppear { expanded = placement.isActive }
        .task { await model.refreshLocalModels() }
        // Ay adları şablonun kurulduğu dilde kalır (arayüz dili sonra değişse de klasör adları değişmez).
        .onChange(of: placement.isActive) { _, active in
            if active, !keepLanguage { placement.language = settings.languageCode }
        }
    }

    /// Hedefteki dosya adlarından seçilen modelle (bu Mac'te) ad şablonu önerisi.
    private func nameTemplate(in destination: URL) async -> SuggestionResult<String> {
        let trimmed = sample.trimmingCharacters(in: .whitespaces)
        let name = ((trimmed.isEmpty ? settings.t(.placementSampleFile) : trimmed) as NSString).lastPathComponent
        let suggestionModel = model.canSuggestWithAI ? model.suggestionModel : nil
        let examples = await Task.detached(priority: .userInitiated) { Suggestions.exampleNames(in: destination) }.value
        nameExamples = examples
        return await Suggestions.nameTemplate(for: name, examples: examples, model: suggestionModel)
    }

    /// Hedefteki klasör yollarından seçilen modelle (bu Mac'te) alt klasör şablonu önerisi.
    private func folderTemplate(in destination: URL) async -> SuggestionResult<String> {
        let suggestionModel = model.canSuggestWithAI ? model.suggestionModel : nil
        let examples = await Task.detached(priority: .userInitiated) { Suggestions.exampleFolders(in: destination) }.value
        folderExamples = examples
        return await Suggestions.folderTemplate(examples: examples, model: suggestionModel)
    }

    /// Ay adı içeren önerilen şablonun dili, örneklerin dilidir (Türkçe "Ağustos" örneklerinden çıkan şablon, arayüz
    /// İngilizce olsa da Türkçe ay adı yazar).
    private func useLanguage(_ language: String?, for template: String) {
        guard let language, template.contains(PlacementToken.monthName.text) else { return }
        keepLanguage = true
        placement.language = language
    }

    /// Ad düzeltmeleri: düzenli ifade → yerine yazılacak metin satırları ve hazır düzeltmeler.
    private var fixesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(settings.t(.placementFixes))
                Spacer()
                Menu(settings.t(.placementFixPresets)) {
                    ForEach(Array(zip(Self.presetTitles, NameFix.presets)), id: \.0) { key, preset in
                        // Hazır düzeltme yeni bir kimlikle eklenir (aynısı iki kez eklenebilir).
                        Button(settings.t(key)) { placement.nameFixes.append(NameFix(pattern: preset.pattern, replacement: preset.replacement)) }
                    }
                }
                .fixedSize()
                Button(settings.t(.placementFixAdd), systemImage: "plus") { placement.nameFixes.append(NameFix()) }
                    .accessibilityIdentifier("copiator.placement.addFix")
            }
            ForEach($placement.nameFixes) { $fix in
                let id = fix.id
                HStack {
                    TextField(settings.t(.placementFixPattern), text: $fix.pattern, prompt: Text(settings.t(.placementFixPattern)))
                        .labelsHidden()
                        .font(.body.monospaced())
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField(settings.t(.placementFixReplacement), text: $fix.replacement, prompt: Text(settings.t(.placementFixReplacement)))
                        .labelsHidden()
                        .font(.body.monospaced())
                    Button(settings.t(.placementFixRemove), systemImage: "minus.circle") { placement.nameFixes.removeAll { $0.id == id } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            if !placement.nameFixes.isEmpty {
                Text(settings.t(.placementFixNote))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static let presetTitles: [LKey] = [.placementFixPresetCode, .placementFixPresetSpaces, .placementFixPresetUnderscores]

    /// - Parameter content: İçerik alanlarının belirteçleri de sunulur (yalnızca ad şablonunda).
    private func tokenMenu(content: Bool, insert: @escaping (String) -> Void) -> some View {
        Menu(settings.t(.placementInsertToken)) {
            ForEach(PlacementToken.allCases) { token in
                Button(settings.title(token)) { insert(token.text) }
            }
            let fields = content ? placement.contentFields.filter { ContentField.isValidName($0.name) } : []
            if !fields.isEmpty {
                Divider()
                ForEach(fields) { field in
                    Button(field.token) { insert(field.token) }
                }
            }
        }
        .fixedSize()
    }

    /// İçerikten alınan değerler: ad ve düzenli ifade satırları; yapıştırılan bir metinle denenir.
    private var fieldsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(settings.t(.placementFields))
                Spacer()
                Button(settings.t(.placementFieldAdd), systemImage: "plus") {
                    placement.contentFields.append(ContentField(name: nextFieldName()))
                }
                .accessibilityIdentifier("copiator.placement.addField")
            }
            ForEach($placement.contentFields) { $field in
                let id = field.id
                HStack {
                    TextField(settings.t(.placementFields), text: $field.name, prompt: Text(settings.t(.placementFieldNamePrompt)))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .frame(maxWidth: 120)
                    Image(systemName: "arrow.left").foregroundStyle(.secondary)
                    TextField(settings.t(.placementFields), text: $field.pattern, prompt: Text(settings.t(.placementFieldPatternPrompt)))
                        .labelsHidden()
                        .font(.body.monospaced())
                    Button(settings.t(.placementFieldRemove), systemImage: "minus.circle") { placement.contentFields.removeAll { $0.id == id } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            if !placement.contentFields.isEmpty {
                TextField(settings.t(.placementFieldSample), text: $sampleText, prompt: Text(settings.t(.placementFieldSamplePrompt)), axis: .vertical)
                    .lineLimit(1...4)
                    .font(.callout.monospaced())
                if !sampleText.isEmpty {
                    ForEach(placement.contentFields) { field in
                        let value = field.value(in: sampleText)
                        Text(value.map { settings.t(.placementFieldValue, OpenSafety.visibleName(field.name), OpenSafety.visibleName($0)) }
                             ?? settings.t(.placementFieldNoMatch, OpenSafety.visibleName(field.name)))
                            .font(.callout.monospaced())
                            .foregroundStyle(value == nil ? Color.orange : Color.secondary)
                    }
                }
                Text(settings.t(.placementFieldNote))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Yeni alanın adı: dilin örnek adı, varsa sonuna numara ("abone", "abone2").
    private func nextFieldName() -> String {
        let base = settings.t(.placementFieldNamePrompt)
        let used = Set(placement.contentFields.map(\.name))
        guard used.contains(base) else { return base }
        return (2...).lazy.map { base + String($0) }.first { !used.contains($0) } ?? base
    }

    private func presetTitle(_ preset: String) -> String {
        switch preset {
        case RoutePlacement.folderPresets[0]: settings.t(.placementPresetYearMonthName)
        case RoutePlacement.folderPresets[1]: settings.t(.placementPresetYearMonth)
        default: settings.t(.placementPresetYear)
        }
    }

    /// "Dene" alanındaki yolun (yoksa örnek bir faturanın) hedefteki yeri; tarih addan, bulunamazsa bugün.
    private var example: String {
        let trimmed = sample.trimmingCharacters(in: .whitespaces)
        let path = trimmed.isEmpty ? settings.t(.placementSampleFile) : trimmed
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let date = TextDate.find(in: name) ?? Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        var preview = placement
        if !placement.isActive { preview.language = settings.languageCode }
        // İçerik alanları örnekte yer tutucuyla gösterilir ("‹abone›"); deneme metni varsa onun değeriyle.
        var content: [String: String] = [:]
        for field in placement.contentFields {
            content[field.name] = (sampleText.isEmpty ? nil : field.value(in: sampleText)) ?? "‹\(field.name)›"
        }
        return preview.target(for: path, date: date, destination: destination?.path ?? "", content: content)
    }
}

/// Yapay zekâ ile şablon önerisi: düğme, bekleme, öneri ve "Kullan"; öneri ancak "Kullan" ile uygulanır.
struct AITemplateSuggestionRow: View {
    let title: LKey
    /// Geçerli öneri çıkmadığında gösterilen metin.
    let failure: LKey
    let identifier: String
    let fetch: () async -> SuggestionResult<String>
    let use: (String) -> Void
    @Environment(AppSettings.self) private var settings
    @State private var thinking = false
    @State private var suggestion: String?
    /// Öneri yoksa gösterilen not: `failure` ya da öneri motoru kullanılamıyor.
    @State private var note: LKey?

    var body: some View {
        HStack {
            Button(settings.t(title), systemImage: "sparkles") { run() }
                .disabled(thinking)
                .accessibilityIdentifier(identifier)
            if thinking {
                ProgressView().controlSize(.small)
                Text(settings.t(.aiThinking)).font(.caption).foregroundStyle(.secondary)
            } else if let suggestion {
                Text(settings.t(.aiTemplateSuggestion, suggestion))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Button(settings.t(.aiUseSuggestion)) {
                    use(suggestion)
                    self.suggestion = nil
                }
            } else if let note {
                Text(settings.t(note))
                    .font(.caption)
                    .foregroundStyle(note == .aiEngineUnavailable ? Color.orange : Color.secondary)
            }
        }
    }

    private func run() {
        thinking = true
        suggestion = nil
        note = nil
        Task {
            let result = await fetch()
            thinking = false
            switch result {
            case .value(let value): suggestion = value
            case .noSuggestion: note = failure
            case .unavailable: note = .aiEngineUnavailable
            }
        }
    }
}
