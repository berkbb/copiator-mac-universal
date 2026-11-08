// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Uyku engeli, güç önerileri ve gelişmiş seçenekler: gerçek rsync ve sistemin engel listesiyle.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct PowerAndOptionsTests {
    /// İş başında uyku engeli alınır ve sistemde doğrulanır, kullanıcıya bildirilir; bitince bırakılır ve bu da bildirilir.
    @Test func sleepIsPreventedVerifiedAndReleased() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeLargeFile("Kaynak/buyuk.bin", megabytes: 384)
        let model = fixture.model
        model.powerProvider = { PowerSnapshot(source: .ac, hasBattery: false) }
        await model.refreshEngine()
        // Engel, iş başlarken (motor çalışmadan önce) alınır.
        let id = try #require(fixture.addJob())
        let status = try #require(model.sleepStatus)
        #expect(status.systemSleepPrevented && !status.unverified)
        #expect(SleepAssertion.activeAssertionNames().contains(model.sleepReason))
        #expect(model.toast != nil)
        await model.waitUntilIdle()
        let log = try #require(model.job(id)).log.compactMap(\.key)
        #expect(log.contains(LKey.sleepPreventedVerified.rawValue))
        #expect(log.contains(LKey.sleepRestored.rawValue))
        #expect(log.contains(LKey.adviceDisplaySleep.rawValue))
        #expect(model.sleepStatus == nil)
        #expect(!SleepAssertion.activeAssertionNames().contains(model.sleepReason))
    }

    /// Duraklatınca da uyku engeli bırakılır.
    @Test func pauseReleasesSleepPrevention() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeLargeFile("Kaynak/buyuk.bin", megabytes: 512)
        let model = fixture.model
        await model.refreshEngine()
        // Hız sınırı: kopya, duraklatma gelmeden bitmesin (tam test yükünde 512 MB çok hızlı kopyalanabiliyordu).
        var options = CopyOptions()
        options.advanced.bandwidthLimitKiB = 50_000
        let id = try #require(fixture.addJob(options: options))
        for _ in 0..<100 where model.job(id)?.status != .copying { try await Task.sleep(for: .milliseconds(20)) }
        model.pause([id])
        await model.waitUntilIdle()
        #expect(model.job(id)?.status == .paused, "\(String(describing: model.job(id)?.result)) \(model.job(id)?.log.map { fixture.settings.log($0) } ?? [])")
        #expect(model.sleepStatus == nil)
        #expect(!SleepAssertion.activeAssertionNames().contains(model.sleepReason))
        #expect(model.job(id)?.log.contains { $0.key == LKey.sleepRestored.rawValue } == true)
    }

    /// "Ekranı da açık tut": ekran engeli de alınır ve doğrulanır.
    @Test func keepDisplayAwakeTakesDisplayAssertion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeLargeFile("Kaynak/buyuk.bin", megabytes: 384)
        fixture.settings.keepDisplayAwake = true
        let model = fixture.model
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        #expect(model.sleepStatus?.displaySleepPrevented == true)
        #expect(SleepAssertion.activeAssertionNames().contains(model.sleepReason + " (display)"))
        await model.waitUntilIdle()
        #expect(model.job(id)?.log.contains { $0.key == LKey.sleepDisplayKept.rawValue } == true)
        #expect(!SleepAssertion.activeAssertionNames().contains(model.sleepReason + " (display)"))
    }

    /// Pille çalışmaya geçme ve pilin azalması iş sürerken fark edilir, günlüğe yazılır ve bildirilir.
    @Test func powerChangesDuringAJobAreAnnounced() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeLargeFile("Kaynak/buyuk.bin", megabytes: 768)
        let model = fixture.model
        let power = PowerBox(PowerSnapshot(source: .ac, hasBattery: true, batteryPercent: 90, isCharging: true))
        model.powerProvider = { power.value }
        model.powerCheckInterval = .milliseconds(100)
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        for _ in 0..<100 where model.job(id)?.status != .copying { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.powerAdvice.contains(.lidClosesSleep))
        power.value = PowerSnapshot(source: .battery, hasBattery: true, batteryPercent: 15)
        for _ in 0..<50 where !model.powerAdvice.contains(.batteryLow) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.powerAdvice.first == .batteryLow)
        power.value = PowerSnapshot(source: .ac, hasBattery: true, batteryPercent: 16, isCharging: true)
        for _ in 0..<50 where model.powerAdvice.contains(.batteryLow) { try await Task.sleep(for: .milliseconds(20)) }
        model.pause([id])
        await model.waitUntilIdle()
        let keys = try #require(model.job(id)).log.compactMap(\.key)
        #expect(keys.contains(LKey.adviceBatteryLow.rawValue))
        #expect(keys.contains(LKey.adviceOnAC.rawValue))
        #expect(model.powerAdvice.isEmpty)
    }

    /// Hatalı gelişmiş seçeneklerle iş kuyruğa eklenmez; açıklama döner.
    @Test func invalidAdvancedOptionsAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var options = CopyOptions()
        options.advanced.chmod = "yanlış"
        let message = fixture.model.addJob(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"), options: options)
        #expect(message == fixture.settings.t(.problemChmod))
        #expect(fixture.model.jobs.isEmpty)
    }

    /// Ayarlar › rsync'teki varsayılanlar yeni işlere geçer, kalıcıdır ve sıfırlanır.
    @Test func advancedDefaultsPersistAndReset() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.settings.defaultAdvanced.hardLinks = true
        fixture.settings.defaultAdvanced.excludePatterns = ["*.tmp"]
        let reopened = AppSettings(defaults: fixture.defaults, bundle: resourcesBundle)
        #expect(reopened.defaultAdvanced.hardLinks)
        #expect(reopened.defaultOptions.advanced.excludePatterns == ["*.tmp"])
        #expect(!reopened.defaultOptions.deleteExtraneous)
        reopened.resetAll()
        #expect(reopened.defaultAdvanced.isDefault)
        #expect(!reopened.keepDisplayAwake)
    }

    /// Komut önizlemesi gerçekten çalıştırılacak argümanları, kabuğa uygun tırnaklarla gösterir.
    @Test func commandPreviewShowsTheRealCommand() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        var options = CopyOptions(copyMode: .contents)
        options.advanced.hardLinks = true
        options.advanced.bandwidthLimitKiB = 2048
        let job = TransferJob(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"), options: options)
        let command = fixture.model.commandPreview(for: job)
        #expect(command.hasPrefix("rsync -rltDh8X --info=progress2 -i --partial"))
        #expect(command.contains(" -H "))
        #expect(command.contains("--bwlimit=2048"))
        // Yol, /private önekini atan standart biçimde gösterilir (aynı klasör).
        let source = fixture.url("Kaynak").standardizedFileURL.path, destination = fixture.url("Hedef").standardizedFileURL.path
        #expect(command.hasSuffix(source + "/ " + destination + "/"), "\(command)")
    }

    /// Süre sınırında duran iş duraklatılmış olur ve bildirim gelir.
    @Test func stoppedAtLimitPausesAndNotifies() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.engineProvider = { _ in StoppingEngine() }
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        await model.waitUntilIdle()
        #expect(model.job(id)?.status == .paused)
        #expect(model.job(id)?.result?.kind == .stoppedAtLimit)
        #expect(fixture.notifications.first?.0 == fixture.settings.t(.notifyStoppedTitle))
    }
}

/// Testte iş sürerken değiştirilen güç durumu.
final class PowerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PowerSnapshot
    init(_ value: PowerSnapshot) { stored = value }
    var value: PowerSnapshot {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Hemen süre sınırında duran sahte motor.
struct StoppingEngine: TransferEngine {
    var kind: JobKind { .rsync }
    func run(_ job: TransferJob, context: EngineContext, onEvent: @escaping @Sendable (TransferEvent) -> Void) async -> JobResult {
        onEvent(.phase(.copying))
        return JobResult(kind: .stoppedAtLimit, exitCode: 30)
    }
    func verify(_ job: TransferJob, context: EngineContext, checksum: Bool) async -> VerifyReport {
        VerifyReport(entries: [], result: JobResult(kind: .succeeded), checksum: checksum)
    }
}
