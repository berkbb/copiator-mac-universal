// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// Ad şablonları yapay zekâsız: tarih parçaları belirteç olur (üç dilde ay adları, iki haneli yıl, gün), ortak metin sabit
/// kalır, örnekten örneğe değişen kısım `{name}` olur; farklı biçimlerde en kalabalık grup kullanılır; tarihsiz örneklerden
/// şablon çıkmaz. Her şablon örnekleri yeniden üretir.
@Test func infersNameTemplatesWithoutAI() {
    let cases: [([String], String?)] = [
        (["Elektrik_Faturası_2026-08.pdf", "Elektrik_Faturası_2026-09.pdf"], "Elektrik_Faturası_{year}-{month}"),
        (["Electricity_Bill_2026-08.pdf", "Electricity_Bill_2026-09.pdf"], "Electricity_Bill_{year}-{month}"),
        (["Factură_Curent_2026-08.pdf", "Factură_Curent_2026-09.pdf"], "Factură_Curent_{year}-{month}"),
        (["123456789_El_08_26.pdf"], "123456789_El_{month}_{yy}"),
        (["Fatura Ağustos 2026.pdf", "Fatura Eylül 2026.pdf"], "Fatura {monthName} {year}"),
        (["Statement_August_2026.pdf"], "Statement_{monthName}_{year}"),
        (["Extras_octombrie_2026.pdf"], "Extras_{monthName}_{year}"),
        (["2026_Ağustos_kira.pdf"], "{year}_{monthName}_kira"),
        (["Dekont_2026-08-15.pdf", "Dekont_2026-09-03.pdf"], "Dekont_{year}-{month}-{day}"),
        (["15.08.2026 tahsilat.pdf"], "{day}.{month}.{year} tahsilat"),
        (["2026-08_fatura.pdf", "2026-09_kira.pdf"], "{year}-{month}_{name}"),
        (["Su_2026-08.pdf", "Elektrik_2026-09.pdf"], "{name}_{year}-{month}"),
        (["Rapor_2026-01.xlsx", "Rapor_2026-02.xlsx", "Rapor_2026-03.xlsx", "notlar.txt", "Sunum 2025.key"], "Rapor_{year}-{month}"),
        (["notlar.txt", "liste.txt"], nil),
        (["a{b}_2026-08.pdf"], nil),
    ]
    for (examples, expected) in cases {
        let template = TemplateInference.nameTemplate(from: examples)
        #expect(template == expected, "\(examples)")
        if let template { #expect(Suggestions.reproducesNames(template, examples: examples.filter { TemplateInference.date(of: $0) != nil }.prefix(3).map { $0 }) || template.contains("{name}") || examples.count > 3, "\(template)") }
    }
}

/// Alt klasör şablonları yapay zekâsız; klasörlerde değişen ad kısmı olamaz.
@Test func infersFolderTemplatesWithoutAI() {
    let cases: [([String], String?)] = [
        (["2025/01-Ocak", "2025/02-Şubat", "2026/10-Ekim"], "{year}/{month}-{monthName}"),
        (["2025/01-January", "2026/10-October"], "{year}/{month}-{monthName}"),
        (["2025/01-Ianuarie", "2026/10-Octombrie"], "{year}/{month}-{monthName}"),
        (["Faturalar/2026/08", "Faturalar/2026/09"], "Faturalar/{year}/{month}"),
        (["2026/Ağustos"], "{year}/{monthName}"),
        (["Faturalar/2025", "Faturalar/2026"], "Faturalar/{year}"),
        (["2025/11", "2026/03"], "{year}/{month}"),
        (["Faturalar/Su", "Faturalar/Elektrik"], nil),
        (["Su/2026-08", "Elektrik/2026-08"], nil),
    ]
    for (examples, expected) in cases {
        #expect(TemplateInference.folderTemplate(from: examples) == expected, "\(examples)")
    }
    #expect(Suggestions.folderLanguage("{year}/{month}-{monthName}", examples: ["2025/01-Ianuarie"]) == "ro")
    #expect(Suggestions.nameLanguage("Fatura {monthName} {year}", examples: ["Fatura Ağustos 2026.pdf"]) == "tr")
    #expect(Suggestions.nameLanguage("Statement_{monthName}_{year}", examples: ["Statement_August_2026.pdf"]) == "en")
}

/// Şablon önerisi önce kurala bağlıdır: model hiç sorulmaz (kapalı olsa da öneri gelir); kural çözemezse ve model yoksa
/// "öneri yok"tur, model varsa o sorulur.
@Test func templateSuggestionsUseRulesFirst() async {
    let silent = FakeSuggestionModel(available: false, answer: "Yanlış_{year}")
    #expect(await Suggestions.nameTemplate(for: "x.pdf", examples: ["Elektrik_Faturası_2026-08.pdf"], model: silent) == .value("Elektrik_Faturası_{year}-{month}"))
    #expect(await Suggestions.folderTemplate(examples: ["2025/01-Ocak"], model: nil) == .value("{year}/{month}-{monthName}"))
    #expect(await Suggestions.folderTemplate(examples: ["Faturalar/2025", "Faturalar/2026"], model: nil) == .value("Faturalar/{year}"))
    #expect(silent.lastPrompt == nil)
    #expect(await Suggestions.nameTemplate(for: "x.pdf", examples: ["notlar.txt"], model: nil) == .noSuggestion)
    let model = FakeSuggestionModel(answer: "Rapor_{year}")
    #expect(await Suggestions.nameTemplate(for: "x.pdf", examples: ["notlar.txt"], model: model) == .noSuggestion)
    #expect(model.lastPrompt?.contains("notlar.txt") == true)
}
