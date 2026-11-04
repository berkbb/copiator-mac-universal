// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Pil kritik seviyede: yeni iş başlamaz, çalışan iş duraklar (günlük ve bildirim), adaptör takılınca pil yüzünden
/// duraklayan iş sürer; ayar kapalıyken hiçbiri olmaz. Pil %10'un altındayken ama adaptör takılıyken bekleme yoktur.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct BatteryPauseTests {
    private let critical = PowerSnapshot(source: .battery, hasBattery: true, batteryPercent: 5)
    private let charging = PowerSnapshot(source: .ac, hasBattery: true, batteryPercent: 5, isCharging: true)

    @Test func noJobStartsUntilTheAdapterIsPluggedIn() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let power = PowerBox(critical)
        model.powerProvider = { power.value }
        model.powerCheckInterval = .milliseconds(50)
        #expect(fixture.settings.pauseOnCriticalBattery, "varsayılan açık")
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.job(id)?.status == .waiting && model.batteryHold)
        power.value = charging
        for _ in 0..<100 where model.job(id)?.status != .finished { try await Task.sleep(for: .milliseconds(30)) }
        await model.waitUntilIdle()
        #expect(model.job(id)?.status == .finished && !model.batteryHold)
    }

    @Test func runningJobPausesAndResumesOnPower() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeLargeFile("Kaynak/buyuk.bin", megabytes: 768)
        let model = fixture.model
        let power = PowerBox(charging)
        model.powerProvider = { power.value }
        model.powerCheckInterval = .milliseconds(50)
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        for _ in 0..<200 where model.job(id)?.status != .copying { try await Task.sleep(for: .milliseconds(10)) }
        power.value = critical
        for _ in 0..<200 where model.job(id)?.status != .paused { try await Task.sleep(for: .milliseconds(20)) }
        let paused = try #require(model.job(id))
        #expect(paused.status == .paused && model.batteryHold && model.pausedForBattery == [id])
        #expect(paused.log.contains { $0.key == LKey.logPausedForBattery.rawValue })
        #expect(fixture.notifications.contains { $0.0 == fixture.settings.t(.notifyBatteryPausedTitle) })
        // Adaptör takılınca iş kendiliğinden sürer.
        power.value = charging
        for _ in 0..<200 where model.job(id)?.log.contains(where: { $0.key == LKey.logResumedOnPower.rawValue }) != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.batteryHold && model.pausedForBattery.isEmpty)
        #expect(model.job(id)?.status != .paused)
        model.pause([id])
        await model.waitUntilIdle()
    }

    /// Kullanıcının duraklattığı iş adaptör takılınca kendiliğinden sürmez.
    @Test func onlyJobsPausedForTheBatteryResume() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let power = PowerBox(critical)
        model.powerProvider = { power.value }
        model.powerCheckInterval = .milliseconds(50)
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        model.pause([id])
        try await Task.sleep(for: .milliseconds(200))
        power.value = charging
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.job(id)?.status == .paused)
    }

    @Test func turnedOffNeverHolds() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        fixture.settings.pauseOnCriticalBattery = false
        model.powerProvider = { self.critical }
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        await model.waitUntilIdle()
        #expect(model.job(id)?.status == .finished && !model.batteryHold)
        #expect(!model.batteryIsCritical(charging))
        fixture.settings.pauseOnCriticalBattery = true
        #expect(model.batteryIsCritical(critical) && !model.batteryIsCritical(charging))
        #expect(!model.batteryIsCritical(PowerSnapshot(source: .battery, hasBattery: true, batteryPercent: 10)))
    }
}

/// "Kopyaları Time Machine'e alma": başarılı çalıştırmadan sonra hedefteki kopya işaretlenir (her çalıştırmada yeniden,
/// günlüğe bir kez); seçenek kapalıyken işaretlenmez.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct TimeMachineExclusionAppTests {
    @Test func successfulRunsKeepTheCopyOutOfTimeMachine() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        #expect(model.addJob(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"),
                             options: CopyOptions(conflictPolicy: .replace, excludeFromTimeMachine: true)) == nil)
        let id = try #require(model.jobs.last?.id)
        await model.waitUntilIdle()
        let copy = fixture.url("Hedef/Kaynak")
        #expect(TimeMachineExclusion.isExcluded(copy))
        #expect(!TimeMachineExclusion.isExcluded(fixture.url("Hedef")))
        // İkinci çalıştırma: işaret kalır, günlüğe yeniden yazılmaz.
        model.resume([id])
        await model.waitUntilIdle()
        #expect(TimeMachineExclusion.isExcluded(copy))
        #expect(model.job(id)?.log.filter { $0.key == LKey.logTimeMachineExcluded.rawValue }.count == 1)
    }

    @Test func offLeavesTheCopyAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        fixture.addJob()
        await fixture.model.waitUntilIdle()
        #expect(!TimeMachineExclusion.isExcluded(fixture.url("Hedef/Kaynak")))
    }
}
