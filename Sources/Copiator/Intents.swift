// SPDX-License-Identifier: GPL-3.0-or-later
import AppIntents
import CopiatorCore
import Foundation

// Kestirmeler (Shortcuts) ve Siri: "Kopyalama İşini Çalıştır", "Tüm İşleri Duraklat", "Tüm İşleri Sürdür".
// Başlıklar ve açıklamalar Localizable.strings anahtarlarıdır (tr/en/ro); Siri ifadeleri AppShortcuts.strings'tedir.
// Meta veri (Metadata.appintents) Scripts/build_app.sh'ta appintentsmetadataprocessor ile üretilir.

/// Eylemlerin çalıştığı model; testler kendi modelini verir.
enum IntentTarget {
    static var model: () -> AppModel = { AppModel.shared }

    static func runJob(_ id: UUID) async -> String { await model().runFromShortcut(id) }
    static func pauseAll() async -> String { await model().pauseAllFromShortcut() }
    static func resumeAll() async -> String { await model().resumeAllFromShortcut() }
}

/// Kestirmelerde seçilebilen bir kopyalama işi.
nonisolated struct JobEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "intentJobTypeName")
    static let defaultQuery = JobEntityQuery()

    let id: UUID
    let name: String
    let destination: String

    init(job: TransferJob) {
        id = job.id
        name = job.source.lastPathComponent
        destination = job.destination.path
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(destination)")
    }
}

nonisolated struct JobEntityQuery: EntityQuery {
    func entities(for identifiers: [JobEntity.ID]) async throws -> [JobEntity] {
        await MainActor.run { IntentTarget.model().jobs.filter { identifiers.contains($0.id) }.map(JobEntity.init) }
    }

    func suggestedEntities() async throws -> [JobEntity] {
        await MainActor.run { IntentTarget.model().jobs.map(JobEntity.init) }
    }
}

/// Bir işi başlatır, sürdürür ya da (bitmişse) yeniden çalıştırır. İşler yine sırayla, birer birer çalışır.
/// (`@Parameter` özelliği değişken olduğu için tür `nonisolated` işaretlenemez; sabitler ayrıca işaretlenir.)
struct RunJobIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "intentRunJobTitle"
    nonisolated static let description = IntentDescription("intentRunJobDescription")
    nonisolated static let openAppWhenRun = false

    @Parameter(title: "intentJobParameter")
    var job: JobEntity

    init() {}

    init(job: JobEntity) {
        self.job = job
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await IntentTarget.runJob(job.id)
        return .result(dialog: "\(message)")
    }
}

nonisolated struct PauseAllJobsIntent: AppIntent {
    static let title: LocalizedStringResource = "intentPauseAllTitle"
    static let description = IntentDescription("intentPauseAllDescription")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await IntentTarget.pauseAll()
        return .result(dialog: "\(message)")
    }
}

nonisolated struct ResumeAllJobsIntent: AppIntent {
    static let title: LocalizedStringResource = "intentResumeAllTitle"
    static let description = IntentDescription("intentResumeAllDescription")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await IntentTarget.resumeAll()
        return .result(dialog: "\(message)")
    }
}

nonisolated struct CopiatorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunJobIntent(),
            phrases: ["Run \(\.$job) in \(.applicationName)", "Back up \(\.$job) with \(.applicationName)"],
            shortTitle: "shortcutRunJob",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PauseAllJobsIntent(),
            phrases: ["Pause all jobs in \(.applicationName)"],
            shortTitle: "shortcutPauseAll",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumeAllJobsIntent(),
            phrases: ["Resume all jobs in \(.applicationName)"],
            shortTitle: "shortcutResumeAll",
            systemImageName: "playpause.circle"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}

extension AppModel {
    /// Kestirmeden gelen "işi çalıştır": uygulama penceresiz açıldıysa önce motor denetlenir.
    func runFromShortcut(_ id: TransferJob.ID) async -> String {
        await launch()
        guard let job = job(id) else { return settings.t(.intentJobNotFound) }
        let name = job.source.lastPathComponent
        if job.status == .waiting || job.status.isActive {
            scheduleNext()
            return settings.t(.intentRunJobStarted, name)
        }
        guard JobQueue.canResume(job) || JobQueue.canRunAgain(job) else { return settings.t(.intentJobCannotRun, name) }
        resume([id])
        return settings.t(.intentRunJobStarted, name)
    }

    func pauseAllFromShortcut() async -> String {
        await launch()
        pauseAll()
        return settings.t(.intentPauseAllDone)
    }

    func resumeAllFromShortcut() async -> String {
        await launch()
        resumeAll()
        return settings.t(.intentResumeAllDone)
    }

    /// Siri ifadelerindeki iş adlarını günceller (yalnızca gerçek uygulama paketinde).
    func refreshShortcutParameters() {
        guard Bundle.main.bundleIdentifier == AppInfo.bundleIdentifier else { return }
        CopiatorShortcuts.updateAppShortcutParameters()
    }
}
