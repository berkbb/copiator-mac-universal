// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Copiator
@testable import CopiatorCore

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Projedeki Vendor/rsync/rsync (yoksa COPIATOR_RSYNC).
let rsyncURL: URL? = {
    let candidates = [
        ProcessInfo.processInfo.environment["COPIATOR_RSYNC"],
        packageRoot.appendingPathComponent("Vendor/rsync/rsync").path,
    ].compactMap { $0 }
    return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

/// Paketin dil tabloları (Resources/<dil>.lproj): testler ve ekran görüntüleri gerçek metinlerle çalışır.
let resourcesBundle = Bundle(url: packageRoot.appendingPathComponent("Resources")) ?? .main

/// `IntentTarget.model` uygulama genelinde tek bir değişkendir: onu değiştiren testler (ayrı takımlarda olsalar da) sırayla
/// çalışır; yoksa paralel bir test kestirmeyi kendi modeline yönlendirebilir.
@MainActor
final class IntentTargetLock {
    static let shared = IntentTargetLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// Her test kendi geçici klasörü, kendi UserDefaults alanı, kendi kayıt dosyası ve gerçek rsync ile çalışan bir
/// AppModel kurar.
@MainActor
final class Fixture {
    let workspace: URL
    let defaults: UserDefaults
    let suiteName = "CopiatorAppTests-\(UUID().uuidString)"
    let settings: AppSettings
    let store: JobStore
    private(set) var model: AppModel
    var notifications: [(String, String)] = []
    /// Bildirimlerin düğmeleri (bildirimlerle aynı sırada).
    var noticeActions: [NoticeAction?] = []

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        workspace = SandboxProfile.resolved(base)
        defaults = try #require(UserDefaults(suiteName: suiteName))
        settings = AppSettings(defaults: defaults, bundle: resourcesBundle)
        settings.customEnginePath = rsyncURL?.path
        settings.updateConsentAsked = true
        // Testler bu Mac'teki gerçek Ollama ya da LM Studio'ya istek göndermesin (Otomatik kip ikisini de yoklar).
        settings.aiProvider = .apple
        store = JobStore(url: workspace.appendingPathComponent("Destek/jobs.json"))
        model = AppModel(settings: settings, store: store, sleepReason: "Copiator test \(suiteName)")
        attach(model)
        try write("Kaynak/not.txt", "merhaba\n")
        try write("Kaynak/alt/b.txt", "alt\n")
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Hedef"), withIntermediateDirectories: true)
    }

    private func attach(_ model: AppModel) {
        model.notifier = { [weak self] title, body, action in
            self?.notifications.append((title, body))
            self?.noticeActions.append(action)
        }
    }

    /// Aynı kayıt dosyası ve ayarlarla yeni bir model (uygulamanın yeniden açılması).
    func relaunch() -> AppModel {
        model = AppModel(settings: settings, store: store, sleepReason: "Copiator test \(suiteName)")
        attach(model)
        return model
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: workspace)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func url(_ path: String) -> URL { workspace.appendingPathComponent(path) }

    func write(_ path: String, _ text: String) throws {
        let url = url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) -> String? {
        (try? Data(contentsOf: url(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Kesip sürdürme testleri için yavaş kopyalanan büyük bir dosya.
    func writeLargeFile(_ path: String, megabytes: Int) throws {
        let url = url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let chunk = Data(repeating: 0xA5, count: 1 << 20)
        for _ in 0..<megabytes { handle.write(chunk) }
        try handle.close()
    }

    @discardableResult
    func addJob(_ source: String = "Kaynak", options: CopyOptions = CopyOptions()) -> TransferJob.ID? {
        let message = model.addJob(source: url(source), destination: url("Hedef"), options: options)
        #expect(message == nil, "\(message ?? "")")
        return model.jobs.last?.id
    }
}

@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct AppModelTests {
    @Test func engineIsFoundAndChosen() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        #expect(fixture.model.engineStatus == .ready(version: "3.5.1", limited: false))
        #expect(fixture.model.engineURL?.path == rsyncURL?.path)
    }

    @Test func addedJobRunsToCompletionAndNotifies() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        await model.waitUntilIdle()
        let job = try #require(model.job(id))
        #expect(job.status == .finished)
        #expect(job.result?.kind == .succeeded)
        #expect(job.progress?.fraction == 1)
        #expect(job.startedAt != nil && job.finishedAt != nil)
        #expect(fixture.read("Hedef/Kaynak/alt/b.txt") == "alt\n")
        #expect(job.log.contains { $0.key == LKey.logStarted.rawValue })
        #expect(job.log.contains { $0.key == LKey.logFinished.rawValue })
        #expect(fixture.notifications.count == 1)
        #expect(model.runningJobID == nil)
        // Uyku engeli iş bitince bırakıldı.
        #expect(!SleepAssertion.activeAssertionNames().contains(model.sleepReason))
        // Kalıcı kayıt: dosyada da bitti olarak durur.
        #expect(try fixture.store.load().first?.status == .finished)
    }

    /// İşler birer birer, listedeki sırayla çalışır.
    @Test func jobsRunOneAtATimeInOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("Ikinci/x.txt", "x\n")
        let model = fixture.model
        await model.refreshEngine()
        settingsHold(fixture, true)
        let first = try #require(fixture.addJob())
        let second = try #require(fixture.addJob("Ikinci"))
        #expect(model.runningJobID == nil)
        settingsHold(fixture, false)
        #expect(model.runningJobID == first)
        #expect(model.job(second)?.status == .waiting)
        await model.waitUntilIdle()
        let a = try #require(model.job(first)), b = try #require(model.job(second))
        #expect(a.status == .finished && b.status == .finished)
        #expect(try #require(a.finishedAt) <= (try #require(b.startedAt)))
        #expect(fixture.read("Hedef/Ikinci/x.txt") == "x\n")
    }

    private func settingsHold(_ fixture: Fixture, _ held: Bool) {
        if fixture.settings.queueHeld != held { fixture.model.toggleQueueHold() }
    }

    /// Duraklatılan iş aynı komutla kaldığı yerden sürer ve aynı sonuca varır; duraklatma bildirim göstermez.
    @Test func pauseAndResumeCompletesTheCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeLargeFile("Kaynak/buyuk.bin", megabytes: 768)
        let model = fixture.model
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        // Kopyalama başlayana kadar bekle.
        for _ in 0..<100 where model.job(id)?.status != .copying { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        model.pause([id])
        #expect(model.isPausingRunningJob)
        await model.waitUntilIdle()
        #expect(model.job(id)?.status == .paused)
        #expect(model.job(id)?.result?.kind == .cancelled)
        #expect(fixture.notifications.isEmpty)
        #expect(!SleepAssertion.activeAssertionNames().contains(model.sleepReason))

        model.resume([id])
        await model.waitUntilIdle()
        let job = try #require(model.job(id))
        #expect(job.status == .finished, "\(String(describing: job.result))")
        #expect(job.log.contains { $0.key == LKey.logResumed.rawValue })
        let size = try FileManager.default.attributesOfItem(atPath: fixture.url("Hedef/Kaynak/buyuk.bin").path)[.size] as? NSNumber
        #expect(size?.intValue == 768 << 20)
    }

    /// Uygulama iş sürerken kapanırsa iş "kesildi" ve duraklatılmış olarak geri gelir; ayar açıksa kendiliğinden sürer.
    @Test func queueIsRestoredAfterRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeLargeFile("Kaynak/buyuk.bin", megabytes: 512)
        let model = fixture.model
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        for _ in 0..<100 where model.job(id)?.status != .copying { try await Task.sleep(for: .milliseconds(20)) }
        model.prepareForTermination()
        await model.waitUntilIdle()

        let reopened = fixture.relaunch()
        let restored = try #require(reopened.job(id))
        #expect(restored.status == .paused)
        #expect(restored.wasInterrupted)
        #expect(restored.log.contains { $0.key == LKey.logInterrupted.rawValue })

        fixture.settings.resumeInterruptedAtLaunch = true
        let again = fixture.relaunch()
        await again.refreshEngine()
        #expect(again.job(id)?.status == .waiting)
        again.scheduleNext()
        await again.waitUntilIdle()
        #expect(again.job(id)?.status == .finished)
    }

    @Test func heldQueueDoesNotStartJobs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        model.toggleQueueHold()
        let id = try #require(fixture.addJob())
        await model.waitUntilIdle()
        #expect(model.job(id)?.status == .waiting)
        model.toggleQueueHold()
        await model.waitUntilIdle()
        #expect(model.job(id)?.status == .finished)
    }

    /// Kaynakla çakışan iş kuyruğa hiç girmez; açıklaması seçili dilde döner.
    @Test func overlappingJobIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let message = fixture.model.addJob(source: fixture.url("Kaynak"), destination: fixture.url("Kaynak/alt"), options: CopyOptions())
        #expect(message != nil)
        #expect(fixture.model.jobs.isEmpty)
    }

    @Test func verifyPresentsDifferencesWithoutChangingAnything() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        await model.waitUntilIdle()
        model.verify(id, checksum: false)
        await model.waitUntilIdle()
        #expect(model.verifyPresentation?.report.isIdentical == true)

        try fixture.write("Kaynak/yeni.txt", "yeni\n")
        model.verifyPresentation = nil
        model.verify(id, checksum: true)
        await model.waitUntilIdle()
        let report = try #require(model.verifyPresentation?.report)
        #expect(report.checksum)
        #expect(report.entries.contains { $0.kind == .missing && $0.path == "Kaynak/yeni.txt" })
        #expect(fixture.read("Hedef/Kaynak/yeni.txt") == nil)
        #expect(model.job(id)?.log.contains { $0.key == LKey.logVerified.rawValue } == true)
    }

    @Test func runningJobsCannotBeRemoved() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeLargeFile("Kaynak/buyuk.bin", megabytes: 512)
        let model = fixture.model
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        model.remove([id])
        #expect(model.job(id) != nil)
        model.pause([id])
        await model.waitUntilIdle()
        model.remove([id])
        #expect(model.job(id) == nil)
        #expect(try fixture.store.load().isEmpty)
    }

    /// Bitmiş iş yeniden çalıştırılınca yalnızca değişenler kopyalanır; --delete seçiliyse fazlalar silinir.
    @Test func runAgainSyncsChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        // Eşitleme işi: yeniden çalıştırmada hedefteki dosyalar güncellenir (çakışma sorusu olmadan).
        let id = try #require(fixture.addJob(options: CopyOptions(deleteExtraneous: true, conflictPolicy: .replace)))
        await model.waitUntilIdle()
        try FileManager.default.removeItem(at: fixture.url("Kaynak/not.txt"))
        try fixture.write("Kaynak/yeni.txt", "yeni\n")
        model.resume([id])
        await model.waitUntilIdle()
        #expect(model.job(id)?.status == .finished)
        #expect(fixture.read("Hedef/Kaynak/yeni.txt") == "yeni\n")
        #expect(fixture.read("Hedef/Kaynak/not.txt") == nil)
        // Kaynak değişmedi (silinen dosyayı kullanıcı sildi; kopya onu geri getirmedi).
        #expect(fixture.read("Kaynak/yeni.txt") == "yeni\n")
    }

    @Test func corruptStoreIsBackedUpAndReported() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bozuk".utf8).write(to: fixture.store.url)
        let model = fixture.relaunch()
        #expect(model.jobs.isEmpty)
        #expect(model.alert != nil)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.store.url.deletingLastPathComponent().path)
        #expect(siblings.contains { $0.hasPrefix("jobs.corrupt-") })
    }

    @Test func filtersCountJobs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.toggleQueueHold()
        fixture.addJob()
        #expect(model.count(for: .all) == 1)
        #expect(model.count(for: .active) == 1)
        #expect(model.count(for: .finished) == 0)
        model.pause(Set(model.jobs.map(\.id)))
        #expect(model.count(for: .paused) == 1)
        model.filter = .finished
        #expect(model.visibleJobs.isEmpty)
    }
}

// MARK: - Ayarlar

@Suite(.serialized)
@MainActor
struct SettingsTests {
    @Test func defaultsAreSafe() throws {
        let suite = "CopiatorSettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, bundle: .main)
        #expect(settings.language == .tr)
        #expect(settings.sandboxEngine)
        #expect(!settings.checkUpdatesAtLaunch)
        #expect(!settings.updateConsentAsked)
        // --delete hiçbir zaman varsayılan değildir.
        #expect(!settings.defaultOptions.deleteExtraneous)
        #expect(settings.defaultOptions.excludeSystemFolders)
        #expect(settings.defaultOptions.preserveExtendedAttributes)
        #expect(settings.defaultOptions.copyMode == .folder)
    }

    @Test func resetRemovesAllPreferences() throws {
        let suite = "CopiatorSettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, bundle: .main)
        settings.language = .ro
        settings.sandboxEngine = false
        settings.queueHeld = true
        settings.setShortcut(KeyboardShortcutData(key: "J", command: true, shift: true), for: .verify)
        settings.resetAll()
        let remaining = defaults.dictionaryRepresentation().keys.filter { defaults.persistentDomain(forName: suite)?[$0] != nil }
        #expect(remaining.isEmpty, "\(remaining)")
        #expect(settings.sandboxEngine)
        #expect(settings.isAllShortcutsDefault)
    }

    @Test func defaultShortcutsDoNotConflict() {
        let shortcuts = ShortcutAction.allCases.map(\.defaultShortcut)
        #expect(Set(shortcuts.map(\.displayString)).count == shortcuts.count)
        #expect(ShortcutAction.allCases.allSatisfy { !$0.allowsBareKey })
    }

    @Test func formatsDurationsAndResults() throws {
        let suite = "CopiatorSettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, bundle: .main)
        #expect(!settings.duration(seconds: 75).isEmpty)
        #expect(!settings.duration(seconds: 7_300).isEmpty)
        #expect(!settings.result(JobResult(kind: .partial, noteCount: 2)).isEmpty)
        // Dil tabloları gerçekten yüklenir (anahtar adları görünmez).
        let real = AppSettings(defaults: defaults, bundle: resourcesBundle)
        #expect(real.t(.menuNewJob) == "Yeni İş…")
        real.language = .ro
        #expect(real.t(.statusPaused) == "Întreruptă")
    }
}
