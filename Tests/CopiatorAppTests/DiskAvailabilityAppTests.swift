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
