// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

// MARK: - Kodlama ve geriye uyum

@Test func jobRoundTripsThroughStore() throws {
    let workspace = try Workspace()
    let store = JobStore(url: workspace.url("Destek/jobs.json"))
    var job = TransferJob(source: URL(fileURLWithPath: "/Users/x/Fotoğraflar"), destination: URL(fileURLWithPath: "/Volumes/Yedek"),
                          options: CopyOptions(copyMode: .contents, preservePermissions: true, deleteExtraneous: true))
    job.progress = TransferProgress(bytesTransferred: 42, fraction: 0.5, filesTransferred: 3, itemsRemaining: 2, itemsTotal: 9, isEstimating: true)
    job.result = JobResult(kind: .partial, exitCode: 23, noteCount: 2, detail: "rsync: x")
    job.appendLog(JobLogEntry(level: .info, key: .logStarted, arguments: ["3.5.1"]))
    job.appendLog(JobLogEntry(level: .error, raw: "rsync: [receiver] ..."))
    try store.save([job])
    let loaded = try store.load()
    #expect(loaded.count == 1)
    #expect(loaded[0].id == job.id)
    #expect(loaded[0].options == job.options)
    #expect(loaded[0].progress == job.progress)
    #expect(loaded[0].result == job.result)
    #expect(loaded[0].log.map(\.key) == job.log.map(\.key))
    #expect(loaded[0].source == job.source)
    #expect(try store.load() == loaded)
}

@Test func missingStoreIsAnEmptyQueue() throws {
    let workspace = try Workspace()
    #expect(try JobStore(url: workspace.url("yok.json")).load().isEmpty)
}

/// Eski (ya da daha yeni bir sürümün yazdığı) kayıt: eksik alanlar varsayılanla dolar, bilinmeyen değerler işi silmez.
@Test func decodesMinimalAndForwardJobs() throws {
    let json = """
    {"version": 1, "jobs": [
      {"id": "8B0F5C9E-3E1B-4D57-9D44-2D1D7C1D2A11", "source": "file:///Users/x/A", "destination": "file:///Volumes/B"},
      {"id": "8B0F5C9E-3E1B-4D57-9D44-2D1D7C1D2A12", "source": "file:///Users/x/C", "destination": "file:///Volumes/D",
       "kind": "aria2", "status": "teleporting", "options": {"copyMode": "contents", "futureOption": true},
       "result": {"kind": "quantumFailure", "exitCode": 99}, "someNewField": [1, 2, 3]}
    ]}
    """
    let workspace = try Workspace()
    let url = workspace.url("jobs.json")
    try Data(json.utf8).write(to: url)
    let jobs = try JobStore(url: url).load()
    #expect(jobs.count == 2)
    #expect(jobs[0].kind == .rsync)
    #expect(jobs[0].status == .waiting)
    #expect(jobs[0].options == CopyOptions())
    #expect(jobs[0].log.isEmpty)
    #expect(jobs[1].kind == .rsync)
    #expect(jobs[1].status == .waiting)
    #expect(jobs[1].options.copyMode == .contents)
    #expect(jobs[1].options.excludeSystemFolders)
    #expect(jobs[1].result?.kind == .failed)
    #expect(jobs[1].result?.exitCode == 99)
}

/// Bozuk kayıt dosyası sessizce silinmez: kenara alınır, kuyruk boş başlar.
@Test func corruptStoreIsSetAside() throws {
    let workspace = try Workspace()
    let store = JobStore(url: workspace.url("jobs.json"))
    try Data("{bozuk".utf8).write(to: store.url)
    #expect(throws: (any Error).self) { try store.load() }
    let backup = try #require(store.quarantineCorruptFile(now: Date(timeIntervalSince1970: 1_000)))
    #expect(backup.lastPathComponent == "jobs.corrupt-1000.json")
    #expect(!FileManager.default.fileExists(atPath: store.url.path))
    #expect(try store.load().isEmpty)
}

@Test func logIsCapped() {
    var job = TransferJob(source: URL(fileURLWithPath: "/a"), destination: URL(fileURLWithPath: "/b"))
    for index in 0..<(TransferJob.maxLogEntries + 25) { job.appendLog(JobLogEntry(level: .info, raw: "\(index)")) }
    #expect(job.log.count == TransferJob.maxLogEntries)
    #expect(job.log.first?.raw == "25")
}

// MARK: - Hedef ve çakışma

@Test func targetDependsOnCopyMode() {
    let folder = TransferJob(source: URL(fileURLWithPath: "/a/Kaynak"), destination: URL(fileURLWithPath: "/b"))
    #expect(folder.target(sourceIsDirectory: true).path == "/b/Kaynak")
    let contents = TransferJob(source: URL(fileURLWithPath: "/a/Kaynak"), destination: URL(fileURLWithPath: "/b"), options: CopyOptions(copyMode: .contents))
    #expect(contents.target(sourceIsDirectory: true).path == "/b")
    #expect(contents.target(sourceIsDirectory: false).path == "/b/Kaynak")
}

@Test func validationRejectsOverlaps() throws {
    let workspace = try Workspace()
    let source = try workspace.mkdir("ev/Belgeler/Proje")
    try workspace.mkdir("ev/Belgeler/Proje/alt")
    let home = workspace.url("ev")
    let disk = try workspace.mkdir("Disk")
    let file = try workspace.write("ev/not.txt", "x")
    func check(_ s: URL, _ d: URL, _ mode: CopyMode = .folder) -> JobValidation.Problem? {
        JobValidation.check(source: s, destination: d, copyMode: mode)
    }
    #expect(check(source, disk) == nil)
    #expect(check(source, disk, .contents) == nil)
    // Kopya kaynağın içine düşer.
    #expect(check(source, source.appendingPathComponent("alt")) == .overlapping)
    #expect(check(source, source) == .overlapping)
    // "Klasörün kendisi" kendi üst klasörüne: karşılık kaynağın kendisi.
    #expect(check(source, source.deletingLastPathComponent()) == .overlapping)
    // Ev klasörüne "klasörün kendisi" (ev/Proje): sorun yok. "İçeriği" (ev): kaynak karşılığın içinde.
    #expect(check(source, home) == nil)
    #expect(check(source, home, .contents) == .overlapping)
    #expect(check(file, home) == .overlapping)
    #expect(check(file, disk) == nil)
    #expect(check(workspace.url("yok"), disk) == .sourceMissing)
    #expect(check(source, workspace.url("takılı değil")) == .destinationMissing)
    #expect(check(source, file) == .destinationNotDirectory)
}

// MARK: - Kuyruk kuralları

private func makeJobs(_ statuses: [JobStatus]) -> [TransferJob] {
    statuses.enumerated().map { index, status in
        TransferJob(source: URL(fileURLWithPath: "/k\(index)"), destination: URL(fileURLWithPath: "/h"), status: status)
    }
}

@Test func nextJobIsTheFirstWaitingOne() {
    let jobs = makeJobs([.finished, .paused, .waiting, .waiting])
    #expect(JobQueue.next(in: jobs) == jobs[2].id)
    #expect(JobQueue.next(in: makeJobs([.finished, .failed, .paused])) == nil)
}

/// Çalışırken kapanan iş duraklatılmış ve "kesildi" olarak geri gelir; öteki durumlar korunur.
@Test func interruptedJobsComeBackPaused() {
    let restored = JobQueue.restoredAfterLaunch(makeJobs([.copying, .scanning, .waiting, .finished]))
    #expect(restored.map(\.status) == [.paused, .paused, .waiting, .finished])
    #expect(restored.map(\.wasInterrupted) == [true, true, false, false])
}

@Test func transitionsFollowEventsAndResults() {
    var job = makeJobs([.waiting])[0]
    JobQueue.apply(.phase(.scanning), to: &job)
    #expect(job.status == .scanning)
    JobQueue.apply(.progress(TransferProgress(bytesTransferred: 10, fraction: 0.4)), to: &job)
    #expect(job.status == .copying)
    #expect(job.progress?.bytesTransferred == 10)
    JobQueue.apply(.log(JobLogEntry(level: .info, raw: "x")), to: &job)
    #expect(job.log.count == 1)

    var paused = job
    JobQueue.finish(&paused, with: JobResult(kind: .cancelled))
    #expect(paused.status == .paused)
    #expect(JobQueue.canResume(paused))

    var finished = job
    JobQueue.finish(&finished, with: JobResult(kind: .succeededWithNotes, noteCount: 3))
    #expect(finished.status == .finished)
    #expect(finished.progress?.fraction == 1)
    #expect(JobQueue.canRunAgain(finished))

    var failed = job
    JobQueue.finish(&failed, with: JobResult(kind: .partial))
    #expect(failed.status == .failed)
    JobQueue.requeue(&failed)
    #expect(failed.status == .waiting && failed.result == nil)
}

@Test func activeJobsCannotBeRemovedOrVerified() {
    for status in [JobStatus.scanning, .copying] {
        let job = makeJobs([status])[0]
        #expect(!JobQueue.canRemove(job))
        #expect(!JobQueue.canVerify(job))
        #expect(JobQueue.canPause(job))
    }
    #expect(JobQueue.canRemove(makeJobs([.finished])[0]))
}

@Test func moveMatchesSwiftUIOnMoveSemantics() {
    var jobs = makeJobs([.waiting, .waiting, .waiting, .waiting])
    let ids = jobs.map(\.id)
    JobQueue.move(&jobs, from: [0], to: 3)
    #expect(jobs.map(\.id) == [ids[1], ids[2], ids[0], ids[3]])
    JobQueue.move(&jobs, from: [3], to: 0)
    #expect(jobs.map(\.id) == [ids[3], ids[1], ids[2], ids[0]])
    JobQueue.move(&jobs, from: [0, 1], to: 4)
    #expect(jobs.map(\.id) == [ids[2], ids[0], ids[3], ids[1]])
    JobQueue.move(&jobs, from: [99], to: 0)
    #expect(jobs.count == 4)
}

// MARK: - Disk alanı ve dosya sistemi

@Test func diskSpaceArithmeticSaturates() {
    #expect(Int64.max.saturatingAdding(1) == .max)
    #expect(Int64.min.saturatingAdding(-1) == .min)
    #expect([Int64.max, 5, 7].saturatingSum() == .max)
    #expect(DiskSpace.hasRoom(required: 10, available: nil))
    #expect(DiskSpace.hasRoom(required: 10, available: DiskSpace.reserve + 10))
    #expect(!DiskSpace.hasRoom(required: 11, available: DiskSpace.reserve + 10))
    #expect(!DiskSpace.hasRoom(required: 1, available: 5))
}

/// Pay ve taban birime göre ölçeklenir: büyük birimlerde 1 GB / 512 MB, küçük bir USB bellekte %2 / %1.
@Test func reserveScalesWithVolumeSize() {
    #expect(DiskSpace.reserve(forVolumeCapacity: 500_000_000_000) == DiskSpace.reserve)
    #expect(DiskSpaceGuard.floor(forVolumeCapacity: 500_000_000_000) == DiskSpaceGuard.floor)
    #expect(DiskSpace.reserve(forVolumeCapacity: 1_000_000_000) == 20_000_000)
    #expect(DiskSpaceGuard.floor(forVolumeCapacity: 1_000_000_000) == 10_000_000)
    #expect(DiskSpace.reserve(forVolumeCapacity: nil) == DiskSpace.reserve)
    #expect(DiskSpace.reserve(forVolumeCapacity: 0) == DiskSpace.reserve)
}

@Test func totalSizeCountsHiddenFilesButNotLinks() throws {
    let workspace = try Workspace()
    try workspace.write("k/a", String(repeating: "a", count: 100))
    try workspace.write("k/._b", String(repeating: "b", count: 50))
    try workspace.write("k/alt/c", String(repeating: "c", count: 25))
    try FileManager.default.createSymbolicLink(atPath: workspace.url("k/bag").path, withDestinationPath: workspace.url("k/a").path)
    #expect(DiskSpace.totalSize(of: [workspace.url("k")]) == 175)
    #expect(DiskSpace.totalSize(of: [workspace.url("k/a"), workspace.url("yok")]) == 100)
    #expect(DiskSpace.totalSize(of: [workspace.url("k")], isCancelled: { true }) == 0)
}

/// Kopyalama sürerken boş alan tabanın altına inerse iş durdurulur.
@Test func diskGuardStopsWhenSpaceRunsOut() async throws {
    let free = Collected<Int64>()
    await #expect(throws: InsufficientSpaceError.self) {
        try await DiskSpaceGuard.run(watching: URL(fileURLWithPath: "/"), floor: 100, interval: .milliseconds(20), available: {
            free.add(1)
            return free.values.count > 3 ? 50 : 1_000
        }) {
            try await Task.sleep(for: .seconds(10))
            return 1
        }
    }
    let value = try await DiskSpaceGuard.run(watching: URL(fileURLWithPath: "/"), floor: 100, interval: .milliseconds(20), available: { 1_000 }) { 7 }
    #expect(value == 7)
}

@Test(arguments: [("apfs", FileSystemKind.apfs), ("hfs", .hfs), ("exfat", .exfat), ("msdos", .fat), ("smbfs", .network),
                  ("ntfs", .ntfs), ("zfs", .other)])
func fileSystemNames(name: String, kind: FileSystemKind) {
    #expect(FileSystemKind(typeName: name) == kind)
}

@Test func detectsLocalFileSystem() throws {
    let workspace = try Workspace()
    let kind = FileSystemKind.of(workspace.url("henuz/yok"))
    #expect(kind == .apfs || kind == .hfs)
    #expect(!kind.lacksPosixMetadata)
    #expect(FileSystemKind.fat.hasCoarseTimestamps && !FileSystemKind.exfat.hasCoarseTimestamps)
    #expect(FileSystemKind.exfat.lacksPosixMetadata)
}

// MARK: - Uyku engeli

@Test func sleepAssertionIsHeldAndReleased() {
    let name = "Copiator test \(UUID().uuidString)"
    let assertion = SleepAssertion(reason: name)
    #expect(!assertion.isHeld)
    #expect(assertion.acquire())
    #expect(assertion.acquire())
    #expect(assertion.isHeld)
    #expect(SleepAssertion.activeAssertionNames().contains(name))
    assertion.release()
    #expect(!assertion.isHeld)
    #expect(!SleepAssertion.activeAssertionNames().contains(name))
    assertion.release()
}

@Test func sleepAssertionIsReleasedOnDeinit() {
    let name = "Copiator deinit \(UUID().uuidString)"
    do {
        let assertion = SleepAssertion(reason: name)
        assertion.acquire()
        #expect(SleepAssertion.activeAssertionNames().contains(name))
    }
    #expect(!SleepAssertion.activeAssertionNames().contains(name))
}

// MARK: - Karantina

@Test func quarantinePropagatesOnlyToFreshCounterparts() throws {
    let workspace = try Workspace()
    let value = "0083;5f000000;Safari;ABC"
    let source = try workspace.write("k/indirilen.app/Contents/MacOS/run", "x")
    try workspace.write("k/yerel.txt", "y")
    #expect(setxattr(source.path, "com.apple.quarantine", value, value.utf8.count, 0, XATTR_NOFOLLOW) == 0)
    let start = Date()
    try workspace.write("h/k/indirilen.app/Contents/MacOS/run", "x")
    try workspace.write("h/k/yerel.txt", "y")
    chmod(workspace.url("h/k/indirilen.app/Contents/MacOS/run").path, 0o555)

    #expect(Quarantine.propagate(from: workspace.url("k"), to: workspace.url("h/k"), since: start) == 1)
    #expect(Quarantine.value(of: workspace.url("h/k/indirilen.app/Contents/MacOS/run")) == value)
    #expect(Quarantine.value(of: workspace.url("h/k/yerel.txt")) == nil)
    // Salt okunur dosyanın kipi geri yüklenir.
    var info = stat()
    lstat(workspace.url("h/k/indirilen.app/Contents/MacOS/run").path, &info)
    #expect(info.st_mode & 0o777 == 0o555)
    // İkinci kez: zaten işaretli, sayılmaz.
    #expect(Quarantine.propagate(from: workspace.url("k"), to: workspace.url("h/k"), since: start) == 0)
    // Eski (kopyalamadan önce var olan) hedef öğelere dokunulmaz.
    #expect(Quarantine.propagate(from: workspace.url("k"), to: workspace.url("h/k"), since: Date().addingTimeInterval(60)) == 0)
}
