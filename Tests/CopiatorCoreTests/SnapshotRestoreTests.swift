// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

/// Anlık görüntülerden geri yükleme, gerçek rsync ile: iki anlık görüntü (arada bir dosya değişir), en yeni önce listelenir;
/// klasörler önce gelir; değişen dosyanın iki, değişmeyenin (sabit bağlantılı) tek sürümü vardır. Silinen dosya ve klasör eski
/// içerikleriyle asıl yerlerine geri gelir; aynı adlı dosya varsa geri yükleme sorar; anlık görüntü hiç değişmez.
@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct SnapshotRestoreTests {
    private func run(_ job: inout TransferJob, _ context: EngineContext) async -> JobResult {
        let events = Collected<TransferEvent>()
        let result = await RsyncEngine().run(job, context: context) { events.add($0) }
        for event in events.values { JobQueue.apply(event, to: &job) }
        JobQueue.finish(&job, with: result)
        return result
    }

    @Test func browseVersionsAndRestore() async throws {
        let w = try Workspace("CopiatorRestore")
        var context = try await engineContext()
        context.scratchDirectory = try w.mkdir("Gecici")
        try w.write("Belgeler/rapor.txt", "ilk sürüm")
        try w.write("Belgeler/Tatil/foto.jpg", "foto")
        try w.mkdir("Yedekler")
        var job = TransferJob(source: w.url("Belgeler"), destination: w.url("Yedekler"),
                              options: CopyOptions(snapshots: SnapshotOptions(enabled: true)))
        #expect(await run(&job, context).kind.isSuccess)
        try await Task.sleep(for: .milliseconds(1_100))
        try w.write("Belgeler/rapor.txt", "ikinci sürüm, daha uzun")
        JobQueue.requeue(&job)
        #expect(await run(&job, context).kind.isSuccess)

        let snapshots = SnapshotRestore.snapshots(of: job)
        #expect(snapshots.count == 2 && snapshots[0].date > snapshots[1].date)
        let root = SnapshotRestore.contentRoot(of: snapshots[0], job: job)
        #expect(root.lastPathComponent == "Belgeler")
        #expect(SnapshotRestore.items(in: root, at: "").map(\.name) == ["Tatil", "rapor.txt"])
        #expect(SnapshotRestore.items(in: root, at: "Tatil").map(\.relativePath) == ["Tatil/foto.jpg"])
        let versions = SnapshotRestore.versions(of: "rapor.txt", job: job)
        #expect(versions.map(\.snapshot.name) == [snapshots[0].name, snapshots[1].name] && versions.map(\.size) == [Int64("ikinci sürüm, daha uzun".utf8.count), Int64("ilk sürüm".utf8.count)])
        #expect(SnapshotRestore.versions(of: "Tatil/foto.jpg", job: job).map(\.snapshot.name) == [snapshots[1].name])
        #expect(SnapshotRestore.originalFolder(of: "Tatil/foto.jpg", job: job) == w.url("Belgeler/Tatil"))
        #expect(SnapshotRestore.originalFolder(of: "", job: job) == w.url(""))

        // Silinen dosyanın eski sürümü ve silinen klasör asıl yerlerine geri gelir.
        try FileManager.default.removeItem(at: w.url("Belgeler/rapor.txt"))
        try FileManager.default.removeItem(at: w.url("Belgeler/Tatil"))
        var restore = SnapshotRestore.restoreJob("rapor.txt", from: snapshots[1], of: job,
                                                 to: SnapshotRestore.originalFolder(of: "rapor.txt", job: job))
        #expect(await run(&restore, context).kind.isSuccess, "\(restore.log.suffix(4))")
        #expect(w.read("Belgeler/rapor.txt") == "ilk sürüm")
        try FileManager.default.createDirectory(at: SnapshotRestore.originalFolder(of: "Tatil", job: job), withIntermediateDirectories: true)
        var folder = SnapshotRestore.restoreJob("Tatil", from: snapshots[0], of: job, to: SnapshotRestore.originalFolder(of: "Tatil", job: job))
        #expect(await run(&folder, context).kind.isSuccess)
        #expect(w.read("Belgeler/Tatil/foto.jpg") == "foto")

        // Aynı adlı dosya varsa sorulur; anlık görüntü değişmez.
        var again = SnapshotRestore.restoreJob("rapor.txt", from: snapshots[0], of: job, to: w.url("Belgeler"))
        #expect(await run(&again, context).kind == .awaitingDecision)
        #expect(again.pendingConflicts?.items.map(\.path) == ["rapor.txt"] && w.read("Belgeler/rapor.txt") == "ilk sürüm")
        #expect(w.read("Yedekler/\(snapshots[1].name)/Belgeler/rapor.txt") == "ilk sürüm")

        // Kaynağın tamamı başka bir klasöre ("klasörün kendisi" kipinde klasör adıyla).
        try w.mkdir("Baska")
        var whole = SnapshotRestore.restoreJob("", from: snapshots[0], of: job, to: w.url("Baska"))
        #expect(await run(&whole, context).kind.isSuccess)
        #expect(w.read("Baska/Belgeler/rapor.txt") == "ikinci sürüm, daha uzun" && w.read("Baska/Belgeler/Tatil/foto.jpg") == "foto")
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.url("Gecici").path).isEmpty)
    }
}
