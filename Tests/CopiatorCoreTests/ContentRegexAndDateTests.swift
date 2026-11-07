// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// İçerik ölçütünde düzenli ifade: metne yazıldığı gibi uygulanır (sözcük sınırı gibi "içerir"in yapamadığı eşleşmeler),
/// Spotlight'a sorulmaz; adım sınırını aşan ifade taramayı hatayla bitirir (sessizce "uymaz" sayılmaz).
@Test func contentCriterionMatchesRegularExpressions() async throws {
    let w = try Workspace("CopiatorContentRegex")
    try w.write("Gelen/su.txt", "ASI tahsilat makbuzu")
    try w.write("Gelen/tasima.txt", "TAŞIMA ve ASIL belge")
    try w.write("Gelen/bos.bin", "ASI")
    #expect(RuleAttribute.content.operators == [.contains, .matchesRegex])
    let word = RuleGroup(conditions: [RuleCondition(attribute: .content, op: .matchesRegex, value: #"\bASI\b"#)])
    #expect(try await RuleScanner.scan(w.url("Gelen"), rules: word).paths == ["su.txt"], "okunamayan tür eşleşmez")
    let contains = RuleGroup(conditions: [RuleCondition(attribute: .content, op: .contains, value: "ASI")])
    #expect(Set(try await RuleScanner.scan(w.url("Gelen"), rules: contains).paths).isSuperset(of: ["su.txt", "tasima.txt"]))

    try w.write("Gelen/uzun.txt", String(repeating: "a", count: 40) + "b")
    let runaway = RuleGroup(conditions: [RuleCondition(attribute: .content, op: .matchesRegex, value: #"^(a+)+$"#)])
    await #expect(throws: RuleEvaluator.RunawayRegex.self) { try await RuleScanner.scan(w.url("Gelen"), rules: runaway) }
}

/// Tarih kaynağı açıkça seçildiyse ve tarih bulunamazsa değiştirilme tarihine geçilmez; otomatik kaynak geçer. Karar
/// biçimi "yyyy-MM-dd"; geçersiz değer okunmaz.
@Test func explicitDateSourcesReportMissingDates() async throws {
    let w = try Workspace("CopiatorDates")
    let file = try w.write("fatura.txt", "tarih yok")
    let modified = PlacementDate.modified(of: file)
    #expect(await PlacementDate.find(file, relativePath: "fatura.txt", source: .contents) == nil)
    #expect(await PlacementDate.find(file, relativePath: "fatura.txt", source: .fileName) == nil)
    #expect(await PlacementDate.find(file, relativePath: "fatura.txt", source: .captureDate) == nil)
    #expect(await PlacementDate.find(file, relativePath: "fatura.txt", source: .automatic) == modified)
    #expect(await PlacementDate.resolve(file, relativePath: "fatura.txt", source: .contents) == modified, "önizleme eski davranışı korur")
    #expect(PlacementDateSource.allCases.filter(\.asksWhenMissing) == [.fileName, .contents, .captureDate])
    #expect(PlacementDate.string(DateComponents(year: 2026, month: 9, day: 5)) == "2026-09-05")
    #expect(PlacementDate.components("2026-09-05") == DateComponents(year: 2026, month: 9, day: 5))
    for bad in ["2026-13-01", "2026-09", "abc", "1800-01-01", "2026-09-32"] { #expect(PlacementDate.components(bad) == nil, "\(bad)") }

    let old = try JSONDecoder().decode(PlacementResolution.self, from: Data(#"{"folders":{}}"#.utf8))
    #expect(old.dates.isEmpty)
    let item = try JSONDecoder().decode(PlacementReport.Item.self, from: Data(#"{"path":"a.pdf","suggestions":[]}"#.utf8))
    #expect(item.missingDate == nil)
}

/// Karar planı ve gerçek hazırlık: tarihi bulunamayan dosya için tarih sorulur (önerilen değer değiştirilme tarihi); tarih
/// seçilince o tarihle adlanır; tarihi bulunan dosya beklemez; önizleme beklemez.
@Test func missingDatesAreAskedAndChosenDatesAreUsed() async throws {
    let w = try Workspace("CopiatorDates")
    try w.write("Gelen/enerjisa.txt", "ENERJİSA fatura Ekim 2026")
    try w.write("Gelen/taranmis.txt", "metin var ama tarih yok")
    try w.mkdir("Arsiv")
    let placement = RoutePlacement(nameTemplate: "El_{month}_{yy}", dateSource: .contents)
    let suggested = PlacementDate.string(PlacementDate.modified(of: w.url("Gelen/taranmis.txt")))
    let plan = try PlacementQuestions.plan(paths: ["enerjisa.txt", "taranmis.txt"], source: w.url("Gelen"), destination: w.url("Arsiv"),
                                           placement: placement, resolution: nil, undated: ["taranmis.txt": suggested])
    let item = try #require(plan.report?.items.first)
    #expect(plan.paths == ["enerjisa.txt"] && item.path == "taranmis.txt" && item.missingDate == suggested && !item.needsFolder)
    let preview = try PlacementQuestions.plan(paths: ["enerjisa.txt", "taranmis.txt"], source: w.url("Gelen"), destination: w.url("Arsiv"),
                                              placement: placement, resolution: nil, undated: ["taranmis.txt": suggested], decide: false)
    #expect(preview.report == nil && preview.paths.count == 2)

    let rules = RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "txt")])
    var job = TransferJob(source: w.url("Gelen"), destination: w.url("Arsiv"), options: CopyOptions(copyMode: .contents, rules: rules, placement: placement))
    var waiting = job
    do {
        _ = try await RuleSelection.prepare(&waiting, zeroTerminated: true, skippedPaths: [], scratch: try w.mkdir("Gecici"), isCancelled: { false })
        Issue.record("tarih sorulmalıydı")
    } catch let needed as PlacementQuestions.DecisionNeeded {
        #expect(needed.report.items.map(\.path) == ["taranmis.txt"] && needed.report.items.first?.missingDate == suggested)
    }
    job.placementResolution = PlacementResolution(dates: ["taranmis.txt": "2026-09-15", "bozuk.txt": "yok"])
    let prepared = try #require(try await RuleSelection.prepare(&job, zeroTerminated: true, skippedPaths: [], scratch: try w.mkdir("Gecici2"),
                                                                 isCancelled: { false }))
    #expect(Set(prepared.targets) == ["El_10_26.txt", "El_09_26.txt"])

    // Otomatik kaynak sormaz: tarihi bulunamayan dosya değiştirilme tarihini alır.
    var automatic = TransferJob(source: w.url("Gelen"), destination: w.url("Arsiv"),
                                options: CopyOptions(copyMode: .contents, rules: rules, placement: RoutePlacement(nameTemplate: "El_{month}_{yy}")))
    #expect(try await RuleSelection.prepare(&automatic, zeroTerminated: true, skippedPaths: [], scratch: try w.mkdir("Gecici3"),
                                            isCancelled: { false })?.targets.count == 2)
}
