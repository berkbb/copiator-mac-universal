// SPDX-License-Identifier: GPL-3.0-or-later
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
        }
    }

    /// Yerleşimin kısa özeti ("{year}/{month}-{monthName} / {name}_{yy}"); şablon yoksa nil.
    func describe(_ placement: RoutePlacement) -> String? {
        guard placement.isActive else { return nil }
        let folder = placement.folderTemplate.trimmingCharacters(in: .whitespaces)
        let name = placement.nameTemplate.trimmingCharacters(in: .whitespaces)
        let parts = [folder, name.isEmpty ? t(.placementSameName) : name].filter { !$0.isEmpty }
        let fixes = placement.nameFixes.filter { !$0.pattern.isEmpty }.count
        return (placement.askFolder ? t(.placementAskSummary) + " / " : "") + parts.joined(separator: " / ")
            + (fixes > 0 ? " • " + t(.placementFixesSummary, fixes) : "") + " • " + title(placement.dateSource)
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
                        tokenMenu { placement.folderTemplate += $0 }
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
                        tokenMenu { placement.nameTemplate += $0 }
                    }
                }
                if model.canSuggestWithAI, let destination {
                    AITemplateSuggestionRow(title: .aiSuggestFolderTemplate, failure: .aiNoFolderTemplate,
                                            identifier: "copiator.placement.aiFolderTemplate",
                                            fetch: { await folderTemplate(in: destination) }, use: { placement.folderTemplate = $0 })
                    AITemplateSuggestionRow(title: .aiSuggestTemplate, failure: .aiNoTemplate, identifier: "copiator.placement.aiTemplate",
                                            fetch: { await nameTemplate(in: destination) }, use: { placement.nameTemplate = $0 })
                    AILanguageWarning()
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
            if active { placement.language = settings.languageCode }
        }
    }

    /// Hedefteki dosya adlarından seçilen modelle (bu Mac'te) ad şablonu önerisi.
    private func nameTemplate(in destination: URL) async -> String? {
        let trimmed = sample.trimmingCharacters(in: .whitespaces)
        let name = ((trimmed.isEmpty ? settings.t(.placementSampleFile) : trimmed) as NSString).lastPathComponent
        let suggestionModel = model.suggestionModel
        let examples = await Task.detached(priority: .userInitiated) { Suggestions.exampleNames(in: destination) }.value
        return await Suggestions.nameTemplate(for: name, examples: examples, model: suggestionModel)
    }

    /// Hedefteki klasör yollarından seçilen modelle (bu Mac'te) alt klasör şablonu önerisi.
    private func folderTemplate(in destination: URL) async -> String? {
        let suggestionModel = model.suggestionModel
        let examples = await Task.detached(priority: .userInitiated) { Suggestions.exampleFolders(in: destination) }.value
        return await Suggestions.folderTemplate(examples: examples, model: suggestionModel)
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

    private func tokenMenu(insert: @escaping (String) -> Void) -> some View {
        Menu(settings.t(.placementInsertToken)) {
            ForEach(PlacementToken.allCases) { token in
                Button(settings.title(token)) { insert(token.text) }
            }
        }
        .fixedSize()
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
        return preview.target(for: path, date: date, destination: destination?.path ?? "")
    }
}

/// Yapay zekâ ile şablon önerisi: düğme, bekleme, öneri ve "Kullan"; öneri ancak "Kullan" ile uygulanır.
struct AITemplateSuggestionRow: View {
    let title: LKey
    /// Öneri çıkmadığında gösterilen metin.
    let failure: LKey
    let identifier: String
    let fetch: () async -> String?
    let use: (String) -> Void
    @Environment(AppSettings.self) private var settings
    @State private var thinking = false
    @State private var suggestion: String?
    @State private var failed = false

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
            } else if failed {
                Text(settings.t(failure)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func run() {
        thinking = true
        suggestion = nil
        failed = false
        Task {
            let result = await fetch()
            thinking = false
            suggestion = result
            failed = result == nil
        }
    }
}
