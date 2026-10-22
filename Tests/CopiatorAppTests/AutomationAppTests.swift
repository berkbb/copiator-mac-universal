// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Düzenleme ve çoğaltma, disk takılınca başlatma, önizleme, geçmiş, kopyalama sonrası doğrulama, Kestirmeler,
/// Dock/menü çubuğu sayaçları ve yetim süreç temizliği (uygulama modeli, gerçek rsync).
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct AutomationAppTests {
    @Test func editKeepsHistoryAndDuplicateOpensANewJob() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        await model.waitUntilIdle()
        #expect(model.job(id)?.history.count == 1)

        model.beginEdit(id)
        let request = try #require(model.newJobRequest)
        #expect(request.editing == id && request.source == fixture.url("Kaynak") && request.options == CopyOptions())
        model.newJobRequest = nil

        try FileManager.default.createDirectory(at: fixture.url("Hedef2"), withIntermediateDirectories: true)
        var options = CopyOptions(copyMode: .contents, verifyAfterCopy: .checksum)
        options.advanced.excludePresets = [.macOSJunk]
        #expect(model.updateJob(id, source: fixture.url("Kaynak"), destination: fixture.url("Hedef2"), options: options) == nil)
        let edited = try #require(model.job(id))
        #expect(edited.destination == fixture.url("Hedef2") && edited.options == options)
        #expect(edited.history.count == 1)
        #expect(edited.log.contains { $0.key == LKey.logEdited.rawValue })
        // Geçersiz seçenekler ve çakışan yollar kaydedilmez.
        options.snapshots = SnapshotOptions(enabled: true, keepLast: 0)
        #expect(model.updateJob(id, source: fixture.url("Kaynak"), destination: fixture.url("Hedef2"), options: options) != nil)
        #expect(model.updateJob(id, source: fixture.url("Kaynak"), destination: fixture.url("Kaynak"), options: CopyOptions()) != nil)
        #expect(model.job(id)?.options.snapshots.enabled == false)

        model.beginDuplicate(id)
        let duplicate = try #require(model.newJobRequest)
        #expect(duplicate.editing == nil && duplicate.destination == fixture.url("Hedef2") && duplicate.options == edited.options)
        model.newJobRequest = nil

        // Çalışan iş düzenlenemez.
        model.toggleQueueHold()
        model.resume([id])
        #expect(JobQueue.canEdit(try #require(model.job(id))))
        model.toggleQueueHold()
        #expect(model.job(id)?.status.isActive == true)
        model.beginEdit(id)
        #expect(model.newJobRequest == nil)
        await model.waitUntilIdle()
        #expect(model.job(id)?.history.count == 2)
        #expect(model.job(id)?.result?.differenceCount == 0)
    }

    /// "Disk takılınca başla": disk yokken iş bekler (hata vermez), sıradaki iş başlar; disk takılınca (bitmiş olsa da)
    /// yeniden çalışır.
    @Test func runWhenConnectedWaitsAndStartsOnMount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        var connected = false
        let volume = fixture.url("Hedef")
        model.pathsAvailable = { job in job.usesAsDestination(volume: volume) ? connected : true }
        model.toggleQueueHold()
        let waiting = try #require(fixture.addJob(options: CopyOptions(runWhenConnected: true)))
        let other = try #require(fixture.addJob(options: CopyOptions(copyMode: .contents)))
        #expect(model.isWaitingForDisk(try #require(model.job(waiting))))
        model.toggleQueueHold()
        await model.waitUntilIdle()
        #expect(model.job(waiting)?.status == .waiting)
        #expect(model.job(other)?.status == .finished)

        connected = true
        model.volumeDidMount(volume)
        await model.waitUntilIdle()
        #expect(model.job(waiting)?.status == .finished)
        // Bitmiş iş disk yeniden takılınca yeniden çalışır; seçeneği olmayan bitmiş iş çalışmaz.
        model.volumeDidMount(volume)
        #expect(model.job(waiting)?.log.contains { $0.key == LKey.logStartedOnConnect.rawValue } == true)
        await model.waitUntilIdle()
        #expect(model.job(waiting)?.history.count == 2)
        #expect(model.job(other)?.history.count == 1)
        // Başka bir disk hiçbir şeyi tetiklemez.
        model.volumeDidMount(fixture.url("BaskaDisk"))
        await model.waitUntilIdle()
        #expect(model.job(waiting)?.history.count == 2)
    }

    /// Disk çıkarılırken çalışan iş duraklar (bildirim yerine kısa uyarı), disk takılınca kaldığı yerden sürer.
    @Test func ejectPausesAndRemountResumes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeLargeFile("Kaynak/buyuk.bin", megabytes: 512)
        let model = fixture.model
        await model.refreshEngine()
        let volume = fixture.url("Hedef")
        let id = try #require(fixture.addJob())
        for _ in 0..<100 where model.job(id)?.status != .copying { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(150))
        model.volumeWillUnmount(volume)
        await model.waitUntilIdle()
        let paused = try #require(model.job(id))
        #expect(paused.status == .paused && paused.suspendedForDisk)
        #expect(paused.log.contains { $0.key == LKey.logSuspendedForDisk.rawValue })
        #expect(fixture.notifications.isEmpty)
        #expect(model.toast != nil)

        model.volumeDidMount(volume)
        await model.waitUntilIdle()
        let resumed = try #require(model.job(id))
        #expect(resumed.status == .finished, "\(String(describing: resumed.result))")
        #expect(!resumed.suspendedForDisk)
        #expect(resumed.log.contains { $0.key == LKey.logResumedAfterDisk.rawValue })
        #expect(resumed.history.map(\.result.kind) == [.cancelled, .succeeded])
    }

    /// Kablo çekilince G/Ç hatasıyla az önce biten iş de disk takılınca sürmek üzere duraklatılır; kullanıcının
    /// duraklattığı işe dokunulmaz.
    @Test func unplugMarksRecentFailuresAsWaitingForDisk() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.engineProvider = { _ in StoppingEngine() }
        model.toggleQueueHold()
        let failed = try #require(fixture.addJob())
        let userPaused = try #require(fixture.addJob(options: CopyOptions(copyMode: .contents)))
        let waiting = try #require(fixture.addJob(options: CopyOptions(preservePermissions: true)))
        model.pause([userPaused])
        let store = JobStore(url: fixture.url("Destek/jobs.json"))
        var jobs = try store.load()
        let index = try #require(jobs.firstIndex { $0.id == failed })
        JobQueue.finish(&jobs[index], with: JobResult(kind: .ioError, exitCode: 11), at: Date())
        try store.save(jobs)
        let model2 = fixture.relaunch()
        model2.volumeDidUnmount(fixture.url("Hedef"))
        #expect(model2.job(failed)?.status == .paused && model2.job(failed)?.suspendedForDisk == true)
        #expect(model2.job(waiting)?.status == .paused && model2.job(waiting)?.suspendedForDisk == true)
        #expect(model2.job(userPaused)?.suspendedForDisk == false)
        model2.volumeDidMount(fixture.url("Hedef"))
        #expect(model2.job(failed)?.status == .waiting && model2.job(waiting)?.status == .waiting)
        #expect(model2.job(userPaused)?.status == .paused)
    }

    @Test func previewListsChangesWithoutWriting() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        try fixture.write("Hedef/Kaynak/eski.txt", "eski\n")
        let report = await model.preview(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"),
                                         options: CopyOptions(deleteExtraneous: true))
        #expect(report.result.kind == .succeeded)
        #expect(Set(report.entries.filter { $0.kind == .missing }.map(\.path)).isSuperset(of: ["Kaynak/not.txt", "Kaynak/alt/b.txt"]))
        #expect(report.entries.contains { $0.kind == .extra && $0.path == "Kaynak/eski.txt" })
        #expect(fixture.read("Hedef/Kaynak/eski.txt") == "eski\n")
        #expect(fixture.read("Hedef/Kaynak/not.txt") == nil)
        // Anlık görüntü işinde henüz anlık görüntü yokken her şey kopyalanacak görünür; hedefe hiçbir şey yazılmaz.
        try FileManager.default.createDirectory(at: fixture.url("Yedekler"), withIntermediateDirectories: true)
        let snapshot = await model.preview(source: fixture.url("Kaynak"), destination: fixture.url("Yedekler"),
                                           options: CopyOptions(snapshots: SnapshotOptions(enabled: true)))
        #expect(snapshot.entries.contains { $0.kind == .missing && $0.path == "Kaynak/not.txt" })
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url("Yedekler").path).isEmpty)
    }

    /// Anlık görüntü işi: her çalıştırma tarihli klasör, "Latest", geçmişte anlık görüntü adı; komut önizlemesi
    /// `--link-dest` ve "….partial" hedefini gösterir.
    @Test func snapshotJobsRecordSnapshotsInHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        try FileManager.default.createDirectory(at: fixture.url("Yedekler"), withIntermediateDirectories: true)
        let options = CopyOptions(snapshots: SnapshotOptions(enabled: true, keepLast: 5), verifyAfterCopy: .quick)
        #expect(model.addJob(source: fixture.url("Kaynak"), destination: fixture.url("Yedekler"), options: options) == nil)
        let id = try #require(model.jobs.last?.id)
        await model.waitUntilIdle()
        model.resume([id])
        await model.waitUntilIdle()
        let job = try #require(model.job(id))
        #expect(job.status == .finished, "\(String(describing: job.result))")
        let names = job.history.compactMap(\.result.snapshot)
        #expect(names.count == 2)
        #expect(SnapshotStore.completeSnapshots(in: fixture.url("Yedekler")) == names)
        #expect(fixture.read("Yedekler/Latest/Kaynak/not.txt") == "merhaba\n")
        let command = model.commandPreview(for: job)
        #expect(command.contains("--link-dest=") && command.contains(names[1]) && command.contains(".partial/"))
    }

    @Test func verificationFailureFailsTheJobAndNotifies() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        model.engineProvider = { _ in DifferingEngine() }
        let id = try #require(fixture.addJob(options: CopyOptions(verifyAfterCopy: .quick)))
        await model.waitUntilIdle()
        let job = try #require(model.job(id))
        #expect(job.status == .failed)
        #expect(job.result?.kind == .verificationFailed && job.result?.differenceCount == 3)
        #expect(fixture.notifications.count == 1)
        #expect(fixture.settings.result(try #require(job.result)).contains("3"))
    }

    /// Kestirmeler: iş listesi, çalıştırma, tümünü duraklatma ve sürdürme.
    @Test func shortcutsRunAndPauseJobs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await IntentTargetLock.shared.acquire()
        defer { IntentTargetLock.shared.release() }
        IntentTarget.model = { model }
        defer { IntentTarget.model = { AppModel.shared } }
        model.toggleQueueHold()
        let id = try #require(fixture.addJob())
        let entities = try await JobEntityQuery().suggestedEntities()
        #expect(entities.map(\.id) == [id] && entities.first?.name == "Kaynak")
        #expect(try await JobEntityQuery().entities(for: [id, UUID()]).map(\.id) == [id])

        #expect(await IntentTarget.pauseAll() == fixture.settings.t(.intentPauseAllDone))
        #expect(model.job(id)?.status == .paused)
        model.toggleQueueHold()
        let message = await IntentTarget.runJob(id)
        #expect(message == fixture.settings.t(.intentRunJobStarted, "Kaynak"))
        await model.waitUntilIdle()
        #expect(model.job(id)?.status == .finished)
        #expect(await IntentTarget.runJob(UUID()) == fixture.settings.t(.intentJobNotFound))
        #expect(await IntentTarget.resumeAll() == fixture.settings.t(.intentResumeAllDone))
    }

    /// Kuyruğu temizleme: bitmiş işler hemen, tüm işler onaydan sonra kaldırılır; çalışan iş ve diskteki dosyalar kalır.
    @Test func clearFinishedAndClearAll() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeLargeFile("Kaynak/buyuk.bin", megabytes: 256)
        let model = fixture.model
        await model.refreshEngine()
        model.toggleQueueHold()
        let finished = try #require(fixture.addJob(options: CopyOptions(copyMode: .contents)))
        let running = try #require(fixture.addJob())
        let paused = try #require(fixture.addJob(options: CopyOptions(preservePermissions: true)))
        model.pause([running, paused])
        model.toggleQueueHold()
        await model.waitUntilIdle()
        #expect(model.job(finished)?.status == .finished)

        model.removeFinished()
        #expect(model.job(finished) == nil && model.jobs.count == 2)
        #expect(fixture.read("Hedef/not.txt") == "merhaba\n")

        model.resume([running])
        for _ in 0..<100 where model.job(running)?.status.isActive != true { try await Task.sleep(for: .milliseconds(20)) }
        model.requestRemoveAll()
        let alert = try #require(model.alert)
        #expect(alert.isDestructive)
        #expect(alert.message.contains("1"))
        alert.action?()
        #expect(model.jobs.map(\.id) == [running])
        model.pause([running])
        await model.waitUntilIdle()
        model.removeAll()
        #expect(model.jobs.isEmpty)
        model.alert = nil
        model.requestRemoveAll()
        #expect(model.alert == nil)
    }

    /// Dock ve menü çubuğu sayaçları; etkinlik değişince bildirim gelir.
    @Test func activityCountersFollowTheQueue() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        var notified = 0
        model.onActivityChange = { notified += 1 }
        model.toggleQueueHold()
        fixture.addJob()
        fixture.addJob(options: CopyOptions(copyMode: .contents))
        #expect(model.pendingCount == 2)
        #expect(model.runningFraction == nil)
        model.toggleQueueHold()
        await model.waitUntilIdle()
        #expect(model.pendingCount == 0)
        #expect(notified > 2)
    }

    /// Önceki oturumdan kalan yetim rsync açılışta durdurulur ve kesilen işin günlüğüne yazılır.
    @Test func launchReapsOrphanedEngines() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let result = try await CommandRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
            .run(["-c", "/bin/sleep 30 >/dev/null 2>&1 </dev/null & echo $!"], timeout: 10)
        let pid = try #require(pid_t(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        for _ in 0..<40 where ChildProcessGuard.bsdInfo(pid)?.pbi_ppid != 1 { try await Task.sleep(for: .milliseconds(50)) }
        let stateFile = fixture.url("Destek/running.json")
        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([try #require(ChildProcessGuard.record(for: pid, name: "rsync"))]).write(to: stateFile)

        fixture.model.toggleQueueHold()
        let id = try #require(fixture.addJob())
        var jobs = try fixture.store.load()
        jobs[0].status = .copying
        try fixture.store.save(jobs)
        let model = AppModel(settings: fixture.settings, store: fixture.store, sleepReason: "Copiator test \(fixture.suiteName)",
                             processStateFile: stateFile)
        defer { ChildProcessGuard.configure(stateFile: nil) }
        await model.launch()
        for _ in 0..<40 where ChildProcessGuard.bsdInfo(pid).map({ $0.pbi_status != UInt32(SZOMB) }) == true {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ChildProcessGuard.bsdInfo(pid).map { $0.pbi_status == UInt32(SZOMB) } ?? true)
        let job = try #require(model.job(id))
        #expect(job.wasInterrupted)
        #expect(job.log.contains { $0.key == LKey.logOrphanStopped.rawValue && $0.arguments.first?.contains(String(pid)) == true })
    }
}

/// Kopyalamayı başarıyla bitirip doğrulamada fark bulan sahte motor.
struct DifferingEngine: TransferEngine {
    var kind: JobKind { .rsync }
    func run(_ job: TransferJob, context: EngineContext, onEvent: @escaping @Sendable (TransferEvent) -> Void) async -> JobResult {
        onEvent(.phase(.copying))
        onEvent(.phase(.verifying))
        return JobResult(kind: .verificationFailed, exitCode: 0, differenceCount: 3)
    }
    func verify(_ job: TransferJob, context: EngineContext, checksum: Bool) async -> VerifyReport {
        VerifyReport(entries: [], result: JobResult(kind: .succeeded), checksum: checksum)
    }
}
