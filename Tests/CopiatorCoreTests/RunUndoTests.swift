// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import Testing
@testable import CopiatorCore

/// Son çalıştırmayı geri alma. Testlerin "Çöp Sepeti" geçici bir klasördür; gerçek Çöp Sepeti'ne dokunulmaz.
@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct RunUndoTests {
    /// Test Çöp'ü: öğe, çakışmasın diye sıra numarasıyla bir klasöre taşınır.
    private final class TestTrash: @unchecked Sendable {
        let folder: URL
        var moved: [String] = []
        init(_ folder: URL) { self.folder = folder }
        func callAsFunction(_ url: URL) -> Bool {
            let target = folder.appendingPathComponent("\(moved.count)-\(url.lastPathComponent)")
            guard (try? FileManager.default.moveItem(at: url, to: target)) != nil else { return false }
            moved.append(url.lastPathComponent)
            return true
        }
    }

    private func setDate(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Gerçek rsync: eklenen dosya ve klasörler kaydedilir, üzerine yazılan sayılır; geri alma yalnızca eklenenleri ve
    /// boş kalan eklenen klasörleri taşır, önceden var olanlara ve sonradan değiştirilen ya da içine dosya eklenenlere
    /// dokunmaz.
    @Test func undoMovesOnlyWhatTheRunCreated() async throws {
        let w = try Workspace("CopiatorRunUndo")
        var context = try await engineContext()
        context.scratchDirectory = try w.mkdir("Gecici")
        try w.write("Belgeler/yeni.txt", "yeni")
        try w.write("Belgeler/degisen.txt", "yeni içerik, daha uzun")
        try w.write("Belgeler/Bos/a.txt", "a")
        try w.write("Belgeler/Dolu/b.txt", "b")
        try w.write("Belgeler/sonra.txt", "sonra")
        // Kaynak dosyalar çoğunlukla çalıştırmadan çok eskidir: rsync değişme zamanını taşır, macOS da kopyanın oluşma
        // zamanını ona çeker. Geri alma yine de bu kopyaları taşımalı.
        for path in ["Belgeler/yeni.txt", "Belgeler/Bos/a.txt", "Belgeler/Dolu/b.txt", "Belgeler/sonra.txt"] {
            try setDate(w.url(path), Date(timeIntervalSince1970: 1_700_000_000))
        }
        try w.write("Hedef/Belgeler/degisen.txt", "eski")
        try w.write("Hedef/Belgeler/onceden.txt", "önceden vardı")
        var job = TransferJob(source: w.url("Belgeler"), destination: w.url("Hedef"), options: CopyOptions(conflictPolicy: .replace))
        let started = Date()
        let result = await RsyncEngine().run(job, context: context) { _ in }
        let finished = Date()
        #expect(result.kind.isSuccess)
        let record = try #require(result.undo)
        #expect(Set(record.created) == ["Belgeler/yeni.txt", "Belgeler/Bos", "Belgeler/Bos/a.txt", "Belgeler/Dolu", "Belgeler/Dolu/b.txt",
                                        "Belgeler/sonra.txt"])
        #expect(record.otherChanges == 1 && !record.truncated)
        JobQueue.finish(&job, with: result)
        #expect(job.history.last?.result.undo == record)

        // Çalıştırmadan sonra: bir dosya değişti, eklenen bir klasöre kullanıcı dosya koydu.
        try setDate(w.url("Hedef/Belgeler/sonra.txt"), finished.addingTimeInterval(60))
        try w.write("Hedef/Belgeler/Dolu/kullanici.txt", "kullanıcının")
        let trash = TestTrash(try w.mkdir("Cop"))
        let outcome = RunUndo.undoCreated(record, destination: w.url("Hedef"), startedAt: started, finishedAt: finished, trash: trash.callAsFunction)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: w.url("Hedef/Belgeler/yeni.txt").path))
        #expect(!fm.fileExists(atPath: w.url("Hedef/Belgeler/Bos").path), "boş kalan eklenen klasör")
        #expect(!fm.fileExists(atPath: w.url("Hedef/Belgeler/Dolu/b.txt").path))
        #expect(fm.fileExists(atPath: w.url("Hedef/Belgeler/Dolu/kullanici.txt").path), "içine dosya eklenen klasör kalır")
        #expect(fm.fileExists(atPath: w.url("Hedef/Belgeler/sonra.txt").path), "sonradan değişen dosya kalır")
        #expect(fm.fileExists(atPath: w.url("Hedef/Belgeler/degisen.txt").path), "üzerine yazılan dosya kalır")
        #expect(fm.fileExists(atPath: w.url("Hedef/Belgeler/onceden.txt").path), "önceden var olan dosya kalır")
        #expect(outcome.trashed == 4 && outcome.failed.isEmpty)
        #expect(Set(outcome.kept) == ["Belgeler/Dolu", "Belgeler/sonra.txt"])
        #expect(fm.fileExists(atPath: w.url("Hedef/Belgeler").path), "hedefteki klasör önceden vardı")
    }

    /// Kayıttaki yollar hedefin dışına çıkamaz: ".." içeren, mutlak ve hedef içindeki bir bağlantı üzerinden dışarı giden
    /// yollar taşınmaz (zaman denetimi her şeyi kabul edecek biçimde ayarlı: yalnızca yol denetimleri korur);
    /// çalıştırmadan önce var olan dosya kayıtta olsa da taşınmaz.
    @Test func recordsCannotLeaveTheDestination() throws {
        let w = try Workspace("CopiatorRunUndoSafety")
        try w.write("Hedef/ic.txt", "iç")
        try w.write("Hedef/etc/hosts", "hedefteki")
        try w.mkdir("Hedef/alt")
        try w.write("Disari/x.txt", "dışarı")
        try w.write("Disari.txt", "dışarı")
        try FileManager.default.createSymbolicLink(at: w.url("Hedef/baglanti"), withDestinationURL: w.url("Disari"))
        let trash = TestTrash(try w.mkdir("Cop"))
        let record = RunUndo.Record(created: ["../Disari.txt", "/etc/hosts", "alt/../ic.txt", "baglanti/x.txt", ""], truncated: false,
                                    otherChanges: 0)
        let outcome = RunUndo.undoCreated(record, destination: w.url("Hedef"), startedAt: .distantPast, finishedAt: .distantFuture,
                                          trash: trash.callAsFunction)
        #expect(trash.moved.isEmpty && outcome.trashed == 0)
        for path in ["Disari.txt", "Disari/x.txt", "Hedef/ic.txt", "Hedef/etc/hosts"] {
            #expect(FileManager.default.fileExists(atPath: w.url(path).path), "\(path)")
        }
        // Çalıştırmadan önce var olan dosya kayıtta olsa da taşınmaz.
        let before = RunUndo.undoCreated(RunUndo.Record(created: ["ic.txt"], truncated: false, otherChanges: 0), destination: w.url("Hedef"),
                                         startedAt: Date().addingTimeInterval(60), finishedAt: .distantFuture, trash: trash.callAsFunction)
        #expect(before.trashed == 0 && FileManager.default.fileExists(atPath: w.url("Hedef/ic.txt").path))
    }

    @Test func snapshotUndoMovesTheNewestAndRepointsLatest() throws {
        let w = try Workspace("CopiatorSnapshotUndo")
        let utc = TimeZone(identifier: "UTC")!
        try w.write("Yedek/2026-11-01-100000/a.txt", "1")
        try w.write("Yedek/2026-11-02-100000/a.txt", "2")
        let root = w.url("Yedek")
        #expect(SnapshotStore.updateLatestLink(in: root, to: "2026-11-02-100000"))
        let trash = TestTrash(try w.mkdir("Cop"))
        #expect(!RunUndo.undoSnapshot("2026-11-01-100000", root: root, timeZone: utc, trash: trash.callAsFunction), "en yeni değil")
        #expect(RunUndo.undoSnapshot("2026-11-02-100000", root: root, timeZone: utc, trash: trash.callAsFunction))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-11-02-100000").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("Latest").path) == "2026-11-01-100000")
        #expect(RunUndo.undoSnapshot("2026-11-01-100000", root: root, timeZone: utc, trash: trash.callAsFunction))
        var info = stat()
        #expect(lstat(root.appendingPathComponent("Latest").path, &info) != 0, "son anlık görüntü de gidince bağlantı kalkar")
        #expect(trash.moved == ["2026-11-02-100000", "2026-11-01-100000"])
    }

    @Test func recordsAreStoredOnlyOnTheLastRun() throws {
        var job = TransferJob(source: URL(fileURLWithPath: "/tmp/a"), destination: URL(fileURLWithPath: "/tmp/b"))
        var first = JobResult(kind: .succeeded)
        first.undo = RunUndo.Record(created: ["a"], truncated: false, otherChanges: 0)
        JobQueue.finish(&job, with: first)
        var second = JobResult(kind: .succeeded)
        second.undo = RunUndo.Record(created: ["b"], truncated: false, otherChanges: 2)
        JobQueue.finish(&job, with: second)
        #expect(job.history.map { $0.result.undo?.created } == [nil, ["b"]])
        let old = try JSONDecoder().decode(JobResult.self, from: Data(#"{"kind":"succeeded"}"#.utf8))
        #expect(old.undo == nil)
        let saved = try JSONDecoder().decode(JobRun.self, from: JSONEncoder().encode(job.history[1]))
        #expect(saved.result.undo == second.undo && saved.undoneAt == nil)
    }
}
