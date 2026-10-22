// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

/// Sahte model: verilen yanıtı döndürür, gelen istemi kaydeder.
final class FakeSuggestionModel: SuggestionModel, @unchecked Sendable {
    let isAvailable: Bool
    let answer: String
    private let lock = NSLock()
    private var prompts: [String] = []

    init(available: Bool = true, answer: String) {
        isAvailable = available
        self.answer = answer
    }

    var lastPrompt: String? { lock.withLock { prompts.last } }

    func respond(instructions: String, prompt: String) async throws -> String {
        lock.withLock { prompts.append(prompt) }
        return answer
    }
}

private let folders = ["Özel/Ev/Tapu", "Özel/Ev/Faturalar/Elektrik", "Özel/Ev/Faturalar/Su", "Özel/Araba/Sigorta"]
    .map { FolderSuggester.Suggestion(path: $0, score: 0.5) }

/// Model yalnızca var olan adaylar arasından sıralar: sayılar ayrıştırılır, aralık dışı ve tekrarlar atılır; seçilmeyenler
/// ardından gelir. Model yoksa, tek aday varsa ya da yanıt geçersizse sıra değişmez (nil).
@Test func aiRankingOnlyReordersExistingCandidates() async {
    #expect(Suggestions.parseOrder("3, 1, 4, 3, 99, 0, x2", count: 4) == [3, 1, 4, 2])
    #expect(Suggestions.parseOrder("yok", count: 4).isEmpty)

    let model = FakeSuggestionModel(answer: "2, 4")
    let ranked = await Suggestions.rankFolders(folders, for: "enerjisa_ekim.pdf", content: "ENERJİSA fatura", model: model)
    #expect(ranked?.map(\.path) == ["Özel/Ev/Faturalar/Elektrik", "Özel/Araba/Sigorta", "Özel/Ev/Tapu", "Özel/Ev/Faturalar/Su"])
    #expect(model.lastPrompt?.contains("1. Özel/Ev/Tapu") == true && model.lastPrompt?.contains("ENERJİSA fatura") == true)

    #expect(await Suggestions.rankFolders(folders, for: "x", content: nil, model: FakeSuggestionModel(available: false, answer: "1")) == nil)
    #expect(await Suggestions.rankFolders(folders, for: "x", content: nil, model: FakeSuggestionModel(answer: "bilmiyorum")) == nil)
    #expect(await Suggestions.rankFolders(Array(folders.prefix(1)), for: "x", content: nil, model: FakeSuggestionModel(answer: "1")) == nil)
}

/// Model yanıtından ad şablonu: tırnak, ayraç, önek ve uzantı atılır; bilinmeyen belirteç, "/" ve boş yanıt reddedilir.
@Test func aiTemplatesAreCleanedAndValidated() async {
    #expect(Suggestions.cleanTemplate("123456789_El_({month}_{yy}).pdf") == "123456789_El_{month}_{yy}")
    #expect(Suggestions.cleanTemplate("Template: `Rapor_{year}-{month}`") == "Rapor_{year}-{month}")
    #expect(Suggestions.cleanTemplate("“Fatura_{monthName}_{year}.xlsx”\nAçıklama: ay adı") == "Fatura_{monthName}_{year}")
    #expect(Suggestions.cleanTemplate("{name}") == "{name}")
    #expect(Suggestions.cleanTemplate("{yil}_fatura") == nil)
    #expect(Suggestions.cleanTemplate("2026/{month}") == nil)
    #expect(Suggestions.cleanTemplate("Fatura_{}_x") == nil)
    #expect(Suggestions.cleanTemplate("   \n  ") == nil)

    let model = FakeSuggestionModel(answer: "123456789_El_{month}_{yy}.pdf")
    let template = await Suggestions.nameTemplate(for: "Enerjisa Ekim 2026.pdf", examples: ["123456789_El_08_26.pdf", "123456789_El_09_26.pdf"], model: model)
    #expect(template == "123456789_El_{month}_{yy}")
    #expect(model.lastPrompt?.contains("- 123456789_El_09_26.pdf") == true && model.lastPrompt?.contains("New file: Enerjisa Ekim 2026.pdf") == true)
    #expect(await Suggestions.nameTemplate(for: "x.pdf", examples: [], model: model) == nil)
}

/// Örnek adlar: en yeni değişen önce, gizliler hariç; klasörde dosya yoksa en yeni alt klasörden.
@Test func exampleNamesPreferRecentFiles() throws {
    let w = try Workspace()
    try w.write("Arsiv/eski.pdf", "1")
    try w.write("Arsiv/yeni.pdf", "2")
    try w.write("Arsiv/.gizli", "3")
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: w.url("Arsiv/eski.pdf").path)
    #expect(Suggestions.exampleNames(in: w.url("Arsiv")) == ["yeni.pdf", "eski.pdf"])
    try w.write("Kok/2025/a.pdf", "a")
    try w.write("Kok/2026/b.pdf", "b")
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: w.url("Kok/2025").path)
    #expect(Suggestions.exampleNames(in: w.url("Kok")) == ["b.pdf"])
}

/// Bu Mac'te cihaz üstü model varsa gerçek bir çağrı: yanıt ne olursa olsun yalnızca geçerli sonuç ya da nil döner.
@Test(.enabled(if: OnDeviceSuggestionModel().isAvailable, "Cihaz üstü model yok"), .timeLimit(.minutes(2)))
func onDeviceModelGivesOnlyValidSuggestions() async {
    let model = OnDeviceSuggestionModel()
    if let template = await Suggestions.nameTemplate(for: "Enerjisa fatura Ekim 2026.pdf",
                                                     examples: ["123456789_El_08_26.pdf", "123456789_El_09_26.pdf"], model: model) {
        #expect(RoutePlacement(nameTemplate: template).problems().isEmpty && !template.contains("/"), "\(template)")
    }
    if let ranked = await Suggestions.rankFolders(folders, for: "enerjisa_ekim_2026.pdf", content: nil, model: model) {
        #expect(Set(ranked.map(\.path)) == Set(folders.map(\.path)))
    }
    let candidates = folders.map(\.path)
    if let placement = await Suggestions.placeFile("enerjisa_ekim_2026.pdf", content: nil, candidates: candidates, model: model) {
        #expect(placement.order.allSatisfy(candidates.contains))
        #expect(placement.newFolder.map { !$0.contains("..") && !$0.hasPrefix("/") && !$0.contains("{") } ?? true)
    }
    if let template = await Suggestions.folderTemplate(examples: ["2025/01-Ocak", "2026/10-Ekim"], model: model) {
        #expect(RoutePlacement(folderTemplate: template).problems().isEmpty, "\(template)")
    }
}
