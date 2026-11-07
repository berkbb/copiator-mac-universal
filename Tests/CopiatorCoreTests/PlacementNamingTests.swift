// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// Karar sayfasında dosya başına ad: onaylanan ad şablonun ve düzeltmelerin yerine geçer, uzantı korunur, ad güvenli bir
/// bileşene dönüşür (hedefin dışına çıkamaz); "Ad Öner" seçilen klasördeki adlardan kurala bağlı bir ad çıkarır.
@Test func chosenNameReplacesTheTemplateAndKeepsTheExtension() {
    let placement = RoutePlacement(nameTemplate: "El_{month}_{yy}", nameFixes: [NameFix(pattern: "_", replacement: "-")], askFolder: true)
    let date = DateComponents(year: 2026, month: 10, day: 3)
    #expect(placement.target(for: "Gelen/fatura.pdf", date: date, folder: "Ev/Elektrik") == "Ev/Elektrik/El-10-26.pdf")
    #expect(placement.target(for: "Gelen/fatura.pdf", date: date, folder: "Ev/Elektrik", name: "128820964_El_10_26")
        == "Ev/Elektrik/128820964_El_10_26.pdf")
    // Güvenli ad: "/" tireye döner, baştaki noktalar atılır; boş kalan ad yok sayılır ve şablon kullanılır.
    #expect(placement.target(for: "fatura.pdf", date: date, folder: "Ev", name: "../../etc/x") == "Ev/-..-etc-x.pdf")
    #expect(placement.target(for: "fatura.pdf", date: date, folder: "Ev", name: " .. ") == "Ev/El-10-26.pdf")
    #expect(placement.target(for: "notlar", date: date, folder: "Ev", name: "Yeni Not") == "Ev/Yeni Not")
}

@Test func namesTravelWithTheDecisionAndOldRecordsDecode() throws {
    let old = try JSONDecoder().decode(PlacementResolution.self, from: Data(#"{"folders":{"a.pdf":"Ev"}}"#.utf8))
    #expect(old.names.isEmpty && old.folders == ["a.pdf": "Ev"])
    let w = try Workspace("CopiatorPlacementNames")
    try w.write("Gelen/a.pdf", "a")
    try w.write("Gelen/b.pdf", "b")
    try w.mkdir("Arsiv/Ev")
    let resolution = PlacementResolution(folders: ["a.pdf": "Ev", "b.pdf": "Ev"], names: ["a.pdf": "Tapu 2026", "b.pdf": " .. "])
    let plan = try PlacementQuestions.plan(paths: ["a.pdf", "b.pdf"], source: w.url("Gelen"), destination: w.url("Arsiv"),
                                           placement: RoutePlacement(askFolder: true), resolution: resolution)
    #expect(plan.names == ["a.pdf": "Tapu 2026"], "güvenli bir ada dönüşmeyen ad atılır")
}

@Test func nameSuggestionFollowsTheFolderExamples() async throws {
    let w = try Workspace("CopiatorPlacementNames")
    try w.write("Arsiv/Elektrik/Elektrik_Faturasi_2026-08.pdf", "1")
    try w.write("Arsiv/Elektrik/Elektrik_Faturasi_2026-09.pdf", "2")
    try w.mkdir("Arsiv/Bos")
    let date = DateComponents(year: 2026, month: 10, day: 1)
    let suggested = await PlacementNaming.suggest(for: "Gelen/enerjisa ekim.pdf", in: w.url("Arsiv/Elektrik"), date: date, model: nil)
    #expect(suggested.value == "Elektrik_Faturasi_2026-10")
    let none = await PlacementNaming.suggest(for: "Gelen/enerjisa ekim.pdf", in: w.url("Arsiv/Bos"), date: date, model: nil)
    #expect(none.value == nil)
}

/// Gerçek hazırlık: onaylanan ad hazırlık ağacında (ve dolayısıyla hedefte) kullanılır, öteki dosya şablonla adlanır.
@Test func stagingUsesTheApprovedName() async throws {
    let w = try Workspace("CopiatorPlacementNames")
    try w.write("Gelen/a.pdf", "a")
    try w.write("Gelen/b.pdf", "b")
    try w.mkdir("Arsiv/Ev")
    let rules = RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "pdf")])
    var job = TransferJob(source: w.url("Gelen"), destination: w.url("Arsiv"),
                          options: CopyOptions(copyMode: .contents, rules: rules,
                                               placement: RoutePlacement(nameTemplate: "Belge_{name}", askFolder: true)))
    job.placementResolution = PlacementResolution(folders: ["a.pdf": "Ev", "b.pdf": "Ev"], names: ["a.pdf": "Tapu"])
    let prepared = try #require(try await RuleSelection.prepare(&job, zeroTerminated: true, skippedPaths: [], scratch: try w.mkdir("Gecici"),
                                                                 isCancelled: { false }))
    #expect(Set(prepared.targets) == ["Ev/Tapu.pdf", "Ev/Belge_b.pdf"])
}
