// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CopiatorCore
import SwiftUI

/// Başka bir Mac'e taşınan ayarlar. Bilerek dışarıda kalanlar: güncelleme izni (ağ bağlantısı yeni Mac'te yeniden
/// sorulur), kum havuzu (güvenlik ayarı bir dosyadan değişmez), yapay zekâ (önkoşullar yeni Mac'te denetlenir), kuyruğun
/// beklemesi ve hatırlatma kayıtları (durum), özel rsync yolu, takılınca bütünlük denetimi listesi ve varsayılan gelişmiş
/// seçeneklerdeki dosya ve klasör yolları (bu Mac'e özgü). Alanlar isteğe bağlıdır: eski ve yeni dosyalar okunabilir.
struct PortableSettings: Codable, Equatable {
    var language: String?
    var appearance: String?
    var notifyOnFinish: Bool?
    var resumeInterruptedAtLaunch: Bool?
    var defaultCopyMode: CopyMode?
    var defaultPreservePermissions: Bool?
    var defaultPreserveXattrs: Bool?
    var defaultExcludeSystemFolders: Bool?
    var keepDisplayAwake: Bool?
    var lowPriorityIO: Bool?
    var defaultAdvanced: AdvancedOptions?
    var defaultVerifyAfterCopy: VerifyAfterCopy?
    var defaultConflictPolicy: ConflictPolicy?
    var showMenuBarIcon: Bool?
    var showDockProgress: Bool?
    var backupReminderDays: Int?
    var customShortcuts: [String: KeyboardShortcutData]?

    init(_ settings: AppSettings) {
        language = settings.language.rawValue
        appearance = settings.appearance.rawValue
        notifyOnFinish = settings.notifyOnFinish
        resumeInterruptedAtLaunch = settings.resumeInterruptedAtLaunch
        defaultCopyMode = settings.defaultCopyMode
        defaultPreservePermissions = settings.defaultPreservePermissions
        defaultPreserveXattrs = settings.defaultPreserveXattrs
        defaultExcludeSystemFolders = settings.defaultExcludeSystemFolders
        keepDisplayAwake = settings.keepDisplayAwake
        lowPriorityIO = settings.lowPriorityIO
        defaultAdvanced = Self.withoutPaths(settings.defaultAdvanced)
        defaultVerifyAfterCopy = settings.defaultVerifyAfterCopy
        defaultConflictPolicy = settings.defaultConflictPolicy
        showMenuBarIcon = settings.showMenuBarIcon
        showDockProgress = settings.showDockProgress
        backupReminderDays = settings.backupReminderDays
        customShortcuts = settings.customShortcuts
    }

    /// Varsayılan gelişmiş seçeneklerden bu Mac'e özgü yollar ve tek seferlik durma zamanı çıkarılır.
    static func withoutPaths(_ options: AdvancedOptions) -> AdvancedOptions {
        var options = options
        options.includeFromFile = nil
        options.excludeFromFile = nil
        options.filesFromFile = nil
        options.conflictExcludeFile = nil
        options.referenceDirectory = nil
        options.backupDirectory = nil
        options.logFile = nil
        options.batchFile = nil
        options.stopAt = nil
        return options
    }

    /// Dosyadaki değerleri uygular; tanınmayan değerler (ör. daha yeni bir sürümün dili) atlanır.
    func apply(to settings: AppSettings) {
        if let value = language.flatMap(AppLanguage.init(rawValue:)) { settings.language = value }
        if let value = appearance.flatMap(AppAppearance.init(rawValue:)) { settings.appearance = value }
        if let notifyOnFinish { settings.notifyOnFinish = notifyOnFinish }
        if let resumeInterruptedAtLaunch { settings.resumeInterruptedAtLaunch = resumeInterruptedAtLaunch }
        if let defaultCopyMode { settings.defaultCopyMode = defaultCopyMode }
        if let defaultPreservePermissions { settings.defaultPreservePermissions = defaultPreservePermissions }
        if let defaultPreserveXattrs { settings.defaultPreserveXattrs = defaultPreserveXattrs }
        if let defaultExcludeSystemFolders { settings.defaultExcludeSystemFolders = defaultExcludeSystemFolders }
        if let keepDisplayAwake { settings.keepDisplayAwake = keepDisplayAwake }
        if let lowPriorityIO { settings.lowPriorityIO = lowPriorityIO }
        if let defaultAdvanced { settings.defaultAdvanced = Self.withoutPaths(defaultAdvanced) }
        if let defaultVerifyAfterCopy { settings.defaultVerifyAfterCopy = defaultVerifyAfterCopy }
        if let defaultConflictPolicy { settings.defaultConflictPolicy = defaultConflictPolicy }
        if let showMenuBarIcon { settings.showMenuBarIcon = showMenuBarIcon }
        if let showDockProgress { settings.showDockProgress = showDockProgress }
        if let backupReminderDays, BackupFreshness.choices.contains(backupReminderDays) { settings.backupReminderDays = backupReminderDays }
        if let customShortcuts { settings.customShortcuts = customShortcuts }
    }
}

/// İçe aktarılacak işler ve ayarlar (dosyadan okunmuş, yeni kimlikli, duraklatılmış).
struct SetupImportRequest: Identifiable {
    let id = UUID()
    var jobs: [TransferJob]
    var settings: PortableSettings?
}

extension AppModel {
    /// Rutinlere bağlı olmayan işler ve taşınabilir ayarlar dosyaya yazılır (rutinler kendi dosyalarıyla taşınır).
    func exportSetup(to url: URL) {
        do {
            try SetupTransfer.export(jobs: jobs.filter { $0.routineID == nil }, settings: PortableSettings(settings)).write(to: url, options: .atomic)
            showToast(settings.t(.toastSetupExported), systemImage: "square.and.arrow.up")
        } catch {
            alert = AlertItem(title: settings.t(.exportSetupFailed), message: error.localizedDescription)
        }
    }

    /// Bir kurulum dosyasını okur ve içe aktarma sayfasını açar; okunamazsa nedenini bildirir.
    func beginSetupImport(from url: URL) {
        let title = settings.t(.setupImportFailedTitle)
        do {
            let contents = try SetupTransfer.read(Data(contentsOf: url), settings: PortableSettings.self)
            guard !contents.jobs.isEmpty || contents.settings != nil else { throw SetupTransfer.Failure.notSetup }
            setupImport = SetupImportRequest(jobs: contents.jobs, settings: contents.settings)
        } catch SetupTransfer.Failure.newerVersion {
            alert = AlertItem(title: title, message: settings.t(.setupImportNewer))
        } catch SetupTransfer.Failure.tooLarge {
            alert = AlertItem(title: title, message: settings.t(.setupImportTooLarge))
        } catch {
            alert = AlertItem(title: title, message: settings.t(.setupImportInvalid))
        }
    }

    /// Seçilen işleri duraklatılmış olarak kuyruğa ekler (denetimden geçemeyenler eklenmez) ve istenirse ayarları
    /// uygular. Hiçbir iş kendiliğinden başlamaz. - Returns: Eklenemeyen işlerin nedeni (iş kimliğine göre).
    func importSetup(_ imported: [TransferJob], settings portable: PortableSettings?) -> [TransferJob.ID: String] {
        var failures: [TransferJob.ID: String] = [:]
        var added = 0
        for job in imported {
            if let message = importProblem(job) {
                failures[job.id] = message
                continue
            }
            var job = job
            job.status = .paused
            appendImported(job)
            added += 1
        }
        portable?.apply(to: settings)
        save()
        refreshShortcutParameters()
        showToast(settings.t(.setupImportDone, added), systemImage: "square.and.arrow.down")
        return failures
    }
}

enum SetupTransferPanels {
    static func chooseExport(model: AppModel, settings: AppSettings) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = settings.t(.exportSetupName)
        if panel.runModal() == .OK, let url = panel.url { model.exportSetup(to: url) }
    }

    static func chooseImport(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { model.beginSetupImport(from: url) }
    }
}

/// İçe aktarma: dosyadaki işler seçilir, bu Mac'te bulunmayan klasörler yeniden eşlenir, ayarların uygulanıp
/// uygulanmayacağı seçilir. İşler duraklatılmış gelir.
struct SetupImportSheet: View {
    let request: SetupImportRequest
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var jobs: [TransferJob] = []
    @State private var excluded: Set<TransferJob.ID> = []
    @State private var applySettings = true
    @State private var failures: [TransferJob.ID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "macbook.and.arrow.down").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                Text(settings.t(.setupImportTitle)).font(.headline)
            }
            Text(settings.t(.setupImportNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(
                            get: { !excluded.contains(job.id) },
                            set: { if $0 { excluded.remove(job.id) } else { excluded.insert(job.id) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(OpenSafety.visibleName(job.source.lastPathComponent)).font(.body.weight(.semibold))
                                Text(OpenSafety.visibleName(job.source.path) + " → " + OpenSafety.visibleName(job.destination.path))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .toggleStyle(.checkbox)
                        ForEach(SetupTransfer.missingFolders(in: [job])) { missing in
                            HStack {
                                Label(settings.t(missing.isSource ? .importSourceMissing : .importDestinationMissing,
                                                 OpenSafety.visibleName(missing.url.path)), systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button(settings.t(.buttonChoose)) { remap(missing) }
                            }
                            .padding(.leading, 20)
                        }
                        if let failure = failures[job.id] {
                            Label(failure, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                                .padding(.leading, 20)
                        }
                    }
                }
            }
            .accessibilityIdentifier("copiator.setupImport.jobs")
            if request.settings != nil {
                Toggle(settings.t(.setupImportSettings), isOn: $applySettings)
                    .accessibilityIdentifier("copiator.setupImport.settings")
            }
            HStack {
                Spacer()
                Button(settings.t(.buttonCancel)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.t(.importButton)) { importChosen() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty && !(applySettings && request.settings != nil))
                    .accessibilityIdentifier("copiator.setupImport.confirm")
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .onAppear { jobs = request.jobs }
    }

    private var chosen: [TransferJob] { jobs.filter { !excluded.contains($0.id) } }

    private func remap(_ missing: SetupTransfer.Missing) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = missing.isSource
        panel.canChooseDirectories = true
        panel.canCreateDirectories = !missing.isSource
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { SetupTransfer.remap(missing, to: url, in: &jobs) }
    }

    private func importChosen() {
        let imported = chosen
        failures = model.importSetup(imported, settings: applySettings ? request.settings : nil)
        // Eklenenler listeden çıkar; eklenemeyenler nedenleriyle kalır. Ayarlar bir kez uygulanır.
        if failures.isEmpty { dismiss() } else { jobs.removeAll { job in imported.contains { $0.id == job.id } && failures[job.id] == nil } }
        applySettings = false
    }
}
