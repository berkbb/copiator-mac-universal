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
        }
    }

    /// Yerleşimin kısa özeti ("{year}/{month}-{monthName} / {name}_{yy}"); şablon yoksa nil.
    func describe(_ placement: RoutePlacement) -> String? {
        guard placement.isActive else { return nil }
        let folder = placement.folderTemplate.trimmingCharacters(in: .whitespaces)
        let name = placement.nameTemplate.trimmingCharacters(in: .whitespaces)
        let parts = [folder, name.isEmpty ? t(.placementSameName) : name].filter { !$0.isEmpty }
        return parts.joined(separator: " / ") + " • " + title(placement.dateSource)
    }
}

/// Rotanın hedefte yerleşimi: alt klasör şablonu (tarih klasörleri), ad şablonu, tarih kaynağı ve örnek.
struct PlacementEditor: View {
    @Binding var placement: RoutePlacement
    /// Rutin sayfasının "Dene" alanındaki yol (örnek için).
    let sample: String
    @Environment(AppSettings.self) private var settings
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
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
                    .disabled(placement.folderTemplate.trimmingCharacters(in: .whitespaces).isEmpty)
                LabeledContent(settings.t(.placementName)) {
                    HStack {
                        TextField(settings.t(.placementName), text: $placement.nameTemplate, prompt: Text(settings.t(.placementNamePrompt)))
                            .labelsHidden()
                            .font(.body.monospaced())
                            .accessibilityIdentifier("copiator.placement.name")
                        tokenMenu { placement.nameTemplate += $0 }
                    }
                }
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
        // Ay adları şablonun kurulduğu dilde kalır (arayüz dili sonra değişse de klasör adları değişmez).
        .onChange(of: placement.isActive) { _, active in
            if active { placement.language = settings.languageCode }
        }
    }

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
        return preview.target(for: path, date: date)
    }
}
