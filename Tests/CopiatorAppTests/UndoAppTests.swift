// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Son çalıştırmayı geri alma uygulamada: onay ne olacağını söyler; eklenen öğeler (ya da son anlık görüntü) Çöp'e
/// gider; çalıştırma geri alındı olarak işaretlenir ve bir daha geri alınamaz. Çalışan, bekleyen ve başarısız işte yoktur.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct UndoAppTests {
    @Test func undoMovesTheAddedFilesAfterConfirmation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        #expect(model.addJob(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"), options: CopyOptions(conflictPolicy: .replace)) == nil)
        let id = try #require(model.jobs.last?.id)
        await model.waitUntilIdle()
        let job = try #require(model.job(id))
        // Kaynak/not.txt, Kaynak/alt/, Kaynak/alt/b.txt ve Kaynak klasörünün kendisi.
        #expect(model.undoPlan(for: job) == .created(count: 4, otherChanges: 0))
        model.requestUndoLastRun(id)
        let alert = try #require(model.alert)
        #expect(alert.message == fixture.settings.t(.undoCreatedMessage, 4, 0) && alert.isDestructive)
        alert.action?()
        #expect(!FileManager.default.fileExists(atPath: fixture.url("Hedef/Kaynak").path))
        #expect(FileManager.default.fileExists(atPath: fixture.url("Kaynak/not.txt").path), "kaynak değişmez")
        let undone = try #require(model.job(id))
        #expect(undone.history.last?.undoneAt != nil)
        #expect(undone.log.contains { $0.key == LKey.logUndoneCreated.rawValue && $0.arguments == ["4", "0"] })
        #expect(model.undoPlan(for: undone) == nil, "bir daha geri alınamaz")
    }

    @Test func snapshotUndoMovesTheNewestSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        #expect(model.addJob(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"),
                             options: CopyOptions(snapshots: SnapshotOptions(enabled: true))) == nil)
        let id = try #require(model.jobs.last?.id)
        await model.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(1_100))
        try fixture.write("Kaynak/yeni.txt", "yeni")
        model.resume([id])
        await model.waitUntilIdle()
        let snapshots = SnapshotStore.completeSnapshots(in: fixture.url("Hedef"))
        try #require(snapshots.count == 2)
        let job = try #require(model.job(id))
        #expect(model.undoPlan(for: job) == .snapshot(snapshots[1]))
        // Son anlık görüntü artık en yeni değilse (ör. elle silindi) geri alma sunulmaz.
        let newest = fixture.url("Hedef/" + snapshots[1])
        let aside = fixture.url("Kenar")
        try FileManager.default.moveItem(at: newest, to: aside)
        #expect(model.undoPlan(for: job) == nil)
        try FileManager.default.moveItem(at: aside, to: newest)
        model.undoLastRun(id)
        #expect(SnapshotStore.completeSnapshots(in: fixture.url("Hedef")) == [snapshots[0]])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.url("Hedef/Latest").path) == snapshots[0])
        #expect(model.undoPlan(for: try #require(model.job(id))) == nil)
    }

    @Test func noUndoForWaitingOrFailedRuns() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.toggleQueueHold()
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        #expect(model.undoPlan(for: try #require(model.job(id))) == nil, "hiç çalışmadı")
        try fixture.write("Okunmaz/a.txt", "a")
        let file = fixture.url("Okunmaz/a.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        try FileManager.default.createDirectory(at: fixture.url("Hedef2"), withIntermediateDirectories: true)
        #expect(model.addJob(source: fixture.url("Okunmaz"), destination: fixture.url("Hedef2"), options: CopyOptions()) == nil)
        let failing = try #require(model.jobs.last?.id)
        model.toggleQueueHold()
        await model.waitUntilIdle()
        let failed = try #require(model.job(failing))
        #expect(failed.result?.kind.isSuccess == false)
        #expect(model.undoPlan(for: failed) == nil)
    }

    /// Başarısız bir çalıştırmanın (bozuk bir kayıtta bile) geri alma kaydı kullanılmaz.
    @Test func failedRunsAreNeverUndone() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var job = TransferJob(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"))
        var result = JobResult(kind: .partial, exitCode: 23)
        result.undo = RunUndo.Record(created: ["Kaynak/not.txt"], truncated: false, otherChanges: 0)
        JobQueue.finish(&job, with: result)
        try fixture.store.save([job])
        let model = fixture.relaunch()
        #expect(model.undoPlan(for: try #require(model.job(job.id))) == nil)
        var succeeded = job
        succeeded.history[succeeded.history.count - 1].result.kind = .succeeded
        succeeded.status = .finished
        #expect(model.undoPlan(for: succeeded) == .created(count: 1, otherChanges: 0), "aynı kayıt başarılı çalıştırmada sunulur")
    }
}

