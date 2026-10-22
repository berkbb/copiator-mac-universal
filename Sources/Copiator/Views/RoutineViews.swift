// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CopiatorCore
import SwiftUI

// MARK: - Kural metinleri

extension AppSettings {
    func title(_ attribute: RuleAttribute) -> String {
        switch attribute {
        case .name: t(.ruleAttrName)
        case .fileExtension: t(.ruleAttrExtension)
        case .folderName: t(.ruleAttrFolder)
        case .path: t(.ruleAttrPath)
        case .kind: t(.ruleAttrKind)
        }
    }

    func title(_ op: RuleOperator) -> String {
        switch op {
        case .contains: t(.ruleOpContains)
        case .equals: t(.ruleOpEquals)
        case .beginsWith: t(.ruleOpBegins)
        case .endsWith: t(.ruleOpEnds)
        case .matchesRegex: t(.ruleOpRegex)
        }
    }

    func title(_ kind: FileKind) -> String {
        switch kind {
        case .image: t(.fileKindImage)
        case .movie: t(.fileKindMovie)
        case .audio: t(.fileKindAudio)
        case .pdf: t(.fileKindPDF)
        case .document: t(.fileKindDocument)
        case .spreadsheet: t(.fileKindSpreadsheet)
        case .presentation: t(.fileKindPresentation)
        case .text: t(.fileKindText)
        case .sourceCode: t(.fileKindSourceCode)
        case .archive: t(.fileKindArchive)
        case .application: t(.fileKindApplication)
        }
    }

    func title(_ match: RuleMatch) -> String {
        switch match {
        case .all: t(.ruleMatchAll)
        case .any: t(.ruleMatchAny)
        case .none: t(.ruleMatchNone)
        }
    }

    /// Kuralların okunur özeti: "Uzantı eşittir “xlsx” ve (Ad içerir “rapor” veya …)".
    func describe(_ group: RuleGroup) -> String {
        guard !group.isEmpty else { return t(.rulesEverything) }
        let conditions = group.conditions.map { condition in
            let value = condition.attribute == .kind ? FileKind(rawValue: condition.value).map(title) ?? condition.value : condition.value
            return t(.ruleConditionFormat, title(condition.attribute), title(condition.op).lowercased(with: locale), value)
        }
        let parts = conditions + group.groups.filter { !$0.isEmpty }.map { "(" + describe($0) + ")" }
        switch group.match {
        case .all: return parts.joined(separator: t(.rulesAnd))
        case .any: return parts.joined(separator: t(.rulesOr))
        case .none: return t(.rulesNoneOf, parts.joined(separator: t(.rulesOr)))
        }
    }
}

// MARK: - Kural düzenleyici

/// Tek koşul satırı: [özellik] [karşılaştırma] [değer] [−].
struct RuleConditionRow: View {
    @Binding var condition: RuleCondition
    let onRemove: () -> Void
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 6) {
            Picker(settings.t(.ruleAttrName), selection: attribute) {
                ForEach(RuleAttribute.allCases) { Text(settings.title($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Picker(settings.t(.ruleOpContains), selection: $condition.op) {
                ForEach(condition.attribute.operators) { Text(settings.title($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if condition.attribute == .kind {
                Picker(settings.t(.ruleAttrKind), selection: $condition.value) {
                    ForEach(FileKind.allCases) { Text(settings.title($0)).tag($0.rawValue) }
                }
                .labelsHidden()
            } else {
                TextField(settings.t(condition.op == .matchesRegex ? .ruleRegexPlaceholder : .ruleValuePlaceholder), text: $condition.value)
                    .font(condition.op == .matchesRegex ? .body.monospaced() : .body)
                    .labelsHidden()
                if let error = regexError {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                        .help(settings.t(.ruleRegexInvalid) + "\n" + error)
                        .accessibilityLabel(settings.t(.ruleRegexInvalid))
                }
            }
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(settings.t(.buttonRemove))
            .accessibilityLabel(settings.t(.buttonRemove))
        }
    }

    /// Özellik değişince karşılaştırma ve değer uygun hâle gelir (tür seçilince değer bir tür olur).
    private var attribute: Binding<RuleAttribute> {
        Binding(
            get: { condition.attribute },
            set: { newValue in
                let wasKind = condition.attribute == .kind
                condition.attribute = newValue
                if !newValue.operators.contains(condition.op) { condition.op = newValue.operators[0] }
                if newValue == .kind, FileKind(rawValue: condition.value) == nil { condition.value = FileKind.image.rawValue }
                if wasKind, newValue != .kind { condition.value = "" }
            }
        )
    }

    private var regexError: String? {
        guard condition.op == .matchesRegex, !condition.value.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: condition.value)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Koşul grubu: [Tümü/Herhangi biri/Hiçbiri doğru], koşullar, iç içe gruplar ve ekleme düğmeleri.
struct RuleGroupEditor: View {
    @Binding var group: RuleGroup
    var depth = 0
    var onRemove: (() -> Void)?
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(settings.t(.ruleGroupLabel), selection: $group.match) {
                    ForEach(RuleMatch.allCases) { Text(settings.title($0)).tag($0) }
                }
                .fixedSize()
                Spacer()
                if let onRemove {
                    Button(settings.t(.ruleRemoveGroup), systemImage: "minus.circle", action: onRemove)
                        .buttonStyle(.borderless)
                }
            }
            ForEach($group.conditions) { $condition in
                let id = condition.id
                RuleConditionRow(condition: $condition) { group.conditions.removeAll { $0.id == id } }
            }
            ForEach($group.groups) { $child in
                let id = child.id
                RuleGroupEditor(group: $child, depth: depth + 1) { group.groups.removeAll { $0.id == id } }
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2)
                    }
            }
            HStack(spacing: 14) {
                Button(settings.t(.ruleAddCondition), systemImage: "plus.circle") {
                    group.conditions.append(RuleCondition(attribute: .name, op: .contains))
                }
                if depth < RuleGroup.maxDepth - 1 {
                    Button(settings.t(.ruleAddGroup), systemImage: "plus.rectangle.on.rectangle") {
                        group.groups.append(RuleGroup(match: .any, conditions: [RuleCondition()]))
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }
}

// MARK: - Yol seçici

/// Klasör seçme satırı (Yeni İş ve rutin sayfaları).
struct FolderChooserRow: View {
    let title: String
    @Binding var url: URL?
    let systemImage: String
    let panelMessage: String
    @Environment(AppSettings.self) private var settings

    var body: some View {
        LabeledContent(title) {
            HStack {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Text(OpenSafety.visibleName(url.path))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: systemImage)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Button(settings.t(.buttonChoose)) { choose() }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.message = panelMessage
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let url { panel.directoryURL = url }
        if panel.runModal() == .OK, let chosen = panel.url { url = chosen }
    }
}

// MARK: - Rutin düzenleme sayfası

struct RoutineEditorSheet: View {
    let request: RoutineEditorRequest
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var routine = Routine()
    @State private var problem: String?
    @State private var sample = ""
    @State private var showAdvanced = false
    @State private var previewTask: Task<Void, Never>?
    @State private var previewPresentation: PreviewPresentation?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(settings.t(.routineName), text: $routine.name, prompt: Text(settings.t(.routineNamePlaceholder)))
                        .accessibilityIdentifier("copiator.routine.name")
                } footer: {
                    Text(settings.t(.routineRoutesNote))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach($routine.routes) { $route in
                    let index = routine.routes.firstIndex { $0.id == route.id } ?? 0
                    Section {
                        FolderChooserRow(title: settings.t(.newJobSource), url: $route.source, systemImage: "folder",
                                         panelMessage: settings.t(.panelChooseSource))
                        FolderChooserRow(title: settings.t(.newJobDestination), url: $route.destination, systemImage: "externaldrive",
                                         panelMessage: settings.t(.panelChooseDestination))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(settings.t(.routineRules)).font(.headline)
                            RuleGroupEditor(group: $route.rules)
                        }
                        HStack {
                            Button(settings.t(.newJobPreview), systemImage: "eye") { preview(route) }
                                .disabled(route.source == nil || route.destination == nil || previewTask != nil
                                          || !route.rules.problems().isEmpty)
                            if previewTask != nil { ProgressView().controlSize(.small) }
                            Spacer()
                            if routine.routes.count > 1 {
                                Button(settings.t(.routineRemoveRoute), systemImage: "trash", role: .destructive) {
                                    let id = route.id
                                    routine.routes.removeAll { $0.id == id }
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                    } header: {
                        Text(settings.t(.routineRoute, index + 1))
                    }
                }

                Section {
                    Button(settings.t(.routineAddRoute), systemImage: "plus") {
                        routine.routes.append(RoutineRoute(source: routine.routes.last?.source))
                    }
                    .accessibilityIdentifier("copiator.routine.addRoute")
                }

                Section {
                    TextField(settings.t(.routineSampleTitle), text: $sample, prompt: Text(settings.t(.routineSamplePlaceholder)))
                        .font(.body.monospaced())
                    if !sample.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(Array(routine.routes.enumerated()), id: \.element.id) { index, route in
                            let matches = (try? RuleEvaluator(route.rules).matches(RuleItem(relativePath: sample))) ?? false
                            Label(settings.t(matches ? .routineSampleMatches : .routineSampleNoMatch, index + 1),
                                  systemImage: matches ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(matches ? .green : .secondary)
                        }
                    }
                } header: {
                    Text(settings.t(.routineSampleTitle))
                } footer: {
                    Text(settings.t(.routineSampleNote)).font(.footnote).foregroundStyle(.secondary)
                }

                Section(settings.t(.routineOptions)) {
                    Toggle(settings.t(.optionPreservePermissions), isOn: $routine.options.preservePermissions)
                    Toggle(settings.t(.optionXattrs), isOn: $routine.options.preserveExtendedAttributes)
                    Toggle(settings.t(.optionExcludeSystem), isOn: $routine.options.excludeSystemFolders)
                }
                SnapshotSection(options: $routine.options.snapshots)
                AutomationSection(options: $routine.options)
                Section {
                    Toggle(settings.t(.newJobAdvanced), isOn: $showAdvanced)
                }
                if showAdvanced {
                    AdvancedOptionsSections(options: $routine.options.advanced, deleteEnabled: false,
                                            snapshotsEnabled: routine.options.snapshots.enabled)
                }

                let problems = routine.problems(checkPaths: false)
                if problem != nil || !problems.isEmpty {
                    Section {
                        if let problem {
                            Label(problem, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red).font(.callout)
                        }
                        ForEach(problems.indices, id: \.self) { index in
                            Label(settings.routineProblem(problems[index]), systemImage: "exclamationmark.octagon.fill")
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(settings.t(.buttonCancel), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.t(.routineSaveRun)) { save(run: true) }
                    .disabled(!routine.problems(checkPaths: false).isEmpty)
                    .accessibilityIdentifier("copiator.routine.saveRun")
                Button(settings.t(.routineSave)) { save(run: false) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!routine.problems(checkPaths: false).isEmpty)
                    .accessibilityIdentifier("copiator.routine.save")
            }
            .padding(14)
        }
        .frame(width: 680)
        .frame(minHeight: 640)
        .navigationTitle(settings.t(request.isExisting ? .routineEditTitle : .routineNewTitle))
        .onAppear {
            routine = request.routine
            showAdvanced = !routine.options.advanced.isDefault
        }
        .onDisappear { previewTask?.cancel() }
        .onChange(of: routine) { problem = nil }
        .sheet(item: $previewPresentation) { PreviewSheet(presentation: $0) }
    }

    private func preview(_ route: RoutineRoute) {
        guard previewTask == nil else { return }
        let routine = routine
        let name = routine.name.isEmpty ? (route.source?.lastPathComponent ?? "") : routine.name
        previewTask = Task {
            if let report = await model.previewRoute(route, of: routine), !Task.isCancelled, report.result.kind != .cancelled {
                previewPresentation = PreviewPresentation(jobName: name, report: report, deleteEnabled: false)
            }
            previewTask = nil
        }
    }

    private func save(run: Bool) {
        if let message = model.saveRoutine(routine) {
            problem = message
            return
        }
        if run { model.runRoutine(routine.id) }
        dismiss()
    }
}

// MARK: - Rutin ayrıntısı (ana sütun)

struct RoutineDetailView: View {
    let routine: Routine
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var model = model
        let jobs = model.jobs(for: routine.id)
        List(selection: $model.selection) {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(OpenSafety.visibleName(routine.name), systemImage: "wand.and.stars")
                            .font(.title2.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        Button(settings.t(.routineRun), systemImage: "play.fill") { model.runRoutine(routine.id) }
                            .buttonStyle(.glassProminent)
                            .accessibilityIdentifier("copiator.routine.run")
                        Button(settings.t(.menuEditJob)) { model.beginEditRoutine(routine.id) }
                        Menu {
                            Button(settings.t(.menuDuplicateJob), systemImage: "plus.square.on.square") { model.beginDuplicateRoutine(routine.id) }
                            Button(settings.t(.routineDelete), systemImage: "trash", role: .destructive) { model.requestDeleteRoutine(routine.id) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(settings.t(.routineMore))
                        .accessibilityLabel(settings.t(.routineMore))
                    }
                    Text(routine.lastRunAt.map { settings.t(.routineLastRun, settings.date($0)) } ?? settings.t(.routineNeverRun))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            ForEach(Array(routine.routes.enumerated()), id: \.element.id) { index, route in
                Section(settings.t(.routineRoute, index + 1)) {
                    LabeledContent(settings.t(.newJobSource), value: OpenSafety.visibleName(route.source?.path ?? ""))
                    LabeledContent(settings.t(.newJobDestination), value: OpenSafety.visibleName(route.destination?.path ?? ""))
                    // Uzun kurallar kesilmeden, etiketin altında okunur (liste kaydırılabilir; yükseklik sütunu etkilemez).
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settings.t(.routineRules))
                        Text(settings.describe(route.rules))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section(settings.t(.routineJobs)) {
                if jobs.isEmpty {
                    Text(settings.t(.routineNoJobs)).foregroundStyle(.secondary)
                } else {
                    ForEach(jobs) { job in
                        JobRow(job: job, model: model, settings: settings)
                            .tag(job.id)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}
