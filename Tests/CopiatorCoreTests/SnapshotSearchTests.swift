// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// Anlık görüntülerde arama ve karşılaştırma, elle kurulmuş iki anlık görüntüyle (rsync gerekmez): değişmeyen dosya sabit
/// bağlantıdır; ayrı kopya olsa da boyutu ve tarihi aynıysa değişmemiş sayılır; yalnızca tarihi değişen dosya değişmiştir.
/// Gizli dosyalar sayılmaz. Arama harf, aksan ve Türkçe I/ı farkını gözetmez; anlık görüntüler hiç değişmez.
struct SnapshotSearchTests {
    private let utc = TimeZone(identifier: "UTC")!

    private func setDate(_ url: URL, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }

    /// Eski (2026-11-01) ve yeni (2026-11-02) anlık görüntü; iş "klasörün kendisi" kipinde, içerik kökü anlık görüntü/Belgeler.
    private func makeSnapshots(_ w: Workspace) throws -> (TransferJob, [SnapshotRestore.Snapshot]) {
        try w.mkdir("Belgeler")
        let old = "Yedek/2026-11-01-100000/Belgeler/"
        let new = "Yedek/2026-11-02-100000/Belgeler/"
        try setDate(w.write(old + "rapor.txt", "rapor"), 1_000)
        try setDate(w.write(old + "Tatil/foto.jpg", "foto"), 1_000)
        try setDate(w.write(old + "eski.txt", "silinecek"), 1_000)
        try setDate(w.write(old + "Iğdır notları.txt", "notlar"), 1_000)
        try setDate(w.write(old + "ayni-boy.txt", "aaaa"), 1_000)
        try setDate(w.write(old + ".gizli", "a"), 1_000)
        try w.mkdir(new + "Tatil")
        try FileManager.default.linkItem(at: w.url(old + "rapor.txt"), to: w.url(new + "rapor.txt"))
        try setDate(w.write(new + "Tatil/foto.jpg", "foto, daha büyük"), 2_000)
        try setDate(w.write(new + "Tatil/kopya.jpg", "kopya"), 2_000)
        try setDate(w.write(new + "yeni.txt", "yeni"), 2_000)
        try setDate(w.write(new + "Iğdır notları.txt", "notlar"), 1_000)
        try setDate(w.write(new + "ayni-boy.txt", "bbbb"), 2_000)
        try setDate(w.write(new + ".gizli", "değişti"), 2_000)
        let job = TransferJob(source: w.url("Belgeler"), destination: w.url("Yedek"),
                              options: CopyOptions(snapshots: SnapshotOptions(enabled: true)))
        return (job, SnapshotRestore.snapshots(of: job, timeZone: utc))
    }

    @Test func compareFindsAddedChangedAndRemovedFiles() throws {
        let w = try Workspace("CopiatorSnapshotCompare")
        let (job, snapshots) = try makeSnapshots(w)
        try #require(snapshots.map(\.name) == ["2026-11-02-100000", "2026-11-01-100000"])
        let difference = SnapshotSearch.compare(snapshots[1], snapshots[0], job: job)
        #expect(difference.added.map(\.relativePath) == ["Tatil/kopya.jpg", "yeni.txt"])
        #expect(difference.changed.map(\.relativePath) == ["ayni-boy.txt", "Tatil/foto.jpg"])
        #expect(difference.removed.map(\.relativePath) == ["eski.txt"])
        #expect(difference.addedCount == 2 && difference.changedCount == 2 && difference.removedCount == 1)
        #expect(difference.changed.first { $0.relativePath == "Tatil/foto.jpg" }?.size == Int64("foto, daha büyük".utf8.count))
        #expect(difference.removed.first?.size == Int64("silinecek".utf8.count))
        #expect(!difference.isEmpty)
        // Aynı anlık görüntü kendisiyle aynıdır; ters yönde eklenen ve silinen yer değiştirir.
        #expect(SnapshotSearch.compare(snapshots[0], snapshots[0], job: job).isEmpty)
        let reverse = SnapshotSearch.compare(snapshots[0], snapshots[1], job: job)
        #expect(reverse.added.map(\.relativePath) == ["eski.txt"])
        #expect(reverse.removed.map(\.relativePath) == ["Tatil/kopya.jpg", "yeni.txt"])
        // Liste sınırı yalnızca listeyi kısaltır; sayılar tamdır.
        let short = SnapshotSearch.compare(snapshots[1], snapshots[0], job: job, limit: 1)
        #expect(short.added.map(\.relativePath) == ["Tatil/kopya.jpg"] && short.addedCount == 2)
        // Durdurulan karşılaştırma bir şey bulmaz.
        #expect(SnapshotSearch.compare(snapshots[1], snapshots[0], job: job, isCancelled: { true }).isEmpty)
    }

    @Test func searchMatchesNamesAcrossSnapshots() throws {
        let w = try Workspace("CopiatorSnapshotSearch")
        let (job, snapshots) = try makeSnapshots(w)
        let rapor = SnapshotSearch.search("RAPOR", in: snapshots, job: job)
        #expect(rapor.hits.map(\.relativePath) == ["rapor.txt"])
        #expect(rapor.hits.first?.snapshots.map(\.name) == ["2026-11-02-100000", "2026-11-01-100000"])
        #expect(!rapor.isTruncated)
        // Aksan ve Türkçe ı/İ: "igdir" "Iğdır notları.txt" ile eşleşir.
        #expect(SnapshotSearch.search("igdir", in: snapshots, job: job).hits.map(\.name) == ["Iğdır notları.txt"])
        #expect(SnapshotSearch.search("IĞDIR", in: snapshots, job: job).hits.count == 1)
        // Sonuçlar yola göre sıralıdır.
        #expect(SnapshotSearch.search("txt", in: snapshots, job: job).hits.map(\.relativePath)
            == ["ayni-boy.txt", "eski.txt", "Iğdır notları.txt", "rapor.txt", "yeni.txt"])
        let tatil = SnapshotSearch.search("tatil", in: snapshots, job: job).hits
        #expect(tatil.map(\.relativePath) == ["Tatil"] && tatil.first?.isDirectory == true)
        // Yalnızca yeni anlık görüntüde olan dosya.
        #expect(SnapshotSearch.search("kopya", in: snapshots, job: job).hits.first?.snapshots.map(\.name) == ["2026-11-02-100000"])
        // Gizli dosyalar, boş ve yalnızca boşluk olan sorgu bulunmaz.
        #expect(SnapshotSearch.search("gizli", in: snapshots, job: job).hits.isEmpty)
        #expect(SnapshotSearch.search("  ", in: snapshots, job: job).hits.isEmpty)
        // Sınır: en çok `limit` yol; fazlası işaretlenir, var olan yolun anlık görüntüleri yine eklenir.
        let limited = SnapshotSearch.search("t", in: snapshots, job: job, limit: 1)
        #expect(limited.hits.count == 1 && limited.isTruncated)
        #expect(SnapshotSearch.search("txt", in: snapshots, job: job, isCancelled: { true }).hits.isEmpty)
    }

    /// Arama ve karşılaştırma anlık görüntüleri değiştirmez.
    @Test func snapshotsStayUnchanged() throws {
        let w = try Workspace("CopiatorSnapshotReadOnly")
        let (job, snapshots) = try makeSnapshots(w)
        func listing() throws -> [String] {
            try FileManager.default.subpathsOfDirectory(atPath: w.url("Yedek").path).sorted().map { path in
                let attributes = try FileManager.default.attributesOfItem(atPath: w.url("Yedek/" + path).path)
                return "\(path) \(attributes[.size] ?? 0) \(attributes[.modificationDate] ?? "")"
            }
        }
        let before = try listing()
        _ = SnapshotSearch.search("a", in: snapshots, job: job)
        _ = SnapshotSearch.compare(snapshots[1], snapshots[0], job: job)
        #expect(try listing() == before)
    }
}
