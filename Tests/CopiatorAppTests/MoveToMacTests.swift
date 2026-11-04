// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Copiator
@testable import CopiatorCore

/// İşleri ve ayarları başka bir Mac'e taşıma: ayarların taşınabilir kısmı gider (güncelleme izni, kum havuzu, yapay zekâ,
/// özel rsync yolu, bütünlük listesi ve yollar gitmez); rutin işleri dosyaya yazılmaz; içe aktarılan işler duraklatılmış
/// gelir ve çalışmaz, denetimden geçemeyen iş eklenmez; ayarlar yalnızca istenirse uygulanır.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct MoveToMacTests {
    @Test func portableSettingsLeaveMachineAndSecurityChoicesAlone() throws {
        let source = try Fixture()
        defer { source.cleanUp() }
        let s = source.settings
        s.language = .ro
        s.notifyOnFinish = false
        s.backupReminderDays = 14
        s.defaultConflictPolicy = .keepBoth
        s.keepDisplayAwake = true
        s.defaultAdvanced.hardLinks = true
        s.defaultAdvanced.logFile = "/Users/test/rsync.log"
        s.defaultAdvanced.backupDirectory = "/Users/test/Eski"
        s.defaultAdvanced.stopAt = Date()
        s.sandboxEngine = false
        s.checkUpdatesAtLaunch = true
        s.aiSuggestions = true
        s.customEnginePath = "/opt/test/rsync"
        s.integrityOnConnect = ["/Volumes/Yedek"]
        let portable = PortableSettings(s)
        let json = try #require(String(data: JSONEncoder().encode(portable), encoding: .utf8))
        for word in ["sandbox", "checkUpdates", "updateConsent", "aiSuggestions", "customEngine", "integrityOnConnect", "/Users/test", "/opt/test"] {
            #expect(!json.contains(word), "\(word)")
        }
        #expect(portable.defaultAdvanced?.hardLinks == true && portable.defaultAdvanced?.stopAt == nil)

        let target = try Fixture()
        defer { target.cleanUp() }
        let t = target.settings
        let sandbox = t.sandboxEngine, updates = t.checkUpdatesAtLaunch, ai = t.aiSuggestions
        portable.apply(to: t)
        #expect(t.language == .ro && !t.notifyOnFinish && t.backupReminderDays == 14 && t.defaultConflictPolicy == .keepBoth)
        #expect(t.keepDisplayAwake && t.defaultAdvanced.hardLinks && t.defaultAdvanced.logFile == nil && t.defaultAdvanced.backupDirectory == nil)
        #expect(t.sandboxEngine == sandbox && t.checkUpdatesAtLaunch == updates && t.aiSuggestions == ai)
        #expect(t.customEnginePath == target.settings.customEnginePath && t.integrityOnConnect.isEmpty)

        // Tanınmayan değerler (daha yeni bir sürümün dili, listede olmayan gün sayısı) atlanır; dosyadaki yollar da.
        var odd = portable
        odd.language = "xx"
        odd.backupReminderDays = 3
        odd.defaultAdvanced?.logFile = "/Users/test/other.log"
        odd.apply(to: t)
        #expect(t.language == .ro && t.backupReminderDays == 14 && t.defaultAdvanced.logFile == nil)
    }

    @Test func exportLeavesRoutineJobsOutAndImportArrivesPaused() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        model.toggleQueueHold()
        let standalone = try #require(fixture.addJob())
        try FileManager.default.createDirectory(at: fixture.url("Hedef/Rutin"), withIntermediateDirectories: true)
        let routine = Routine(name: "Rutin", routes: [RoutineRoute(source: fixture.url("Kaynak"), destination: fixture.url("Hedef/Rutin"))])
        #expect(model.saveRoutine(routine) == nil)
        _ = model.runRoutine(routine.id)
        #expect(model.jobs.contains { $0.routineID == routine.id })
        fixture.settings.backupReminderDays = 60
        let file = fixture.url("kurulum.json")
        model.exportSetup(to: file)
        #expect(model.alert == nil)

        let other = try Fixture()
        defer { other.cleanUp() }
        let target = other.model
        await target.refreshEngine()
        target.beginSetupImport(from: file)
        let request = try #require(target.setupImport)
        #expect(request.jobs.count == 1, "rutin işi yazılmaz")
        #expect(request.jobs.first?.source == model.job(standalone)?.source)
        #expect(request.settings?.backupReminderDays == 60)

        // Ayarlarsız içe aktarma: ayar değişmez; iş duraklatılmış gelir ve kuyruk beklemiyorken bile çalışmaz.
        #expect(target.importSetup(request.jobs, settings: nil).isEmpty)
        #expect(other.settings.backupReminderDays != 60)
        await target.waitUntilIdle()
        #expect(target.jobs.map(\.status) == [.paused])
        #expect(target.jobs.first?.id != standalone)
        // Ayarlarla: uygulanır.
        _ = target.importSetup([], settings: request.settings)
        #expect(other.settings.backupReminderDays == 60)
    }

    @Test func invalidJobsAreRefusedAndBadFilesExplained() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        // Kaynak hedefin içinde: yeni bir işle aynı denetim reddeder.
        let overlapping = TransferJob(source: fixture.url("Kaynak"), destination: fixture.url("Kaynak/alt"), status: .paused)
        let good = TransferJob(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"), status: .paused)
        let failures = model.importSetup([overlapping, good], settings: nil)
        #expect(failures.keys.sorted { $0.uuidString < $1.uuidString } == [overlapping.id])
        #expect(model.jobs.map(\.id) == [good.id])

        let bad = fixture.url("bozuk.json")
        try Data("{}".utf8).write(to: bad)
        model.beginSetupImport(from: bad)
        #expect(model.setupImport == nil)
        #expect(model.alert?.message == fixture.settings.t(.setupImportInvalid))
        model.alert = nil
        let newer = fixture.url("yeni.json")
        try Data(#"{"format":"copiator-setup","version":99}"#.utf8).write(to: newer)
        model.beginSetupImport(from: newer)
        #expect(model.alert?.message == fixture.settings.t(.setupImportNewer))
        model.alert = nil
        // Ne iş ne ayar taşıyan dosya da geçersizdir.
        let empty = fixture.url("bos.json")
        try SetupTransfer.export(jobs: [], settings: PortableSettings?.none).write(to: empty)
        model.beginSetupImport(from: empty)
        #expect(model.alert?.message == fixture.settings.t(.setupImportInvalid))
    }
}

/// Düşük disk önceliği ayarı işin motor bağlamına geçer ve günlüğe yazılır; kapalıyken yazılmaz.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct LowPriorityAppTests {
    @Test func settingReachesTheJobAndItsLog() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        #expect(!fixture.settings.lowPriorityIO, "varsayılan kapalı")
        await model.refreshEngine()
        let normal = try #require(fixture.addJob())
        await model.waitUntilIdle()
        #expect(model.job(normal)?.log.contains(where: { $0.key == LKey.logLowPriority.rawValue }) == false)
        fixture.settings.lowPriorityIO = true
        #expect(AppSettings(defaults: fixture.defaults, bundle: resourcesBundle).lowPriorityIO, "kalıcı")
        _ = fixture.relaunch()
        await fixture.model.refreshEngine()
        // Ayrı hedef: ilk işin dosyaları aynı adlı dosya sorusu doğurmasın.
        try FileManager.default.createDirectory(at: fixture.url("Hedef2"), withIntermediateDirectories: true)
        #expect(fixture.model.addJob(source: fixture.url("Kaynak"), destination: fixture.url("Hedef2"), options: CopyOptions()) == nil)
        let low = try #require(fixture.model.jobs.last?.id)
        await fixture.model.waitUntilIdle()
        let job = try #require(fixture.model.job(low))
        #expect(job.status == .finished)
        #expect(job.log.contains { $0.key == LKey.logLowPriority.rawValue })
        fixture.settings.resetAll()
        #expect(!fixture.settings.lowPriorityIO)
    }
}
