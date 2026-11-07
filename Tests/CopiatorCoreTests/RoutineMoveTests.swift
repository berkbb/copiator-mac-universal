// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// Çok rotalı rutinde "Taşı": kaynak yalnızca onu seçen bütün rotaların hedefindeki karşılıkları birebir aynıysa Çöp'e
/// gider; bir hedefte farklı ya da eksikse kaynak kalır; boşalan klasörler köke kadar gider, kök kalır.
@Test func sourcesMoveOnlyWhenEveryRouteHasAnIdenticalCopy() throws {
    let w = try Workspace("CopiatorRoutineMove")
    let bin = try w.mkdir(".Trash")
    for (path, text) in [("alt/a.txt", "a"), ("b.txt", "b"), ("c.txt", "c")] { try w.write("Gelen/" + path, text) }
    for (path, text) in [("a.txt", "a"), ("b.txt", "b"), ("c.txt", "c")] { try w.write("H1/" + path, text) }
    for (path, text) in [("a.txt", "a"), ("b.txt", "B değişti")] { try w.write("H2/" + path, text) }
    let root = w.url("Gelen").path
    func move(_ source: String, _ target: String) -> SourceTrash.PendingMove {
        SourceTrash.PendingMove(source: w.url("Gelen/" + source).path, target: w.url(target).path, root: root)
    }
    let moves = [move("alt/a.txt", "H1/a.txt"), move("alt/a.txt", "H2/a.txt"), move("b.txt", "H1/b.txt"), move("b.txt", "H2/b.txt"),
                 move("c.txt", "H1/c.txt"), move("c.txt", "H2/c.txt")]
    let outcome = SourceTrash.moveAcrossRoutes(moves, trash: { url in
        let target = bin.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        return (try? FileManager.default.moveItem(at: url, to: target)) != nil ? target : nil
    })
    #expect(outcome.moved == 1 && outcome.kept == 2 && outcome.folders == 1 && outcome.failed.isEmpty)
    #expect(!w.exists("Gelen/alt") && w.read("Gelen/b.txt") == "b" && w.read("Gelen/c.txt") == "c" && w.exists("Gelen"))
    #expect(outcome.located.filter { $0.target != nil }.map(\.original) == [w.url("Gelen/alt/a.txt").path])

    // Kayıt: yollar çözülür; sınırı aşan kayıt hiç tutulmaz.
    let pair = SourceTrash.Pair(source: w.url("Gelen/b.txt"), target: w.url("H1/b.txt"))
    #expect(SourceTrash.pendingMoves([pair], root: w.url("Gelen")) == [SourceTrash.PendingMove(source: w.url("Gelen/b.txt").path,
                                                                                                target: w.url("H1/b.txt").path, root: root)])
    #expect(SourceTrash.pendingMoves(Array(repeating: pair, count: RunUndo.maxRecordedItems + 1), root: w.url("Gelen")) == nil)
}

/// Rota işi taşımayı ertelediğinde kaynak yerinde kalır, karşılıklar kaydedilir; kayıt yalnızca son çalıştırmada tutulur.
@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct LiveRoutineMoveTests {
    @Test func deferredRouteKeepsSourcesAndRecordsPairs() async throws {
        let w = try Workspace("CopiatorRoutineMove")
        var context = try await engineContext()
        context.scratchDirectory = try w.mkdir("Gecici")
        context.trashItem = { _ in Issue.record("ertelenen rota kaynağı taşımamalı"); return nil }
        try w.write("Gelen/a.txt", "a")
        try w.write("Gelen/alt/b.txt", "b")
        try w.mkdir("Hedef")
        var job = TransferJob(source: w.url("Gelen"), destination: w.url("Hedef"),
                              options: CopyOptions(copyMode: .contents, conflictPolicy: .replace, trashSourceAfterCopy: true))
        job.moveGroup = UUID()
        let result = await RsyncEngine().run(job, context: context) { _ in }
        #expect(result.kind.isSuccess, "\(result)")
        #expect(Set(result.pendingMoves?.map(\.source) ?? []) == [w.url("Gelen/a.txt").path, w.url("Gelen/alt/b.txt").path])
        #expect(w.read("Gelen/a.txt") == "a" && w.read("Hedef/alt/b.txt") == "b")
        JobQueue.finish(&job, with: result)
        JobQueue.finish(&job, with: JobResult(kind: .succeeded))
        #expect(job.history.allSatisfy { $0.result.pendingMoves == nil })
        let saved = try JSONDecoder().decode(JobResult.self, from: JSONEncoder().encode(result))
        #expect(saved.pendingMoves == result.pendingMoves)
    }
}

/// Geri alma: kaynak başka bir rotanın geri alınmasıyla zaten yerine döndüyse (ve kopyayla aynıysa) bu rotanın kopyası
/// korunmaz; yerindeki dosya farklıysa korunur.
@Test func undoTrashesACopyWhenTheSourceIsAlreadyBack() throws {
    let w = try Workspace("CopiatorRoutineMove")
    try w.write("Gelen/a.txt", "a")
    try w.write("Gelen/b.txt", "yeni b")
    try w.write("H2/a.txt", "a")
    try w.write("H2/b.txt", "eski b")
    try w.mkdir(".Trash")
    let moved = [
        RunUndo.MovedSource(original: w.url("Gelen/a.txt").path, trashed: w.url(".Trash/a.txt").path, target: w.url("H2/a.txt").path),
        RunUndo.MovedSource(original: w.url("Gelen/b.txt").path, trashed: w.url(".Trash/b.txt").path, target: w.url("H2/b.txt").path),
    ]
    let outcome = RunUndo.restoreSources(moved, source: w.url("Gelen"))
    #expect(outcome.keepTargets == [RunUndo.key(w.url("H2/b.txt").path)], "aynı olan kopya korunmaz, farklı olan korunur")
}
