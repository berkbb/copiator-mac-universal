// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// Testlerin "Çöp Sepeti": öğeler sistemin Çöp Sepeti yerine testin klasörüne taşınır.
private func trash(into folder: URL) -> @Sendable (URL) -> Bool {
    { url in
        let target = folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        return (try? FileManager.default.moveItem(at: url, to: target)) != nil
    }
}

private func trashed(_ folder: URL) -> Set<String> {
    Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { String($0.dropFirst(37)) })
}

/// Eşleşmeler: kurulsuz klasör işinde hedef/Ad/…; sistem klasörleri ve korunan yollar atlanır; tek dosya işi.
@Test func trashPairsFollowTheCopyLayout() throws {
    let w = try Workspace()
    try w.write("Kaynak/a.txt", "a")
    try w.write("Kaynak/alt/b.txt", "b")
    try w.write("Kaynak/.Trashes/x", "x")
    try w.write("Kaynak/.ssh/id", "gizli")
    let folder = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"))
    let pairs = SourceTrash.pairs(for: folder, selection: nil, skippedNames: [".Trashes"], skippedPaths: [".ssh"])
    #expect(Set(pairs.map { $0.target.path }) == [w.url("Hedef/Kaynak/a.txt").path, w.url("Hedef/Kaynak/alt/b.txt").path])
    var contents = folder
    contents.options.copyMode = .contents
    #expect(Set(SourceTrash.pairs(for: contents, selection: nil, skippedNames: [".Trashes"], skippedPaths: [".ssh"]).map(\.target.path))
        == [w.url("Hedef/a.txt").path, w.url("Hedef/alt/b.txt").path])
    let single = TransferJob(source: w.url("Kaynak/a.txt"), destination: w.url("Hedef"))
    #expect(SourceTrash.pairs(for: single, selection: nil, skippedNames: [], skippedPaths: [])
        == [SourceTrash.Pair(source: w.url("Kaynak/a.txt"), target: w.url("Hedef/a.txt"))])
    // Kural seçimi: hedefteki yerleşim yollarıyla.
    let selected = SourceTrash.pairs(for: contents, selection: (w.url("Kaynak"), ["alt/b.txt"], ["2026/b-yeni.txt"]), skippedNames: [], skippedPaths: [])
    #expect(selected == [SourceTrash.Pair(source: w.url("Kaynak/alt/b.txt"), target: w.url("Hedef/2026/b-yeni.txt"))])
}

/// Yalnızca hedefteki karşılığıyla içeriği birebir aynı olanlar taşınır; farklı, eksik ya da bağlantı olanlar kalır;
/// boşalan alt klasörler gider, kök kalır; taşınamayan dosya yerinde kalır ve bildirilir.
@Test func onlyIdenticalCopiesAreTrashed() throws {
    let w = try Workspace()
    let bin = try w.mkdir("Cop")
    for (path, text) in [("a.txt", "aynı"), ("b.txt", "kaynak"), ("c.txt", "eksik"), ("alt/d.txt", "alt"), ("korumali.txt", "aynı 2")] {
        try w.write("Kaynak/" + path, text)
    }
    for (path, text) in [("a.txt", "aynı"), ("b.txt", "hedef!"), ("alt/d.txt", "alt"), ("korumali.txt", "aynı 2")] {
        try w.write("Hedef/" + path, text)
    }
    try FileManager.default.createSymbolicLink(atPath: w.url("Kaynak/bag.txt").path, withDestinationPath: w.url("Kaynak/a.txt").path)
    try w.write("Hedef/bag.txt", "aynı")
    let job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"), options: CopyOptions(copyMode: .contents))
    let pairs = SourceTrash.pairs(for: job, selection: nil, skippedNames: [], skippedPaths: [])
    let move = trash(into: bin)
    let outcome = SourceTrash.moveVerified(pairs, root: w.url("Kaynak"), trash: { url in
        url.lastPathComponent == "korumali.txt" ? false : move(url)
    })
    #expect(outcome.moved == 2 && outcome.kept == 2 && outcome.folders == 1 && outcome.failed == ["korumali.txt"])
    #expect(trashed(bin) == ["a.txt", "d.txt", "alt"])
    #expect(w.read("Kaynak/b.txt") == "kaynak" && w.read("Kaynak/c.txt") == "eksik" && w.read("Kaynak/korumali.txt") == "aynı 2")
    #expect(w.exists("Kaynak/bag.txt") && w.exists("Kaynak") && !w.exists("Kaynak/alt"))
    #expect(w.read("Hedef/a.txt") == "aynı" && w.read("Hedef/alt/d.txt") == "alt")
}

/// Temizleme aracı: hedefte herhangi bir yerde aynı içerikte kopyası olan kaynak dosyalar bulunur (gizliler hariç) ve
/// Çöp Sepeti'ne taşınır.
@Test func cleanupFindsArchivedFilesAnywhere() throws {
    let w = try Workspace()
    let bin = try w.mkdir("Cop")
    try w.write("Indirilenler/fatura.pdf", "fatura içeriği")
    try w.write("Indirilenler/Klasor/foto.jpg", "foto içeriği")
    try w.write("Indirilenler/yeni.txt", "henüz arşivde değil")
    try w.write("Indirilenler/.gizli", "fatura içeriği")
    try w.write("Arsiv/2026/Faturalar/123456789_El_10_26.pdf", "fatura içeriği")
    try w.write("Arsiv/Fotolar/IMG.jpg", "foto içeriği")
    let found = try SourceTrash.archivedFiles(in: w.url("Indirilenler"), destination: w.url("Arsiv"))
    #expect(found.map(\.lastPathComponent) == ["foto.jpg", "fatura.pdf"])
    let outcome = SourceTrash.move(found, root: w.url("Indirilenler"), trash: trash(into: bin))
    #expect(outcome.moved == 2 && outcome.folders == 1 && outcome.failed.isEmpty)
    #expect(w.read("Indirilenler/yeni.txt") != nil && w.exists("Indirilenler/.gizli") && !w.exists("Indirilenler/Klasor"))
}

@Test func trashOptionDecodesOffByDefault() throws {
    #expect(try JSONDecoder().decode(CopyOptions.self, from: Data(#"{"copyMode": "folder"}"#.utf8)).trashSourceAfterCopy == false)
    let options = CopyOptions(trashSourceAfterCopy: true)
    #expect(try JSONDecoder().decode(CopyOptions.self, from: JSONEncoder().encode(options)).trashSourceAfterCopy)
    // rsync'e hiçbir zaman kaynak silme seçeneği verilmez.
    let arguments = RsyncCommand.transfer(TransferJob(source: URL(fileURLWithPath: "/a"), destination: URL(fileURLWithPath: "/b"), options: options),
                                          environment: RsyncCommand.Environment(engine: fullEngine, destinationFileSystem: .apfs, sourceIsDirectory: true))
    #expect(!arguments.contains { $0.contains("remove-source") || $0.contains("remove-sent") })
}

/// "Taşı" gerçek rsync ile: kopyalanan ve hedefte birebir aynı olan dosyalar Çöp'e gider; dışlanan, atlanan (aynı adlı
/// karar) dosyalar kalır; yerleştirilen rotada yeni adlarla eşleşir; anlık görüntüde ve iptalde hiçbir şey taşınmaz.
@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct LiveSourceTrashTests {
    private func context(_ w: Workspace, bin: URL) async throws -> EngineContext {
        var context = try await engineContext()
        context.scratchDirectory = try w.mkdir("Gecici")
        context.trashItem = trash(into: bin)
        return context
    }

    @Test func movesOnlyVerifiedCopies() async throws {
        let w = try Workspace("CopiatorTrash")
        let bin = try w.mkdir("Cop")
        try w.write("Kaynak/rapor.txt", "rapor\n")
        try w.write("Kaynak/alt/not.txt", "not\n")
        try w.write("Kaynak/gecici.tmp", "geçici\n")
        try w.write("Kaynak/catisma.txt", "kaynaktaki\n")
        try w.write("Hedef/Kaynak/gecici.tmp", "eski!!\n")
        try w.write("Hedef/Kaynak/catisma.txt", "hedefteki farklı\n")
        var advanced = AdvancedOptions()
        advanced.excludePatterns = ["*.tmp"]
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"),
                              options: CopyOptions(advanced: advanced, trashSourceAfterCopy: true))
        job.conflictResolution = ConflictResolution(decisions: ["Kaynak/catisma.txt": .skip])
        let events = Collected<TransferEvent>()
        let result = await RsyncEngine().run(job, context: try await context(w, bin: bin)) { events.add($0) }
        #expect(result.kind == .succeeded, "\(result)")
        #expect(trashed(bin) == ["rapor.txt", "not.txt", "alt"])
        #expect(w.read("Kaynak/gecici.tmp") == "geçici\n" && w.read("Kaynak/catisma.txt") == "kaynaktaki\n" && w.exists("Kaynak"))
        #expect(w.read("Hedef/Kaynak/rapor.txt") == "rapor\n" && w.read("Hedef/Kaynak/alt/not.txt") == "not\n")
        let log = events.values.compactMap { if case .log(let entry) = $0 { entry } else { nil } }
        #expect(log.contains { $0.key == LKey.logSourcesTrashed.rawValue && $0.arguments == ["2", "1", "2"] })
    }

    @Test func placedRouteTrashesByTargetAndSnapshotsNeverTrash() async throws {
        let w = try Workspace("CopiatorTrash")
        let bin = try w.mkdir("Cop")
        let context = try await context(w, bin: bin)
        try w.write("Gelen/Enerjisa Ekim 2026.pdf", "fatura\n")
        try w.write("Gelen/baska.txt", "başka\n")
        try w.mkdir("Arsiv")
        let rules = RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "pdf")])
        let options = CopyOptions(copyMode: .contents, rules: rules,
                                  placement: RoutePlacement(folderTemplate: "{year}/{month}", nameTemplate: "El_{month}_{yy}", dateSource: .fileName),
                                  trashSourceAfterCopy: true)
        let job = TransferJob(source: w.url("Gelen"), destination: w.url("Arsiv"), options: options)
        let result = await RsyncEngine().run(job, context: context) { _ in }
        #expect(result.kind == .succeeded, "\(result)")
        #expect(w.read("Arsiv/2026/10/El_10_26.pdf") == "fatura\n")
        #expect(trashed(bin) == ["Enerjisa Ekim 2026.pdf"] && w.read("Gelen/baska.txt") == "başka\n")

        // Anlık görüntü: kaynak hiç taşınmaz (seçenek yok sayılır).
        try w.write("Kaynak2/x.txt", "x\n")
        try w.mkdir("Yedekler")
        let snapshot = TransferJob(source: w.url("Kaynak2"), destination: w.url("Yedekler"),
                                   options: CopyOptions(snapshots: SnapshotOptions(enabled: true), trashSourceAfterCopy: true))
        #expect(await RsyncEngine().run(snapshot, context: context) { _ in }.kind == .succeeded)
        #expect(w.read("Kaynak2/x.txt") == "x\n")
    }
}
