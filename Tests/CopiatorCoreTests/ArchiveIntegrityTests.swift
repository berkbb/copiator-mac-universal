// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// Arşiv bütünlüğü: ilk denetim özetleri kaydeder; boyutu ve tarihi aynı kalıp içeriği değişen dosya bozuk sayılır ve
/// düzeltilene kadar bildirilir; meşru değişiklik güncellenir; kaybolan dosya bir kez bildirilir; sabit bağlantılı kopya bir
/// kez okunur; okunamayan dosya ayrı bildirilir; iptalde liste yazılmaz; sistem dosyaları ve listenin kendisi atlanır.
@Test func archiveIntegrityFindsSilentCorruption() throws {
    let w = try Workspace()
    try w.write("Arsiv/a.txt", "birinci dosya")
    try w.write("Arsiv/alt/c.txt", "ikinci dosya")
    try w.write("Arsiv/.DS_Store", "finder")
    try FileManager.default.linkItem(at: w.url("Arsiv/a.txt"), to: w.url("Arsiv/alt/a-baglanti.txt"))
    let root = w.url("Arsiv")

    let first = try ArchiveIntegrity.check(root)
    #expect(first.isFirstCheck && first.added == 3 && !first.hasProblems)
    #expect(first.bytes == Int64("birinci dosya".utf8.count + "ikinci dosya".utf8.count))
    #expect(ArchiveIntegrity.manifest(in: root)?.files.keys.sorted() == ["a.txt", "alt/a-baglanti.txt", "alt/c.txt"])

    let second = try ArchiveIntegrity.check(root)
    #expect(!second.isFirstCheck && second.intact == 3 && second.added == 0 && !second.hasProblems)

    // Sessiz bozulma: aynı uzunlukta farklı içerik, eski değiştirilme tarihi geri yazılır.
    let c = w.url("Arsiv/alt/c.txt")
    let date = try #require(try FileManager.default.attributesOfItem(atPath: c.path)[.modificationDate] as? Date)
    try Data("İKİNCİ".utf8.prefix(0) + Data("ikinci dosyA".utf8)).write(to: c)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: c.path)
    let damaged = try ArchiveIntegrity.check(root)
    #expect(damaged.corrupted == ["alt/c.txt"] && damaged.intact == 2)
    #expect(try ArchiveIntegrity.check(root).corrupted == ["alt/c.txt"])

    // Meşru değişiklik (tarih değişir) güncellenir; kaybolan dosya bir kez bildirilir.
    try w.write("Arsiv/alt/c.txt", "yeni içerik")
    try FileManager.default.removeItem(at: w.url("Arsiv/alt/a-baglanti.txt"))
    let changed = try ArchiveIntegrity.check(root)
    #expect(changed.updated == 1 && changed.missing == ["alt/a-baglanti.txt"] && changed.corrupted.isEmpty)
    #expect(try ArchiveIntegrity.check(root).missing.isEmpty)

    // Okunamayan dosya; iptalde liste değişmez.
    try w.write("Arsiv/kilitli.txt", "gizli")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: w.url("Arsiv/kilitli.txt").path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: w.url("Arsiv/kilitli.txt").path) }
    #expect(try ArchiveIntegrity.check(root).unreadable == ["kilitli.txt"])
    let before = ArchiveIntegrity.manifest(in: root)
    #expect(throws: CancellationError.self) { try ArchiveIntegrity.check(root, isCancelled: { true }) }
    #expect(ArchiveIntegrity.manifest(in: root) == before)
}

/// Gerçek rsync ile: "fazla dosyaları sil" ve "kopyaladıktan sonra doğrula" açık bir iş, hedefteki fazla dosyayı siler ama
/// bütünlük listesine dokunmaz; doğrulama listeyi fazla dosya saymaz.
@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct LiveIntegrityTests {
    @Test func deleteKeepsTheIntegrityList() async throws {
        let w = try Workspace("CopiatorIntegrity")
        var context = try await engineContext()
        context.scratchDirectory = try w.mkdir("Gecici")
        try w.write("Kaynak/a.txt", "a")
        try w.write("Hedef/fazla.txt", "fazla")
        _ = try ArchiveIntegrity.check(w.url("Hedef"))
        #expect(w.exists("Hedef/" + ArchiveIntegrity.manifestName))
        let job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"),
                              options: CopyOptions(copyMode: .contents, deleteExtraneous: true, verifyAfterCopy: .quick))
        let events = Collected<TransferEvent>()
        let result = await RsyncEngine().run(job, context: context) { events.add($0) }
        #expect(result.kind.isSuccess, "\(result)")
        #expect(!w.exists("Hedef/fazla.txt") && w.read("Hedef/a.txt") == "a")
        #expect(w.exists("Hedef/" + ArchiveIntegrity.manifestName))
        let logs = events.values.flatMap { event -> [JobLogEntry] in
            if case .log(let entry) = event { return [entry] }
            if case .logBatch(let entries) = event { return entries }
            return []
        }
        #expect(logs.contains { $0.key == LKey.logVerifyAfterCopyPassed.rawValue })
    }
}
