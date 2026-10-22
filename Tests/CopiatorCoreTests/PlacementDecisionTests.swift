// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

/// Öğrenilmiş klasör anahtarı: harf, aksan, rakam ve ay adı farkı gözetilmez; uzantı ayırt edilir; yalnızca tarihten oluşan
/// adlar öğrenilmez. Seçilen klasör hedefin dışına çıkamaz.
@Test func placementMemoryKeysAndCleanFolders() {
    #expect(PlacementMemory.key(for: "Faturalar/Enerjisa Ekim 2026.pdf") == "enerjisa.pdf")
    #expect(PlacementMemory.key(for: "ENERJİSA_kasım_26.PDF") == "enerjisa.pdf")
    #expect(PlacementMemory.key(for: "enerjisa October 2026.pdf") == "enerjisa.pdf")
    #expect(PlacementMemory.key(for: "Su Faturası Martie.pdf") == "su faturasi.pdf")
    #expect(PlacementMemory.key(for: "enerjisa ekim.txt") != PlacementMemory.key(for: "enerjisa ekim.pdf"))
    #expect(PlacementMemory.key(for: "2026-10.pdf") == nil && PlacementMemory.key(for: "Ekim 2026.pdf") == nil)
    #expect(PlacementMemory.key(for: "notlar") == "notlar")
    #expect(PlacementResolution.clean("../x/./ y/..") == "x/y")
    #expect(PlacementResolution.clean("/Faturalar//Su (12)/") == "Faturalar/Su (12)")
    #expect(PlacementResolution.clean("..") == "" && PlacementResolution.clean(". ..") == "")
}

/// Plan: kararlı dosyalar seçilen klasöre, atlananlar hiç; öğrenilmiş klasör hedefte varsa sorulmaz, yoksa yeniden sorulur;
/// kararsızlar için hedefteki klasörler önerilir ve iş karar bekler. Önizlemede ilk öneri kullanılır.
@Test func placementPlanUsesDecisionsMemoryAndSuggestions() throws {
    let w = try Workspace()
    try w.write("Kaynak/elektrik ekim.txt", "Elektrik faturası")
    try w.write("Kaynak/su ekim.txt", "Su")
    try w.write("Kaynak/sigorta poliçesi.txt", "poliçe")
    try w.write("Kaynak/notlar.txt", "not")
    for folder in ["Hedef/Faturalar/Elektrik (123456789)", "Hedef/Faturalar/Su (987654321)", "Hedef/Sigorta"] { try w.mkdir(folder) }
    let paths = ["elektrik ekim.txt", "su ekim.txt", "sigorta poliçesi.txt", "notlar.txt"]
    var placement = RoutePlacement(askFolder: true, learnedFolders: ["elektrik.txt": "Faturalar/Elektrik (123456789)", "su.txt": "Yok"])
    let resolution = PlacementResolution(folders: ["notlar.txt": "../Notlar"], skipped: ["su ekim.txt"])

    let plan = try PlacementQuestions.plan(paths: paths, source: w.url("Kaynak"), destination: w.url("Hedef"), placement: placement,
                                           resolution: resolution)
    #expect(plan.paths == ["elektrik ekim.txt", "notlar.txt"])
    #expect(plan.folders == ["elektrik ekim.txt": "Faturalar/Elektrik (123456789)", "notlar.txt": "Notlar"])
    let report = try #require(plan.report)
    #expect(report.total == 1 && report.items.map(\.path) == ["sigorta poliçesi.txt"])
    #expect(report.items[0].suggestions.first == "Sigorta")

    // Öğrenilmiş klasör hedefte yoksa yeniden sorulur.
    placement.learnedFolders["sigorta policesi.txt"] = "Sigorta"
    let asked = try PlacementQuestions.plan(paths: ["su ekim.txt", "sigorta poliçesi.txt"], source: w.url("Kaynak"), destination: w.url("Hedef"),
                                            placement: placement, resolution: nil)
    #expect(asked.paths == ["sigorta poliçesi.txt"] && asked.report?.items.map(\.path) == ["su ekim.txt"])
    #expect(asked.report?.items.first?.suggestions.first == "Faturalar/Su (987654321)")

    // Önizleme beklemez: kararsız dosya ilk öneriye konur.
    let preview = try PlacementQuestions.plan(paths: ["su ekim.txt"], source: w.url("Kaynak"), destination: w.url("Hedef"),
                                              placement: placement, resolution: nil, decide: false)
    #expect(preview.report == nil && preview.folders == ["su ekim.txt": "Faturalar/Su (987654321)"])

    // Çok sayıda kararsız dosya: listede en çok `maxItems` tanesi, toplam ayrı.
    let many = (0..<(PlacementReport.maxItems + 5)).map { "dosya \($0).txt" }
    let big = try PlacementQuestions.plan(paths: many, source: w.url("Kaynak"), destination: w.url("Hedef"), placement: placement, resolution: nil)
    #expect(big.report?.items.count == PlacementReport.maxItems && big.report?.total == many.count)

    // Seçilen klasör hedef belirteçlerine girer; şablon klasörleri onun altına kurulur.
    let named = RoutePlacement(folderTemplate: "{year}", nameTemplate: "{targetNumber}_{name}", askFolder: true)
    #expect(named.target(for: "alt/elektrik ekim.txt", date: DateComponents(year: 2026, month: 10), destination: w.url("Hedef").path,
                         folder: "Faturalar/Elektrik (123456789)") == "Faturalar/Elektrik (123456789)/2026/123456789_elektrik ekim.txt")
    #expect(RoutePlacement(askFolder: true).target(for: "alt/a.txt", date: nil, folder: "") == "a.txt")
    #expect(RoutePlacement(keepStructure: true, askFolder: true).target(for: "alt/a.txt", date: nil, folder: "X") == "X/alt/a.txt")
    #expect(RoutePlacement(askFolder: true).target(for: "a.txt", date: nil, folder: "../../Disari/./..") == "Disari/a.txt")
}

/// Bekleyen klasör kararları işle kaydedilir; başarıda silinir, duraklatmada seçimler kalır; eski iş kayıtlarında yoktur.
@Test func placementDecisionsLiveOnTheJob() throws {
    var job = TransferJob(source: URL(fileURLWithPath: "/a"), destination: URL(fileURLWithPath: "/b"),
                          options: CopyOptions(rules: RuleGroup(), placement: RoutePlacement(askFolder: true, learnedFolders: ["a.pdf": "A"])))
    let report = PlacementReport(items: [PlacementReport.Item(path: "x.pdf", suggestions: ["A", "B"])], total: 1)
    JobQueue.apply(.placements(report), to: &job)
    JobQueue.finish(&job, with: JobResult(kind: .awaitingDecision, noteCount: 1))
    #expect(job.isAwaitingDecision && job.pendingPlacements == report)
    let decoded = try JSONDecoder().decode(TransferJob.self, from: JSONEncoder().encode(job))
    #expect(decoded.pendingPlacements == report && decoded.options.placement?.learnedFolders == ["a.pdf": "A"])

    job.pendingPlacements = nil
    job.placementResolution = PlacementResolution(folders: ["x.pdf": "A"])
    JobQueue.finish(&job, with: JobResult(kind: .cancelled))
    #expect(!job.isAwaitingDecision && job.placementResolution?.folders == ["x.pdf": "A"])
    JobQueue.finish(&job, with: JobResult(kind: .succeeded))
    #expect(job.placementResolution == nil && job.pendingPlacements == nil)

    let legacy = try JSONDecoder().decode(TransferJob.self, from: Data(#"{"id": "8B0F5C9E-3E1B-4D57-9D44-2D1D7C1D2A41", "source": "file:///a", "destination": "file:///b"}"#.utf8))
    #expect(legacy.pendingPlacements == nil && legacy.placementResolution == nil)
    #expect(try JSONDecoder().decode(RoutePlacement.self, from: Data(#"{"folderTemplate": "{year}"}"#.utf8)).askFolder == false)
    #expect(try JSONDecoder().decode(PlacementResolution.self, from: Data("{}".utf8)) == PlacementResolution())
}

/// Gerçek rsync ile "Klasörü sor": önce hiçbir şey kopyalanmadan klasörler önerilir ve iş karar bekler; seçilen klasörlere,
/// hedef numarasıyla adlandırılarak kopyalanır, atlanan kopyalanmaz; öğrenilen klasör sonraki benzer dosyada sorulmaz.
@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct LivePlacementDecisionTests {
    private func run(_ job: inout TransferJob, _ context: EngineContext) async -> JobResult {
        let events = Collected<TransferEvent>()
        let result = await RsyncEngine().run(job, context: context) { events.add($0) }
        for event in events.values { JobQueue.apply(event, to: &job) }
        JobQueue.finish(&job, with: result)
        return result
    }

    private func files(_ root: URL) -> [String: String] {
        var result: [String: String] = [:]
        for path in (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [] {
            var isDirectory: ObjCBool = false
            let full = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: full.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            result[path.precomposedStringWithCanonicalMapping] = (try? String(contentsOf: full, encoding: .utf8)) ?? ""
        }
        return result
    }

    @Test func askedFoldersAreSuggestedChosenAndRemembered() async throws {
        let w = try Workspace("CopiatorPlacement")
        var context = try await engineContext()
        context.scratchDirectory = try w.mkdir("Gecici")
        try w.write("Kaynak/enerjisa ekim.txt", "Elektrik faturası, Ekim 2026")
        try w.write("Kaynak/sigorta.txt", "poliçe")
        for folder in ["Hedef/Elektrik (123456789)", "Hedef/Su (987654321)"] { try w.mkdir(folder) }
        let placement = RoutePlacement(nameTemplate: "{targetNumber}_{name}", askFolder: true)
        // Hedefte aynı adla zaten kopyalanmış dosyalar atlanır (yoksa üçüncü çalıştırma ayrıca onları sorardı).
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"),
                              options: CopyOptions(copyMode: .contents, rules: RuleGroup(), conflictPolicy: .skip, placement: placement))

        #expect(await run(&job, context).kind == .awaitingDecision)
        let report = try #require(job.pendingPlacements)
        #expect(job.isAwaitingDecision && report.total == 2)
        #expect(report.items.first { $0.path == "enerjisa ekim.txt" }?.suggestions.first == "Elektrik (123456789)")
        #expect(files(w.url("Hedef")).isEmpty)
        #expect(job.log.contains { $0.key == LKey.logAwaitingPlacement.rawValue && $0.arguments == ["2"] })
        #expect(job.result?.detail == JobResult.placementsDetail)

        job.pendingPlacements = nil
        job.placementResolution = PlacementResolution(folders: ["enerjisa ekim.txt": "Elektrik (123456789)"], skipped: ["sigorta.txt"])
        JobQueue.requeue(&job)
        let result = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result) \(job.log.suffix(5))")
        #expect(files(w.url("Hedef")) == ["Elektrik (123456789)/123456789_enerjisa ekim.txt": "Elektrik faturası, Ekim 2026"])
        #expect(job.placementResolution == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.url("Gecici").path).isEmpty)

        // "Hatırla": benzer adlı yeni dosya sorulmadan aynı klasöre gider; öbürü yine sorulur.
        job.options.placement?.learnedFolders = [try #require(PlacementMemory.key(for: "enerjisa ekim.txt")): "Elektrik (123456789)"]
        try w.write("Kaynak/Enerjisa Kasım.txt", "Elektrik faturası, Kasım 2026")
        JobQueue.requeue(&job)
        #expect(await run(&job, context).kind == .awaitingDecision)
        #expect(job.pendingPlacements?.items.map(\.path) == ["sigorta.txt"])
        job.pendingPlacements = nil
        job.placementResolution = PlacementResolution(skipped: ["sigorta.txt"])
        JobQueue.requeue(&job)
        let last = await run(&job, context)
        #expect(last.kind == .succeeded, "\(last) \(job.log.suffix(4))")
        #expect(files(w.url("Hedef"))["Elektrik (123456789)/123456789_Enerjisa Kasım.txt"] == "Elektrik faturası, Kasım 2026")
        #expect(files(w.url("Kaynak")).count == 3)
    }

    /// Önizleme karar beklemez ve hiçbir şey yazmaz: dosyalar ilk önerilen klasördeki yerleriyle listelenir.
    @Test func previewUsesTheFirstSuggestion() async throws {
        let w = try Workspace("CopiatorPlacement")
        var context = try await engineContext()
        context.scratchDirectory = try w.mkdir("Gecici")
        try w.write("Kaynak/su ekim.txt", "su")
        try w.mkdir("Hedef/Su (987654321)")
        let job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"),
                              options: CopyOptions(copyMode: .contents, rules: RuleGroup(),
                                                   placement: RoutePlacement(nameTemplate: "{targetNumber}_{name}", askFolder: true)))
        let preview = await RsyncEngine().verify(job, context: context, checksum: false)
        #expect(preview.result.kind.isSuccess, "\(preview.result)")
        #expect(preview.entries.contains { $0.path == "Su (987654321)/987654321_su ekim.txt" }, "\(preview.entries.map(\.path))")
        #expect(files(w.url("Hedef")).isEmpty)
    }
}
