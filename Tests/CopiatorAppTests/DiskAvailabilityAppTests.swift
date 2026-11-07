// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Takılı olmayan disk uygulamada: iş ve rutin kaydedilir; iki hedefli rutinde takılı hedefe giden rota çalışır, takılı
/// olmayan diskteki rota hata vermeden bekler; içe aktarma engellenmez. Bu Mac'te olmayan hedef klasör istenince oluşturulur;
/// takılı olmayan diskte klasör oluşturulmaz.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct DiskAvailabilityAppTests {
    private let away = URL(fileURLWithPath: "/Volumes/CopiatorYok-\(UUID().uuidString)/Ev/Fatura")

    @Test func unpluggedDiskWaitsWhileTheOtherRouteRuns() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()

        // Tek iş: eklenir, hata vermez, disk bekler.
        #expect(model.addJob(source: fixture.url("Kaynak"), destination: away, options: CopyOptions()) == nil)
        let jobID = try #require(model.jobs.last?.id)
        await model.waitUntilIdle()
        let job = try #require(model.job(jobID))
        #expect(job.status == .waiting && model.isWaitingForDisk(job) && job.history.isEmpty)

        // İki hedefli rutin ("disk takılınca başla" kapalı): kaydedilir; bu Mac'teki hedef kopyalanır, öteki bekler.
        let routine = Routine(name: "Faturalar", routes: [RoutineRoute(source: fixture.url("Kaynak"), destination: fixture.url("Hedef")),
                                                          RoutineRoute(source: fixture.url("Kaynak"), destination: away)],
                              options: CopyOptions(conflictPolicy: .skip))
        #expect(model.saveRoutine(routine) == nil)
        #expect(model.runRoutine(routine.id) == nil)
        await model.waitUntilIdle()
        let routeJobs = model.jobs(for: routine.id)
        #expect(routeJobs.count == 2)
        #expect(routeJobs.first { $0.destination == fixture.url("Hedef") }?.status == .finished)
        #expect(fixture.read("Hedef/not.txt") == "merhaba\n")
        let waiting = try #require(routeJobs.first { $0.destination == away })
        #expect(waiting.status == .waiting && model.isWaitingForDisk(waiting) && waiting.result == nil, "hata vermez, bekler")

        // İçe aktarma: takılı olmayan diskteki rota aktarılır.
        var imported = routine
        imported.id = UUID()
        imported.name = "Aktarılan"
        #expect(model.importRoutines([imported]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: away.deletingLastPathComponent().deletingLastPathComponent().path))
    }

    /// Rutine gönderilen öğeler ("Copiator Rutinine Gönder"): takılı diskteki rota kopyalar, takılı olmayan diskteki rota
    /// reddedilmez, diskini bekler. Mac'te olmayan hedef klasör ise sorun kalır; hiç iş eklenmez.
    @Test func sentItemsWaitForAnUnpluggedDisk() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        let routine = Routine(name: "Gönderilen", routes: [RoutineRoute(source: fixture.url("Kaynak"), destination: fixture.url("Hedef")),
                                                            RoutineRoute(source: fixture.url("Kaynak"), destination: away)],
                              options: CopyOptions(conflictPolicy: .skip))
        #expect(model.saveRoutine(routine) == nil)
        #expect(model.runRoutine(routine.id, on: [fixture.url("Kaynak/not.txt")]) == nil, "takılı olmayan disk göndermeyi engellemez")
        await model.waitUntilIdle()
        let sent = model.jobs(for: routine.id)
        #expect(sent.count == 2 && sent.allSatisfy { $0.options.selectedItems == ["not.txt"] && !$0.options.runWhenConnected })
        #expect(sent.first { $0.destination == fixture.url("Hedef") }?.status == .finished)
        #expect(fixture.read("Hedef/not.txt") == "merhaba\n")
        let waiting = try #require(sent.first { $0.destination == away })
        #expect(waiting.status == .waiting && model.isWaitingForDisk(waiting) && waiting.result == nil, "hata vermez, bekler")

        // Bu Mac'te olmayan hedef klasör: gönderme reddedilir, hiçbir rota için iş eklenmez.
        let archive = fixture.url("Arsiv")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let local = Routine(name: "Klasörü silinen", routes: [RoutineRoute(source: fixture.url("Kaynak"), destination: fixture.url("Hedef")),
                                                               RoutineRoute(source: fixture.url("Kaynak"), destination: archive)],
                            options: CopyOptions(conflictPolicy: .skip))
        #expect(model.saveRoutine(local) == nil)
        try FileManager.default.removeItem(at: archive)
        #expect(model.runRoutine(local.id, on: [fixture.url("Kaynak/not.txt")]) != nil)
        #expect(model.jobs(for: local.id).isEmpty)
        model.alert = nil
    }

    /// "Taşı" seçili iki hedefli rutin: kaynak ancak iki rota da kopyalayınca Çöp'e gider (iki hedefte de kopya var); geri
    /// alma iki rotada da çalışır. Bir rotanın diski takılı değilse kaynak yerinde kalır.
    @Test func moveWaitsForEveryRoute() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        try FileManager.default.createDirectory(at: fixture.url("Hedef2"), withIntermediateDirectories: true)
        var options = CopyOptions(conflictPolicy: .replace, trashSourceAfterCopy: true)
        options.verifyAfterCopy = .quick
        let both = Routine(name: "İki hedef", routes: [RoutineRoute(source: fixture.url("Kaynak"), destination: fixture.url("Hedef")),
                                                        RoutineRoute(source: fixture.url("Kaynak"), destination: fixture.url("Hedef2"))],
                           options: options)
        #expect(model.saveRoutine(both) == nil)
        #expect(model.runRoutine(both.id) == nil)
        await model.waitUntilIdle()
        // Taşıma arka planda yapılır: kaynak gidene kadar kısa bir süre beklenir.
        for _ in 0..<50 where FileManager.default.fileExists(atPath: fixture.url("Kaynak/not.txt").path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.url("Kaynak/not.txt").path), "iki rota da kopyaladı, kaynak Çöp'te")
        #expect(fixture.read("Hedef/not.txt") == "merhaba\n" && fixture.read("Hedef2/not.txt") == "merhaba\n", "iki hedefte de kopya var")
        let routeJobs = model.jobs(for: both.id)
        #expect(routeJobs.allSatisfy { $0.log.contains { $0.key == LKey.logRoutineSourcesTrashed.rawValue } })
        let first = try #require(routeJobs.first { $0.destination == fixture.url("Hedef") })
        guard case .moved = model.undoPlan(for: first) else { Issue.record("taşıma geri alınabilmeli: \(String(describing: model.undoPlan(for: first)))"); return }
        model.undoLastRun(first.id)
        #expect(fixture.read("Kaynak/not.txt") == "merhaba\n" && !FileManager.default.fileExists(atPath: fixture.url("Hedef/not.txt").path))
        let second = try #require(model.job(routeJobs.first { $0.destination == fixture.url("Hedef2") }!.id))
        model.undoLastRun(second.id)
        #expect(!FileManager.default.fileExists(atPath: fixture.url("Hedef2/not.txt").path), "kaynak zaten yerinde: kopya da geri alınır")
        #expect(fixture.read("Kaynak/not.txt") == "merhaba\n")

        // Bir rotanın diski takılı değil: o rota bekler, kaynak yerinde kalır.
        let partial = Routine(name: "Biri takılı değil", routes: [RoutineRoute(source: fixture.url("Kaynak"), destination: fixture.url("Hedef")),
                                                                  RoutineRoute(source: fixture.url("Kaynak"), destination: away)],
                              options: options)
        #expect(model.saveRoutine(partial) == nil)
        #expect(model.runRoutine(partial.id) == nil)
        await model.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(500))
        #expect(fixture.read("Kaynak/not.txt") == "merhaba\n", "bir rota diskini beklerken kaynak taşınmaz")
        #expect(fixture.read("Hedef/not.txt") == "merhaba\n")
        #expect(model.jobs(for: partial.id).contains { $0.destination == away && model.isWaitingForDisk($0) })
    }

    @Test func missingLocalFolderIsCreatedOnRequestOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let missing = fixture.url("Arsiv/Faturalar")
        #expect(model.addJob(source: fixture.url("Kaynak"), destination: missing, options: CopyOptions()) != nil, "olmayan klasör sorun kalır")
        #expect(AppModel.isCreatableDestination(missing) && !AppModel.isCreatableDestination(away) && !AppModel.isCreatableDestination(fixture.url("Hedef")))
        #expect(model.createDestinationFolder(missing) == nil && FileManager.default.fileExists(atPath: missing.path))
        #expect(model.addJob(source: fixture.url("Kaynak"), destination: missing, options: CopyOptions()) == nil)
        // Takılı olmayan diskte klasör oluşturulmaz (/Volumes altında boş bir klasör diski taklit ederdi).
        #expect(model.createDestinationFolder(away) != nil && !FileManager.default.fileExists(atPath: away.path))
    }
}
