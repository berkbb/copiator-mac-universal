// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

private func setModified(_ url: URL, _ seconds: TimeInterval) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
}

/// İki klasörün planı: yalnızca bir yanda olanlar öbür yana, iki yanda aynı olanlar atlanır (harf farkı ve yalnızca zamanı
/// farklı ama içeriği aynı olanlar dahil), içeriği farklı olanlar karara kalır.
@Test func syncPlanFindsMissingSameAndDifferentFiles() async throws {
    let w = try Workspace()
    try w.write("A/yalniz-a.txt", "a")
    try w.write("A/ayni.txt", "aynı")
    try w.write("A/Rapor.TXT", "rapor")
    try w.write("A/farkli.txt", "A'daki")
    try w.write("A/zaman.txt", "aynı içerik")
    try w.write("B/ayni.txt", "aynı")
    try w.write("B/rapor.txt", "rapor")
    try w.write("B/farkli.txt", "B'deki, daha uzun")
    try w.write("B/zaman.txt", "aynı içerik")
    try w.write("B/yalniz-b.txt", "b")
    try w.write("B/alt/c.txt", "c")
    try setModified(w.url("A/zaman.txt"), 1_700_000_000)
    try setModified(w.url("B/zaman.txt"), 1_700_100_000)
    for name in ["ayni.txt", "Rapor.TXT"] { try setModified(w.url("A/" + name), 1_700_000_000) }
    for name in ["ayni.txt", "rapor.txt"] { try setModified(w.url("B/" + name), 1_700_000_000) }
    let job = TransferJob(kind: .sync, source: w.url("A"), destination: w.url("B"))
    let plan = try await SyncPlanner.plan(job, context: try await engineContext())
    #expect(plan.toB == ["yalniz-a.txt"])
    #expect(plan.toA == ["alt/c.txt", "yalniz-b.txt"])
    #expect(plan.differences.map(\.pathA) == ["farkli.txt"])
    #expect(plan.same == 3)
}

/// "Yenisi kazansın": yeni olan yazılır, zamanlar eşitse atlanır; eşitlemede "ikisini de sakla" yoktur (atlanır).
@Test func syncDecisionsFollowThePolicy() {
    let newerA = SyncPlan.Difference(pathA: "x", pathB: "x", modifiedA: Date(timeIntervalSince1970: 200), modifiedB: Date(timeIntervalSince1970: 100))
    let newerB = SyncPlan.Difference(pathA: "x", pathB: "x", modifiedA: Date(timeIntervalSince1970: 100), modifiedB: Date(timeIntervalSince1970: 200))
    let equal = SyncPlan.Difference(pathA: "x", pathB: "x", modifiedA: Date(timeIntervalSince1970: 100), modifiedB: Date(timeIntervalSince1970: 100.5))
    #expect(SyncEngine.decision(.newer, newerA) == .replace)
    #expect(SyncEngine.decision(.newer, newerB) == .reverse)
    #expect(SyncEngine.decision(.newer, equal) == .skip)
    #expect(SyncEngine.decision(.keepBoth, newerA) == .skip)
    #expect(SyncEngine.decision(.ask, newerA) == nil && SyncEngine.decision(.reverse, newerA) == .reverse)
    #expect(ConflictPolicy.choices(for: .sync) == [.ask, .newer, .replace, .reverse, .skip])
    #expect(ConflictPolicy.choices(for: .rsync) == [.ask, .replace, .keepBoth, .skip])
    #expect(ConflictDecision.choices(for: .sync) == [.replace, .reverse, .skip])
    // Bir yönün rsync işi hiçbir zaman silmez ve aynı adlı dosya denetimi yapmaz.
    let part = SyncEngine.partOptions(CopyOptions(deleteExtraneous: true, snapshots: SnapshotOptions(enabled: true), trashSourceAfterCopy: true),
                                      list: "/tmp/liste", zeroTerminated: true)
    #expect(!part.deleteExtraneous && !part.snapshots.enabled && !part.trashSourceAfterCopy && part.conflictPolicy == .replace)
    let arguments = RsyncCommand.transfer(TransferJob(source: URL(fileURLWithPath: "/a"), destination: URL(fileURLWithPath: "/b"), options: part),
                                          environment: RsyncCommand.Environment(engine: fullEngine, destinationFileSystem: .apfs, sourceIsDirectory: true))
    #expect(!arguments.contains { $0.hasPrefix("--delete") } && arguments.contains("--files-from=/tmp/liste"))
}

/// Eşitleme rutini: yerleşim, anlık görüntü ve "taşı" kullanılmaz, iş türü eşitlemedir; kopyalama rutininde eşitlemeye
/// özgü kurallar "sor"a döner. Eski rutinler kopyalama rutinidir.
@Test func syncRoutineOptions() throws {
    var routine = Routine(name: "Eşitle", kind: .sync, routes: [RoutineRoute(placement: RoutePlacement(folderTemplate: "{year}"))],
                          options: CopyOptions(snapshots: SnapshotOptions(enabled: true), conflictPolicy: .keepBoth, trashSourceAfterCopy: true))
    let options = routine.jobOptions(for: routine.routes[0])
    #expect(routine.jobKind == .sync && options.placement == nil && !options.snapshots.enabled && !options.trashSourceAfterCopy)
    #expect(options.conflictPolicy == .ask)
    routine.kind = .copy
    routine.options.conflictPolicy = .newer
    #expect(routine.jobOptions(for: routine.routes[0]).conflictPolicy == .ask && routine.jobKind == .rsync)
    let legacy = try JSONDecoder().decode(Routine.self, from: Data(#"{"id": "8B0F5C9E-3E1B-4D57-9D44-2D1D7C1D2A41", "name": "Eski"}"#.utf8))
    #expect(legacy.kind == .copy)
    #expect(try JSONDecoder().decode(Routine.self, from: JSONEncoder().encode(Routine(name: "S", kind: .sync))).kind == .sync)
}

/// Gerçek rsync ile iki yönlü eşitleme: önce sorar ve hiçbir şey kopyalamaz; kararla eksikler iki yöne kopyalanır, farklı
/// dosya kararla yazılır, hiçbir şey silinmez; ikinci çalıştırmada yapılacak bir şey kalmaz. Kurallar iki yana uygulanır.
@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct LiveSyncTests {
    private func run(_ job: inout TransferJob, _ context: EngineContext) async -> (JobResult, [JobLogEntry]) {
        let events = Collected<TransferEvent>()
        let result = await SyncEngine().run(job, context: context) { events.add($0) }
        for event in events.values { JobQueue.apply(event, to: &job) }
        return (result, events.values.flatMap { event -> [JobLogEntry] in
            switch event {
            case .log(let entry): [entry]
            case .logBatch(let entries): entries
            default: []
            }
        })
    }

    @Test func twoWaySyncAsksCopiesBothWaysAndNeverDeletes() async throws {
        let w = try Workspace("CopiatorSync")
        var context = try await engineContext()
        context.scratchDirectory = try w.mkdir("Gecici")
        try w.write("Ozel/fatura.pdf", "A'daki fatura")
        try w.write("Ozel/ortak.txt", "A sürümü")
        try w.write("Ozel(MacBook)/not.txt", "B'deki not")
        try w.write("Ozel(MacBook)/alt/foto.jpg", "foto")
        try w.write("Ozel(MacBook)/ortak.txt", "B sürümü, daha uzun")
        var job = TransferJob(kind: .sync, source: w.url("Ozel"), destination: w.url("Ozel(MacBook)"))

        #expect(await run(&job, context).0.kind == .awaitingDecision)
        #expect(job.pendingConflicts?.items.map(\.path) == ["ortak.txt"])
        #expect(!w.exists("Ozel(MacBook)/fatura.pdf") && !w.exists("Ozel/not.txt"))

        job.conflictResolution = ConflictResolution(decisions: ["ortak.txt": .reverse])
        let (result, log) = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result)")
        #expect(w.read("Ozel(MacBook)/fatura.pdf") == "A'daki fatura")
        #expect(w.read("Ozel/not.txt") == "B'deki not" && w.read("Ozel/alt/foto.jpg") == "foto")
        #expect(w.read("Ozel/ortak.txt") == "B sürümü, daha uzun" && w.read("Ozel(MacBook)/ortak.txt") == "B sürümü, daha uzun")
        #expect(log.contains { $0.key == LKey.logSyncDone.rawValue && $0.arguments == ["1", "3", "0"] })
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.url("Gecici").path).isEmpty)

        // Bir yanda silinen dosya öbür yandan geri gelir (silme yok); ikinci eşitlemede başka bir şey yapılmaz.
        try FileManager.default.removeItem(at: w.url("Ozel/fatura.pdf"))
        job.conflictResolution = nil
        let (again, againLog) = await run(&job, context)
        #expect(again.kind == .succeeded)
        #expect(w.read("Ozel/fatura.pdf") == "A'daki fatura")
        #expect(againLog.contains { $0.key == LKey.logSyncPlanned.rawValue && $0.arguments == ["0", "1", "0"] })
    }

    /// İki yanda farklı bir paket (.app) A'dan B'ye yazılır: paketin B'deki fazla dosyası silinmez.
    @Test func packagesAreCopiedWithoutDeletingInside() async throws {
        let w = try Workspace("CopiatorSync")
        var context = try await engineContext()
        context.scratchDirectory = try w.mkdir("Gecici")
        try w.write("A/Proje.app/Contents/ikili", "A sürümü")
        try w.write("B/Proje.app/Contents/ikili", "B")
        try w.write("B/Proje.app/Contents/fazla", "B'de fazla")
        var job = TransferJob(kind: .sync, source: w.url("A"), destination: w.url("B"), options: CopyOptions(conflictPolicy: .replace))
        #expect(await run(&job, context).0.kind == .succeeded)
        #expect(w.read("B/Proje.app/Contents/ikili") == "A sürümü")
        #expect(w.read("B/Proje.app/Contents/fazla") == "B'de fazla")
    }

    @Test func newerWinsRulesFilterAndPreviewWritesNothing() async throws {
        let w = try Workspace("CopiatorSync")
        var context = try await engineContext()
        context.scratchDirectory = try w.mkdir("Gecici")
        try w.write("A/eski.txt", "A eski")
        try w.write("B/eski.txt", "B yeni sürüm")
        try setModified(w.url("A/eski.txt"), 1_700_000_000)
        try setModified(w.url("B/eski.txt"), 1_700_500_000)
        try w.write("A/resim.jpg", "jpg")
        try w.write("B/belge.txt", "belge")
        let rules = RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "txt")])
        var job = TransferJob(kind: .sync, source: w.url("A"), destination: w.url("B"),
                              options: CopyOptions(rules: rules, conflictPolicy: .newer))

        let preview = await SyncEngine().verify(job, context: context, checksum: false)
        #expect(preview.result.kind.isSuccess)
        #expect(preview.count(.extra) == 1 && preview.count(.changed) == 1 && preview.count(.missing) == 0)
        #expect(!w.exists("A/belge.txt"))

        #expect(await run(&job, context).0.kind == .succeeded)
        #expect(w.read("A/eski.txt") == "B yeni sürüm" && w.read("A/belge.txt") == "belge")
        #expect(!w.exists("B/resim.jpg"))

        let missing = TransferJob(kind: .sync, source: w.url("A"), destination: w.url("Yok"))
        #expect(await SyncEngine().run(missing, context: context) { _ in }.kind == .destinationMissing)
    }
}
