// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

@Test func detectorReadsItemizeAllOutput() {
    // Gerçek rsync 3.5.1 `-n -ii` çıktısı: değişmeyen ve değişen dosyalar çakışma, yeniler ve klasörler değil.
    let output = """
    .d          src/
    .f          src/a.txt
    >f+++++++++ src/yeni.txt
    .d          src/alt/
    >f.s....... src/alt/b.txt
    cL+++++++++ src/bag -> a.txt
    .L          src/eski-bag -> a.txt
    >f.st...... src/ad\\#012satir.txt
    *deleting   src/fazla.txt
    """
    let conflicts = ConflictDetector.conflicts(in: output, format: .rsync3)
    #expect(conflicts == [
        FileConflict(path: "src/a.txt", identical: true),
        FileConflict(path: "src/alt/b.txt", identical: false),
        FileConflict(path: "src/ad\nsatir.txt", identical: false),
    ])
    // openrsync: 9 sütun.
    let open = ConflictDetector.conflicts(in: ".f        a.txt\n>f+++++++ yeni.txt\n>fcs..... b.txt", format: .openrsync)
    #expect(open.map(\.path) == ["a.txt", "b.txt"] && open[0].identical && !open[1].identical)
}

@Test func numberedNamesFollowFinder() {
    let taken: Set<String> = ["rapor 2.xlsx", "Notlar 2"]
    #expect(ConflictDetector.numberedName(for: "rapor.xlsx", isTaken: { taken.contains($0) }) == "rapor 3.xlsx")
    #expect(ConflictDetector.numberedName(for: "Notlar", isTaken: { taken.contains($0) }) == "Notlar 3")
    #expect(ConflictDetector.numberedName(for: "arşiv.tar.gz", isTaken: { _ in false }) == "arşiv.tar 2.gz")
    #expect(ConflictDetector.numberedName(for: ".zshrc", isTaken: { _ in false }) == ".zshrc 2")
    #expect(ConflictDetector.excludePatterns(for: ["Kaynak/a*.txt", "b[1].txt"]) == [#"/Kaynak/a\*.txt"#, #"/b\[1].txt"#])
}

/// `--from0` liste seçeneklerinden önce gelir; yoksa rsync NUL ile ayrılmış dışlama listesinin yalnızca ilk kalıbını okur.
@Test func from0PrecedesListOptions() {
    var job = TransferJob(source: URL(fileURLWithPath: "/a"), destination: URL(fileURLWithPath: "/b"))
    job.options.advanced.conflictExcludeFile = "/tmp/x"
    job.options.advanced.filesFromZeroTerminated = true
    let environment = RsyncCommand.Environment(engine: fullEngine, destinationFileSystem: .apfs, sourceIsDirectory: true)
    for arguments in [RsyncCommand.transfer(job, environment: environment), RsyncCommand.verify(job, environment: environment, checksum: false),
                      RsyncCommand.conflictCheck(job, environment: environment)] {
        let from0 = arguments.firstIndex(of: "--from0")
        let list = arguments.firstIndex(of: "--exclude-from=/tmp/x")
        #expect(from0 != nil && list != nil && from0! < list!)
    }
    let open = RsyncCommand.Environment(engine: openrsyncEngine, destinationFileSystem: .apfs, sourceIsDirectory: true)
    #expect(!RsyncCommand.transfer(job, environment: open).contains("--from0"))
}

@Test func conflictOptionsDecodeWithAskAsDefault() throws {
    let options = try JSONDecoder().decode(CopyOptions.self, from: Data(#"{"copyMode": "contents"}"#.utf8))
    #expect(options.conflictPolicy == .ask)
    // Bu ayardan önce kaydedilmiş seçenekler: ilk karar sayfasında "hatırla" önerilir; yenilerde önerilmez.
    #expect(options.suggestsRememberingConflictChoice)
    #expect(!CopyOptions().suggestsRememberingConflictChoice)
    let saved = try JSONDecoder().decode(CopyOptions.self, from: JSONEncoder().encode(CopyOptions(conflictPolicy: .ask)))
    #expect(!saved.suggestsRememberingConflictChoice)
    var legacy = options
    legacy.suggestsRememberingConflictChoice = true
    #expect(try JSONDecoder().decode(CopyOptions.self, from: JSONEncoder().encode(legacy)).suggestsRememberingConflictChoice)
    let unknown = try JSONDecoder().decode(CopyOptions.self, from: Data(#"{"conflictPolicy": "merge"}"#.utf8))
    #expect(unknown.conflictPolicy == .ask)
    #expect(ConflictPolicy.allCases.compactMap(\.decision) == [.replace, .keepBoth, .skip])
    #expect(ConflictDecision.allCases.map(\.policy) == [.replace, .keepBoth, .skip])
    let resolution = ConflictResolution(decisions: ["a": .skip], others: .replace)
    #expect(resolution.decision(for: "a") == .skip && resolution.decision(for: "b") == .replace)
    #expect(ConflictResolution().decision(for: "a") == nil)
}

@Test func finishingClearsConflictStateExceptWhenPaused() {
    var job = TransferJob(source: URL(fileURLWithPath: "/a"), destination: URL(fileURLWithPath: "/b"))
    JobQueue.apply(.conflicts(ConflictReport(items: [FileConflict(path: "a/x", identical: true)], total: 1)), to: &job)
    JobQueue.finish(&job, with: JobResult(kind: .awaitingDecision, noteCount: 1))
    #expect(job.status == .paused && job.isAwaitingDecision && job.pendingConflicts?.total == 1)
    job.pendingConflicts = nil
    job.conflictResolution = ConflictResolution(others: .keepBoth)
    JobQueue.finish(&job, with: JobResult(kind: .cancelled))
    #expect(job.conflictResolution != nil)
    JobQueue.finish(&job, with: JobResult(kind: .succeeded))
    #expect(job.conflictResolution == nil && job.pendingConflicts == nil)
}

/// Gerçek rsync ile: sor, değiştir, ikisini de sakla, atla ve dosya dosya karar.
@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct ConflictEngineTests {
    private func setUp() throws -> Workspace {
        let workspace = try Workspace()
        try workspace.write("Kaynak/ayni.txt", "aynı\n")
        try workspace.write("Kaynak/alt/farkli.txt", "yeni sürüm, daha uzun\n")
        try workspace.write("Kaynak/yeni.txt", "yeni\n")
        try workspace.mkdir("Hedef/Kaynak/alt")
        try FileManager.default.copyItem(at: workspace.url("Kaynak/ayni.txt"), to: workspace.url("Hedef/Kaynak/ayni.txt"))
        try workspace.write("Hedef/Kaynak/alt/farkli.txt", "eski\n")
        try workspace.write("Hedef/Kaynak/alt/farkli 2.txt", "daha önceki bir kopya\n")
        return workspace
    }

    private func run(_ job: TransferJob) async throws -> (JobResult, [TransferEvent]) {
        let events = Collected<TransferEvent>()
        let result = await RsyncEngine().run(job, context: try await engineContext()) { events.add($0) }
        return (result, events.values)
    }

    @Test func askStopsBeforeCopyingAndListsEverySameNameFile() async throws {
        let workspace = try setUp()
        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"))
        let (result, events) = try await run(job)
        #expect(result.kind == .awaitingDecision && result.noteCount == 2)
        let report = try #require(events.compactMap { if case .conflicts(let report) = $0 { report } else { nil } }.first)
        #expect(Set(report.items) == [FileConflict(path: "Kaynak/ayni.txt", identical: true), FileConflict(path: "Kaynak/alt/farkli.txt", identical: false)])
        // Hiçbir şey kopyalanmadı.
        #expect(!workspace.exists("Hedef/Kaynak/yeni.txt"))
        #expect(workspace.read("Hedef/Kaynak/alt/farkli.txt") == "eski\n")
    }

    @Test(arguments: [ConflictPolicy.replace, .keepBoth, .skip])
    func policiesApplyWithoutAsking(policy: ConflictPolicy) async throws {
        let workspace = try setUp()
        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"),
                              options: CopyOptions(verifyAfterCopy: .quick, conflictPolicy: policy))
        let (result, events) = try await run(job)
        #expect(result.kind == .succeeded, "\(result)")
        #expect(result.differenceCount == 0)
        #expect(workspace.read("Hedef/Kaynak/yeni.txt") == "yeni\n")
        let keys = events.flatMap { event -> [JobLogEntry] in
            switch event {
            case .log(let entry): [entry]
            case .logBatch(let entries): entries
            default: []
            }
        }
        switch policy {
        case .replace:
            #expect(workspace.read("Hedef/Kaynak/alt/farkli.txt") == "yeni sürüm, daha uzun\n")
            #expect(!workspace.exists("Hedef/Kaynak/alt/farkli 3.txt"))
        case .keepBoth:
            // Hedefteki dosyalar kalır, yeniler numaralı adla gelir ("farkli 2.txt" dolu olduğu için "farkli 3.txt").
            #expect(workspace.read("Hedef/Kaynak/alt/farkli.txt") == "eski\n")
            #expect(workspace.read("Hedef/Kaynak/alt/farkli 2.txt") == "daha önceki bir kopya\n")
            #expect(workspace.read("Hedef/Kaynak/alt/farkli 3.txt") == "yeni sürüm, daha uzun\n")
            #expect(workspace.read("Hedef/Kaynak/ayni 2.txt") == "aynı\n")
            #expect(keys.contains { $0.key == LKey.logKeptBoth.rawValue && $0.arguments == ["Kaynak/alt/farkli.txt", "farkli 3.txt"] })
        case .skip:
            #expect(workspace.read("Hedef/Kaynak/alt/farkli.txt") == "eski\n")
            #expect(!workspace.exists("Hedef/Kaynak/ayni 2.txt"))
        case .ask:
            break
        }
        // "Değiştir" ayarında denetim gerekmez (rsync'in olağan davranışı); ötekilerde kararlar günlüğe yazılır.
        #expect(keys.contains { $0.key == LKey.logConflictsResolved.rawValue } == (policy != .replace))
        // Kaynak değişmedi.
        #expect(workspace.read("Kaynak/alt/farkli.txt") == "yeni sürüm, daha uzun\n")
    }

    /// Dosya dosya karar; listede olmayan yeni bir çakışma "ötekiler" kararıyla, o da yoksa yeniden sorulur.
    @Test func perFileDecisionsAndLaterConflicts() async throws {
        let workspace = try setUp()
        var job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"))
        job.conflictResolution = ConflictResolution(decisions: ["Kaynak/ayni.txt": .skip, "Kaynak/alt/farkli.txt": .keepBoth])
        try workspace.write("Kaynak/sonradan.txt", "kaynak\n")
        try workspace.write("Hedef/Kaynak/sonradan.txt", "hedef\n")
        // Yalnızca kararı verilmemiş dosya sorulur; verilmiş iki karar saklı kalır.
        let (asked, events) = try await run(job)
        #expect(asked.kind == .awaitingDecision && asked.noteCount == 1)
        let reports = events.compactMap { if case .conflicts(let report) = $0 { report } else { nil } }
        #expect(reports.first?.items.map(\.path) == ["Kaynak/sonradan.txt"])
        #expect(workspace.read("Hedef/Kaynak/sonradan.txt") == "hedef\n")

        job.conflictResolution?.others = .replace
        let (result, _) = try await run(job)
        #expect(result.kind == .succeeded, "\(result)")
        #expect(!workspace.exists("Hedef/Kaynak/ayni 2.txt"))
        #expect(workspace.read("Hedef/Kaynak/alt/farkli 3.txt") == "yeni sürüm, daha uzun\n")
        #expect(workspace.read("Hedef/Kaynak/sonradan.txt") == "kaynak\n")
    }

    /// Rutin işinde (kurallar, `--files-from`) ve tek dosyalık işte de çakışma bulunur; anlık görüntüde denetim yapılmaz.
    @Test func ruleJobsSingleFilesAndSnapshots() async throws {
        let workspace = try setUp()
        let rules = RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "txt")])
        let routineJob = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef/Kaynak"),
                                     options: CopyOptions(rules: rules, conflictPolicy: .keepBoth))
        let (result, _) = try await run(routineJob)
        #expect(result.kind == .succeeded, "\(result)")
        #expect(workspace.read("Hedef/Kaynak/alt/farkli 3.txt") == "yeni sürüm, daha uzun\n")

        let file = TransferJob(source: workspace.url("Kaynak/yeni.txt"), destination: workspace.url("Hedef/Kaynak"))
        let (fileResult, _) = try await run(file)
        #expect(fileResult.kind == .awaitingDecision && fileResult.noteCount == 1)

        try workspace.mkdir("Yedekler")
        let snapshot = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Yedekler"),
                                   options: CopyOptions(snapshots: SnapshotOptions(enabled: true)))
        #expect(try await run(snapshot).0.kind == .succeeded)
        #expect(try await run(snapshot).0.kind == .succeeded)
    }
}
