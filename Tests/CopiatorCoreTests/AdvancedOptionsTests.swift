// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

private func job(_ options: AdvancedOptions, delete: Bool = false, mode: CopyMode = .folder) -> TransferJob {
    TransferJob(source: URL(fileURLWithPath: "/Users/x/Proje"), destination: URL(fileURLWithPath: "/Volumes/Yedek"),
                options: CopyOptions(copyMode: mode, deleteExtraneous: delete, excludeSystemFolders: false, advanced: options))
}

private func env(_ fs: FileSystemKind = .apfs, engine: EngineInfo = fullEngine, protected: [String] = []) -> RsyncCommand.Environment {
    RsyncCommand.Environment(engine: engine, destinationFileSystem: fs, sourceIsDirectory: true, protectedPaths: protected)
}

// MARK: - Varsayılanlar ve kodlama

/// Varsayılan gelişmiş seçenekler hiçbir ek argüman üretmez: komut eskisiyle birebir aynı kalır.
@Test func defaultAdvancedOptionsChangeNothing() {
    #expect(AdvancedOptions().isDefault)
    let arguments = RsyncCommand.transfer(job(AdvancedOptions()), environment: env())
    #expect(arguments == ["-rltDhX", "--info=progress2", "--partial", "--exclude=/" + ArchiveIntegrity.manifestName, "--", "/Users/x/Proje",
                          "/Volumes/Yedek/"])
}

@Test func advancedOptionsRoundTripAndDecodeTolerantly() throws {
    var options = AdvancedOptions()
    options.excludePatterns = ["*.tmp", "/Önbellek/"]
    options.hardLinks = true
    options.referenceMode = .linkDest
    options.referenceDirectory = "/Volumes/Yedek/2026-10-20"
    options.stopAt = Date(timeIntervalSince1970: 1_900_000_000)
    options.maxSizeBytes = 5 << 30
    let data = try JSONEncoder().encode(options)
    #expect(try JSONDecoder().decode(AdvancedOptions.self, from: data) == options)
    // Eksik alanlar varsayılan, bilinmeyen değerler varsayılana düşer, fazla alanlar yok sayılır.
    let partial = #"{"hardLinks": true, "symlinks": "teleport", "progressDetail": "perFile", "future": 42}"#
    let decoded = try JSONDecoder().decode(AdvancedOptions.self, from: Data(partial.utf8))
    #expect(decoded.hardLinks)
    #expect(decoded.symlinks == .preserve)
    #expect(decoded.progressDetail == .perFile)
    #expect(decoded.excludePatterns.isEmpty)
    // Eski bir iş kaydı (gelişmiş alan yok) okunur.
    let legacy = #"{"copyMode": "contents", "deleteExtraneous": true}"#
    let copy = try JSONDecoder().decode(CopyOptions.self, from: Data(legacy.utf8))
    #expect(copy.advanced.isDefault)
    #expect(copy.copyMode == .contents)
}

// MARK: - Doğrulama

@Test func validatesValuesAndPaths() throws {
    var options = AdvancedOptions()
    #expect(options.problems(source: nil).isEmpty)
    options.excludePatterns = ["", "a\nb"]
    options.chmod = "D755;F644"
    options.iconv = "utf-8 mac"
    options.backupSuffix = "a/b"
    options.maxDelete = -1
    options.stopAfterMinutes = 0
    options.stopAt = Date(timeIntervalSince1970: 0)
    options.referenceMode = .linkDest
    options.batchMode = .write
    options.logFile = "goreli/gunluk.txt"
    let problems = options.problems(source: nil, now: Date(timeIntervalSince1970: 100))
    #expect(problems.contains(.invalidPattern("")))
    #expect(problems.contains(.invalidPattern("a\nb")))
    #expect(problems.contains(.invalidChmod))
    #expect(problems.contains(.invalidIconv))
    #expect(problems.contains(.invalidSuffix))
    #expect(problems.contains(.invalidNumber))
    #expect(problems.contains(.stopAtInPast))
    #expect(problems.contains(.missingReferenceDirectory))
    #expect(problems.contains(.missingBatchFile))
    #expect(problems.contains(.pathNotAbsolute("logFile")))

    #expect(AdvancedOptions.isValidChmod("D755,F644"))
    #expect(AdvancedOptions.isValidChmod("u+rwX,go-w"))
    #expect(!AdvancedOptions.isValidChmod("755,"))
    #expect(AdvancedOptions.isValidIconv("utf-8-mac,utf-8"))
    #expect(AdvancedOptions.isValidIconv("."))
    #expect(!AdvancedOptions.isValidIconv("a,b,c"))
    #expect(AdvancedOptions.isValidSuffix("~"))
}

/// rsync'in yazacağı yollar (günlük, toplu iş, eski sürümler) kaynağın içinde olamaz: kaynak salt okunurdur.
@Test func writtenPathsMustStayOutsideTheSource() throws {
    let workspace = try Workspace()
    let source = try workspace.mkdir("Kaynak")
    var options = AdvancedOptions()
    options.logFile = source.appendingPathComponent("gunluk.txt").path
    options.batchMode = .write
    options.batchFile = workspace.url("disarida.batch").path
    options.keepBackups = true
    options.backupDirectory = source.appendingPathComponent("eski").path
    let problems = options.problems(source: source)
    #expect(problems.contains(.writesInsideSource("logFile")))
    #expect(problems.contains(.writesInsideSource("backupDirectory")))
    #expect(!problems.contains(.writesInsideSource("batchFile")))
}

@Test func stopAtUsesRsyncFormatInLocalTime() {
    let date = Date(timeIntervalSince1970: 1_792_000_000)
    let utc = AdvancedOptions.stopAtArgument(date, timeZone: TimeZone(identifier: "UTC")!)
    #expect(utc == "2026-10-14T17:46")
    let istanbul = AdvancedOptions.stopAtArgument(date, timeZone: TimeZone(identifier: "Europe/Istanbul")!)
    #expect(istanbul == "2026-10-14T20:46")
}

// MARK: - Argümanlar

/// Her seçenek rsync'in kendi bayrağına çevrilir.
@Test func everyOptionMapsToItsRsyncFlag() {
    var o = AdvancedOptions()
    o.filterRules = ["- *.log"]
    o.includePatterns = ["*/", "*.jpg"]
    o.excludePatterns = ["*"]
    o.useFilterFiles = true
    o.includeFromFile = "/l/inc.txt"
    o.excludeFromFile = "/l/exc.txt"
    o.filesFromFile = "/l/files.txt"
    o.maxSizeBytes = 1000
    o.minSizeBytes = 10
    o.ignoreExisting = true
    o.existingOnly = true
    o.updateOnly = true
    o.pruneEmptyDirectories = true
    o.hardLinks = true
    o.creationTimes = true
    o.accessTimes = true
    o.numericIDs = true
    o.oneFileSystem = true
    o.chmod = "D755,F644"
    o.symlinks = .copyTargets
    o.sparse = true
    o.inplace = true
    o.wholeFile = true
    o.appendMode = .appendVerify
    o.sizeOnly = true
    o.modifyWindowSeconds = 3
    o.bandwidthLimitKiB = 500
    o.stopAfterMinutes = 30
    o.iconv = "utf-8-mac,utf-8"
    o.referenceMode = .linkDest
    o.referenceDirectory = "/Volumes/Yedek/onceki"
    o.keepBackups = true
    o.backupDirectory = "/Volumes/Yedek/eski"
    o.backupSuffix = ".eski"
    o.progressDetail = .perFile
    o.showFileNames = true
    o.fileListProgress = true
    o.showStats = true
    o.logChanges = true
    o.preciseProgress = true
    o.logFile = "/l/rsync.log"
    o.batchMode = .onlyWrite
    o.batchFile = "/l/degisiklik"
    let arguments = RsyncCommand.transfer(job(o), environment: env())
    let expected = [
        "--info=progress1,name1,flist2,stats2", "--no-inc-recursive", "-i", "--ignore-existing", "--existing", "-u", "-m",
        "--max-size=1000", "--min-size=10", "-H", "-N", "-U", "--numeric-ids", "-x", "--chmod=D755,F644", "-L", "--size-only",
        "--modify-window=3", "--iconv=utf-8-mac,utf-8", "--link-dest=/Volumes/Yedek/onceki", "--sparse", "--inplace", "-W",
        "--append-verify", "--bwlimit=500", "--stop-after=30", "-b", "--backup-dir=/Volumes/Yedek/eski", "--suffix=.eski",
        "--log-file=/l/rsync.log", "--only-write-batch=/l/degisiklik", "--filter=- *.log", "--include=*/", "--include=*.jpg",
        "--exclude=*", "-F", "--include-from=/l/inc.txt", "--exclude-from=/l/exc.txt", "--files-from=/l/files.txt",
    ]
    for flag in expected { #expect(arguments.contains(flag), "\(flag)") }
    #expect(arguments.suffix(3) == ["--", "/Users/x/Proje", "/Volumes/Yedek/"])
    // Silme ayrıntıları yalnızca --delete ile.
    #expect(!arguments.contains { $0.hasPrefix("--delete") || $0 == "--ignore-errors" || $0.hasPrefix("--max-delete") })
}

@Test func symlinkAndReferenceAndBatchVariants() {
    var o = AdvancedOptions()
    o.symlinks = .copyUnsafeTargets
    o.referenceMode = .compareDest
    o.referenceDirectory = "/r"
    o.batchMode = .write
    o.batchFile = "/b"
    o.appendMode = .append
    var a = RsyncCommand.transfer(job(o), environment: env())
    #expect(a.contains("--copy-unsafe-links") && a.contains("--compare-dest=/r") && a.contains("--write-batch=/b") && a.contains("--append"))
    o.symlinks = .skipUnsafe
    o.referenceMode = .copyDest
    a = RsyncCommand.transfer(job(o), environment: env())
    #expect(a.contains("--safe-links") && a.contains("--copy-dest=/r"))
    // Kesin ilerleme olmadan liste sayacı (flist2) verilmez.
    o.fileListProgress = true
    #expect(RsyncCommand.transfer(job(o), environment: env()).contains("--info=progress2"))
}

@Test func deleteDetailsOnlyWithDelete() {
    var o = AdvancedOptions()
    o.deleteTiming = .delay
    o.deleteExcluded = true
    o.maxDelete = 100
    o.ignoreErrors = true
    let arguments = RsyncCommand.transfer(job(o, delete: true), environment: env())
    for flag in ["--delete", "--delete-delay", "--delete-excluded", "--max-delete=100", "--ignore-errors"] {
        #expect(arguments.contains(flag), "\(flag)")
    }
    for (timing, flag) in [(DeleteTiming.before, "--delete-before"), (.after, "--delete-after")] {
        o.deleteTiming = timing
        #expect(RsyncCommand.transfer(job(o, delete: true), environment: env()).contains(flag))
    }
}

/// Kişisel klasör dışlamaları kullanıcının kurallarından önce gelir: bir `--include` onları geri alamaz.
@Test func protectedExclusionsComeBeforeUserRules() {
    var o = AdvancedOptions()
    o.includePatterns = [".ssh/***"]
    let arguments = RsyncCommand.transfer(job(o), environment: env(protected: [".ssh"]))
    let protected = arguments.firstIndex(of: "--exclude=/Proje/.ssh")
    let userInclude = arguments.firstIndex(of: "--include=.ssh/***")
    #expect(protected != nil && userInclude != nil)
    #expect(protected! < userInclude!)
}

/// Doğrulama karşılaştırmayı etkileyen seçenekleri alır, yazmayı ve çıktıyı etkileyenleri almaz.
@Test func verifyKeepsComparisonOptionsOnly() {
    var o = AdvancedOptions()
    o.excludePatterns = ["*.tmp"]
    o.hardLinks = true
    o.sizeOnly = true
    o.referenceMode = .linkDest
    o.referenceDirectory = "/r"
    o.logFile = "/l/x.log"
    o.batchMode = .write
    o.batchFile = "/b"
    o.bandwidthLimitKiB = 10
    o.stopAfterMinutes = 5
    o.keepBackups = true
    o.inplace = true
    o.showStats = true
    o.logChanges = true
    o.deleteExcluded = true
    o.maxDelete = 3
    let arguments = RsyncCommand.verify(job(o, delete: true), environment: env(), checksum: false)
    for flag in ["--exclude=*.tmp", "-H", "--size-only", "--link-dest=/r", "--delete", "--delete-excluded", "-n", "-i"] {
        #expect(arguments.contains(flag), "\(flag)")
    }
    for prefix in ["--log-file", "--write-batch", "--bwlimit", "--stop-after", "-b", "--inplace", "--info", "--max-delete"] {
        #expect(!arguments.contains { $0 == prefix || $0.hasPrefix(prefix + "=") }, "\(prefix)")
    }
}

@Test func fatWindowNeverBelowOneSecond() {
    var o = AdvancedOptions()
    #expect(RsyncCommand.transfer(job(o), environment: env(.fat)).contains("--modify-window=1"))
    o.modifyWindowSeconds = 5
    let fat = RsyncCommand.transfer(job(o), environment: env(.fat))
    #expect(fat.contains("--modify-window=5") && !fat.contains("--modify-window=1"))
    o.modifyWindowSeconds = 0
    #expect(RsyncCommand.transfer(job(o), environment: env(.fat)).contains("--modify-window=1"))
    #expect(RsyncCommand.transfer(job(o), environment: env(.apfs)).contains("--modify-window=0"))
}

/// macOS'un openrsync'i desteklemediği seçenekleri almaz; bunlar iş günlüğünde bildirilir.
@Test func openrsyncDropsUnsupportedOptions() {
    var o = AdvancedOptions()
    o.creationTimes = true
    o.iconv = "utf-8-mac,utf-8"
    o.stopAfterMinutes = 5
    o.logFile = "/l/x.log"
    o.showFileNames = true
    o.hardLinks = true
    let arguments = RsyncCommand.transfer(job(o), environment: env(engine: openrsyncEngine))
    #expect(!arguments.contains("-N") && !arguments.contains { $0.hasPrefix("--iconv") || $0.hasPrefix("--stop-after") || $0.hasPrefix("--log-file") || $0.hasPrefix("--info") })
    #expect(arguments.contains("-H"))
    let dropped = RsyncCommand.droppedOptions(job(o), environment: env(engine: openrsyncEngine))
    #expect(Set(dropped) == ["-X", "-N", "--iconv", "--stop-after", "--log-file", "--info"])
    #expect(RsyncCommand.droppedOptions(job(o), environment: env()).isEmpty)
}

@Test func commandDisplayQuotesForTheShell() {
    let shown = RsyncCommand.displayString(arguments: ["-rltDhX", "--exclude=*.tmp", "--", "/Users/x/Fotoğraflar 2026", "/Volumes/Yedek/", "it's"])
    #expect(shown == "rsync -rltDhX '--exclude=*.tmp' -- '/Users/x/Fotoğraflar 2026' /Volumes/Yedek/ 'it'\\''s'")
}

// MARK: - Sonuç sınıfı

/// `--stop-at`/`--stop-after` sınırında rsync 30 koduyla çıkar; iş sürdürülebilir (duraklatıldı).
@Test func stopLimitIsResumable() {
    let stderr = "stopping at requested limit\nrsync error: timeout in data send/receive (code 30) at io.c(945) [sender=3.5.1]"
    let result = RsyncOutcome.classify(exitCode: 30, stderr: stderr, destinationFileSystem: .apfs)
    #expect(result.kind == .stoppedAtLimit)
    var job = job(AdvancedOptions())
    job.status = .copying
    JobQueue.finish(&job, with: result)
    #expect(job.status == .paused)
    #expect(JobQueue.canResume(job))
    // Gerçek bir zaman aşımı sürdürülebilir sayılmaz.
    #expect(RsyncOutcome.classify(exitCode: 30, stderr: "rsync error: timeout in data send/receive (code 30)", destinationFileSystem: .apfs).kind == .ioError)
}

// MARK: - Kum havuzu

@Test func sandboxGetsOnlyTheExtraPathsItNeeds() throws {
    let workspace = try Workspace()
    let home = workspace.url("ev")
    try workspace.write("ev/.ssh/liste.txt", "a\n")
    var o = AdvancedOptions()
    o.filesFromFile = workspace.url("ev/.ssh/liste.txt").path
    o.logFile = workspace.url("gunluk/rsync.log").path
    o.batchMode = .write
    o.batchFile = workspace.url("gunluk/toplu").path
    o.keepBackups = true
    o.backupDirectory = workspace.url("eski").path
    let profile = SandboxProfile.forTransfer(
        sources: [workspace.url("Kaynak")], destination: workspace.url("Hedef"), home: home,
        extraReadable: o.readablePaths, extraWritableFiles: o.writableFiles, extraWritableDirectories: o.writableDirectories
    )
    #expect(profile.readableFiles.map(\.lastPathComponent).contains("liste.txt"))
    #expect(profile.writableFiles.map(\.lastPathComponent) == ["rsync.log", "toplu", "toplu.sh"])
    #expect(profile.writableDirectories.map(\.lastPathComponent) == ["Hedef", "eski"])
    #expect(profile.profileText.contains("(literal (param \"A0\"))"))
    let arguments = profile.launchArguments(executable: URL(fileURLWithPath: "/a/rsync"), arguments: [])
    #expect(arguments.contains { $0.hasPrefix("A2=") && $0.hasSuffix("toplu.sh") })
}

/// Yalnızca `--link-dest` önceki yedeğe yazma izni alır (macOS sabit bağlantıyı var olan dosyaya yazma sayar);
/// `--compare-dest` ve `--copy-dest` yalnızca okur. Önceki yedek kaynağın içinde olamaz.
@Test func onlyLinkDestMakesTheReferenceWritable() throws {
    var o = AdvancedOptions()
    o.referenceDirectory = "/Volumes/Yedek/onceki"
    for mode in [ReferenceMode.compareDest, .copyDest] {
        o.referenceMode = mode
        #expect(o.writableDirectories.isEmpty)
        #expect(o.readablePaths.map(\.path) == ["/Volumes/Yedek/onceki"])
    }
    o.referenceMode = .linkDest
    #expect(o.writableDirectories.map(\.path) == ["/Volumes/Yedek/onceki"])
    let workspace = try Workspace()
    let source = try workspace.mkdir("Kaynak")
    o.referenceDirectory = source.appendingPathComponent("eski").path
    #expect(o.problems(source: source).contains(.writesInsideSource("referenceDirectory")))
}

/// Liste dosyaları özel (0700) bir klasöre kopyalanır; seçenekler kopyaları gösterir, özgün dosyalar değişmez.
@Test func listFilesAreStagedPrivately() throws {
    let workspace = try Workspace()
    let list = try workspace.write("liste.txt", "a.txt\nb.txt\n")
    var o = AdvancedOptions()
    o.filesFromFile = list.path
    o.excludeFromFile = list.path
    let folder = try #require(try RsyncEngine.stageListFiles(&o))
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(o.filesFromFile != list.path && o.excludeFromFile != list.path)
    #expect(try String(contentsOfFile: try #require(o.filesFromFile), encoding: .utf8) == "a.txt\nb.txt\n")
    let mode = (try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue
    #expect(mode == 0o700)
    var none = AdvancedOptions()
    #expect(try RsyncEngine.stageListFiles(&none) == nil)
    var missing = AdvancedOptions()
    missing.filesFromFile = workspace.url("yok.txt").path
    #expect(throws: (any Error).self) { _ = try RsyncEngine.stageListFiles(&missing) }
}
