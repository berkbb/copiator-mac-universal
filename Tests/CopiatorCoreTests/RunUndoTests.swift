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

    /// "Taşı" seçili çalıştırma: Çöp'e giden kaynak dosya ve boşalan klasörlerin yerleri kaydedilir. Geri alma önce
    /// kaynakları yerine koyar; eski yeri dolmuş kaynağın hedefteki kopyası Çöp'e gitmez (tek kopya o olabilir).
    @Test func moveRunPutsSourcesBackBeforeTrashingCopies() async throws {
        let w = try Workspace("CopiatorMoveUndo")
        let sourceTrash = try w.mkdir(".Trash")
        var context = try await engineContext()
        context.scratchDirectory = try w.mkdir("Gecici")
        context.trashItem = { url in
            let target = sourceTrash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            return (try? FileManager.default.moveItem(at: url, to: target)) != nil ? target : nil
        }
        try w.write("Gelen/a.txt", "a")
        try w.write("Gelen/alt/b.txt", "b")
        try w.write("Gelen/c.txt", "c")
        try w.mkdir("Arsiv")
        let job = TransferJob(source: w.url("Gelen"), destination: w.url("Arsiv"),
                              options: CopyOptions(copyMode: .contents, conflictPolicy: .replace, trashSourceAfterCopy: true))
        let started = Date()
        let result = await RsyncEngine().run(job, context: context) { _ in }
        let finished = Date()
        #expect(result.kind.isSuccess, "\(result)")
        let record = try #require(result.undo)
        #expect(!record.movedSourcesIncomplete && record.knowsMovedSources)
        #expect(Set(record.movedSources.map(\.original)) == Set(["Gelen/a.txt", "Gelen/alt/b.txt", "Gelen/c.txt", "Gelen/alt"].map { w.url($0).path }))
        #expect(record.movedSources.first { $0.original == w.url("Gelen/alt").path }?.target == nil, "klasörün kopyası kaydedilmez")
        #expect(!w.exists("Gelen/a.txt") && !w.exists("Gelen/alt") && w.exists("Gelen"))

        // Kullanıcı c.txt'nin yerine yeni bir dosya koydu: o kaynak geri konamaz, kopyası hedefte kalır.
        try w.write("Gelen/c.txt", "yeni c")
        let restore = RunUndo.restoreSources(record.movedSources, source: job.source)
        #expect(restore.restored == 2 && restore.notRestored == [w.url("Gelen/c.txt").path])
        #expect(w.read("Gelen/a.txt") == "a" && w.read("Gelen/alt/b.txt") == "b" && w.read("Gelen/c.txt") == "yeni c")
        let trash = TestTrash(try w.mkdir("Cop"))
        let outcome = RunUndo.undoCreated(record, destination: job.destination, startedAt: started, finishedAt: finished,
                                          keep: restore.keepTargets, trash: trash.callAsFunction)
        #expect(!w.exists("Arsiv/a.txt") && !w.exists("Arsiv/alt") && w.read("Arsiv/c.txt") == "c")
        #expect(outcome.kept == ["c.txt"] && outcome.failed.isEmpty)
    }

    /// Kayıt yalnızca bir Çöp klasöründeki öğeyi ve yalnızca kaynağın içine geri koyar: Çöp dışından, kaynağın dışına
    /// ya da "." ve ".." içeren yollarla hiçbir şey taşınmaz; geri konamayan dosyaların kopyaları korunur.
    @Test func restoreAcceptsOnlyTrashToSource() throws {
        let w = try Workspace("CopiatorMoveUndoSafety")
        try w.mkdir("Gelen")
        try w.write("Disari/x.txt", "dışarıdaki")
        try w.write(".Trash/y.txt", "çöpteki")
        try w.write(".Trash/z.txt", "çöpteki")
        let moved = [
            RunUndo.MovedSource(original: w.url("Gelen/x.txt").path, trashed: w.url("Disari/x.txt").path, target: "/hedef/x.txt"),
            RunUndo.MovedSource(original: w.url("Baska/y.txt").path, trashed: w.url(".Trash/y.txt").path, target: "/hedef/y.txt"),
            RunUndo.MovedSource(original: w.url("Gelen").path + "/../Baska/z.txt", trashed: w.url(".Trash/z.txt").path, target: "/hedef/z.txt"),
            RunUndo.MovedSource(original: "Gelen/z.txt", trashed: w.url(".Trash/z.txt").path, target: "/hedef/w.txt"),
        ]
        let outcome = RunUndo.restoreSources(moved, source: w.url("Gelen"))
        #expect(outcome.restored == 0 && outcome.notRestored.count == 4)
        #expect(outcome.keepTargets == ["/hedef/x.txt", "/hedef/y.txt", "/hedef/z.txt", "/hedef/w.txt"])
        #expect(w.exists("Disari/x.txt") && w.exists(".Trash/y.txt") && w.exists(".Trash/z.txt") && !w.exists("Baska"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: w.url("Gelen").path)) ?? ["?"]).isEmpty)
    }

    /// 1.1.0'ın kayıtları Çöp'e taşınan kaynakları bilmez; yeni kayıtlar bilir ve kaydedilip okununca aynı kalır.
    @Test func legacyRecordsDoNotKnowMovedSources() throws {
        let legacy = try JSONDecoder().decode(RunUndo.Record.self, from: Data(#"{"created":["a"],"truncated":false,"otherChanges":0}"#.utf8))
        #expect(!legacy.knowsMovedSources && !legacy.movedSourcesIncomplete && legacy.movedSources.isEmpty && legacy.created == ["a"])
        let record = RunUndo.Record(created: ["a"], truncated: false, otherChanges: 1,
                                    movedSources: [RunUndo.MovedSource(original: "/k/a", trashed: "/u/.Trash/a", target: "/h/a")])
        let decoded = try JSONDecoder().decode(RunUndo.Record.self, from: JSONEncoder().encode(record))
        #expect(decoded == record && decoded.knowsMovedSources)
        let broken = try JSONDecoder().decode(RunUndo.Record.self, from: Data(#"{"created":["a"],"truncated":false,"otherChanges":0,"movedSources":7}"#.utf8))
        #expect(broken.movedSourcesIncomplete, "okunamayan taşıma listesi eksik sayılır")
    }
}
