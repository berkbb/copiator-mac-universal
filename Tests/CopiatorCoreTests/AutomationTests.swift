// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

// MARK: - Disk takılınca başlatma ve kuyruk

@Test func diskWaitingJobsAreSkippedNotFailed() {
    var waiting = TransferJob(source: URL(fileURLWithPath: "/Users/x/A"), destination: URL(fileURLWithPath: "/Volumes/Yok/Yedek"),
                              options: CopyOptions(runWhenConnected: true))
    let other = TransferJob(source: URL(fileURLWithPath: "/Users/x/B"), destination: URL(fileURLWithPath: "/Users/x/Yok"))
    let unplugged = TransferJob(source: URL(fileURLWithPath: "/Users/x/B"), destination: URL(fileURLWithPath: "/Volumes/Yok/Yedek"))
    let missing: (TransferJob) -> Bool = { _ in false }
    // Diski bekleyen iş atlanır; diski takılı olmayan iş seçenek kapalıyken de bekler; bu Mac'te hedefi olmayan iş sırasını
    // alır (ve hatayla biter).
    #expect(JobQueue.isWaitingForDisk(waiting, pathsAvailable: missing))
    #expect(JobQueue.isWaitingForDisk(unplugged, pathsAvailable: missing))
    #expect(!JobQueue.isWaitingForDisk(other, pathsAvailable: missing))
    #expect(JobQueue.next(in: [waiting, unplugged, other], pathsAvailable: missing) == other.id)
    #expect(JobQueue.next(in: [waiting], pathsAvailable: missing) == nil)
    #expect(JobQueue.next(in: [waiting, other], pathsAvailable: { _ in true }) == waiting.id)
    waiting.status = .paused
    #expect(!JobQueue.isWaitingForDisk(waiting, pathsAvailable: missing))
}

@Test func jobsMatchVolumesByPathComponents() {
    let job = TransferJob(source: URL(fileURLWithPath: "/Volumes/Kaynak Disk/Fotoğraflar"), destination: URL(fileURLWithPath: "/Volumes/Yedek/Arşiv"))
    #expect(job.uses(volume: URL(fileURLWithPath: "/Volumes/Yedek")))
    #expect(job.usesAsDestination(volume: URL(fileURLWithPath: "/Volumes/Yedek/")))
    #expect(job.uses(volume: URL(fileURLWithPath: "/Volumes/Kaynak Disk")))
    #expect(!job.usesAsDestination(volume: URL(fileURLWithPath: "/Volumes/Kaynak Disk")))
    #expect(!job.uses(volume: URL(fileURLWithPath: "/Volumes/Yed")))
    #expect(!job.uses(volume: URL(fileURLWithPath: "/Volumes/Yedek 2")))
    // Başlangıç birimi takılıp çıkarılmaz: hiçbir işle eşleşmez.
    #expect(!job.uses(volume: URL(fileURLWithPath: "/")))
}

@Test func finishingRecordsHistoryAndRequeueClearsDiskSuspension() {
    var job = TransferJob(source: URL(fileURLWithPath: "/a"), destination: URL(fileURLWithPath: "/b"))
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    job.startedAt = start
    job.progress = TransferProgress(bytesTransferred: 4_096, fraction: 0.4, filesTransferred: 7)
    JobQueue.finish(&job, with: JobResult(kind: .cancelled), at: start.addingTimeInterval(30))
    job.suspendedForDisk = true
    JobQueue.requeue(&job)
    #expect(!job.suspendedForDisk)
    job.startedAt = start.addingTimeInterval(100)
    job.progress = TransferProgress(bytesTransferred: 10_000, fraction: 1, filesTransferred: 12)
    JobQueue.finish(&job, with: JobResult(kind: .succeeded, snapshot: "2026-01-01-000000", differenceCount: 0), at: start.addingTimeInterval(160))
    #expect(job.history.count == 2)
    #expect(job.history[0].result.kind == .cancelled)
    #expect(job.history[0].bytesTransferred == 4_096 && job.history[0].filesTransferred == 7)
    #expect(job.history[0].duration == 30)
    #expect(job.history[1].result.snapshot == "2026-01-01-000000")
    #expect(job.history[1].duration == 60)
    // Doğrulama farkı bulan iş "hatalı" biter.
    JobQueue.finish(&job, with: JobResult(kind: .verificationFailed, differenceCount: 3))
    #expect(job.status == .failed)
    #expect(!JobResultKind.verificationFailed.isSuccess)
    #expect(JobStatus.verifying.isActive && !JobQueue.canEdit({ var j = job; j.status = .verifying; return j }()))
    #expect(JobQueue.canEdit(job))

    for index in 0..<(TransferJob.maxHistoryEntries + 20) {
        job.appendRun(JobRun(startedAt: start.addingTimeInterval(Double(index)), finishedAt: start, result: JobResult(kind: .succeeded)))
    }
    #expect(job.history.count == TransferJob.maxHistoryEntries)
    #expect(job.history.last?.startedAt == start.addingTimeInterval(Double(TransferJob.maxHistoryEntries + 19)))
}

/// Yeni alanlar eski kayıtlarda yoktur; daha yeni bir sürümün bilinmeyen değerleri öteki ayarları silmez.
@Test func newFieldsDecodeTolerantly() throws {
    let json = """
    {"version": 1, "jobs": [
      {"id": "8B0F5C9E-3E1B-4D57-9D44-2D1D7C1D2A21", "source": "file:///Users/x/A", "destination": "file:///Volumes/B",
       "status": "verifying",
       "options": {"verifyAfterCopy": "bitByBit", "runWhenConnected": true,
                   "snapshots": {"enabled": true, "keepDaily": 7},
                   "advanced": {"excludePresets": ["developer", "hologram", "macOSJunk"], "hardLinks": true}},
       "history": [{"startedAt": "2026-01-01T10:00:00Z", "result": {"kind": "succeeded", "snapshot": "2026-01-01-100000"}},
                   {"broken": true}],
       "suspendedForDisk": true}
    ]}
    """
    let workspace = try Workspace()
    let url = workspace.url("jobs.json")
    try Data(json.utf8).write(to: url)
    let job = try #require(try JobStore(url: url).load().first)
    #expect(job.status == .verifying)
    #expect(job.options.verifyAfterCopy == .off)
    #expect(job.options.runWhenConnected)
    #expect(job.options.snapshots == SnapshotOptions(enabled: true, keepDaily: 7))
    #expect(job.options.advanced.excludePresets == [.developer, .macOSJunk])
    #expect(job.options.advanced.hardLinks)
    #expect(job.suspendedForDisk)
    // Bozuk bir geçmiş satırı tüm geçmişi düşürür ama işi silmez.
    #expect(job.history.isEmpty || job.history.count == 1)
    // Uygulama açılırken doğrulanan iş de "kesildi" olur.
    #expect(JobQueue.restoredAfterLaunch([job])[0].status == .paused)
}

// MARK: - Hazır dışlama listeleri

@Test func excludePresetsComeAfterUserRules() {
    var advanced = AdvancedOptions()
    advanced.includePatterns = ["node_modules/onemli/"]
    advanced.excludePresets = [.macOSJunk, .developer]
    let job = TransferJob(source: URL(fileURLWithPath: "/a"), destination: URL(fileURLWithPath: "/b"), options: CopyOptions(advanced: advanced))
    let environment = RsyncCommand.Environment(engine: fullEngine, destinationFileSystem: .apfs, sourceIsDirectory: true)
    let arguments = RsyncCommand.transfer(job, environment: environment)
    let include = arguments.firstIndex(of: "--include=node_modules/onemli/")
    let developer = arguments.firstIndex(of: "--exclude=node_modules/")
    let junk = arguments.firstIndex(of: "--exclude=.DS_Store")
    #expect(include != nil && developer != nil && junk != nil)
    if let include, let developer, let junk {
        #expect(include < developer)
        // Listeler her zaman aynı sırada (ExcludePreset.allCases) verilir.
        #expect(developer < junk)
    }
    #expect(!arguments.contains("--exclude=.git"))
    // Doğrulama da aynı listeleri kullanır.
    #expect(RsyncCommand.verify(job, environment: environment, checksum: false).contains("--exclude=node_modules/"))
    for preset in ExcludePreset.allCases {
        #expect(!preset.patterns.isEmpty)
        #expect(preset.patterns.allSatisfy(AdvancedOptions.isValidPattern))
    }
}

@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct ExcludePresetEngineTests {
    @Test func presetsSkipBuildFoldersAndRepositories() async throws {
        let workspace = try Workspace()
        try workspace.write("Kaynak/app/main.swift", "print(1)\n")
        try workspace.write("Kaynak/app/node_modules/x/index.js", "x\n")
        try workspace.write("Kaynak/app/.git/HEAD", "ref\n")
        try workspace.write("Kaynak/alt/.git", "gitdir: ../x\n")
        try workspace.write("Kaynak/.DS_Store", "ds\n")
        try workspace.write("Kaynak/Library/Caches/c.bin", "cache\n")
        try workspace.write("Kaynak/Caches/benim.txt", "kullanıcı klasörü\n")
        try workspace.mkdir("Hedef")
        var advanced = AdvancedOptions()
        advanced.excludePresets = ExcludePreset.allCases
        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"), options: CopyOptions(advanced: advanced))
        let result = await RsyncEngine().run(job, context: try await engineContext()) { _ in }
        #expect(result.kind == .succeeded, "\(result)")
        #expect(workspace.exists("Hedef/Kaynak/app/main.swift"))
        #expect(!workspace.exists("Hedef/Kaynak/app/node_modules"))
        #expect(!workspace.exists("Hedef/Kaynak/app/.git"))
        #expect(!workspace.exists("Hedef/Kaynak/alt/.git"))
        #expect(!workspace.exists("Hedef/Kaynak/.DS_Store"))
        #expect(!workspace.exists("Hedef/Kaynak/Library/Caches"))
        // Yalnızca adı "Caches" olan bir klasör dışlanmaz (kalıp yolun sonuyla eşleşir).
        #expect(workspace.exists("Hedef/Kaynak/Caches/benim.txt"))
    }
}

// MARK: - Yetim süreç koruması

@Suite(.serialized)
struct ChildProcessGuardTests {
    /// Üst süreci ölmüş (launchd'ye geçmiş) bir `sleep` başlatır: yetim kalmış bir rsync gibi.
    private func spawnOrphan() async throws -> pid_t {
        let result = try await CommandRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
            .run(["-c", "/bin/sleep 30 >/dev/null 2>&1 </dev/null & echo $!"], timeout: 10)
        let pid = try #require(pid_t(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        // Kabuk çıktı; sleep'in üst süreci launchd olur.
        for _ in 0..<40 where ChildProcessGuard.bsdInfo(pid)?.pbi_ppid != 1 { try await Task.sleep(for: .milliseconds(50)) }
        return pid
    }

    private func isRunning(_ pid: pid_t) -> Bool {
        guard let info = ChildProcessGuard.bsdInfo(pid) else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }

    @Test func reapsOnlyMatchingOrphans() async throws {
        let workspace = try Workspace()
        let file = workspace.url("running.json")
        let orphan = try await spawnOrphan()
        defer { kill(orphan, SIGKILL) }
        let decoy = try await spawnOrphan()
        defer { kill(decoy, SIGKILL) }
        // Kendi çocuğumuz (üst süreci yaşıyor) yetim değildir.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }

        var mismatched = try #require(ChildProcessGuard.record(for: decoy, name: "rsync"))
        mismatched.startMicroseconds &+= 1
        let records = [try #require(ChildProcessGuard.record(for: orphan, name: "rsync")), mismatched,
                       try #require(ChildProcessGuard.record(for: child.processIdentifier, name: "rsync")),
                       ChildProcessGuard.Record(pid: 999_999, startSeconds: 1, startMicroseconds: 1, name: "rsync")]
        try JSONEncoder().encode(records).write(to: file)

        let reaped = ChildProcessGuard.reapOrphans(stateFile: file, gracePeriod: 3)
        #expect(reaped.map(\.pid) == [orphan])
        for _ in 0..<40 where isRunning(orphan) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!isRunning(orphan))
        #expect(isRunning(decoy))
        #expect(child.isRunning)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Dosya yoksa ya da bozuksa hiçbir şey yapılmaz.
        #expect(ChildProcessGuard.reapOrphans(stateFile: file).isEmpty)
        try Data("bozuk".utf8).write(to: file)
        #expect(ChildProcessGuard.reapOrphans(stateFile: file).isEmpty)
    }

    /// `CommandRunner` her süreci çalışırken kaydeder, bitince siler. (Kayıt dosyası küresel bir ayardır; paralel
    /// testler birbirini bozmasın diye dosyaya yazma uygulama testinde, açılıştaki temizlikle birlikte denetlenir.)
    @Test func runnerRegistersRunningProcesses() async throws {
        let workspace = try Workspace()
        let marker = workspace.url("basladi")
        let runner = CommandRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let task = Task { try await runner.run(["-c", "echo $$ > '\(marker.path)'; exec /bin/sleep 2"]) }
        var pid: pid_t?
        for _ in 0..<60 {
            if let text = workspace.read("basladi"), let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                pid = value
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let running = try #require(pid)
        #expect(ChildProcessGuard.registeredPIDs.contains(running))
        _ = try await task.value
        #expect(!ChildProcessGuard.registeredPIDs.contains(running))
    }

    /// Uygulama bir sinyalle sonlanırken (çökme ya da SIGTERM) kayıtlı alt süreçler de durdurulur. Ayrı bir süreçte.
    @Test func crashHandlerStopsRegisteredChildren() async throws {
        let workspace = try Workspace()
        let pidFile = workspace.url("child.pid").path
        await #expect(processExitsWith: .signal(SIGTERM)) { [pidFile = pidFile as String] in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["30"]
            try child.run()
            ChildProcessGuard.register(child.processIdentifier, name: "sleep")
            try Data(String(child.processIdentifier).utf8).write(to: URL(fileURLWithPath: pidFile))
            ChildProcessGuard.installCrashHandlers()
            raise(SIGTERM)
            // Buraya gelinmez.
            sleep(5)
        }
        let pid = try #require(pid_t(String(decoding: try Data(contentsOf: URL(fileURLWithPath: pidFile)), as: UTF8.self)))
        defer { kill(pid, SIGKILL) }
        for _ in 0..<60 where isRunning(pid) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!isRunning(pid))
    }
}
