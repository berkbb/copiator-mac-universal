// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Copiator
@testable import CopiatorCore

/// "Kuyruk bitince Mac'i uyut": kuyruk bitince iptal edilebilir geri sayım başlar ve sonunda Mac uyutulur (testlerde sahte
/// uyutma: bu Mac uyutulmaz); seçim tek seferliktir. Karar ya da sıra bekleyen iş varken başlamaz; yeni iş geri sayımı
/// durdurur ama seçimi kapatmaz.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct SleepWhenDoneTests {
    private final class SleepCounter {
        var count = 0
    }

    private func prepare(_ fixture: Fixture, counter: SleepCounter) {
        let model = fixture.model
        model.sleeper = { counter.count += 1; return true }
        model.sleepCountdownSeconds = 2
        model.sleepTick = .milliseconds(50)
        model.isMainWindowVisible = { true }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func sleepsOnceAfterTheQueueFinishes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let counter = SleepCounter()
        prepare(fixture, counter: counter)
        let model = fixture.model
        await model.refreshEngine()
        model.sleepWhenQueueFinishes = true
        fixture.addJob()
        await model.waitUntilIdle()
        #expect(model.sleepCountdown != nil)
        try await waitFor { counter.count > 0 }
        #expect(counter.count == 1 && !model.sleepWhenQueueFinishes && model.sleepCountdown == nil)
        // Tek seferlik: sonraki kuyruk Mac'i uyutmaz.
        try fixture.write("Kaynak/yeni.txt", "yeni")
        try FileManager.default.createDirectory(at: fixture.url("Hedef2"), withIntermediateDirectories: true)
        #expect(model.addJob(source: fixture.url("Kaynak"), destination: fixture.url("Hedef2"), options: CopyOptions()) == nil)
        await model.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.count == 1 && model.sleepCountdown == nil)
    }

    @Test func cancellingStopsTheCountdown() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let counter = SleepCounter()
        prepare(fixture, counter: counter)
        fixture.model.isMainWindowVisible = { false }
        let model = fixture.model
        await model.refreshEngine()
        model.sleepWhenQueueFinishes = true
        fixture.addJob()
        await model.waitUntilIdle()
        #expect(model.sleepCountdown == 2)
        #expect(fixture.notifications.contains { $0.0 == fixture.settings.t(.notifySleepTitle) }, "pencere görünmüyorsa bildirilir")
        model.sleepWhenQueueFinishes = false
        #expect(model.sleepCountdown == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.count == 0)
    }

    /// Sıra bekleyen ya da karar bekleyen iş varken kuyruk bitmiş sayılmaz.
    @Test func waitingOrUndecidedJobsKeepTheMacAwake() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let counter = SleepCounter()
        prepare(fixture, counter: counter)
        let model = fixture.model
        await model.refreshEngine()
        // Karar bekleyen iş: hedefte aynı adlı dosya var, politika "sor".
        try fixture.write("Hedef/Kaynak/not.txt", "başka")
        model.sleepWhenQueueFinishes = true
        fixture.addJob()
        await model.waitUntilIdle()
        #expect(model.jobs.last?.isAwaitingDecision == true)
        #expect(!model.queueIsFinished && model.sleepCountdown == nil)
        // Sıra bekleyen iş (kuyruk bekletiliyor).
        let other = try Fixture()
        defer { other.cleanUp() }
        prepare(other, counter: counter)
        other.model.toggleQueueHold()
        await other.model.refreshEngine()
        other.model.sleepWhenQueueFinishes = true
        other.addJob()
        other.model.considerSleepAfterQueue()
        #expect(!other.model.queueIsFinished && other.model.sleepCountdown == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.count == 0)
    }

    /// Geri sayım sırasında yeni iş başlarsa sayım durur, seçim kalır; o iş bitince sayım yeniden başlar.
    @Test func newWorkPausesTheCountdown() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let counter = SleepCounter()
        prepare(fixture, counter: counter)
        let model = fixture.model
        model.sleepCountdownSeconds = 100
        await model.refreshEngine()
        model.sleepWhenQueueFinishes = true
        fixture.addJob()
        await model.waitUntilIdle()
        #expect(model.sleepCountdown != nil)
        try fixture.writeLargeFile("Kaynak2/buyuk.bin", megabytes: 32)
        var options = CopyOptions()
        options.advanced.bandwidthLimitKiB = 20_000
        #expect(model.addJob(source: fixture.url("Kaynak2"), destination: fixture.url("Hedef"), options: options) == nil)
        try await waitFor { model.sleepCountdown == nil }
        #expect(model.sleepCountdown == nil && model.sleepWhenQueueFinishes)
        await model.waitUntilIdle()
        #expect(model.sleepCountdown != nil, "kuyruk yeniden bitti")
        model.sleepNow()
        #expect(counter.count == 1 && !model.sleepWhenQueueFinishes)
    }
}
