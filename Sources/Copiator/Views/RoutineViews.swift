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
        case .size: t(.ruleAttrSize)
        case .modified: t(.ruleAttrModified)
        case .created: t(.ruleAttrCreated)
        case .added: t(.ruleAttrAdded)
        case .tag: t(.ruleAttrTag)
        case .hidden: t(.ruleAttrHidden)
        case .depth: t(.ruleAttrDepth)
        case .captureDate: t(.ruleAttrCaptureDate)
        case .resolution: t(.ruleAttrResolution)
        case .duration: t(.ruleAttrDuration)
        case .cameraModel: t(.ruleAttrCamera)
        case .content: t(.ruleAttrContent)
        case .inDestination: t(.ruleAttrInDestination)
        }
    }

    /// Karşılaştırmanın adı; "var/yok" özelliğe göre okunur ("gizli", "herhangi bir etiketi var").
    func title(_ op: RuleOperator, for attribute: RuleAttribute = .name) -> String {
        switch op {
        case .contains: t(.ruleOpContains)
        case .equals: t(.ruleOpEquals)
        case .beginsWith: t(.ruleOpBegins)
        case .endsWith: t(.ruleOpEnds)
        case .matchesRegex: t(.ruleOpRegex)
        case .isOneOf: t(.ruleOpOneOf)
        case .greaterThan: t(.ruleOpGreater)
        case .lessThan: t(.ruleOpLess)
        case .atMost: t(.ruleOpAtMost)
        case .atLeast: t(.ruleOpAtLeast)
        case .withinLast: t(.ruleOpWithinLast)
        case .notWithinLast: t(.ruleOpNotWithinLast)
        case .before: t(.ruleOpBefore)
        case .after: t(.ruleOpAfter)
        case .isTrue: t(attribute == .hidden ? .ruleOpHidden : attribute == .inDestination ? .ruleOpExists : .ruleOpHasTag)
        case .isFalse: t(attribute == .hidden ? .ruleOpVisible : attribute == .inDestination ? .ruleOpNotExists : .ruleOpNoTag)
        }
    }

    func title(_ unit: RuleUnit) -> String {
        switch unit {
        case .kilobytes: t(.unitKB)
        case .megabytes: t(.unitMB)
        case .gigabytes: t(.unitGB)
        case .terabytes: t(.unitTB)
        case .seconds: t(.unitSeconds)
        case .minutes: t(.unitMinutes)
        case .hours: t(.unitHours)
        case .days: t(.unitDays)
        case .weeks: t(.unitWeeks)
        case .months: t(.unitMonths)
        case .years: t(.unitYears)
        case .pixels: t(.unitPixels)
        case .levels: t(.unitLevels)
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
            let attribute = title(condition.attribute)
            let op = title(condition.op, for: condition.attribute).lowercased(with: locale)
            let value: String
            switch condition.op.input(for: condition.attribute) {
            case .none: return t(.ruleConditionFormatNoValue, attribute, op)
            case .number:
                let number = condition.number.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
                value = number + (condition.unit.map { " " + title($0) } ?? "")
                // "son 7 gün içinde": dilde karşılaştırma sayının iki yanına düşebilir.
                if condition.op == .withinLast { return t(.ruleWithinFormat, attribute, value) }
                if condition.op == .notWithinLast { return t(.ruleNotWithinFormat, attribute, value) }
            case .date: value = condition.date.map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)) } ?? ""
            case .text:
                value = condition.attribute == .kind ? FileKind(rawValue: condition.value).map(title) ?? condition.value : condition.value
            }
            return t(.ruleConditionFormat, attribute, op, value)
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
                ForEach(RuleAttribute.basic) { Text(settings.title($0)).tag($0) }
                Section(settings.t(.ruleAdvancedSection)) {
                    ForEach(RuleAttribute.advanced) { Text(settings.title($0)).tag($0) }
                }
            }
            .labelsHidden()
            .fixedSize()
            Picker(settings.t(.ruleOpContains), selection: $condition.op) {
                ForEach(condition.attribute.operators) { Text(settings.title($0, for: condition.attribute)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            valueEditor
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(settings.t(.buttonRemove))
            .accessibilityLabel(settings.t(.buttonRemove))
        }
    }

    /// Karşılaştırmaya göre değer alanı: metin, tür, sayı ve birim, gün ya da hiçbiri.
    @ViewBuilder
    private var valueEditor: some View {
        switch condition.op.input(for: condition.attribute) {
        case .none:
            EmptyView()
        case .number:
            TextField(settings.t(.ruleValuePlaceholder), value: $condition.number, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            let units = condition.attribute.units
            if units.count > 1 {
                Picker(settings.t(.ruleValuePlaceholder), selection: unit) {
                    ForEach(units) { Text(settings.title($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            } else if let unit = units.first {
                Text(settings.title(unit)).foregroundStyle(.secondary)
            }
        case .date:
            DatePicker(settings.t(.ruleValuePlaceholder), selection: day, displayedComponents: .date)
                .labelsHidden()
                .fixedSize()
        case .text where condition.attribute == .kind:
            Picker(settings.t(.ruleAttrKind), selection: $condition.value) {
                ForEach(FileKind.allCases) { Text(settings.title($0)).tag($0.rawValue) }
            }
            .labelsHidden()
        case .text:
            TextField(settings.t(placeholder), text: $condition.value)
                .font(condition.op == .matchesRegex ? .body.monospaced() : .body)
                .labelsHidden()
            if let error = regexError {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .help(settings.t(.ruleRegexInvalid) + "\n" + error)
                    .accessibilityLabel(settings.t(.ruleRegexInvalid))
            }
        }
    }

    private var placeholder: LKey {
        switch (condition.attribute, condition.op) {
        case (_, .matchesRegex): .ruleRegexPlaceholder
        case (_, .isOneOf): .ruleListPlaceholder
        case (.tag, _): .ruleTagPlaceholder
        default: .ruleValuePlaceholder
        }
    }

    private var unit: Binding<RuleUnit> {
        Binding(get: { condition.unit ?? condition.attribute.units.first ?? .days }, set: { condition.unit = $0 })
    }

    /// "Önce/sonra" günü; seçilmemişse bugün gösterilir ve seçilince kaydedilir.
    private var day: Binding<Date> {
        Binding(get: { condition.date ?? Calendar.current.startOfDay(for: Date()) }, set: { condition.date = Calendar.current.startOfDay(for: $0) })
    }

    /// Özellik değişince karşılaştırma ve değer o özelliğe uygun bir başlangıca döner; iki metin özelliği arasında yazılan
    /// değer ve (uygunsa) karşılaştırma korunur.
    private var attribute: Binding<RuleAttribute> {
        Binding(
            get: { condition.attribute },
            set: { newValue in
                let old = condition
                var fresh = RuleCondition.starting(newValue)
                fresh.id = old.id
                if old.attribute.valueKind == .text, newValue.valueKind == .text {
                    fresh.value = old.value
                    if newValue.operators.contains(old.op) { fresh.op = old.op }
                }
                condition = fresh
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
    @State private var confirmTrash = false
    @State private var runAfterSave = false
    @State private var previewTask: Task<Void, Never>?
    @State private var previewPresentation: PreviewPresentation?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(settings.t(.routineName), text: $routine.name, prompt: Text(settings.t(.routineNamePlaceholder)))
                        .accessibilityIdentifier("copiator.routine.name")
                    Picker(settings.t(.routineKind), selection: $routine.kind) {
                        Text(settings.t(.routineKindCopy)).tag(RoutineKind.copy)
                        Text(settings.t(.routineKindSync)).tag(RoutineKind.sync)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("copiator.routine.kind")
                } footer: {
                    Text(settings.t(routine.kind == .sync ? .routineKindSyncNote : .routineRoutesNote))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach($routine.routes) { $route in
                    let index = routine.routes.firstIndex { $0.id == route.id } ?? 0
                    Section {
                        let sync = routine.kind == .sync
                        FolderChooserRow(title: settings.t(sync ? .syncFolderA : .newJobSource), url: $route.source, systemImage: "folder",
                                         panelMessage: settings.t(.panelChooseSource))
                        FolderChooserRow(title: settings.t(sync ? .syncFolderB : .newJobDestination), url: $route.destination,
                                         systemImage: sync ? "folder" : "externaldrive", panelMessage: settings.t(.panelChooseDestination))
                        if !sync {
                            HStack {
                                Spacer()
                                FolderSuggestionButton(destination: $route.destination, sample: sample)
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(settings.t(.routineRules)).font(.headline)
                            RuleGroupEditor(group: $route.rules)
                        }
                        if !sync {
                            PlacementEditor(placement: $route.placement, sample: sample, destination: route.destination)
                        }
                        HStack {
                            Button(settings.t(.newJobPreview), systemImage: "eye") { preview(route) }
                                .disabled(route.source == nil || route.destination == nil || previewTask != nil
                                          || !route.rules.problems().isEmpty || !route.placement.problems().isEmpty)
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
                            let evaluator = try? RuleEvaluator(route.rules)
                            let matches = evaluator?.matches(RuleItem(relativePath: sample)) ?? false
                            if evaluator?.runawayPattern != nil {
                                Label(settings.t(.routineSampleTooComplex, index + 1), systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            } else {
                                Label(settings.t(matches ? .routineSampleMatches : .routineSampleNoMatch, index + 1),
                                      systemImage: matches ? "checkmark.circle.fill" : "xmark.circle")
                                    .foregroundStyle(matches ? .green : .secondary)
                            }
                        }
                    }
                } header: {
                    Text(settings.t(.routineSampleTitle))
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.t(.routineSampleNote))
                        if routine.routes.contains(where: { $0.rules.allConditions.contains { $0.attribute.isAdvanced } }) {
                            Text(settings.t(.routineSampleAdvancedNote))
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section(settings.t(.routineOptions)) {
                    Toggle(settings.t(.optionPreservePermissions), isOn: $routine.options.preservePermissions)
                    Toggle(settings.t(.optionXattrs), isOn: $routine.options.preserveExtendedAttributes)
                    Toggle(settings.t(.optionExcludeSystem), isOn: $routine.options.excludeSystemFolders)
                    ConflictPolicyPicker(selection: $routine.options.conflictPolicy, kind: routine.jobKind)
                    if routine.kind == .copy {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(settings.t(.optionTrashSource), isOn: $routine.options.trashSourceAfterCopy)
                                .disabled(routine.options.snapshots.enabled)
                            Text(settings.t(.optionTrashSourceNote))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if routine.kind == .copy {
                    SnapshotSection(options: $routine.options.snapshots)
                }
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
                Button(settings.t(.routineSaveRun)) { requestSave(run: true) }
                    .disabled(!routine.problems(checkPaths: false).isEmpty)
                    .accessibilityIdentifier("copiator.routine.saveRun")
                Button(settings.t(.routineSave)) { requestSave(run: false) }
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
        .confirmationDialog(settings.t(.trashConfirmTitle), isPresented: $confirmTrash, titleVisibility: .visible) {
            Button(settings.t(.trashConfirmButton), role: .destructive) { save(run: runAfterSave) }
            Button(settings.t(.buttonCancel), role: .cancel) {}
        } message: {
            Text(settings.t(.trashConfirmMessage, routine.routes.compactMap { $0.source.map { OpenSafety.visibleName($0.path) } }.joined(separator: ", ")))
        }
    }

    /// "Kaynak dosyaları Çöp Sepeti'ne taşı" yeni seçildiyse kaydetmeden önce onay istenir.
    private func requestSave(run: Bool) {
        let alreadyOn = request.isExisting && request.routine.options.trashSourceAfterCopy
        if routine.kind == .copy, routine.options.trashSourceAfterCopy && !routine.options.snapshots.enabled && !alreadyOn {
            runAfterSave = run
            confirmTrash = true
        } else {
            save(run: run)
        }
    }

    private func preview(_ route: RoutineRoute) {
        guard previewTask == nil else { return }
        let routine = routine
        let name = routine.name.isEmpty ? (route.source?.lastPathComponent ?? "") : routine.name
        previewTask = Task {
            if let report = await model.previewRoute(route, of: routine), !Task.isCancelled, report.result.kind != .cancelled {
                previewPresentation = PreviewPresentation(jobName: name, report: report, deleteEnabled: false, sync: routine.kind == .sync)
            }
            previewTask = nil
        }
    }

    private func save(run: Bool) {
        if routine.options.snapshots.enabled { routine.options.trashSourceAfterCopy = false }
        if !ConflictPolicy.choices(for: routine.jobKind).contains(routine.options.conflictPolicy) { routine.options.conflictPolicy = .ask }
        if routine.kind == .sync {
            routine.options.snapshots.enabled = false
            routine.options.trashSourceAfterCopy = false
        }
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
                    Text((routine.kind == .sync ? settings.t(.routineKindSync) + " • " : "")
                         + (routine.lastRunAt.map { settings.t(.routineLastRun, settings.date($0)) } ?? settings.t(.routineNeverRun)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            ForEach(Array(routine.routes.enumerated()), id: \.element.id) { index, route in
                Section(settings.t(.routineRoute, index + 1)) {
                    let sync = routine.kind == .sync
                    LabeledContent(settings.t(sync ? .syncFolderA : .newJobSource), value: OpenSafety.visibleName(route.source?.path ?? ""))
                    LabeledContent(settings.t(sync ? .syncFolderB : .newJobDestination), value: OpenSafety.visibleName(route.destination?.path ?? ""))
                    // Uzun kurallar kesilmeden, etiketin altında okunur (liste kaydırılabilir; yükseklik sütunu etkilemez).
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settings.t(.routineRules))
                        Text(settings.describe(route.rules))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let placement = settings.describe(route.placement) {
                        LabeledContent(settings.t(.placementTitle), value: placement)
                    }
                    if let destination = route.destination {
                        Button(settings.t(.menuDestinationSummary), systemImage: "chart.bar.doc.horizontal") {
                            model.showDestinationSummary(destination)
                        }
                        .buttonStyle(.borderless)
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
