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
/// ardından gelir. Model yoksa "kullanılamıyor", tek aday varsa ya da yanıt geçersizse "öneri yok"; sıra değişmez.
@Test func aiRankingOnlyReordersExistingCandidates() async {
    #expect(Suggestions.parseOrder("3, 1, 4, 3, 99, 0, x2", count: 4) == [3, 1, 4, 2])
    #expect(Suggestions.parseOrder("yok", count: 4).isEmpty)

    let model = FakeSuggestionModel(answer: "2, 4")
    let ranked = await Suggestions.rankFolders(folders, for: "enerjisa_ekim.pdf", content: "ENERJİSA fatura", model: model)
    #expect(ranked.value?.map(\.path) == ["Özel/Ev/Faturalar/Elektrik", "Özel/Araba/Sigorta", "Özel/Ev/Tapu", "Özel/Ev/Faturalar/Su"])
    #expect(model.lastPrompt?.contains("1. Özel/Ev/Tapu") == true && model.lastPrompt?.contains("ENERJİSA fatura") == true)

    #expect(await Suggestions.rankFolders(folders, for: "x", content: nil, model: FakeSuggestionModel(available: false, answer: "1")) == .unavailable)
    #expect(await Suggestions.rankFolders(folders, for: "x", content: nil, model: FakeSuggestionModel(answer: "bilmiyorum")) == .noSuggestion)
    #expect(await Suggestions.rankFolders(Array(folders.prefix(1)), for: "x", content: nil, model: FakeSuggestionModel(answer: "1")) == .noSuggestion)
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
    #expect(template == .value("123456789_El_{month}_{yy}"))
    // Örneklerden kural çıkarabildi: model sorulmadı. Çıkaramayınca model, örnekler ve yeni dosyanın adıyla sorulur.
    #expect(model.lastPrompt == nil)
    _ = await Suggestions.nameTemplate(for: "Enerjisa Ekim 2026.pdf", examples: ["notlar.txt", "liste.txt"], model: model)
    #expect(model.lastPrompt?.contains("- liste.txt") == true && model.lastPrompt?.contains("New file: Enerjisa Ekim 2026.pdf") == true)
    #expect(await Suggestions.nameTemplate(for: "x.pdf", examples: [], model: model) == .noSuggestion)
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
                                                     examples: ["123456789_El_08_26.pdf", "123456789_El_09_26.pdf"], model: model).value {
        #expect(RoutePlacement(nameTemplate: template).problems().isEmpty && !template.contains("/"), "\(template)")
    }
    if let ranked = await Suggestions.rankFolders(folders, for: "enerjisa_ekim_2026.pdf", content: nil, model: model).value {
        #expect(Set(ranked.map(\.path)) == Set(folders.map(\.path)))
    }
    let candidates = folders.map(\.path)
    if let placement = await Suggestions.placeFile("enerjisa_ekim_2026.pdf", content: nil, candidates: candidates, model: model).value {
        #expect(placement.order.allSatisfy(candidates.contains))
        #expect(placement.newFolder.map { !$0.contains("..") && !$0.hasPrefix("/") && !$0.contains("{") } ?? true)
    }
    if let template = await Suggestions.folderTemplate(examples: ["2025/01-Ocak", "2026/10-Ekim"], model: model).value {
        #expect(RoutePlacement(folderTemplate: template).problems().isEmpty, "\(template)")
    }
}

/// İstemlerde kopyalanabilecek örnek yanıt yoktur: aday numarası ("3, 1"), örnek yeni klasör ya da değerlendirmenin
/// beklediği alt klasör şablonu. Apple'ın modeli istemdeki "3, 1" örneğini kopyalayıp hep 3 numaralı adayı seçiyordu.
@Test func instructionsHaveNoAnswersToCopy() {
    for text in [Suggestions.rankingInstructions, Suggestions.placementInstructions] {
        #expect(text.range(of: #"\d\s*,\s*\d"#, options: .regularExpression) == nil, "\(text)")
        #expect(text.range(of: #"NEW:\s*\S+/"#, options: .regularExpression) == nil, "\(text)")
    }
    #expect(!Suggestions.folderTemplateInstructions.contains("{year}/{month}-{monthName}"))
}

/// Ad şablonunun sonundaki nokta ve boşluklar atılır (uzantı da).
@Test func templateTrailingDotsAreRemoved() {
    #expect(Suggestions.cleanTemplate("Enerji_Faturası_{year}-{monthName}.") == "Enerji_Faturası_{year}-{monthName}")
    #expect(Suggestions.cleanTemplate("Rapor_{year}-{month}.pdf.") == "Rapor_{year}-{month}")
    #expect(Suggestions.cleanTemplate("Rapor_{year}... ") == "Rapor_{year}")
    #expect(Suggestions.cleanTemplate("...") == nil)
}

/// Adla seçen model (Apple gibi): klasör adıyla, yönlendirilmiş seçimle sorulur; aday listesi bir de ters sırayla sorulur
/// ve iki yanıt aynı olmalıdır. Konuma göre seçen model (hep ilk aday) böylece yakalanır ve öneri verilmez; "hiçbiri"
/// seçilirse yeni klasör yolu ayrıca sorulur.
@Test func byNameChoiceCatchesPositionalBias() async {
    struct Chooser: SuggestionModel {
        var isAvailable = true
        var choosesByName: Bool { true }
        var pick: @Sendable ([String]) -> String
        func respond(instructions: String, prompt: String) async throws -> String { "Sağlık/Reçeteler" }
        func choose(instructions: String, prompt: String, choices: [String]) async throws -> String { pick(choices) }
    }
    let candidates = ["Faturalar/Su", "Faturalar/Elektrik", "Sigorta/Kasko"]
    let semantic = Chooser { choices in
        choices == ["yes", "no"] ? "yes" : choices.first { $0.contains("Elektrik") } ?? choices[choices.count - 1]
    }
    let positional = Chooser { choices in choices[0] }
    let none = Chooser { choices in choices[choices.count - 1] }
    #expect(await Suggestions.placeFile("elektrik.pdf", content: nil, candidates: candidates, model: semantic)
        == .value(.init(order: ["Faturalar/Elektrik"], newFolder: nil)))
    #expect(await Suggestions.placeFile("elektrik.pdf", content: nil, candidates: candidates, model: positional) == .noSuggestion)
    #expect(await Suggestions.placeFile("reçete.pdf", content: nil, candidates: candidates, model: none)
        == .value(.init(order: [], newFolder: "Sağlık/Reçeteler")))
    let suggestions = candidates.map { FolderSuggester.Suggestion(path: $0, score: 0) }
    let ranked = await Suggestions.rankFolders(suggestions, for: "elektrik.pdf", content: nil, model: semantic)
    #expect(ranked.value?.map(\.path) == ["Faturalar/Elektrik", "Faturalar/Su", "Sigorta/Kasko"])
    #expect(await Suggestions.rankFolders(suggestions, for: "elektrik.pdf", content: nil, model: positional) == .noSuggestion)
}

/// Hata veren, takılan ya da iptali dinlemeyen model öneri motorunu çökertmez ve bekletmez: süre dolunca sonuç
/// "kullanılamıyor"dur. Otomatik kipte üç model birden yanıt veremezse de öyle.
@Test func failuresAndTimeoutsMakeTheEngineUnavailable() async {
    struct Failing: SuggestionModel {
        var isAvailable = true
        func respond(instructions: String, prompt: String) async throws -> String { throw LocalModelServer.Failure.unavailable }
    }
    struct Stubborn: SuggestionModel {
        var isAvailable = true
        func respond(instructions: String, prompt: String) async throws -> String {
            // İptali dinlemez: 20 saniye sonra yanıt verir.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) { continuation.resume() }
            }
            return "1"
        }
    }
    let clock = ContinuousClock()
    let start = clock.now
    let slow = await Suggestions.$timeout.withValue(.milliseconds(300)) {
        await Suggestions.placeFile("a.pdf", content: nil, candidates: ["A", "B"], model: Stubborn())
    }
    #expect(slow == .unavailable)
    #expect(await Suggestions.nameTemplate(for: "a.pdf", examples: ["notlar.txt"], model: Failing()) == .unavailable)
    let chain = FallbackSuggestionModel([
        (name: "Apple Intelligence", model: Failing()),
        (name: "Ollama", model: Stubborn()),
        (name: "LM Studio", model: Failing(isAvailable: false)),
    ])
    let all = await Suggestions.$timeout.withValue(.milliseconds(300)) {
        await Suggestions.folderTemplate(examples: ["Faturalar/Su"], model: chain)
    }
    #expect(all == .unavailable && chain.lastSource == nil)
    #expect(start.duration(to: clock.now) < .seconds(5))
}

/// Şablon önerisi örnekleri yeniden üretmelidir: yanlış sabit metin, yanlış ay biçimi, tarihsiz örnekler ya da bilinemeyen
/// değerler reddedilir; ay adları üç dilde tanınır, `{name}` herhangi bir metne uyar.
@Test func templatesMustReproduceTheExamples() {
    let names = ["Elektrik_Faturası_2026-08.pdf", "Elektrik_Faturası_2026-09.pdf"]
    #expect(Suggestions.reproducesNames("Elektrik_Faturası_{year}-{month}", examples: names))
    #expect(!Suggestions.reproducesNames("Enerji_Faturası_{year}-{monthName}", examples: names))
    #expect(!Suggestions.reproducesNames("enerjisa_{monthName}_{year}", examples: names))
    #expect(Suggestions.reproducesNames("Fatura_{monthName}_{year}", examples: ["Fatura_Ağustos_2026.pdf", "Fatura_Eylül_2026.pdf"]))
    #expect(!Suggestions.reproducesNames("Fatura_{monthName}_{year}", examples: ["Fatura Ağustos 2026.pdf"]))
    #expect(Suggestions.reproducesNames("Bill {monthName} {year}", examples: ["Bill August 2026.pdf"]))
    #expect(Suggestions.reproducesNames("Bill_{monthName}_{year}", examples: ["Bill_August_2026.pdf"]))
    #expect(Suggestions.reproducesNames("{year}-{month}_{name}", examples: ["2026-08_fatura.pdf", "2026-09_kira.pdf"]))
    #expect(!Suggestions.reproducesNames("Rapor_{year}", examples: ["Rapor_A.pdf"]))
    #expect(!Suggestions.reproducesNames("{folder}_{year}-{month}", examples: ["x_2026-08.pdf"]))
    let folders = ["2025/01-Ocak", "2026/10-Ekim"]
    #expect(Suggestions.reproducesFolders("{year}/{month}-{monthName}", examples: folders))
    #expect(!Suggestions.reproducesFolders("{year}/{month}", examples: folders))
    #expect(!Suggestions.reproducesFolders("Reports-{month}-{monthName}", examples: folders))
    #expect(Suggestions.reproducesFolders("{year}/{month}-{monthName}", examples: ["2025/02-Februarie", "2026/10-Octombrie"]))
}

/// Uygunluk denetimi: model var olan bir klasör seçse de "bu klasöre mi ait?" sorusuna "hayır" derse yeni klasör sorulur;
/// "evet" ya da anlaşılmayan yanıtta seçim korunur. Numarayla seçen modelde de aynıdır.
@Test func fitCheckTurnsWrongFoldersIntoNewOnes() async {
    struct Chooser: SuggestionModel {
        var isAvailable = true
        var choosesByName: Bool { true }
        var fit: String
        func respond(instructions: String, prompt: String) async throws -> String { "Sağlık/Reçeteler" }
        func choose(instructions: String, prompt: String, choices: [String]) async throws -> String {
            choices == ["yes", "no"] ? fit : choices.first { $0.contains("Su") } ?? choices[0]
        }
    }
    let candidates = ["Faturalar/Su", "Faturalar/Elektrik", "Sigorta/Kasko"]
    #expect(await Suggestions.placeFile("reçete.pdf", content: nil, candidates: candidates, model: Chooser(fit: "no"))
        == .value(.init(order: [], newFolder: "Sağlık/Reçeteler")))
    #expect(await Suggestions.placeFile("su.pdf", content: nil, candidates: candidates, model: Chooser(fit: "yes"))
        == .value(.init(order: ["Faturalar/Su"], newFolder: nil)))

    final class Numbered: SuggestionModel, @unchecked Sendable {
        let isAvailable = true
        let fit: String
        init(fit: String) { self.fit = fit }
        func respond(instructions: String, prompt: String) async throws -> String {
            if instructions == Suggestions.fitInstructions { return fit }
            if instructions == Suggestions.newFolderInstructions { return "Sağlık/Reçeteler" }
            return "1"
        }
    }
    #expect(await Suggestions.placeFile("reçete.pdf", content: nil, candidates: candidates, model: Numbered(fit: "Hayır."))
        == .value(.init(order: [], newFolder: "Sağlık/Reçeteler")))
    #expect(await Suggestions.placeFile("su.pdf", content: nil, candidates: candidates, model: Numbered(fit: "Yes"))
        == .value(.init(order: ["Faturalar/Su"], newFolder: nil)))
    #expect(await Suggestions.placeFile("su.pdf", content: nil, candidates: candidates, model: Numbered(fit: "bilmiyorum"))
        == .value(.init(order: ["Faturalar/Su"], newFolder: nil)))
}

/// Otomatik kipte Apple'ın seçtiği var olan klasörü sıradaki hazır model de onaylamalı: "hayır" derse sıradaki modelin
/// kararı kullanılır ve kaynak o olur; "evet" derse ya da sıradaki model hazır değilse Apple'ın seçimi kalır. İlk model
/// Apple değilse çapraz denetim yapılmaz.
@Test func automaticCrossChecksApplesFolderPicks() async {
    struct Apple: SuggestionModel {
        var isAvailable = true
        var choosesByName: Bool { true }
        func respond(instructions: String, prompt: String) async throws -> String { "Sağlık/Reçeteler" }
        func choose(instructions: String, prompt: String, choices: [String]) async throws -> String {
            choices == ["yes", "no"] ? "yes" : choices.first { $0.contains("Bordro") } ?? choices[0]
        }
    }
    final class Next: SuggestionModel, @unchecked Sendable {
        let isAvailable: Bool
        let fit: String
        private let lock = NSLock()
        private var asked: [String] = []
        init(fit: String, available: Bool = true) {
            self.fit = fit
            isAvailable = available
        }
        var questions: [String] { lock.withLock { asked } }
        func respond(instructions: String, prompt: String) async throws -> String {
            let kind = instructions == Suggestions.fitInstructions ? "fit" : instructions == Suggestions.placementInstructions ? "place" : "other"
            lock.withLock { asked.append(kind) }
            switch kind {
            case "fit": return fit
            case "place": return "NEW: Belgeler/Kira"
            default: return "?"
            }
        }
    }
    let candidates = ["Faturalar/Su", "Faturalar/Elektrik", "İş/Bordrolar"]
    let disagree = Next(fit: "no")
    let chain = FallbackSuggestionModel([(name: "Apple Intelligence", model: Apple()), (name: "Ollama", model: disagree)])
    #expect(await Suggestions.placeFile("kira sözleşmesi.pdf", content: nil, candidates: candidates, model: chain)
        == .value(.init(order: [], newFolder: "Belgeler/Kira")))
    #expect(chain.lastSource == "Ollama" && disagree.questions == ["fit", "place"])

    let agree = Next(fit: "yes")
    let trusting = FallbackSuggestionModel([(name: "Apple Intelligence", model: Apple()), (name: "Ollama", model: agree)])
    #expect(await Suggestions.placeFile("bordro.pdf", content: nil, candidates: candidates, model: trusting)
        == .value(.init(order: ["İş/Bordrolar"], newFolder: nil)))
    #expect(trusting.lastSource == "Apple Intelligence" && agree.questions == ["fit"])

    let off = Next(fit: "no", available: false)
    let alone = FallbackSuggestionModel([(name: "Apple Intelligence", model: Apple()), (name: "Ollama", model: off)])
    #expect(await Suggestions.placeFile("bordro.pdf", content: nil, candidates: candidates, model: alone).value?.order == ["İş/Bordrolar"])
    #expect(off.questions.isEmpty)

    let first = Next(fit: "yes")
    let ollamaFirst = FallbackSuggestionModel([(name: "Ollama", model: first), (name: "Apple Intelligence", model: Apple())])
    #expect(await Suggestions.placeFile("kira.pdf", content: nil, candidates: candidates, model: ollamaFirst)
        == .value(.init(order: [], newFolder: "Belgeler/Kira")))
    #expect(ollamaFirst.lastSource == "Ollama" && first.questions == ["place"])
}
