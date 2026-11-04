// SPDX-License-Identifier: GPL-3.0-only
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
    static func runRoutine(_ id: UUID) async -> String { await model().runRoutineFromShortcut(id) }
    static func runRoutine(_ id: UUID, on files: [URL]) async -> String { await model().runRoutineOnFilesFromShortcut(id, files: files) }
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

/// Kestirmelerde seçilebilen bir kopyalama rutini.
nonisolated struct RoutineEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "intentRoutineTypeName")
    static let defaultQuery = RoutineEntityQuery()

    let id: UUID
    let name: String
    let routeCount: Int

    init(routine: Routine) {
        id = routine.id
        name = routine.name
        routeCount = routine.routes.count
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

nonisolated struct RoutineEntityQuery: EntityQuery {
    func entities(for identifiers: [RoutineEntity.ID]) async throws -> [RoutineEntity] {
        await MainActor.run { IntentTarget.model().routines.filter { identifiers.contains($0.id) }.map(RoutineEntity.init) }
    }

    func suggestedEntities() async throws -> [RoutineEntity] {
        await MainActor.run { IntentTarget.model().routines.map(RoutineEntity.init) }
    }
}

/// Bir rutini çalıştırır: her rotası kuyruğa bir iş olarak girer.
/// (`@Parameter` özelliği değişken olduğu için tür `nonisolated` işaretlenemez; sabitler ayrıca işaretlenir.)
struct RunRoutineIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "intentRunRoutineTitle"
    nonisolated static let description = IntentDescription("intentRunRoutineDescription")
    nonisolated static let openAppWhenRun = false

    @Parameter(title: "intentRoutineParameter")
    var routine: RoutineEntity

    init() {}

    init(routine: RoutineEntity) {
        self.routine = routine
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await IntentTarget.runRoutine(routine.id)
        return .result(dialog: "\(message)")
    }
}

/// Bir rutini verilen dosyalarla çalıştırır (Kestirmeler'de Finder Hızlı Eylemi olarak kullanılabilir): her rota rotanın
/// kaynağı yerine bu dosyalara kurallarını ve yerleşimini uygular.
/// (`@Parameter` özelliği değişken olduğu için tür `nonisolated` işaretlenemez; sabitler ayrıca işaretlenir.)
struct RunRoutineOnFilesIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "intentRunRoutineOnFilesTitle"
    nonisolated static let description = IntentDescription("intentRunRoutineOnFilesDescription")
    nonisolated static let openAppWhenRun = false

    @Parameter(title: "intentRoutineParameter")
    var routine: RoutineEntity

    @Parameter(title: "intentFilesParameter")
    var files: [IntentFile]

    init() {}

    init(routine: RoutineEntity, files: [IntentFile]) {
        self.routine = routine
        self.files = files
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await IntentTarget.runRoutine(routine.id, on: files.compactMap(\.fileURL))
        return .result(dialog: "\(message)")
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
            intent: RunRoutineIntent(),
            phrases: ["Run \(\.$routine) routine in \(.applicationName)"],
            shortTitle: "shortcutRunRoutine",
            systemImageName: "wand.and.stars"
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

    /// Kestirmeden gelen "rutini şu dosyalarla çalıştır".
    func runRoutineOnFilesFromShortcut(_ id: Routine.ID, files: [URL]) async -> String {
        await launch()
        guard let routine = routine(id) else { return settings.t(.intentRoutineNotFound) }
        if let message = runRoutine(id, on: files) {
            alert = nil
            return message
        }
        return settings.t(.intentRoutineQueued, routine.name)
    }

    /// Kestirmeden gelen "rutini çalıştır".
    func runRoutineFromShortcut(_ id: Routine.ID) async -> String {
        await launch()
        guard let routine = routine(id) else { return settings.t(.intentRoutineNotFound) }
        if let message = runRoutine(id) {
            alert = nil
            return message
        }
        return settings.t(.intentRoutineQueued, routine.name)
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
