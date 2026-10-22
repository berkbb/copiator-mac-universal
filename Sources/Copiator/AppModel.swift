// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CopiatorCore
import Foundation
import Observation
@preconcurrency import UserNotifications

enum EngineStatus: Equatable {
    case checking
    /// `limited`: openrsync ya da eski bir rsync; ilerleme ayrıntısız gösterilir.
    case ready(version: String, limited: Bool)
    case missing
    case blocked
}

enum UpdateState: Equatable {
    case idle
    case checking
    case available(latest: String, installed: String?)
    case upToDate(version: String)
    case installing(version: String)
    case installed(version: String)
    case failed(message: String)
}

enum AppUpdateState: Equatable {
    case idle
    case checking
    case available(AppRelease)
    case upToDate
    case failed(message: String)
}

/// Kuyruğun dışında, pencereyi kapatan tek seferlik işlem (doğrulama, rsync güncellemesi).
struct OperationState: Identifiable {
    let id = UUID()
    let titleKey: LKey
    var progress: Double?
    /// Vazgeç'e basıldı; rsync duruyor.
    var isCancelling = false
}

/// Biten işlemin sonucu: ilerleme penceresi başarıda tamamlanmış görünüp kısa bir an bekler, iptal ve hatada hemen kapanır.
enum OperationOutcome: Equatable {
    case succeeded
    case cancelled
    case failed
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let systemImage: String
    let revealURL: URL?
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var isDestructive = false
    /// Vazgeç düğmesinin başlığı ve eylemi (varsayılan: "Vazgeç", eylemsiz).
    var cancelTitle: String?
    var cancelAction: (() -> Void)?
}

/// Yeni İş sayfası (Finder servisi ya da sürükle-bırak kaynağı önceden doldurabilir). Var olan bir işi düzenlerken
/// `editing` o işin kimliğidir; çoğaltırken sayfa işin ayarlarıyla dolu, yeni bir iş olarak açılır.
struct NewJobRequest: Identifiable {
    let id = UUID()
    var source: URL?
    var destination: URL?
    var options: CopyOptions?
    var editing: TransferJob.ID?
}

/// Rutin düzenleme sayfası (yeni, düzenleme ya da çoğaltma).
struct RoutineEditorRequest: Identifiable {
    let id = UUID()
    var routine: Routine
    /// Kayıtlı bir rutin düzenleniyor (yoksa yeni rutin).
    var isExisting: Bool
}

/// Kenar çubuğunun seçimi: bir iş süzgeci ya da bir rutin.
enum SidebarItem: Hashable {
    case filter(JobFilter)
    case routine(Routine.ID)
}

/// Doğrulama sonucunun gösterimi.
struct VerifyPresentation: Identifiable {
    let id = UUID()
    let jobID: TransferJob.ID
    let jobName: String
    let report: VerifyReport
}

enum JobFilter: String, CaseIterable, Identifiable, Hashable {
    case all, active, paused, finished, failed

    var id: String { rawValue }

    var titleKey: LKey {
        switch self {
        case .all: .filterAll
        case .active: .filterActive
        case .paused: .filterPaused
        case .finished: .filterFinished
        case .failed: .filterFailed
        }
    }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .active: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle"
        case .finished: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    func includes(_ job: TransferJob) -> Bool {
        switch self {
        case .all: true
        case .active: job.status == .waiting || job.status.isActive
        case .paused: job.status == .paused
        case .finished: job.status == .finished
        case .failed: job.status == .failed
        }
    }
}

@Observable
final class AppModel {
    static let shared = AppModel(settings: .shared, processStateFile: AppModel.defaultProcessStateFile)

    /// Çalışan alt süreçlerin kaydı (bkz. `ChildProcessGuard`): çökmeden sonra açılışta yetim rsync durdurulur.
    nonisolated static var defaultProcessStateFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Copiator/running-processes.json")
    }

    let settings: AppSettings

    var engineStatus: EngineStatus = .checking
    private(set) var engineURL: URL?
    private(set) var engineInfo: EngineInfo?
    var updateState: UpdateState = .idle
    var appUpdateState: AppUpdateState = .idle

    private(set) var jobs: [TransferJob] = []
    var selection: Set<TransferJob.ID> = []
    var filter: JobFilter = .all
    /// Kopyalama rutinleri (kenar çubuğundaki kütüphane).
    private(set) var routines: [Routine] = []
    /// Kenar çubuğunda seçili rutin (yoksa iş listesi görünür).
    var selectedRoutineID: Routine.ID?
    var routineEditor: RoutineEditorRequest?

    /// Kenar çubuğunun seçimi: süzgeç ya da rutin.
    var sidebarSelection: SidebarItem {
        get { selectedRoutineID.map(SidebarItem.routine) ?? .filter(filter) }
        set {
            switch newValue {
            case .filter(let filter):
                self.filter = filter
                selectedRoutineID = nil
            case .routine(let id):
                selectedRoutineID = id
            }
        }
    }
    private(set) var runningJobID: TransferJob.ID?
    /// Çalışan iş için Duraklat'a basıldı; rsync duruyor.
    private(set) var isPausingRunningJob = false

    var operation: OperationState?
    var lastOperationOutcome: OperationOutcome?
    var toast: Toast?
    var alert: AlertItem? { didSet { if alert == nil { schedulePendingConsent() } } }
    var newJobRequest: NewJobRequest? { didSet { if newJobRequest == nil { schedulePendingConsent() } } }
    /// Doğrulama türü seçimi (hızlı / sağlama) bekleyen iş.
    var verifyChoice: TransferJob.ID?
    var verifyPresentation: VerifyPresentation?
    /// Kullanıcının ayrıntılar paneli tercihi (açık/kapalı).
    var showInspector = true

    /// Panel yalnızca iş varken görünür: iş yokken gösterecek bir şeyi yoktur ve karşılama ekranını daraltırdı.
    /// Tercih (`showInspector`) korunur; ilk iş eklenince panel tercihe göre geri gelir.
    var isInspectorVisible: Bool {
        get { showInspector && !jobs.isEmpty }
        set { if !jobs.isEmpty { showInspector = newValue } }
    }

    /// Ayrıntılar panelini açar ya da kapatır (iş yokken bir şey yapmaz).
    func toggleInspector() {
        guard !jobs.isEmpty else { return }
        showInspector.toggle()
    }
    var isDropTargeted = false

    @ObservationIgnored private let store: JobStore
    @ObservationIgnored private let routineStore: RoutineStore
    @ObservationIgnored private var runningTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var didLaunch = false
    @ObservationIgnored private var consentPending = false
    /// Uyku engeli (`caffeinate -i`, isteğe bağlı `-d` karşılığı); sistemin engel listesinde doğrulanır.
    @ObservationIgnored private let sleepGuard: SleepGuard
    /// Uyku engelinin `pmset -g assertions` çıktısında görünen adı.
    nonisolated static let sleepReason = "Copiator copy job"
    let sleepReason: String
    /// Çalışan işin uyku engeli durumu (iş yokken nil).
    private(set) var sleepStatus: SleepGuard.Status?
    /// Çalışan iş için güç, pil ve ekran önerileri.
    private(set) var powerAdvice: [PowerAdvice] = []
    private(set) var powerSnapshot: PowerSnapshot?
    /// Güç durumu kaynağı; testler sahte bir durum verebilir.
    @ObservationIgnored var powerProvider: () -> PowerSnapshot = PowerSnapshot.current
    /// İş sürerken güç durumunun yeniden denetlenme aralığı.
    @ObservationIgnored var powerCheckInterval: Duration = .seconds(60)
    @ObservationIgnored private var powerMonitor: Task<Void, Never>?
    /// İş bitince gösterilen bildirim; testler ve paket dışı çalıştırma için değiştirilebilir.
    @ObservationIgnored var notifier: (_ title: String, _ body: String) -> Void = AppModel.postUserNotification
    /// Motorlar (iş türü → motor); testler sahte bir motor verebilir.
    @ObservationIgnored var engineProvider: (JobKind) -> any TransferEngine = TransferEngines.engine(for:)
    /// Son ilerleme kaydının zamanı: ilerleme diske en çok bu aralıkla yazılır.
    @ObservationIgnored private var lastProgressSave = Date.distantPast
    /// Uygulama kapanıyor: çalışan iş durdurulup "kesildi" olarak kaydedildi, kuyruk ilerlemez.
    @ObservationIgnored private var isTerminating = false
    /// Çalışan işin diski çıkarılıyor: rsync durduruluyor, iş disk takılınca sürecek.
    @ObservationIgnored private var isSuspendingRunningJobForDisk = false
    /// Kaynak ve hedefin erişilebilirliği ("disk takılınca başla" işleri için); testler sahte bir denetim verebilir.
    @ObservationIgnored var pathsAvailable: (TransferJob) -> Bool = { $0.pathsAvailable }
    /// Alt süreç kayıt dosyası (yalnızca uygulamada; testlerde nil).
    @ObservationIgnored private let processStateFile: URL?
    /// Dock simgesi ve menü çubuğu için ilerleme bildirimi (uygulama kurar; testlerde nil).
    @ObservationIgnored var onActivityChange: (() -> Void)?

    /// - Parameter routineStore: Rutin kaydı; verilmezse iş kaydının yanındaki routines.json (testler kendi klasörlerini kullanır).
    init(
        settings: AppSettings, store: JobStore = JobStore(), routineStore: RoutineStore? = nil,
        sleepReason: String = AppModel.sleepReason, processStateFile: URL? = nil
    ) {
        self.settings = settings
        self.store = store
        self.routineStore = routineStore ?? RoutineStore(url: store.url.deletingLastPathComponent().appendingPathComponent("routines.json"))
        self.sleepReason = sleepReason
        self.processStateFile = processStateFile
        sleepGuard = SleepGuard(reason: sleepReason)
        loadJobs()
        loadRoutines()
    }

    private func t(_ key: LKey) -> String { settings.t(key) }
    private func t(_ key: LKey, _ arguments: any CVarArg...) -> String {
        String(format: settings.t(key), locale: settings.locale, arguments: arguments)
    }

    // MARK: - Pencere

    @ObservationIgnored private var openMainWindowAction: (() -> Void)?

    func registerWindowOpener(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    /// Ana pencereyi açar (kapalıysa ya da hiç açılmadıysa) ve öne getirir.
    /// Finder servisi uygulamayı penceresiz başlatabilir; Yeni İş sayfasının görünmesi için gerekir.
    func presentMainWindow(attempt: Int = 0) {
        NSApp?.activate()
        guard let openMainWindowAction else {
            // Menü komutları henüz kurulmadıysa (çok erken soğuk açılış) kısa bir süre sonra yeniden dene.
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.presentMainWindow(attempt: attempt + 1) }
            }
            return
        }
        openMainWindowAction()
        DispatchQueue.main.async {
            (NSApp?.windows ?? [])
                .filter { $0.canBecomeMain && $0.isVisible }
                .forEach { $0.orderFrontRegardless() }
        }
    }

    // MARK: - Açılış ve motor

    func launch() async {
        guard !didLaunch else { return }
        didLaunch = true
        settings.applyAppearance()
        reapOrphanedProcesses()
        refreshShortcutParameters()
        await refreshEngine()
        scheduleNext()
        if !settings.updateConsentAsked {
            consentPending = true
            presentPendingConsentIfIdle()
        } else if settings.checkUpdatesAtLaunch {
            await checkForUpdates(interactive: false)
            await checkForAppUpdate(interactive: false)
        }
    }

    private func presentPendingConsentIfIdle() {
        guard consentPending, operation == nil, alert == nil, newJobRequest == nil else { return }
        consentPending = false
        askUpdateConsent()
    }

    private func schedulePendingConsent() {
        guard consentPending else { return }
        Task { @MainActor in self.presentPendingConsentIfIdle() }
    }

    /// İlk açılışta, GitHub'a bağlanmadan önce bir kez izin ister.
    private func askUpdateConsent() {
        alert = AlertItem(
            title: t(.consentTitle),
            message: t(.consentMessage),
            actionTitle: t(.consentAllow),
            action: { [weak self] in self?.respondToUpdateConsent(true) },
            cancelTitle: t(.consentDeny),
            cancelAction: { [weak self] in self?.respondToUpdateConsent(false) }
        )
    }

    func respondToUpdateConsent(_ allow: Bool) {
        settings.updateConsentAsked = true
        settings.checkUpdatesAtLaunch = allow
        guard allow else { return }
        Task {
            await checkForUpdates(interactive: false)
            await checkForAppUpdate(interactive: false)
        }
    }

    @ObservationIgnored private var engineChecked = false
    @ObservationIgnored private var engineProbe: Task<Void, Never>?

    var engineVersion: String? { engineInfo?.version }

    /// Motor henüz denetlenmediyse denetler; süren bir denetim varsa onu bekler.
    func ensureEngine() async {
        if engineChecked { return }
        if let engineProbe {
            await engineProbe.value
            return
        }
        await refreshEngine()
    }

    func refreshEngine() async {
        if let engineProbe {
            await engineProbe.value
            return
        }
        let probe = Task { await self.probeEngine() }
        engineProbe = probe
        await probe.value
        engineProbe = nil
        engineChecked = true
    }

    /// Adaylar sınanır: kullanıcının seçtiği çalışıyorsa her zaman o; aksi hâlde tam özellikli kopyaların en yenisi,
    /// hiçbiri yoksa sistemin rsync'i (kısıtlı kip).
    private func probeEngine() async {
        engineStatus = .checking
        let candidates = EngineLocator.candidates(customPath: settings.customEnginePath)
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard !candidates.isEmpty else {
            engineURL = nil
            engineInfo = nil
            engineStatus = .missing
            return
        }
        var probed: [(url: URL, info: EngineInfo?)] = []
        for url in candidates {
            probed.append((url, await EngineLocator.probe(url)))
        }
        if let chosen = EngineLocator.choose(probed, customPath: settings.customEnginePath) {
            engineURL = chosen.url
            engineInfo = chosen.info
            engineStatus = .ready(version: chosen.info.version, limited: !chosen.info.supportsProgress2)
        } else {
            engineURL = candidates.first
            engineInfo = nil
            engineStatus = .blocked
        }
    }

    // MARK: - rsync güncellemesi

    private var updater: EngineUpdater? {
        // Kullanılan rsync'in sürümü betiğe verilir: paket yazılamadığında betik henüz boş olan yedek klasöre bakıp
        // "kurulu değil" sanmasın. Kullanıcının seçtiği rsync güncellenmediği için onun sürümü verilmez.
        let current = settings.customEnginePath == nil ? engineVersion : nil
        return Bundle.main.url(forResource: "update-rsync", withExtension: "sh").map { EngineUpdater(scriptURL: $0, currentVersion: current) }
    }

    func checkForUpdates(interactive: Bool) async {
        guard let updater, updateState != .checking else { return }
        updateState = .checking
        do {
            let result = try await updater.check()
            let latest = result.latestVersion ?? t(.unknown)
            if result.status == .updateAvailable {
                updateState = .available(latest: latest, installed: result.currentVersion)
                if interactive {
                    alert = AlertItem(
                        title: t(.menuCheckEngineUpdates),
                        message: t(.updateAvailable, latest, result.currentVersion ?? t(.unknown)) + "\n\n" + t(.updateBuildNote),
                        actionTitle: t(.updateInstall, latest),
                        action: { [weak self] in self?.installUpdate() }
                    )
                }
            } else {
                updateState = .upToDate(version: result.currentVersion ?? engineVersion ?? latest)
                if interactive {
                    alert = AlertItem(title: t(.menuCheckEngineUpdates), message: t(.updateUpToDate, engineVersion ?? latest))
                }
            }
        } catch {
            updateState = .failed(message: message(for: error))
            if interactive { alert = AlertItem(title: t(.updateFailed), message: message(for: error)) }
        }
    }

    /// rsync yalnızca kaynak kodu yayımlar: kurulum indirir, doğrular ve bu Mac'te derler (birkaç dakika).
    /// Bir iş çalışırken kurulmaz; ilerleme penceresi açıkken iptal edilebilir.
    func installUpdate() {
        guard let updater, runningJobID == nil else { return }
        if case .installing = updateState { return }
        let target: String
        if case .available(let latest, _) = updateState { target = latest } else { target = "" }
        updateState = .installing(version: target)
        perform(.progressUpdatingEngine) { [weak self] in
            guard let self else { return }
            do {
                let result = try await updater.install()
                await refreshEngine()
                let version = engineVersion ?? result.latestVersion ?? target
                updateState = result.status == .installed ? .installed(version: version) : .upToDate(version: version)
                if result.status == .installed { showToast(t(.toastEngineUpdated, version), systemImage: "arrow.down.circle.fill") }
            } catch {
                updateState = .failed(message: message(for: error))
                throw error
            }
        }
    }

    // MARK: - Copiator güncellemesi

    func checkForAppUpdate(interactive: Bool) async {
        guard appUpdateState != .checking else { return }
        appUpdateState = .checking
        do {
            let release = try await AppUpdateChecker.latest(repository: AppInfo.repository)
            if AppUpdateChecker.isNewer(release.version, than: AppInfo.version) {
                appUpdateState = .available(release)
                if interactive {
                    alert = AlertItem(
                        title: t(.menuCheckAppUpdates),
                        message: t(.appUpdateAvailable, release.version, AppInfo.version),
                        actionTitle: t(.appUpdateDownload),
                        action: { [weak self] in self?.openAppDownload() }
                    )
                }
            } else {
                appUpdateState = .upToDate
                if interactive { alert = AlertItem(title: t(.menuCheckAppUpdates), message: t(.appUpdateUpToDate, AppInfo.version)) }
            }
        } catch {
            let message = (error as? AppUpdateChecker.CheckError) == .noReleases ? t(.appUpdateNoReleases) : error.localizedDescription
            appUpdateState = .failed(message: message)
            if interactive { alert = AlertItem(title: t(.updateFailed), message: message) }
        }
    }

    /// Ad-hoc imzalı uygulama kendini kurmaz; indirme bağlantısı (yoksa sürüm sayfası) tarayıcıda açılır.
    func openAppDownload() {
        guard case .available(let release) = appUpdateState else {
            NSWorkspace.shared.open(AppLinks.releases)
            return
        }
        NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
    }

    /// Önceki oturum çöktüyse ya da zorla kapatıldıysa hâlâ çalışan rsync durdurulur (kuyruk başlamadan önce) ve
    /// kesilen işin günlüğüne yazılır. Sonra bu oturumun alt süreçleri aynı dosyaya kaydedilmeye başlar.
    func reapOrphanedProcesses() {
        guard let processStateFile else { return }
        let reaped = ChildProcessGuard.reapOrphans(stateFile: processStateFile)
        ChildProcessGuard.configure(stateFile: processStateFile)
        guard !reaped.isEmpty else { return }
        let description = reaped.map { "\($0.name) \($0.pid)" }.joined(separator: ", ")
        let interrupted = jobs.filter(\.wasInterrupted).map(\.id)
        for id in interrupted.isEmpty ? Array(jobs.suffix(1).map(\.id)) : interrupted {
            update(id) { $0.appendLog(JobLogEntry(level: .warning, key: .logOrphanStopped, arguments: [description])) }
        }
        save()
    }

    // MARK: - Rutinler

    private func loadRoutines() {
        do {
            routines = try routineStore.load()
        } catch {
            routines = []
            if let backup = routineStore.quarantineCorruptFile() {
                alert = AlertItem(title: t(.errorTitle), message: t(.errorStoreCorrupt, backup.path))
            }
        }
    }

    private func saveRoutines() {
        do {
            try routineStore.save(routines)
        } catch {
            alert = AlertItem(title: t(.errorTitle), message: t(.errorSaveFailed, error.localizedDescription))
        }
    }

    func routine(_ id: Routine.ID) -> Routine? { routines.first { $0.id == id } }

    /// Bir rutinin kuyruktaki işleri (rota sırasıyla).
    func jobs(for routineID: Routine.ID) -> [TransferJob] {
        let order = routine(routineID)?.routes.map(\.id) ?? []
        return jobs.filter { $0.routineID == routineID }
            .sorted { (order.firstIndex(of: $0.routeID ?? UUID()) ?? .max) < (order.firstIndex(of: $1.routeID ?? UUID()) ?? .max) }
    }

    func beginNewRoutine(source: URL? = nil) {
        var routine = Routine(routes: [RoutineRoute(source: source)], options: settings.defaultOptions)
        routine.options.copyMode = .contents
        routine.options.deleteExtraneous = false
        routineEditor = RoutineEditorRequest(routine: routine, isExisting: false)
    }

    func beginEditRoutine(_ id: Routine.ID) {
        guard let routine = routine(id) else { return }
        routineEditor = RoutineEditorRequest(routine: routine, isExisting: true)
    }

    /// Rutinin bir kopyasını düzenleme sayfasında açar (yeni kimlikler, "… kopya" adı).
    func beginDuplicateRoutine(_ id: Routine.ID) {
        guard let original = routine(id) else { return }
        var copy = Routine(name: t(.routineCopyName, original.name), routes: original.routes.map {
            RoutineRoute(source: $0.source, destination: $0.destination, rules: $0.rules)
        }, options: original.options)
        copy.options.rules = nil
        routineEditor = RoutineEditorRequest(routine: copy, isExisting: false)
    }

    /// Rutini denetleyip kaydeder; kuyruktaki çalışmayan işlerini yeni ayarlarla günceller. Silinen rotaların işleri
    /// sıradan iş olarak kalır. - Returns: Sorun varsa açıklaması (sayfa kapanmaz).
    @discardableResult
    func saveRoutine(_ routine: Routine) -> String? {
        var routine = routine
        routine.name = routine.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Diski takılı değilken "disk takılınca başla" seçili rutin yine kaydedilebilir.
        if let problem = routine.problems(checkPaths: !routine.options.runWhenConnected).first {
            return settings.routineProblem(problem)
        }
        routine.updatedAt = Date()
        if let index = routines.firstIndex(where: { $0.id == routine.id }) {
            routine.lastRunAt = routines[index].lastRunAt
            routines[index] = routine
        } else {
            routines.append(routine)
        }
        let routeIDs = Set(routine.routes.map(\.id))
        for index in jobs.indices where jobs[index].routineID == routine.id && !jobs[index].status.isActive {
            if let routeID = jobs[index].routeID, routeIDs.contains(routeID), let route = routine.routes.first(where: { $0.id == routeID }) {
                apply(route, of: routine, to: &jobs[index])
            } else {
                jobs[index].routineID = nil
                jobs[index].routeID = nil
            }
        }
        saveRoutines()
        save()
        selectedRoutineID = routine.id
        showToast(t(.toastRoutineSaved), systemImage: "wand.and.stars")
        refreshShortcutParameters()
        return nil
    }

    func requestDeleteRoutine(_ id: Routine.ID) {
        guard let routine = routine(id) else { return }
        alert = AlertItem(
            title: t(.routineDeleteConfirmTitle),
            message: t(.routineDeleteConfirmMessage, routine.name),
            actionTitle: t(.routineDeleteButton),
            action: { [weak self] in self?.deleteRoutine(id) },
            isDestructive: true
        )
    }

    /// Rutini siler; işleri kuyrukta sıradan iş olarak kalır, kopyalanmış dosyalara dokunulmaz.
    func deleteRoutine(_ id: Routine.ID) {
        routines.removeAll { $0.id == id }
        for index in jobs.indices where jobs[index].routineID == id {
            jobs[index].routineID = nil
            jobs[index].routeID = nil
        }
        if selectedRoutineID == id { selectedRoutineID = nil }
        saveRoutines()
        save()
        refreshShortcutParameters()
    }

    /// Rutini çalıştırır: her rota kuyruğa bir iş olarak girer (rota başına tek iş; bitmiş iş yeniden sıraya alınır,
    /// bekleyen ya da çalışan iş olduğu gibi kalır). - Returns: Sorun varsa açıklaması.
    @discardableResult
    func runRoutine(_ id: Routine.ID) -> String? {
        guard var routine = routine(id) else { return t(.intentRoutineNotFound) }
        if let problem = routine.problems(checkPaths: !routine.options.runWhenConnected).first {
            let message = settings.routineProblem(problem)
            alert = AlertItem(title: t(.errorTitle), message: message)
            return message
        }
        for route in routine.routes {
            if let index = jobs.firstIndex(where: { $0.routeID == route.id }) {
                guard !jobs[index].status.isActive, jobs[index].status != .waiting else { continue }
                apply(route, of: routine, to: &jobs[index])
                JobQueue.requeue(&jobs[index])
                jobs[index].appendLog(JobLogEntry(level: .info, key: .logRoutineRun, arguments: [routine.name]))
            } else {
                var job = TransferJob(source: route.source ?? URL(fileURLWithPath: "/"), destination: route.destination ?? URL(fileURLWithPath: "/"),
                                      options: routine.jobOptions(for: route))
                job.routineID = routine.id
                job.routeID = route.id
                job.routineName = routine.name
                job.appendLog(JobLogEntry(level: .info, key: .logRoutineRun, arguments: [routine.name]))
                jobs.append(job)
            }
        }
        routine.lastRunAt = Date()
        if let index = routines.firstIndex(where: { $0.id == id }) { routines[index] = routine }
        saveRoutines()
        save()
        showToast(t(.toastRoutineQueued), systemImage: "play.circle.fill")
        scheduleNext()
        return nil
    }

    /// Rotanın güncel ayarlarını işe yazar (kaynak, hedef, seçenekler, rutin adı).
    private func apply(_ route: RoutineRoute, of routine: Routine, to job: inout TransferJob) {
        if let source = route.source { job.source = source }
        if let destination = route.destination { job.destination = destination }
        job.options = routine.jobOptions(for: route)
        job.routineName = routine.name
    }

    /// Bir rotanın kuru çalıştırması: hangi dosyaların kopyalanacağı.
    func previewRoute(_ route: RoutineRoute, of routine: Routine) async -> VerifyReport? {
        guard let source = route.source, let destination = route.destination else { return nil }
        return await preview(source: source, destination: destination, options: routine.jobOptions(for: route))
    }

    // MARK: - İş kuyruğu: kayıt

    private func loadJobs() {
        do {
            var restored = JobQueue.restoredAfterLaunch(try store.load())
            for index in restored.indices where restored[index].wasInterrupted && restored[index].status == .paused {
                restored[index].appendLog(JobLogEntry(level: .warning, key: .logInterrupted))
                if settings.resumeInterruptedAtLaunch { JobQueue.requeue(&restored[index]) }
            }
            jobs = restored
        } catch {
            jobs = []
            if let backup = store.quarantineCorruptFile() {
                alert = AlertItem(title: t(.errorTitle), message: t(.errorStoreCorrupt, backup.path))
            }
        }
    }

    func save() {
        do {
            try store.save(jobs)
        } catch {
            alert = AlertItem(title: t(.errorTitle), message: t(.errorSaveFailed, error.localizedDescription))
        }
    }

    func job(_ id: TransferJob.ID) -> TransferJob? { jobs.first { $0.id == id } }

    var visibleJobs: [TransferJob] { jobs.filter(filter.includes) }

    func count(for filter: JobFilter) -> Int { jobs.lazy.filter(filter.includes).count }

    var selectedJobs: [TransferJob] { jobs.filter { selection.contains($0.id) } }

    private func update(_ id: TransferJob.ID, _ change: (inout TransferJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    // MARK: - İş kuyruğu: eylemler

    func beginNewJob(source: URL? = nil) {
        newJobRequest = NewJobRequest(source: source)
    }

    /// Çalışmayan bir işi düzenleme sayfasında açar.
    func beginEdit(_ id: TransferJob.ID) {
        guard let job = job(id), JobQueue.canEdit(job) else { return }
        newJobRequest = NewJobRequest(source: job.source, destination: job.destination, options: job.options, editing: id)
    }

    /// İşin ayarlarıyla yeni bir iş sayfası açar (ör. aynı kaynağı başka bir diske yedeklemek için).
    func beginDuplicate(_ id: TransferJob.ID) {
        guard let job = job(id) else { return }
        newJobRequest = NewJobRequest(source: job.source, destination: job.destination, options: job.options)
    }

    /// İş eklenmeden ya da kaydedilmeden önceki denetimler. - Returns: Sorun varsa açıklaması.
    private func validationMessage(source: URL, destination: URL, options: CopyOptions) -> String? {
        if let problem = JobValidation.check(source: source, destination: destination, copyMode: options.copyMode) {
            return settings.result(JobResult(kind: RsyncEngine.resultKind(for: problem)))
        }
        if let problem = options.problems(source: source).first {
            return settings.problem(problem)
        }
        return nil
    }

    /// Çalışmayan bir işin kaynağını, hedefini ve seçeneklerini değiştirir; geçmişi ve günlüğü korunur.
    /// - Returns: Sorun varsa açıklaması (sayfa kapanmaz).
    @discardableResult
    func updateJob(_ id: TransferJob.ID, source: URL, destination: URL, options: CopyOptions) -> String? {
        guard let job = job(id), JobQueue.canEdit(job) else { return settings.t(.errorCancelled) }
        if let message = validationMessage(source: source, destination: destination, options: options) { return message }
        update(id) { job in
            job.source = source
            job.destination = destination
            job.options = options
            job.appendLog(JobLogEntry(level: .info, key: .logEdited))
        }
        save()
        showToast(t(.toastJobUpdated), systemImage: "pencil.circle.fill")
        refreshShortcutParameters()
        scheduleNext()
        return nil
    }

    /// İşi değişiklik yapmadan çalıştırıp neyin kopyalanacağını, güncelleneceğini ve silineceğini listeler.
    func preview(source: URL, destination: URL, options: CopyOptions) async -> VerifyReport {
        await ensureEngine()
        guard let engineURL, let engineInfo else {
            return VerifyReport(entries: [], result: JobResult(kind: .engineMissing), checksum: false)
        }
        let context = EngineContext(executable: engineURL, info: engineInfo, sandboxed: settings.sandboxEngine)
        let job = TransferJob(source: source, destination: destination, options: options)
        return await engineProvider(job.kind).verify(job, context: context, checksum: false)
    }

    /// İşi denetler ve kuyruğa ekler. - Returns: Sorun varsa açıklaması (sayfa kapanmaz).
    @discardableResult
    func addJob(source: URL, destination: URL, options: CopyOptions) -> String? {
        if let message = validationMessage(source: source, destination: destination, options: options) { return message }
        let job = TransferJob(source: source, destination: destination, options: options)
        jobs.append(job)
        selection = [job.id]
        save()
        showToast(t(.toastJobAdded), systemImage: "plus.circle.fill")
        refreshShortcutParameters()
        scheduleNext()
        return nil
    }

    func pause(_ ids: Set<TransferJob.ID>) {
        for id in ids {
            guard let job = job(id), JobQueue.canPause(job) else { continue }
            if id == runningJobID {
                isPausingRunningJob = true
                runningTask?.cancel()
            } else {
                update(id) { $0.status = .paused; $0.appendLog(JobLogEntry(level: .info, key: .logPaused)) }
            }
        }
        save()
    }

    func resume(_ ids: Set<TransferJob.ID>) {
        for id in ids {
            guard let job = job(id), JobQueue.canResume(job) || JobQueue.canRunAgain(job) else { continue }
            update(id) { JobQueue.requeue(&$0) }
        }
        save()
        scheduleNext()
    }

    func pauseAll() { pause(Set(jobs.filter(JobQueue.canPause).map(\.id))) }

    func resumeAll() { resume(Set(jobs.filter(JobQueue.canResume).map(\.id))) }

    func remove(_ ids: Set<TransferJob.ID>) {
        jobs.removeAll { ids.contains($0.id) && JobQueue.canRemove($0) }
        selection.subtract(ids)
        save()
        refreshShortcutParameters()
        onActivityChange?()
    }

    func removeFinished() {
        let finished = Set(jobs.filter { $0.status == .finished }.map(\.id))
        remove(finished)
    }

    /// Çalışmayan tüm işler (geçmişleriyle). Kopyalanmış dosyalara ve anlık görüntülere dokunulmaz.
    var removableJobs: [TransferJob] { jobs.filter(JobQueue.canRemove) }

    /// Tüm işleri kaldırmadan önce onay ister; çalışan iş kuyrukta kalır.
    func requestRemoveAll() {
        let count = removableJobs.count
        guard count > 0 else { return }
        alert = AlertItem(
            title: t(.removeAllConfirmTitle),
            message: t(.removeAllConfirmMessage, count),
            actionTitle: t(.removeAllConfirmButton),
            action: { [weak self] in self?.removeAll() },
            isDestructive: true
        )
    }

    func removeAll() {
        remove(Set(removableJobs.map(\.id)))
    }

    func move(from source: IndexSet, to destination: Int) {
        JobQueue.move(&jobs, from: source, to: destination)
        save()
    }

    func toggleQueueHold() {
        settings.queueHeld.toggle()
        scheduleNext()
    }

    // MARK: - İş kuyruğu: çalıştırma

    /// Boştaysa sıradaki bekleyen işi başlatır. İşler birer birer, listedeki sırayla çalışır.
    func scheduleNext() {
        defer { onActivityChange?() }
        guard !isTerminating, runningJobID == nil, operation == nil, !settings.queueHeld, engineChecked,
              let engineURL, let engineInfo, let next = JobQueue.next(in: jobs, pathsAvailable: pathsAvailable) else { return }
        start(next, context: EngineContext(executable: engineURL, info: engineInfo, sandboxed: settings.sandboxEngine))
    }

    /// "Disk takılınca başla" seçili iş, diski takılı olmadığı için bekliyor.
    func isWaitingForDisk(_ job: TransferJob) -> Bool { JobQueue.isWaitingForDisk(job, pathsAvailable: pathsAvailable) }

    // MARK: - Disk takma ve çıkarma

    /// Bir disk çıkarılmak üzere: çalışan iş o diski kullanıyorsa durdurulur (rsync yarım dosyayı saklar, disk
    /// serbest kalır) ve disk takılınca sürmek üzere duraklatılır. Sırada bekleyen ve o diski kullanan işler de
    /// duraklatılır ("disk takılınca başla" seçili olanlar zaten bekler).
    func volumeWillUnmount(_ volume: URL) {
        if let id = runningJobID, let job = job(id), job.uses(volume: volume) {
            isSuspendingRunningJobForDisk = true
            runningTask?.cancel()
        }
        var changed = false
        for job in jobs where job.status == .waiting && !job.options.runWhenConnected && job.uses(volume: volume) {
            update(job.id) {
                $0.status = .paused
                $0.suspendedForDisk = true
                $0.appendLog(JobLogEntry(level: .info, key: .logSuspendedForDisk))
            }
            changed = true
        }
        if changed { save() }
    }

    /// Disk çıkarıldı (ya da kablo çekildi): çalışan iş hâlâ o diski kullanıyorsa durdurulur; az önce G/Ç hatasıyla
    /// biten iş de "disk bekliyor" olarak duraklatılır.
    func volumeDidUnmount(_ volume: URL, now: Date = Date()) {
        volumeWillUnmount(volume)
        var changed = false
        for job in jobs where job.status == .failed && job.uses(volume: volume) {
            guard let finished = job.finishedAt, now.timeIntervalSince(finished) < 30 else { continue }
            update(job.id) {
                $0.status = .paused
                $0.suspendedForDisk = true
                $0.appendLog(JobLogEntry(level: .info, key: .logSuspendedForDisk))
            }
            changed = true
        }
        if changed { save() }
    }

    /// Bir disk takıldı: o disk yüzünden duraklatılan işler sürer; hedefi bu diskte olan "disk takılınca başla" işleri
    /// (bitmiş ya da hatalı olsalar da) yeniden sıraya girer. Kullanıcının duraklattığı işlere dokunulmaz.
    func volumeDidMount(_ volume: URL) {
        var changed = false
        for job in jobs where job.uses(volume: volume) && pathsAvailable(job) {
            if job.status == .paused && job.suspendedForDisk {
                update(job.id) {
                    JobQueue.requeue(&$0)
                    $0.appendLog(JobLogEntry(level: .info, key: .logResumedAfterDisk))
                }
                changed = true
            } else if job.options.runWhenConnected, job.usesAsDestination(volume: volume),
                      job.status == .finished || job.status == .failed {
                update(job.id) {
                    JobQueue.requeue(&$0)
                    $0.appendLog(JobLogEntry(level: .info, key: .logStartedOnConnect))
                }
                changed = true
            }
        }
        if changed { save() }
        scheduleNext()
    }

    private func start(_ id: TransferJob.ID, context: EngineContext) {
        guard let job = job(id) else { return }
        runningJobID = id
        isPausingRunningJob = false
        let resuming = job.progress != nil || job.wasInterrupted || job.result?.kind == .cancelled
        update(id) {
            // Durum, motorun ilk olayını beklemeden hemen "taranıyor" olur: aksi hâlde başlamış bir iş bir an için
            // "bekliyor" görünür ve kaldırılabilirdi.
            $0.status = .scanning
            $0.startedAt = Date()
            $0.finishedAt = nil
            $0.wasInterrupted = false
            $0.appendLog(JobLogEntry(level: .info, key: resuming ? .logResumed : .logStarted, arguments: resuming ? [] : [context.info.version]))
        }
        beginSleepGuard(for: id)
        save()
        let engine = engineProvider(job.kind)
        let (events, continuation) = AsyncStream<TransferEvent>.makeStream(bufferingPolicy: .unbounded)
        runningTask = Task { [weak self] in
            // Olaylar sırayla ana iş parçacığında uygulanır; sonuç ancak tüm olaylar işlendikten sonra yazılır.
            let consumer = Task { @MainActor [weak self] in
                for await event in events { self?.apply(event, to: id) }
            }
            let result = await engine.run(job, context: context) { continuation.yield($0) }
            continuation.finish()
            await consumer.value
            self?.finishRun(id, result: result)
        }
    }

    private func apply(_ event: TransferEvent, to id: TransferJob.ID) {
        update(id) { JobQueue.apply(event, to: &$0) }
        switch event {
        case .phase, .log, .logBatch:
            save()
        case .progress:
            if Date().timeIntervalSince(lastProgressSave) > 5 {
                lastProgressSave = Date()
                save()
            }
        }
        onActivityChange?()
    }

    /// Çalışan işin ilerlemesi (0…1; bilinmiyorsa nil) — Dock simgesi ve menü çubuğu için.
    var runningFraction: Double? {
        guard let id = runningJobID, let job = job(id), job.status == .copying else { return nil }
        return job.progress?.fraction
    }

    /// Çalışan ve sırada bekleyen işlerin sayısı (Dock rozeti).
    var pendingCount: Int { jobs.lazy.filter { $0.status == .waiting || $0.status.isActive }.count }

    private func finishRun(_ id: TransferJob.ID, result: JobResult) {
        // Çıkışta durdurulan iş "kesildi" olarak kalır (bkz. `prepareForTermination`); sıradaki iş başlatılmaz.
        if isTerminating {
            runningJobID = nil
            runningTask = nil
            isSuspendingRunningJobForDisk = false
            endSleepGuard(for: id, announce: false)
            save()
            return
        }
        let pausedByUser = isPausingRunningJob
        let suspendedForDisk = isSuspendingRunningJobForDisk && result.kind == .cancelled
        update(id) { job in
            JobQueue.finish(&job, with: result)
            switch result.kind {
            case .cancelled where suspendedForDisk:
                job.suspendedForDisk = true
                job.appendLog(JobLogEntry(level: .info, key: .logSuspendedForDisk))
            case .cancelled, .stoppedAtLimit: job.appendLog(JobLogEntry(level: .info, key: .logPaused))
            case let kind where kind.isSuccess: job.appendLog(JobLogEntry(level: .info, key: .logFinished))
            default: job.appendLog(JobLogEntry(level: .error, key: .logFailed, arguments: [settings.result(result)]))
            }
        }
        runningJobID = nil
        runningTask = nil
        isPausingRunningJob = false
        isSuspendingRunningJobForDisk = false
        endSleepGuard(for: id, announce: true)
        save()
        if suspendedForDisk {
            showToast(t(.toastSuspendedForDisk), systemImage: "externaldrive.badge.exclamationmark")
        } else if let job = job(id), result.kind != .cancelled || !pausedByUser {
            notify(job)
        }
        scheduleNext()
    }

    private func notify(_ job: TransferJob) {
        guard settings.notifyOnFinish, let result = job.result, result.kind != .cancelled else { return }
        let name = job.source.lastPathComponent
        if result.kind == .stoppedAtLimit {
            notifier(t(.notifyStoppedTitle), t(.notifyStoppedBody, name))
        } else if result.kind.isSuccess {
            notifier(t(.notifyFinishedTitle), t(.notifyFinishedBody, name))
        } else {
            notifier(t(.notifyFailedTitle), t(.notifyFailedBody, name, settings.result(result)))
        }
    }

    /// macOS bildirimi; yalnızca gerçek uygulama paketinde (testlerde Bundle.main bir xctest paketidir).
    nonisolated static func postUserNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier == AppInfo.bundleIdentifier else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Çıkışta çalışan iş durdurulur (rsync yetim kalmasın) ve kesildi olarak kaydedilir; sonra aynı komutla sürer.
    func prepareForTermination() {
        isTerminating = true
        if let runningJobID {
            runningTask?.cancel()
            update(runningJobID) {
                $0.status = .paused
                $0.wasInterrupted = true
            }
        }
        operationTask?.cancel()
        if let runningJobID { endSleepGuard(for: runningJobID, announce: false) }
        save()
    }

    // MARK: - Uyku engeli ve güç önerileri

    /// İş başında uyku engelini alır, sistemde doğrular, günlüğe yazar ve kullanıcıya bildirir; güç önerilerini
    /// hesaplar ve iş sürerken güç durumunu izlemeye başlar.
    private func beginSleepGuard(for id: TransferJob.ID) {
        let status = sleepGuard.begin(keepDisplayAwake: settings.keepDisplayAwake)
        sleepStatus = status
        update(id) { job in
            job.appendLog(JobLogEntry(level: status.unverified ? .warning : .info,
                                      key: status.systemSleepPrevented ? .sleepPreventedVerified : .sleepPreventedUnverified))
            if status.displaySleepPrevented { job.appendLog(JobLogEntry(level: .info, key: .sleepDisplayKept)) }
        }
        if status.systemSleepPrevented { showToast(t(.toastSleepPrevented), systemImage: "cup.and.saucer.fill") }
        refreshPower(for: id, announceAll: true)
        powerMonitor?.cancel()
        let interval = powerCheckInterval
        powerMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.runningJobID == id else { return }
                self.refreshPower(for: id, announceAll: false)
            }
        }
    }

    /// İş bitince, duraklatılınca, hata verince ya da uygulama kapanırken uyku engelini bırakır ve doğrular.
    private func endSleepGuard(for id: TransferJob.ID, announce: Bool) {
        powerMonitor?.cancel()
        powerMonitor = nil
        guard sleepStatus != nil || sleepGuard.isHeld else { return }
        let stillPresent = sleepGuard.end()
        sleepStatus = nil
        powerAdvice = []
        update(id) { $0.appendLog(JobLogEntry(level: stillPresent ? .warning : .info, key: stillPresent ? .sleepRestoreUnverified : .sleepRestored)) }
        if announce { showToast(t(.toastSleepRestored), systemImage: "moon.zzz.fill") }
    }

    /// Güç durumunu okur ve önerileri günceller. İlk denetimde tüm öneriler, sonrakilerde yalnızca yeni uyarılar (pille
    /// çalışmaya geçme, pilin azalması, Düşük Güç Modu) günlüğe yazılır ve bildirilir; adaptör takılınca bu da yazılır.
    func refreshPower(for id: TransferJob.ID, announceAll: Bool) {
        let snapshot = powerProvider()
        let previous = powerAdvice
        let advice = PowerAdvisor.advice(for: snapshot, keepDisplayAwake: settings.keepDisplayAwake)
        let previousSource = powerSnapshot?.source
        powerSnapshot = snapshot
        powerAdvice = advice
        let toLog = announceAll ? advice : PowerAdvisor.newWarnings(previous: previous, current: advice)
        update(id) { job in
            for item in toLog { job.appendLog(JobLogEntry(level: item.isWarning ? .warning : .info, key: item.titleKey, arguments: item.arguments(snapshot, settings))) }
            if !announceAll, previousSource == .battery, snapshot.source == .ac {
                job.appendLog(JobLogEntry(level: .info, key: .adviceOnAC))
            }
        }
        if !announceAll, let warning = toLog.first(where: \.isWarning) {
            showToast(settings.t(warning.titleKey, arguments: warning.arguments(snapshot, settings)), systemImage: warning.systemImage)
        }
        if !toLog.isEmpty { save() }
    }

    // MARK: - Komut önizlemesi

    /// İşin çalıştıracağı rsync komutu (kopyalanabilir, kabuğa uygun tırnaklı). Kum havuzu ve uyku engeli komutun
    /// parçası değildir; uygulama onları ayrıca sağlar.
    func commandPreview(for job: TransferJob) -> String {
        // Anlık görüntü işi kökte tarihli bir klasöre, önceki anlık görüntüye bağlanarak yazar (klasör oluşturulmaz).
        let job = job.options.snapshots.enabled ? SnapshotStore.apply(SnapshotStore.plan(in: job.destination), to: job) : job
        let info = engineInfo ?? EngineInfo(version: "3.5.1", isOpenrsync: false, supportsACLs: true, supportsXattrs: true)
        let sourceIsDirectory = RsyncEngine.isDirectory(job.source) || !FileManager.default.fileExists(atPath: job.source.path)
        let protected = settings.sandboxEngine && sourceIsDirectory
            ? SandboxProfile.forTransfer(sources: [job.source], destination: job.destination).protectedPaths(inside: job.source)
            : []
        let environment = RsyncCommand.Environment(
            engine: info, destinationFileSystem: FileSystemKind.of(job.destination), sourceIsDirectory: sourceIsDirectory,
            protectedPaths: protected, enginePath: engineURL.map { SandboxProfile.resolved($0).path }
        )
        return RsyncCommand.displayString(arguments: RsyncCommand.transfer(job, environment: environment))
    }

    /// Çalışan işin ya da tek seferlik işlemin bitmesini bekler (testler için).
    func waitUntilIdle() async {
        while true {
            if let runningTask { await runningTask.value; continue }
            if let operationTask { await operationTask.value; continue }
            break
        }
    }

    // MARK: - Doğrulama

    func requestVerify(_ id: TransferJob.ID) {
        guard let job = job(id), JobQueue.canVerify(job) else { return }
        verifyChoice = id
    }

    func verify(_ id: TransferJob.ID, checksum: Bool) {
        verifyChoice = nil
        guard let job = job(id), JobQueue.canVerify(job) else { return }
        perform(.progressVerifying) { [weak self] in
            guard let self, let engineURL, let engineInfo else { throw EngineError.engineNotFound }
            let context = EngineContext(executable: engineURL, info: engineInfo, sandboxed: settings.sandboxEngine)
            let report = await engineProvider(job.kind).verify(job, context: context, checksum: checksum)
            if report.result.kind == .cancelled { throw EngineError.cancelled }
            let differences = report.entries.filter { $0.kind != .attributes }.count
            update(id) { $0.appendLog(JobLogEntry(level: .info, key: .logVerified, arguments: [String(differences)])) }
            save()
            verifyPresentation = VerifyPresentation(jobID: id, jobName: job.source.lastPathComponent, report: report)
        }
    }

    // MARK: - Tek seferlik işlemler

    func cancelOperation() {
        if operationTask != nil, operation?.isCancelling == false {
            operation?.isCancelling = true
            operation?.progress = nil
        }
        operationTask?.cancel()
    }

    private func perform(_ title: LKey, _ body: @escaping () async throws -> Void) {
        guard operation == nil else { return }
        operation = OperationState(titleKey: title, progress: nil)
        operationTask = Task {
            defer {
                operation = nil
                operationTask = nil
                presentPendingConsentIfIdle()
                scheduleNext()
            }
            do {
                try await body()
                lastOperationOutcome = Task.isCancelled ? .cancelled : .succeeded
            } catch {
                let cancelled = Task.isCancelled || (error as? EngineError) == .cancelled || error is CancellationError
                lastOperationOutcome = cancelled ? .cancelled : .failed
                if !cancelled { alert = AlertItem(title: t(.errorTitle), message: message(for: error)) }
            }
        }
    }

    func message(for error: Error) -> String {
        guard let error = error as? EngineError else { return error.localizedDescription }
        switch error {
        case .engineNotFound: return t(.errorEngineNotFound)
        case .timedOut: return t(.errorEngineTimeout)
        case .cancelled: return t(.errorCancelled)
        case .failed(let code, let detail):
            // update-rsync.sh derleyici yoksa bunu ayrı bir kodla bildirir.
            if detail.contains("command-line-tools-missing") { return t(.errorEngineBuildTools) }
            let summary = t(.errorFailed, Int(code))
            return detail.isEmpty ? summary : summary + "\n\n" + detail
        }
    }

    func showToast(_ message: String, systemImage: String, revealURL: URL? = nil) {
        toast = Toast(message: message, systemImage: systemImage, revealURL: revealURL)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Sürükle-bırak ve Finder

    /// Pencereye bırakılan ilk öğe, Yeni İş sayfasında kaynak olur.
    func handleDrop(_ urls: [URL]) {
        guard let first = urls.first(where: \.isFileURL) else { return }
        beginNewJob(source: first)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealSource(_ id: TransferJob.ID) {
        if let job = job(id) { reveal(job.source) }
    }

    /// Hedefteki kopya varsa o, yoksa hedef klasör gösterilir. Anlık görüntü işinde en yeni anlık görüntüdeki kopya.
    func revealDestination(_ id: TransferJob.ID) {
        guard var job = job(id) else { return }
        if job.options.snapshots.enabled, let latest = SnapshotStore.latest(in: job.destination) { job.destination = latest }
        let target = job.target(sourceIsDirectory: RsyncEngine.isDirectory(job.source))
        reveal(FileManager.default.fileExists(atPath: target.path) ? target : job.destination)
    }
}

enum AppLinks {
    static let engineWebsite = URL(string: "https://rsync.samba.org")!
    static let engineManual = URL(string: "https://download.samba.org/pub/rsync/rsync.1")!
    static let engineLicense = URL(string: "https://github.com/RsyncProject/rsync/blob/master/COPYING")!
    static var repository: URL { URL(string: "https://github.com/\(AppInfo.repository)")! }
    static var releases: URL { URL(string: "https://github.com/\(AppInfo.repository)/releases")! }
}

enum AppInfo {
    nonisolated static let bundleIdentifier = "com.babadogantech.copiator"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    /// GitHub deposu ("sahip/ad"); tek kaynağı Info.plist'teki CopiatorRepository anahtarıdır.
    static var repository: String {
        Bundle.main.object(forInfoDictionaryKey: "CopiatorRepository") as? String ?? "berkbb/copiator-mac-universal"
    }
    static var currentYear: String { String(Calendar.current.component(.year, from: .now)) }
}

enum WindowID {
    static let main = "main"
    static let about = "about"
}
