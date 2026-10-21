// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

/// Gelişmiş seçenekler gerçek rsync ile, kum havuzunda.
@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct AdvancedEngineTests {
    private func run(_ job: TransferJob, home: URL? = nil) async throws -> (JobResult, [TransferEvent]) {
        let events = Collected<TransferEvent>()
        let result = await RsyncEngine().run(job, context: try await engineContext(home: home)) { events.add($0) }
        return (result, events.values)
    }

    private func inode(_ url: URL) -> ino_t {
        var info = stat()
        lstat(url.path, &info)
        return info.st_ino
    }

    private func logLines(_ events: [TransferEvent]) -> [JobLogEntry] {
        events.flatMap { event -> [JobLogEntry] in
            switch event {
            case .log(let entry): [entry]
            case .logBatch(let entries): entries
            default: []
            }
        }
    }

    /// Süzgeçler ve sabit bağlantılar; doğrulama aynı süzgeçlerle "birebir" der.
    @Test func filtersAndHardLinks() async throws {
        let workspace = try Workspace()
        try workspace.write("Kaynak/belge.txt", "belge\n")
        try workspace.write("Kaynak/gecici.tmp", "atılacak\n")
        try workspace.write("Kaynak/Önbellek/x.bin", "önbellek\n")
        try FileManager.default.linkItem(at: workspace.url("Kaynak/belge.txt"), to: workspace.url("Kaynak/ikinci-ad.txt"))
        try workspace.mkdir("Hedef")
        var options = AdvancedOptions()
        options.excludePatterns = ["*.tmp", "/Kaynak/Önbellek/"]
        options.hardLinks = true
        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"), options: CopyOptions(advanced: options))
        let (result, _) = try await run(job)
        #expect(result.kind == .succeeded, "\(result)")
        #expect(workspace.exists("Hedef/Kaynak/belge.txt"))
        #expect(!workspace.exists("Hedef/Kaynak/gecici.tmp"))
        #expect(!workspace.exists("Hedef/Kaynak/Önbellek"))
        #expect(inode(workspace.url("Hedef/Kaynak/belge.txt")) == inode(workspace.url("Hedef/Kaynak/ikinci-ad.txt")))
        let report = await RsyncEngine().verify(job, context: try await engineContext(), checksum: false)
        #expect(report.isIdentical, "\(report.entries)")
    }

    /// Time Machine benzeri anlık görüntü: değişmeyen dosya önceki yedekle aynı inode'u paylaşır.
    @Test func linkDestSnapshots() async throws {
        let workspace = try Workspace()
        try workspace.write("Kaynak/sabit.txt", "değişmez\n")
        try workspace.write("Kaynak/degisen.txt", "1\n")
        try workspace.mkdir("Yedekler/1")
        try workspace.mkdir("Yedekler/2")
        let first = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Yedekler/1"),
                                options: CopyOptions(copyMode: .contents))
        #expect(try await run(first).0.kind == .succeeded)
        try workspace.write("Kaynak/degisen.txt", "2, daha uzun\n")
        var options = AdvancedOptions()
        options.referenceMode = .linkDest
        options.referenceDirectory = workspace.url("Yedekler/1").path
        let second = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Yedekler/2"),
                                 options: CopyOptions(copyMode: .contents, advanced: options))
        let (result, _) = try await run(second)
        #expect(result.kind == .succeeded, "\(result)")
        #expect(inode(workspace.url("Yedekler/1/sabit.txt")) == inode(workspace.url("Yedekler/2/sabit.txt")))
        #expect(inode(workspace.url("Yedekler/1/degisen.txt")) != inode(workspace.url("Yedekler/2/degisen.txt")))
        #expect(workspace.read("Yedekler/2/degisen.txt") == "2, daha uzun\n")
    }

    /// Eski sürümler hedefin dışındaki bir klasöre; günlük dosyası ve toplu iş dosyası kum havuzunda yazılır.
    @Test func backupsLogFileAndBatchUnderSandbox() async throws {
        let workspace = try Workspace()
        try workspace.write("Kaynak/not.txt", "ilk\n")
        try workspace.mkdir("Hedef")
        let plain = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"))
        #expect(try await run(plain).0.kind == .succeeded)
        try workspace.write("Kaynak/not.txt", "ikinci sürüm\n")
        var options = AdvancedOptions()
        options.keepBackups = true
        options.backupDirectory = workspace.url("EskiSurumler").path
        options.logFile = workspace.url("Gunluk/rsync.log").path
        options.batchMode = .write
        options.batchFile = workspace.url("Gunluk/degisiklik").path
        try workspace.mkdir("Gunluk")
        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"), options: CopyOptions(advanced: options))
        let (result, _) = try await run(job)
        #expect(result.kind == .succeeded, "\(result)")
        #expect(workspace.read("Hedef/Kaynak/not.txt") == "ikinci sürüm\n")
        #expect(workspace.read("EskiSurumler/Kaynak/not.txt") == "ilk\n")
        #expect(workspace.read("Gunluk/rsync.log")?.contains("Kaynak/not.txt") == true)
        #expect(workspace.exists("Gunluk/degisiklik"))
        #expect(workspace.exists("Gunluk/degisiklik.sh"))
    }

    /// Yalnızca toplu iş dosyası: hedef değişmez.
    @Test func onlyWriteBatchLeavesDestinationUnchanged() async throws {
        let workspace = try Workspace()
        try workspace.write("Kaynak/yeni.txt", "yeni\n")
        try workspace.mkdir("Hedef")
        var options = AdvancedOptions()
        options.batchMode = .onlyWrite
        options.batchFile = workspace.url("toplu").path
        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"), options: CopyOptions(advanced: options))
        let (result, _) = try await run(job)
        #expect(result.kind == .succeeded, "\(result)")
        #expect(!workspace.exists("Hedef/Kaynak/yeni.txt"))
        #expect(workspace.exists("toplu"))
    }

    /// Dosya adları, dosya başı ilerleme, istatistikler ve değişiklik günlüğü olaylara yansır.
    @Test func namesStatsAndChangesReachTheJob() async throws {
        let workspace = try Workspace()
        for index in 0..<5 { try workspace.write("Kaynak/dosya\(index).txt", String(repeating: "x", count: 1000 * (index + 1))) }
        try workspace.mkdir("Hedef")
        var options = AdvancedOptions()
        options.showFileNames = true
        options.showStats = true
        options.logChanges = true
        options.progressDetail = .perFile
        options.preciseProgress = true
        options.fileListProgress = true
        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"), options: CopyOptions(advanced: options))
        let (result, events) = try await run(job)
        #expect(result.kind == .succeeded, "\(result)")
        let progress = events.compactMap { if case .progress(let p) = $0 { p } else { nil } }
        #expect(progress.contains { $0.currentItem?.hasPrefix("Kaynak/dosya") == true })
        #expect(progress.last?.bytesTransferred == 15_000)
        let log = logLines(events)
        #expect(log.contains { $0.key == LKey.logStatsHeader.rawValue })
        #expect(log.contains { $0.raw?.hasPrefix("Number of files:") == true })
        #expect(log.contains { $0.raw?.hasPrefix(">f+++++++++ Kaynak/dosya0.txt") == true })
    }

    /// Kişisel bir klasördeki liste dosyası (--files-from) yalnızca o dosya için açılır.
    @Test func filesFromListInsideProtectedFolder() async throws {
        let workspace = try Workspace()
        let home = workspace.url("ev")
        try workspace.write("ev/.ssh/gizli", "anahtar\n")
        try workspace.write("ev/.ssh/liste.txt", "secili.txt\n")
        try workspace.write("Kaynak/secili.txt", "evet\n")
        try workspace.write("Kaynak/secilmeyen.txt", "hayır\n")
        try workspace.mkdir("Hedef")
        var options = AdvancedOptions()
        options.filesFromFile = workspace.url("ev/.ssh/liste.txt").path
        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"),
                              options: CopyOptions(copyMode: .contents, advanced: options))
        let (result, _) = try await run(job, home: home)
        #expect(result.kind == .succeeded, "\(result)")
        #expect(workspace.read("Hedef/secili.txt") == "evet\n")
        #expect(!workspace.exists("Hedef/secilmeyen.txt"))
        // Liste dosyasının klasörü yine kapalı: rsync listeyi uygulamanın hazırladığı özel bir kopyadan okur.
        let profile = SandboxProfile.forTransfer(sources: [workspace.url("Kaynak")], destination: workspace.url("Hedef"), home: home,
                                                 extraReadable: options.readablePaths)
        #expect(profile.readableDirectories.isEmpty)
        #expect(profile.readableFiles.map(\.lastPathComponent) == ["liste.txt"])
    }

    @Test func invalidOptionsAreRefusedAndPastStopTimeIsIgnored() async throws {
        let workspace = try Workspace()
        try workspace.write("Kaynak/a.txt", "a\n")
        try workspace.mkdir("Hedef")
        var bad = AdvancedOptions()
        bad.chmod = "olmaz"
        let refused = try await run(TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"), options: CopyOptions(advanced: bad))).0
        #expect(refused.kind == .failed)
        #expect(!workspace.exists("Hedef/Kaynak"))
        var past = AdvancedOptions()
        past.stopAt = Date(timeIntervalSinceNow: -3600)
        let resumed = try await run(TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"), options: CopyOptions(advanced: past))).0
        #expect(resumed.kind == .succeeded, "\(resumed)")
    }
}
