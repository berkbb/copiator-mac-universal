// SPDX-License-Identifier: GPL-3.0-only
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
    #expect(unknown.folderConflictPolicy == .ask)
    let unknownFolder = try JSONDecoder().decode(CopyOptions.self, from: Data(#"{"folderConflictPolicy": "future"}"#.utf8))
    #expect(unknownFolder.folderConflictPolicy == .ask)
    #expect(ConflictPolicy.allCases.compactMap(\.decision) == [.replace, .keepBoth, .skip, .reverse])
    #expect(ConflictDecision.allCases.map(\.policy) == [.replace, .keepBoth, .skip, .reverse])
    #expect(FolderConflictPolicy.allCases.compactMap(\.decision) == [.merge, .replace, .keepBoth, .skip])
    #expect(FolderConflictDecision.allCases.map(\.policy) == [.merge, .replace, .keepBoth, .skip])
    #expect(ConflictDetector.numberedFolderName(for: "2026.10", isTaken: { $0 == "2026.10 2" }) == "2026.10 3")
    let folderOutput = """
    .d          ./
    .d..t...... Alt/
    cd+++++++++ Yeni/
    .d          Alt/ic/
    .f          a.txt
    """
    let folderConflicts = ConflictDetector.folderConflicts(in: folderOutput, format: .rsync3, existsAtDestination: { $0 == "Alt" })
    #expect(folderConflicts == [FolderConflict(path: "Alt")])
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
        var job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"))
        // Hedefte "Kaynak" klasörü zaten var: önce klasör için karar istenir, hiçbir şey kopyalanmaz.
        let (folderResult, folderEvents) = try await run(job)
        #expect(folderResult.kind == .awaitingDecision && folderResult.detail == JobResult.foldersDetail && folderResult.noteCount == 1)
        let folderReport = try #require(folderEvents.compactMap { if case .folderConflicts(let r) = $0 { r } else { nil } }.first)
        #expect(folderReport.items == [FolderConflict(path: "Kaynak")])
        #expect(!workspace.exists("Hedef/Kaynak/yeni.txt"))

        // Klasörde "Birleştir" seçilince içindeki aynı adlı dosyalar sorulur.
        job.folderConflictResolution = FolderConflictResolution(decisions: ["Kaynak": .merge])
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
        case .ask, .reverse, .newer:
            // Eşitlemeye özgü kurallar bu testin bağımsız değişkenleri arasında yok.
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
        var job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"),
                              options: CopyOptions(folderConflictPolicy: .merge))
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

    /// Klasör çakışması kararları: birleştir, değiştir (Çöp'e taşıyarak), ikisini de sakla (numaralı klasör) ve atla.
    @Test func folderConflictDecisionsAndContentsMode() async throws {
        for decision in FolderConflictDecision.allCases {
            let w = try Workspace()
            try w.write("Kaynak/yeni.txt", "yeni\n")
            try w.write("Hedef/Kaynak/eski.txt", "eski\n")
            let trash = try w.mkdir("Cop")
            var context = try await engineContext()
            context.trashItem = { url in
                let dst = trash.appendingPathComponent(url.lastPathComponent + "-\(UUID().uuidString)")
                return (try? FileManager.default.moveItem(at: url, to: dst)) != nil ? dst : nil
            }
            var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"),
                                  options: CopyOptions(verifyAfterCopy: .quick))
            job.folderConflictResolution = FolderConflictResolution(decisions: ["Kaynak": decision])
            let result = await RsyncEngine().run(job, context: context) { _ in }
            #expect(result.kind == .succeeded, "\(decision): \(result)")
            switch decision {
            case .merge:
                #expect(w.read("Hedef/Kaynak/eski.txt") == "eski\n")
                #expect(w.read("Hedef/Kaynak/yeni.txt") == "yeni\n")
            case .replace:
                #expect(!w.exists("Hedef/Kaynak/eski.txt"))
                #expect(w.read("Hedef/Kaynak/yeni.txt") == "yeni\n")
                let trashed = try FileManager.default.contentsOfDirectory(atPath: trash.path)
                #expect(trashed.count == 1)
            case .keepBoth:
                #expect(w.read("Hedef/Kaynak/eski.txt") == "eski\n")
                #expect(!w.exists("Hedef/Kaynak/yeni.txt"))
                #expect(w.read("Hedef/Kaynak 2/yeni.txt") == "yeni\n")
                #expect(result.undo?.created.contains("Kaynak 2") == true)
            case .skip:
                #expect(w.read("Hedef/Kaynak/eski.txt") == "eski\n")
                #expect(!w.exists("Hedef/Kaynak/yeni.txt"))
            }
        }

        // İçerik kipinde birden çok alt klasör: tek tek Birleştir / Değiştir / İkisini de sakla / Atla.
        let w = try Workspace()
        try w.write("Kaynak/kok.txt", "kök\n")
        try w.write("Kaynak/Birlestir/yeni.txt", "b-yeni\n")
        try w.write("Kaynak/Degistir/yeni.txt", "d-yeni\n")
        try w.write("Kaynak/Ikisi/yeni.txt", "i-yeni\n")
        try w.write("Kaynak/Atla/yeni.txt", "a-yeni\n")
        try w.write("Hedef/Birlestir/eski.txt", "b-eski\n")
        try w.write("Hedef/Degistir/eski.txt", "d-eski\n")
        try w.write("Hedef/Ikisi/eski.txt", "i-eski\n")
        try w.write("Hedef/Atla/eski.txt", "a-eski\n")
        let trash = try w.mkdir("Cop")
        var context = try await engineContext()
        context.trashItem = { url in
            let dst = trash.appendingPathComponent(url.lastPathComponent)
            return (try? FileManager.default.moveItem(at: url, to: dst)) != nil ? dst : nil
        }
        var contentsJob = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"),
                                      options: CopyOptions(copyMode: .contents, verifyAfterCopy: .quick))
        let (askResult, askEvents) = await { () async -> (JobResult, [TransferEvent]) in
            let ev = Collected<TransferEvent>()
            let r = await RsyncEngine().run(contentsJob, context: context) { ev.add($0) }
            return (r, ev.values)
        }()
        #expect(askResult.kind == .awaitingDecision && askResult.detail == JobResult.foldersDetail && askResult.noteCount == 4)
        let asked = try #require(askEvents.compactMap { if case .folderConflicts(let r) = $0 { r } else { nil } }.first)
        #expect(Set(asked.items.map(\.path)) == ["Birlestir", "Degistir", "Ikisi", "Atla"])

        contentsJob.folderConflictResolution = FolderConflictResolution(decisions: [
            "Birlestir": .merge, "Degistir": .replace, "Ikisi": .keepBoth, "Atla": .skip,
        ])
        let done = await RsyncEngine().run(contentsJob, context: context) { _ in }
        #expect(done.kind == .succeeded, "\(done)")
        #expect(w.read("Hedef/kok.txt") == "kök\n")
        #expect(w.read("Hedef/Birlestir/eski.txt") == "b-eski\n" && w.read("Hedef/Birlestir/yeni.txt") == "b-yeni\n")
        #expect(!w.exists("Hedef/Degistir/eski.txt") && w.read("Hedef/Degistir/yeni.txt") == "d-yeni\n")
        #expect(w.read("Hedef/Ikisi/eski.txt") == "i-eski\n" && !w.exists("Hedef/Ikisi/yeni.txt"))
        #expect(w.read("Hedef/Ikisi 2/yeni.txt") == "i-yeni\n")
        #expect(w.read("Hedef/Atla/eski.txt") == "a-eski\n" && !w.exists("Hedef/Atla/yeni.txt"))
    }

    /// Rutin işinde (kurallar, `--files-from`) de klasör çakışması sorulur; kararlar yalnızca seçilen dosyalara uygulanır.
    @Test func routineFolderConflictsUseRuleSelection() async throws {
        let w = try Workspace()
        try w.write("Kaynak/kok.txt", "kök\n")
        for name in ["Birlestir", "Degistir", "Ikisi", "Atla"] {
            try w.write("Kaynak/\(name)/yeni.txt", "\(name)-yeni\n")
            try w.write("Kaynak/\(name)/disari.log", "kurala uymaz\n")
            try w.write("Hedef/\(name)/eski.txt", "\(name)-eski\n")
        }
        try w.write("Kaynak/Yalniz/yeni.log", "kurala uymaz\n")
        try w.mkdir("Hedef/Yalniz")
        let trash = try w.mkdir("Cop")
        var context = try await engineContext()
        context.trashItem = { url in
            let dst = trash.appendingPathComponent(url.lastPathComponent)
            return (try? FileManager.default.moveItem(at: url, to: dst)) != nil ? dst : nil
        }
        let rules = RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "txt")])
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"),
                              options: CopyOptions(copyMode: .contents, verifyAfterCopy: .quick, rules: rules))
        job.routineID = UUID()

        let events = Collected<TransferEvent>()
        let asked = await RsyncEngine().run(job, context: context) { events.add($0) }
        #expect(asked.kind == .awaitingDecision && asked.detail == JobResult.foldersDetail && asked.noteCount == 4, "\(asked)")
        let report = try #require(events.values.compactMap { if case .folderConflicts(let r) = $0 { r } else { nil } }.first)
        // Kurala uyan dosyası olmayan klasör ("Yalniz") sorulmaz.
        #expect(Set(report.items.map(\.path)) == ["Birlestir", "Degistir", "Ikisi", "Atla"])
        #expect(!w.exists("Hedef/kok.txt"))

        job.folderConflictResolution = FolderConflictResolution(decisions: [
            "Birlestir": .merge, "Degistir": .replace, "Ikisi": .keepBoth, "Atla": .skip,
        ])
        let done = await RsyncEngine().run(job, context: context) { _ in }
        #expect(done.kind == .succeeded, "\(done)")
        #expect(w.read("Hedef/kok.txt") == "kök\n")
        #expect(w.read("Hedef/Birlestir/eski.txt") == "Birlestir-eski\n" && w.read("Hedef/Birlestir/yeni.txt") == "Birlestir-yeni\n")
        #expect(!w.exists("Hedef/Degistir/eski.txt") && w.read("Hedef/Degistir/yeni.txt") == "Degistir-yeni\n")
        #expect(w.read("Hedef/Ikisi/eski.txt") == "Ikisi-eski\n" && !w.exists("Hedef/Ikisi/yeni.txt"))
        #expect(w.read("Hedef/Ikisi 2/yeni.txt") == "Ikisi-yeni\n" && !w.exists("Hedef/Ikisi 2/disari.log"))
        #expect(w.read("Hedef/Atla/eski.txt") == "Atla-eski\n" && !w.exists("Hedef/Atla/yeni.txt"))
        #expect(!w.exists("Hedef/Birlestir/disari.log"))

        // Rota daha önce başarıyla çalıştıysa ("Sor" kipinde) klasörleri kendisi oluşturmuştur: sormadan birleştirir.
        var settled = job
        settled.folderConflictResolution = nil
        settled.history = [JobRun(startedAt: Date(), finishedAt: Date(), result: JobResult(kind: .succeeded))]
        try w.write("Kaynak/Atla/ikinci.txt", "ikinci\n")
        // Hedefte aynı adla duran (ilk çalıştırmanın yazdığı) dosyalar ayrıca dosya düzeyinde sorulur; klasör sorulmaz.
        let settledEvents = Collected<TransferEvent>()
        let settledAsk = await RsyncEngine().run(settled, context: context) { settledEvents.add($0) }
        #expect(settledAsk.kind == .awaitingDecision && settledAsk.detail != JobResult.foldersDetail, "\(settledAsk)")
        #expect(!settledEvents.values.contains { if case .folderConflicts = $0 { true } else { false } })
        settled.conflictResolution = ConflictResolution(decisions: [
            "kok.txt": .replace, "Birlestir/yeni.txt": .replace, "Degistir/yeni.txt": .replace,
        ])
        let settledResult = await RsyncEngine().run(settled, context: context) { _ in }
        #expect(settledResult.kind == .succeeded, "\(settledResult)")
        #expect(w.read("Hedef/Atla/ikinci.txt") == "ikinci\n" && w.read("Hedef/Atla/eski.txt") == "Atla-eski\n")

        // Geri alınan çalıştırma "daha önce çalıştı" sayılmaz: klasör yine sorulur.
        var undone = settled
        undone.conflictResolution = nil
        undone.history[0].undoneAt = Date()
        let undoneResult = await RsyncEngine().run(undone, context: context) { _ in }
        #expect(undoneResult.kind == .awaitingDecision && undoneResult.detail == JobResult.foldersDetail, "\(undoneResult)")

        // Birleştir ayarlı rutin sormaz.
        var merging = job
        merging.folderConflictResolution = nil
        merging.options.folderConflictPolicy = .merge
        merging.options.conflictPolicy = .replace
        #expect(await RsyncEngine().run(merging, context: context) { _ in }.kind == .succeeded)
    }

    /// Satır sonuyla ayrılmış seçim listesinde (kullanıcının liste dosyası varken) de Atla / İkisini de sakla yalnızca
    /// seçilen dosyalara uygulanır; atlanan klasörün hepsi atlanınca liste boş kalır ve kökteki dosya yine kopyalanır.
    @Test func routineFolderConflictsWithNewlineListAndAllSkipped() async throws {
        let w = try Workspace()
        try w.write("Kaynak/kok.txt", "kök\n")
        try w.write("Kaynak/Atla/yeni.txt", "atla-yeni\n")
        try w.write("Kaynak/Ikisi/alt/derin.txt", "derin\n")
        try w.write("Kaynak/Ikisi/disari.log", "kurala uymaz\n")
        try w.write("Hedef/Atla/eski.txt", "atla-eski\n")
        try w.write("Hedef/Ikisi/eski.txt", "ikisi-eski\n")
        try w.write("Hedef/Ikisi 2/onceki.txt", "önceki kopya\n")
        try w.write("Listeler/dislama.txt", "*.tmp\n")
        let rules = RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "txt")])
        var options = CopyOptions(copyMode: .contents, verifyAfterCopy: .quick, rules: rules)
        options.advanced.excludeFromFile = w.url("Listeler/dislama.txt").path
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"), options: options)
        job.routineID = UUID()
        job.folderConflictResolution = FolderConflictResolution(decisions: ["Atla": .skip, "Ikisi": .keepBoth])
        let done = await RsyncEngine().run(job, context: try await engineContext()) { _ in }
        #expect(done.kind == .succeeded, "\(done)")
        #expect(w.read("Hedef/kok.txt") == "kök\n")
        #expect(!w.exists("Hedef/Atla/yeni.txt") && w.read("Hedef/Atla/eski.txt") == "atla-eski\n")
        #expect(!w.exists("Hedef/Ikisi/alt") && w.read("Hedef/Ikisi/eski.txt") == "ikisi-eski\n")
        // "Ikisi 2" doluydu: Finder gibi "Ikisi 3" seçilir; kurala uymayan dosya gelmez.
        #expect(w.read("Hedef/Ikisi 3/alt/derin.txt") == "derin\n" && !w.exists("Hedef/Ikisi 3/disari.log"))
        #expect(w.read("Hedef/Ikisi 2/onceki.txt") == "önceki kopya\n")
    }
}
