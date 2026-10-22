// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CopiatorCore
import SwiftUI

struct NewJobSheet: View {
    let request: NewJobRequest
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var source: URL?
    @State private var destination: URL?
    @State private var options = CopyOptions()
    @State private var problem: String?
    @State private var confirmDelete = false
    @State private var confirmRetention = false
    @State private var isSourceTargeted = false
    @State private var showAdvanced = false
    @State private var previewTask: Task<Void, Never>?
    @State private var previewPresentation: PreviewPresentation?

    /// Düzenlenen iş (yeni işte nil).
    private var editedJob: TransferJob? { request.editing.flatMap(model.job) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    pathRow(.newJobSource, url: source, systemImage: "folder", choose: chooseSource)
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let first = urls.first(where: \.isFileURL) else { return false }
                            source = first
                            return true
                        } isTargeted: { isSourceTargeted = $0 }
                        .listRowBackground(isSourceTargeted ? Color.accentColor.opacity(0.1) : nil)
                    pathRow(.newJobDestination, url: destination, systemImage: "externaldrive", choose: chooseDestination)
                } footer: {
                    if source == nil {
                        Text(settings.t(.newJobDropSource)).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section(settings.t(.newJobMode)) {
                    Picker(settings.t(.newJobMode), selection: $options.copyMode) {
                        Text(settings.t(.modeFolder)).tag(CopyMode.folder)
                        Text(settings.t(.modeContents)).tag(CopyMode.contents)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(!sourceIsDirectory)
                    if let preview = resultPreview {
                        Text(preview)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section(settings.t(.newJobOptions)) {
                    option(.optionPreservePermissions, note: permissionsNote, isOn: $options.preservePermissions)
                        .disabled(destinationFileSystem.lacksPosixMetadata)
                    option(.optionXattrs, note: settings.t(.optionXattrsNote), isOn: $options.preserveExtendedAttributes)
                    option(.optionExcludeSystem, note: settings.t(.optionExcludeSystemNote), isOn: $options.excludeSystemFolders)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(settings.t(.optionDelete), isOn: $options.deleteExtraneous)
                            .accessibilityIdentifier("copiator.newjob.delete")
                            // Anlık görüntü her çalıştırmada yeni bir klasöre yazar: silinecek eski dosya yoktur.
                            .disabled(options.snapshots.enabled)
                        if options.deleteExtraneous && !options.snapshots.enabled {
                            Label(settings.t(.optionDeleteWarning), systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                SnapshotSection(options: $options.snapshots)
                AutomationSection(options: $options)

                Section {
                    Toggle(settings.t(.newJobAdvanced), isOn: $showAdvanced)
                        .accessibilityIdentifier("copiator.newjob.advanced")
                }
                if showAdvanced {
                    AdvancedOptionsSections(options: $options.advanced, deleteEnabled: options.deleteExtraneous,
                                            snapshotsEnabled: options.snapshots.enabled)
                }

                if let job = previewJob {
                    Section {
                        CommandPreview(command: model.commandPreview(for: job))
                    }
                }

                let problems = options.problems(source: source)
                if problem != nil || !problems.isEmpty {
                    Section {
                        if let problem {
                            Label(problem, systemImage: "exclamationmark.octagon.fill")
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                        ForEach(problems.indices, id: \.self) { index in
                            Label(settings.problem(problems[index]), systemImage: "exclamationmark.octagon.fill")
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                // Önizleme: iş eklenmeden kuru çalıştırılır; neyin kopyalanacağı ve silineceği listelenir.
                Button {
                    runPreview()
                } label: {
                    Label(settings.t(.newJobPreview), systemImage: "eye")
                }
                .disabled(source == nil || destination == nil || previewTask != nil || !options.problems(source: source).isEmpty)
                .accessibilityIdentifier("copiator.newjob.preview")
                if previewTask != nil {
                    ProgressView().controlSize(.small)
                    Button(settings.t(.buttonCancel)) { cancelPreview() }
                }
                Spacer()
                Button(settings.t(.buttonCancel), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.t(editedJob == nil ? .newJobAdd : .editJobSave)) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(source == nil || destination == nil || !options.problems(source: source).isEmpty)
                    .accessibilityIdentifier("copiator.newjob.add")
            }
            .padding(14)
        }
        .frame(width: 620)
        .frame(minHeight: 600)
        .navigationTitle(settings.t(editedJob == nil ? .newJobTitle : .editJobTitle))
        .onAppear {
            source = request.source
            destination = request.destination
            options = request.options ?? settings.defaultOptions
            showAdvanced = !options.advanced.isDefault
        }
        .onDisappear { cancelPreview() }
        .onChange(of: source) { problem = nil }
        .onChange(of: destination) { problem = nil }
        .sheet(item: $previewPresentation) { PreviewSheet(presentation: $0) }
        .confirmationDialog(settings.t(.deleteConfirmTitle), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(settings.t(.deleteConfirmButton), role: .destructive) {
                // İkinci onay, birinci kapandıktan sonra açılır.
                if needsRetentionConfirmation { DispatchQueue.main.async { confirmRetention = true } } else { commit() }
            }
            Button(settings.t(.newJobPreview)) { runPreview() }
            Button(settings.t(.buttonCancel), role: .cancel) {}
        } message: {
            Text(settings.t(.deleteConfirmMessage, OpenSafety.visibleName(targetPath ?? "")))
        }
        .confirmationDialog(settings.t(.retentionConfirmTitle), isPresented: $confirmRetention, titleVisibility: .visible) {
            Button(settings.t(.retentionConfirmButton), role: .destructive) { commit() }
            Button(settings.t(.buttonCancel), role: .cancel) {}
        } message: {
            Text(settings.t(.retentionConfirmMessage, OpenSafety.visibleName(destination?.path ?? "")))
        }
    }

    /// `--delete` yeni seçildiyse onay gerekir (düzenlenen işte zaten seçiliyse yeniden sorulmaz).
    private var needsDeleteConfirmation: Bool {
        options.deleteExtraneous && !options.snapshots.enabled && editedJob?.options.deleteExtraneous != true
    }

    /// Saklama kuralları eski anlık görüntüleri siler: kurallar yeni ya da değişmişse onay gerekir.
    private var needsRetentionConfirmation: Bool {
        options.snapshots.hasRetention && editedJob?.options.snapshots != options.snapshots
    }

    private func runPreview() {
        guard let source, let destination, previewTask == nil else { return }
        var options = finalOptions
        if !sourceIsDirectory { options.copyMode = .folder }
        let name = source.lastPathComponent
        previewTask = Task {
            let report = await model.preview(source: source, destination: destination, options: options)
            if !Task.isCancelled, report.result.kind != .cancelled {
                previewPresentation = PreviewPresentation(jobName: name, report: report, deleteEnabled: options.deleteExtraneous)
            }
            previewTask = nil
        }
    }

    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
    }

    /// Kaydedilecek seçenekler: anlık görüntü kipinde `--delete` kullanılmaz.
    private var finalOptions: CopyOptions {
        var options = options
        if options.snapshots.enabled { options.deleteExtraneous = false }
        return options
    }

    private var sourceIsDirectory: Bool { source.map(RsyncEngine.isDirectory) ?? true }

    private var destinationFileSystem: FileSystemKind { destination.map { FileSystemKind.of($0) } ?? .apfs }

    private var permissionsNote: String {
        destinationFileSystem.lacksPosixMetadata
            ? settings.t(.optionPermissionsUnavailable, destinationFileSystem.rawValue)
            : settings.t(.optionPreservePermissionsNote)
    }

    /// Komut önizlemesi için iş (kaynak ve hedef seçildiyse).
    private var previewJob: TransferJob? {
        guard let source, let destination else { return nil }
        var options = options
        if !sourceIsDirectory { options.copyMode = .folder }
        return TransferJob(source: source, destination: destination, options: options)
    }

    private var targetPath: String? {
        guard let source, let destination else { return nil }
        let job = TransferJob(source: source, destination: destination, options: options)
        return job.target(sourceIsDirectory: sourceIsDirectory).path
    }

    /// Seçilen biçimin sonucu: "Hedef/Kaynak/…" ya da "Hedef/…"; anlık görüntüde "Hedef/<tarih>/Kaynak/…".
    private var resultPreview: String? {
        guard let source, let destination else { return nil }
        var base = destination.path.hasSuffix("/") ? destination.path : destination.path + "/"
        if options.snapshots.enabled { base += SnapshotStore.name(for: Date()) + "/" }
        if !sourceIsDirectory { return settings.t(.modeFileHelp, base + source.lastPathComponent) }
        switch options.copyMode {
        case .folder: return settings.t(.modeFolderHelp, base + source.lastPathComponent + "/…")
        case .contents: return settings.t(.modeContentsHelp, base + "…")
        }
    }

    private func pathRow(_ key: LKey, url: URL?, systemImage: String, choose: @escaping () -> Void) -> some View {
        LabeledContent(settings.t(key)) {
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
                Button(settings.t(.buttonChoose), action: choose)
            }
        }
    }

    private func option(_ key: LKey, note: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(settings.t(key), isOn: isOn)
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.message = settings.t(.panelChooseSource)
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { source = url }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.message = settings.t(.panelChooseDestination)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }

    /// `--delete` seçiliyse önce ayrıca onay istenir.
    /// `--delete` yeni seçildiyse ve saklama kuralları eski anlık görüntüleri silecekse önce ayrıca onay istenir.
    private func submit() {
        guard source != nil, destination != nil else { return }
        if needsDeleteConfirmation {
            confirmDelete = true
        } else if needsRetentionConfirmation {
            confirmRetention = true
        } else {
            commit()
        }
    }

    /// İşi ekler ya da (düzenlemede) kaydeder.
    private func commit() {
        guard let source, let destination else { return }
        var options = finalOptions
        if !sourceIsDirectory { options.copyMode = .folder }
        let message = if let id = request.editing {
            model.updateJob(id, source: source, destination: destination, options: options)
        } else {
            model.addJob(source: source, destination: destination, options: options)
        }
        if let message { problem = message } else { dismiss() }
    }
}

struct VerifyResultSheet: View {
    let presentation: VerifyPresentation
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var showAttributes = false

    var body: some View {
        let report = presentation.report
        let entries = report.entries.filter { showAttributes || $0.kind != .attributes }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: summarySymbol)
                    .font(.largeTitle)
                    .foregroundStyle(summaryColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.t(.verifyTitle) + " · " + OpenSafety.visibleName(presentation.jobName))
                        .font(.headline)
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(settings.t(.verifyShowAttributes), isOn: $showAttributes)
                .disabled(report.count(.attributes) == 0)
            if entries.isEmpty {
                ContentUnavailableView(settings.t(.verifyNothingToShow), systemImage: "checkmark.circle")
                    .frame(maxHeight: .infinity)
            } else {
                Table(entries) {
                    TableColumn(settings.t(.detailStatus)) { entry in
                        Text(settings.t(kindKey(entry.kind)))
                            .foregroundStyle(kindColor(entry.kind))
                    }
                    .width(min: 90, ideal: 120, max: 160)
                    TableColumn(settings.t(.detailTarget)) { entry in
                        Label {
                            Text(OpenSafety.visibleName(entry.path))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(settings.t(.buttonClose)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 480)
    }

    private var summary: String {
        let report = presentation.report
        if !report.result.kind.isSuccess {
            return settings.t(.verifyFailed) + ": " + settings.result(report.result)
        }
        if report.isIdentical { return settings.t(report.checksum ? .verifyIdenticalChecksum : .verifyIdentical) }
        return settings.t(.verifySummary, report.count(.missing), report.count(.changed), report.count(.extra))
    }

    private var summarySymbol: String {
        let report = presentation.report
        if !report.result.kind.isSuccess { return "exclamationmark.triangle.fill" }
        return report.isIdentical ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
    }

    private var summaryColor: Color {
        let report = presentation.report
        if !report.result.kind.isSuccess { return .red }
        return report.isIdentical ? .green : .orange
    }

    private func kindKey(_ kind: DiffEntry.Kind) -> LKey {
        switch kind {
        case .missing: .kindMissing
        case .changed: .kindChanged
        case .attributes: .kindAttributes
        case .extra: .kindExtra
        }
    }

    private func kindColor(_ kind: DiffEntry.Kind) -> Color {
        switch kind {
        case .missing: .orange
        case .changed: .blue
        case .attributes: .secondary
        case .extra: .red
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(settings.t(.welcomeTitle))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(settings.t(.welcomeSubtitle))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }

                HStack(spacing: 12) {
                    Button {
                        model.beginNewJob()
                    } label: {
                        Label(settings.t(.menuNewJob), systemImage: "plus")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    Button {
                        model.beginNewRoutine()
                    } label: {
                        Label(settings.t(.menuNewRoutine), systemImage: "wand.and.stars")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.extraLarge)

                DropZone(isTargeted: model.isDropTargeted, hint: settings.t(.welcomeDropHint))

                Text(settings.t(.welcomeFootnote))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)

                EngineStatusView()
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .background {
            // Arka plan yalnızca kendi sütununu kaplar: güvenli alanın dışına taşsaydı yan paneller açılıp kapanırken
            // yeniden boyutlanıp karşılama ekranının üzerinde kayardı.
            LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear], startPoint: .top, endPoint: .center)
        }
    }
}

private struct DropZone: View {
    let isTargeted: Bool
    let hint: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 36, weight: .light))
                .symbolEffect(.bounce, value: isTargeted)
                .accessibilityHidden(true)
            Text(hint)
                .font(.headline)
        }
        .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
        .frame(maxWidth: 480, minHeight: 140)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.45))
        }
        .scaleEffect(isTargeted ? 1.03 : 1)
        .animation(.spring(duration: 0.3), value: isTargeted)
    }
}

/// rsync'in durumunu gösterir; sorun varsa açıklamasını verir.
struct EngineStatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        switch model.engineStatus {
        case .checking:
            Label(settings.t(.engineChecking), systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .ready(let version, let limited):
            if limited {
                Label(settings.t(.engineLimited, version), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label(settings.t(.engineReady, version), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        case .missing:
            warning(title: settings.t(.engineMissingTitle), message: settings.t(.engineMissingMessage))
        case .blocked:
            warning(title: settings.t(.engineBlockedTitle), message: settings.t(.engineBlockedMessage))
        }
    }

    private func warning(title: String, message: String) -> some View {
        VStack(spacing: 4) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }
}
