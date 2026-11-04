// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import os
import Synchronization
import Testing
@testable import CopiatorCore

/// Günlük: dosyaya yazılan kayıtlar uygulama yeniden açılınca geri okunur (önceki oturumun izi kaybolmaz), dosya yalnızca
/// kullanıcıya açıktır, büyüyünce bir kez saklanıp yenisine başlanır.
@Suite(.serialized)
struct AppLogTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CopiatorLogTests-\(UUID().uuidString)", isDirectory: true)

    private func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    /// Sekme, satır sonu ve ters bölü içeren metinler dosyadan aynen geri okunur; sıra ve düzey korunur.
    @Test func entriesSurviveARestart() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AppLog(directory: directory)
        log.info(.app, "Started")
        log.warning(.disk, "Volume waited\tlong", detail: "satır 1\nsatır 2\\son\r\nbitti")
        log.error(.engine, "rsync failed", detail: "rsync: [sender] a.txt")
        let first = log.entries
        #expect(first.map(\.message) == ["Started", "Volume waited\tlong", "rsync failed"])

        let reopened = AppLog(directory: directory)
        let loaded = reopened.entries
        #expect(loaded.map(\.message) == first.map(\.message))
        #expect(loaded.map(\.detail) == [nil, "satır 1\nsatır 2\\son\r\nbitti", "rsync: [sender] a.txt"])
        #expect(loaded.map(\.level) == [.info, .warning, .error])
        #expect(loaded.map(\.category) == [.app, .disk, .engine])
        #expect(loaded.map(\.process) == Array(repeating: getpid(), count: 3))
        #expect(loaded.map(\.id) == [0, 1, 2])
        for (old, new) in zip(first, loaded) {
            #expect(abs(old.date.timeIntervalSince(new.date)) < 0.002)
        }
        // Yeni kayıtlar öncekilerin ardına numaralanır.
        reopened.info(.app, "Started again")
        #expect(reopened.entries.last?.id == 3)
        #expect(AppLog(directory: directory).entries.count == 4)
    }

    @Test func fileIsPrivateToTheUser() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        AppLog(directory: directory).info(.app, "Started")
        #expect(try permissions(directory) == 0o700)
        #expect(try permissions(directory.appendingPathComponent(AppLog.fileName)) == 0o600)
    }

    /// Dosya sınırı aşılınca eskisi `Copiator.1.log` olarak bir kez saklanır; yeniden açılışta ikisi birlikte okunur,
    /// bellekte en çok `capacity` kayıt kalır.
    @Test func rotatesAndKeepsCapacity() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AppLog(directory: directory, capacity: 50, maxFileBytes: 4096)
        for index in 0..<200 {
            log.info(.job, "Entry \(index)", detail: String(repeating: "x", count: 40))
        }
        #expect(log.entries.count == 50)
        #expect(log.entries.first?.message == "Entry 150")
        #expect(log.entries.last?.message == "Entry 199")
        let current = try Data(contentsOf: directory.appendingPathComponent(AppLog.fileName))
        let previous = try Data(contentsOf: directory.appendingPathComponent(AppLog.previousFileName))
        #expect(current.count <= 4096)
        #expect(previous.count <= 4096)

        let reopened = AppLog(directory: directory, capacity: 50, maxFileBytes: 4096)
        // İki dosyada 50'den fazla satır var: yeniden açılışta son 50 kayıt, sırayla numaralanmış.
        #expect(AppLog.parse(String(decoding: previous + current, as: UTF8.self)).count > 50)
        #expect(reopened.entries.map(\.message) == (150..<200).map { "Entry \($0)" })
        #expect(reopened.entries.map(\.id) == Array(0..<50))
    }

    @Test func clearRemovesEntriesAndFiles() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AppLog(directory: directory, maxFileBytes: 1024)
        for index in 0..<40 { log.info(.app, "Entry \(index)") }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(AppLog.previousFileName).path))
        log.clear()
        #expect(log.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(AppLog.fileName).path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(AppLog.previousFileName).path))
        log.error(.app, "After clear")
        #expect(AppLog(directory: directory).entries.map(\.message) == ["After clear"])
    }

    /// Bozuk ya da başka biçimde satırlar (elle düzenlenmiş dosya) atlanır, geri kalanı okunur.
    @Test func malformedLinesAreSkipped() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        AppLog(directory: directory).info(.app, "Good")
        let file = directory.appendingPathComponent(AppLog.fileName)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("garbage\nnot-a-date\tinfo\tapp\t1\tx\t\n2026-10-26T10:00:00.000+0300\tloud\tapp\t1\tx\t\n".utf8))
        try handle.close()
        #expect(AppLog(directory: directory).entries.map(\.message) == ["Good"])
    }

    @Test func memoryOnlyLogWritesNothingAndTestsUseIt() throws {
        let log = AppLog(directory: nil)
        log.error(.app, "Kept in memory")
        #expect(log.entries.count == 1)
        #expect(log.fileURL == nil)
        // `swift test` kullanıcının ~/Library/Logs/Copiator dosyasına ve Konsol'a yazmaz.
        #expect(AppLog.shared.directory == nil)
        #expect(!AppLog.shared.mirrorsToSystemLog)
    }

    @Test func observersAreNotifiedUntilRemoved() {
        let log = AppLog(directory: nil)
        let calls = Atomic<Int>(0)
        let token = log.observe { calls.add(1, ordering: .relaxed) }
        log.info(.app, "One")
        log.clear()
        #expect(calls.load(ordering: .relaxed) == 2)
        log.removeObserver(token)
        log.info(.app, "Two")
        #expect(calls.load(ordering: .relaxed) == 2)
    }

        /// Rutin kayıtlar Konsol'u doldurmasın: bilgi `.info` düzeyinde (Konsol'da varsayılan olarak gizli, kalıcı değil),
    /// uyarı ve hata `.error` düzeyinde gider. Uygulamanın kendi kayıtları düzeyden etkilenmez.
    @Test func routineEntriesUseTheInfoLevelInConsole() {
        #expect(AppLog.Level.info.osLogType == .info)
        #expect(AppLog.Level.warning.osLogType == .error)
        #expect(AppLog.Level.error.osLogType == .error)
        let log = AppLog(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        log.info(.job, "Job 1A2B3C4D ended: succeeded, exit 0, 3 s")
        #expect(AppLog(directory: directory).entries.map(\.message) == ["Job 1A2B3C4D ended: succeeded, exit 0, 3 s"])
    }

    /// Konsol'da açık görünen tür dosya adı içermez; adlar ve rsync iletisi gizli ayrıntıdadır. İş kimliği kısaltılır.
    @Test func errorKindsKeepNamesInTheDetail() {
        let failed = AppLog.describe(EngineError.failed(code: 23, message: "rsync: send_files failed to open \"/Users/test/a.txt\""))
        #expect(failed.kind == "rsync failed with exit code 23" && failed.detail?.contains("a.txt") == true)
        #expect(!failed.kind.contains("a.txt"))
        #expect(AppLog.describe(EngineError.sandboxUnavailable).detail == nil)
        #expect(AppLog.describe(InsufficientSpaceError(required: 10, available: 5)).kind.contains("required 10 bytes"))
        #expect(AppLog.describe(CancellationError()).kind == "cancelled")
        #expect(AppLog.isCancellation(EngineError.cancelled) && AppLog.isCancellation(CancellationError()))
        #expect(!AppLog.isCancellation(EngineError.timedOut))
        let id = UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000000")!
        #expect(AppLog.short(id) == "1A2B3C4D")
    }
}
