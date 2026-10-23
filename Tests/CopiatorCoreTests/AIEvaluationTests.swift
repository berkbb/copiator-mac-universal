// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

/// Üç dilde (Türkçe, İngilizce, Rumence) öneri değerlendirmesi (COPIATOR_AI_EVAL=1). Her dilde 27 soru: 15 klasör seçimi
/// (5'i yalnızca dosya adıyla), 5 "uygun klasör yok, yeni klasör", 4 ad şablonu, 3 alt klasör şablonu. Önce yapay zekâsız
/// taban çizgisi ("Yalnızca kurallar": kural tabanlı klasör önerisinin ilki ve kurala bağlı şablonlar), sonra Apple
/// Intelligence, Ollama ve LM Studio (Bionic) aynı sorularla sınanır. Yalnızca yerel modeller kullanılır (bulut ve gömme
/// modelleri seçilmez); bir sağlayıcıda yerel sohbet modeli yoksa test başarısız olur, atlanmaz. Doğruluk raporlanır;
/// testin başarısı doğruluğa bağlı değildir. COPIATOR_AI_EVAL_REPORT verilirse Markdown rapor oraya yazılır;
/// COPIATOR_AI_EVAL_OLLAMA_MODEL ve COPIATOR_AI_EVAL_LMSTUDIO_MODEL belirli bir modeli seçer; COPIATOR_AI_EVAL_NO_FIT=1
/// uygunluk denetimini kapatır (karşılaştırma için).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["COPIATOR_AI_EVAL"] == "1", "COPIATOR_AI_EVAL verilmedi"), .serialized)
struct AIEvaluationTests {
    enum Task: String, CaseIterable {
        case place = "Klasör seçimi"
        case placeByName = "Klasör seçimi (yalnızca ad)"
        case newFolder = "Yeni klasör"
        case nameTemplate = "Ad şablonu"
        case folderTemplate = "Alt klasör şablonu"
    }

    enum Outcome: String {
        case correct = "✅ doğru"
        case wrong = "⚠️ yanlış öneri"
        /// Yanıt doğrulamadan geçmedi: kullanıcıya yanlış öneri gösterilmez.
        case none = "➖ öneri yok"
        case unavailable = "🚫 motor kullanılamıyor"
    }

    struct Case {
        var language: String
        var task: Task
        var file = ""
        var content: String?
        var candidates: [String] = []
        var examples: [String] = []
        /// Beklenen klasör ya da şablon; yeni klasör sorusunda nil.
        var expected: String?
    }

    struct Row {
        var provider: String
        var item: Case
        var outcome: Outcome
        var answer: String
        var seconds: Double
    }

    /// Bir dilin soruları: (dosya, içerik, beklenen klasör), yalnızca adla sorulanlar, uygun klasörü olmayanlar, şablonlar.
    struct Language {
        var code: String
        var folders: [String]
        var place: [(String, String, String)]
        var byName: [(String, String)]
        var unfit: [(String, String)]
        var names: [([String], String)]
        var paths: [([String], String)]

        var cases: [Case] {
            place.map { Case(language: code, task: .place, file: $0.0, content: $0.1, candidates: folders, expected: $0.2) }
                + byName.map { Case(language: code, task: .placeByName, file: $0.0, candidates: folders, expected: $0.1) }
                + unfit.map { Case(language: code, task: .newFolder, file: $0.0, content: $0.1, candidates: folders) }
                + names.map { Case(language: code, task: .nameTemplate, file: "yeni.pdf", examples: $0.0, expected: $0.1) }
                + paths.map { Case(language: code, task: .folderTemplate, examples: $0.0, expected: $0.1) }
        }
    }

    static let turkish = Language(
        code: "tr",
        folders: ["Faturalar/Elektrik", "Faturalar/Su", "Faturalar/Doğalgaz", "Faturalar/İnternet", "Sigorta/Kasko", "Sigorta/Sağlık",
                  "Banka/Dekontlar", "Banka/Kredi Kartı", "Vergi/Beyannameler", "İş/Bordrolar"],
        place: [
            ("Enerjisa elektrik faturası Ekim 2026.pdf", "ENERJİSA BAŞKENT ELEKTRİK, elektrik tüketim bedeli, son ödeme 15.11.2026", "Faturalar/Elektrik"),
            ("ASKİ su faturası Eylül.pdf", "ASKİ Genel Müdürlüğü su tüketim faturası, metreküp, abone numarası", "Faturalar/Su"),
            ("Başkentgaz doğalgaz faturası.pdf", "Doğalgaz tüketim bedeli, metreküp, Başkentgaz", "Faturalar/Doğalgaz"),
            ("Türk Telekom internet faturası.pdf", "Fiber internet paketi aylık ücreti, modem kirası", "Faturalar/İnternet"),
            ("kasko poliçesi 2026.pdf", "Kasko sigortası poliçesi, araç plakası, prim tutarı", "Sigorta/Kasko"),
            ("tamamlayıcı sağlık sigortası.pdf", "Tamamlayıcı sağlık sigortası poliçesi, anlaşmalı hastaneler, teminatlar", "Sigorta/Sağlık"),
            ("hesap dökümü eylül.pdf", "Banka hesap özeti, EFT ve havale işlemleri, bakiye", "Banka/Dekontlar"),
            ("kredi kartı ekstresi ekim.pdf", "Kredi kartı dönem borcu, asgari ödeme tutarı, harcamalar", "Banka/Kredi Kartı"),
            ("gelir vergisi beyannamesi 2025.pdf", "Yıllık gelir vergisi beyannamesi, matrah, tahakkuk", "Vergi/Beyannameler"),
            ("maaş bordrosu Eylül 2026.pdf", "Ücret bordrosu, brüt maaş, SGK primi, net ödenen", "İş/Bordrolar"),
        ],
        byName: [
            ("elektrik_fatura_kasim.pdf", "Faturalar/Elektrik"), ("dogalgaz-aralik-2026.pdf", "Faturalar/Doğalgaz"),
            ("kredi_karti_ekstre.pdf", "Banka/Kredi Kartı"), ("bordro_ekim.pdf", "İş/Bordrolar"), ("su_faturasi.pdf", "Faturalar/Su"),
        ],
        unfit: [
            ("reçete ilaç listesi.pdf", "Doktor reçetesi, ilaç adı, kullanım dozu"),
            ("kira sözleşmesi.pdf", "Konut kira sözleşmesi, kiracı, kiraya veren, aylık kira bedeli"),
            ("lise diploması.pdf", "Diploma, mezuniyet, okul müdürlüğü"),
            ("uçak bileti İstanbul.pdf", "Uçuş bileti, rezervasyon kodu, kalkış, varış, koltuk"),
            ("veteriner aşı karnesi.pdf", "Kedi aşı karnesi, kuduz aşısı, veteriner hekim"),
        ],
        names: [
            (["Elektrik_Faturası_2026-08.pdf", "Elektrik_Faturası_2026-09.pdf"], "Elektrik_Faturası_{year}-{month}"),
            (["Kira Ödemesi Ağustos 2026.pdf", "Kira Ödemesi Eylül 2026.pdf"], "Kira Ödemesi {monthName} {year}"),
            (["123456789_El_08_26.pdf", "123456789_El_09_26.pdf"], "123456789_El_{month}_{yy}"),
            (["Dekont_15.08.2026.pdf", "Dekont_03.09.2026.pdf"], "Dekont_{day}.{month}.{year}"),
        ],
        paths: [
            (["2025/01-Ocak", "2025/02-Şubat", "2026/10-Ekim"], "{year}/{month}-{monthName}"),
            (["2025/11", "2026/03"], "{year}/{month}"),
            (["Faturalar/2025", "Faturalar/2026"], "Faturalar/{year}"),
        ]
    )

    static let english = Language(
        code: "en",
        folders: ["Bills/Electricity", "Bills/Water", "Bills/Gas", "Bills/Internet", "Insurance/Car", "Insurance/Health",
                  "Bank/Statements", "Bank/Credit Card", "Taxes/Returns", "Work/Payslips"],
        place: [
            ("Electricity bill October 2026.pdf", "Power company electricity bill, kWh used, due 15 November 2026", "Bills/Electricity"),
            ("Water bill September.pdf", "Water utility bill, cubic meters, account number", "Bills/Water"),
            ("Gas bill.pdf", "Natural gas usage charge, gas supplier", "Bills/Gas"),
            ("Internet bill.pdf", "Fiber broadband monthly plan, router rental", "Bills/Internet"),
            ("car insurance policy 2026.pdf", "Comprehensive car insurance policy, vehicle registration, premium", "Insurance/Car"),
            ("health insurance plan.pdf", "Health insurance policy, hospital network, coverage", "Insurance/Health"),
            ("account statement September.pdf", "Bank account statement, transfers, balance", "Bank/Statements"),
            ("credit card statement October.pdf", "Credit card statement, minimum payment due, purchases", "Bank/Credit Card"),
            ("income tax return 2025.pdf", "Annual income tax return, taxable income, assessment", "Taxes/Returns"),
            ("payslip September 2026.pdf", "Payslip, gross salary, social security contribution, net pay", "Work/Payslips"),
        ],
        byName: [
            ("electric_bill_nov.pdf", "Bills/Electricity"), ("gas-december-2026.pdf", "Bills/Gas"),
            ("credit_card_stmt.pdf", "Bank/Credit Card"), ("payslip_oct.pdf", "Work/Payslips"), ("water_bill.pdf", "Bills/Water"),
        ],
        unfit: [
            ("medical prescription.pdf", "Doctor's prescription, medicine name, dosage"),
            ("rental agreement.pdf", "Residential lease agreement, tenant, landlord, monthly rent"),
            ("high school diploma.pdf", "Diploma, graduation, school principal"),
            ("flight ticket London.pdf", "Flight ticket, booking reference, departure, arrival, seat"),
            ("vet vaccination record.pdf", "Cat vaccination record, rabies vaccine, veterinarian"),
        ],
        names: [
            (["Electricity_Bill_2026-08.pdf", "Electricity_Bill_2026-09.pdf"], "Electricity_Bill_{year}-{month}"),
            (["Rent Payment August 2026.pdf", "Rent Payment September 2026.pdf"], "Rent Payment {monthName} {year}"),
            (["987654321_El_08_26.pdf", "987654321_El_09_26.pdf"], "987654321_El_{month}_{yy}"),
            (["Receipt_15.08.2026.pdf", "Receipt_03.09.2026.pdf"], "Receipt_{day}.{month}.{year}"),
        ],
        paths: [
            (["2025/01-January", "2025/02-February", "2026/10-October"], "{year}/{month}-{monthName}"),
            (["2025/11", "2026/03"], "{year}/{month}"),
            (["Bills/2025", "Bills/2026"], "Bills/{year}"),
        ]
    )

    static let romanian = Language(
        code: "ro",
        folders: ["Facturi/Electricitate", "Facturi/Apă", "Facturi/Gaze", "Facturi/Internet", "Asigurări/Auto", "Asigurări/Sănătate",
                  "Bancă/Extrase", "Bancă/Card de credit", "Taxe/Declarații", "Muncă/Fluturași"],
        place: [
            ("Factură energie electrică octombrie 2026.pdf", "Factură de energie electrică, consum kWh, termen de plată 15.11.2026", "Facturi/Electricitate"),
            ("Factură apă septembrie.pdf", "Factură de apă, consum metri cubi, cod client", "Facturi/Apă"),
            ("Factură gaze naturale.pdf", "Consum de gaze naturale, furnizor de gaz", "Facturi/Gaze"),
            ("Factură internet.pdf", "Abonament lunar internet prin fibră, închiriere router", "Facturi/Internet"),
            ("poliță asigurare auto 2026.pdf", "Poliță de asigurare auto CASCO, număr de înmatriculare, primă", "Asigurări/Auto"),
            ("asigurare de sănătate.pdf", "Poliță de asigurare de sănătate, rețea de spitale, acoperire", "Asigurări/Sănătate"),
            ("extras de cont septembrie.pdf", "Extras de cont bancar, transferuri, sold", "Bancă/Extrase"),
            ("extras card de credit octombrie.pdf", "Extras card de credit, plată minimă, cumpărături", "Bancă/Card de credit"),
            ("declarație unică 2025.pdf", "Declarație fiscală anuală, venit impozabil, impozit", "Taxe/Declarații"),
            ("fluturaș de salariu septembrie 2026.pdf", "Fluturaș de salariu, salariu brut, contribuții, salariu net", "Muncă/Fluturași"),
        ],
        byName: [
            ("factura_curent_noiembrie.pdf", "Facturi/Electricitate"), ("gaze-decembrie-2026.pdf", "Facturi/Gaze"),
            ("extras_card_credit.pdf", "Bancă/Card de credit"), ("fluturas_octombrie.pdf", "Muncă/Fluturași"), ("factura_apa.pdf", "Facturi/Apă"),
        ],
        unfit: [
            ("rețetă medicală.pdf", "Rețetă de la medic, numele medicamentului, doză"),
            ("contract de închiriere.pdf", "Contract de închiriere locuință, chiriaș, proprietar, chirie lunară"),
            ("diplomă de bacalaureat.pdf", "Diplomă, absolvire, liceu"),
            ("bilet de avion Londra.pdf", "Bilet de avion, cod rezervare, plecare, sosire, loc"),
            ("carnet vaccinare veterinar.pdf", "Carnet de vaccinare pisică, vaccin antirabic, medic veterinar"),
        ],
        names: [
            (["Factură_Curent_2026-08.pdf", "Factură_Curent_2026-09.pdf"], "Factură_Curent_{year}-{month}"),
            (["Plată Chirie August 2026.pdf", "Plată Chirie Septembrie 2026.pdf"], "Plată Chirie {monthName} {year}"),
            (["555666777_El_08_26.pdf", "555666777_El_09_26.pdf"], "555666777_El_{month}_{yy}"),
            (["Chitanță_15.08.2026.pdf", "Chitanță_03.09.2026.pdf"], "Chitanță_{day}.{month}.{year}"),
        ],
        paths: [
            (["2025/01-Ianuarie", "2025/02-Februarie", "2026/10-Octombrie"], "{year}/{month}-{monthName}"),
            (["2025/11", "2026/03"], "{year}/{month}"),
            (["Facturi/2025", "Facturi/2026"], "Facturi/{year}"),
        ]
    )

    static let cases = turkish.cases + english.cases + romanian.cases

    /// Sağlayıcının yerel sohbet modeli; yoksa nedeni.
    static func model(for provider: SuggestionProvider) async -> (model: (any SuggestionModel)?, name: String, problem: String?) {
        let environment = ProcessInfo.processInfo.environment
        switch provider {
        case .apple, .automatic:
            let model = OnDeviceSuggestionModel()
            return model.isAvailable ? (model, "Apple Intelligence", nil) : (nil, "Apple Intelligence", "bu Mac'te kullanılamıyor")
        case .ollama, .lmStudio:
            let server = provider.server ?? .ollama
            guard let models = await server.models() else { return (nil, server.displayName, "sunucu yanıt vermiyor (127.0.0.1:\(server.port))") }
            let wanted = environment[server == .ollama ? "COPIATOR_AI_EVAL_OLLAMA_MODEL" : "COPIATOR_AI_EVAL_LMSTUDIO_MODEL"]
            guard let name = wanted.flatMap({ models.contains($0) ? $0 : nil }) ?? models.first else {
                return (nil, server.displayName, "yerel sohbet modeli yok (gömme ve bulut modelleri sayılmaz)")
            }
            return (LocalServerSuggestionModel(server: server, model: name, isAvailable: true), "\(server.displayName) · \(name)", nil)
        }
    }

    /// Bir soru: model nil ise yapay zekâsız taban çizgisi.
    static func run(_ item: Case, model: (any SuggestionModel)?) async -> (Outcome, String) {
        func outcome<Value>(_ result: SuggestionResult<Value>) -> Outcome {
            if case .unavailable = result { return .unavailable }
            return .none
        }
        switch item.task {
        case .place, .placeByName, .newFolder:
            guard let model else {
                let first = FolderSuggester.suggestions(for: item.file, folders: item.candidates, content: item.content, limit: 1).first?.path
                guard let first else { return (.none, "") }
                return (item.task != .newFolder && first == item.expected ? .correct : .wrong, first)
            }
            let result = await Suggestions.placeFile(item.file, content: item.content, candidates: item.candidates, model: model)
            guard let answer = result.value else { return (outcome(result), "") }
            let text = answer.newFolder.map { "yeni: \($0)" } ?? answer.order.prefix(2).joined(separator: ", ")
            if item.task == .newFolder { return (answer.newFolder != nil ? .correct : .wrong, text) }
            return (answer.newFolder == nil && answer.order.first == item.expected ? .correct : .wrong, text)
        case .folderTemplate:
            let result = await Suggestions.folderTemplate(examples: item.examples, model: model)
            guard let answer = result.value else { return (outcome(result), "") }
            return (answer == item.expected ? .correct : .wrong, answer)
        case .nameTemplate:
            let result = await Suggestions.nameTemplate(for: item.file, examples: item.examples, model: model)
            guard let answer = result.value else { return (outcome(result), "") }
            return (answer.precomposedStringWithCanonicalMapping == item.expected?.precomposedStringWithCanonicalMapping ? .correct : .wrong, answer)
        }
    }

    @Test func threeLanguagesWithLocalModelsOnly() async throws {
        var rows: [Row] = []
        var missing: [String] = []
        var providers: [(name: String, model: (any SuggestionModel)?)] = [("Yalnızca kurallar", nil)]
        for provider in SuggestionProvider.models {
            let (model, name, problem) = await Self.model(for: provider)
            guard let model else {
                missing.append("\(name): \(problem ?? "")")
                continue
            }
            // Yalnızca yerel modeller: bulut ve gömme modeli hiç seçilmez.
            if let local = model as? LocalServerSuggestionModel {
                #expect(!LocalModelServer.isCloud(local.model) && !local.model.lowercased().contains("embed"), "\(local.model)")
            }
            providers.append((name, model))
        }
        // Varsayılan "Otomatik": hazır modeller sırayla (Apple → Ollama → LM Studio); kullanıcının gerçekte gördüğü.
        let ready = providers.dropFirst().map { (name: $0.name, model: $0.model!) }
        if ready.count > 1 { providers.append(("Otomatik (" + ready.map(\.name).joined(separator: " → ") + ")", FallbackSuggestionModel(ready))) }
        let checksFit = ProcessInfo.processInfo.environment["COPIATOR_AI_EVAL_NO_FIT"] != "1"
        for provider in providers {
            for item in Self.cases {
                let clock = ContinuousClock()
                let start = clock.now
                let (outcome, answer) = await Suggestions.$checksFit.withValue(checksFit) { await Self.run(item, model: provider.model) }
                let elapsed = start.duration(to: clock.now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                rows.append(Row(provider: provider.name, item: item, outcome: outcome, answer: answer, seconds: seconds))
            }
        }

        func count(_ rows: [Row], _ outcome: Outcome) -> Int { rows.filter { $0.outcome == outcome }.count }
        var report = "## Özet\n\n| Model | tr | en | ro | Doğru | Yanlış öneri | Öneri yok | Kullanılamıyor | Ort. süre (sn) |\n|---|---|---|---|---|---|---|---|---|\n"
        for provider in providers.map(\.name) {
            let mine = rows.filter { $0.provider == provider }
            func score(_ language: String) -> String {
                let part = mine.filter { $0.item.language == language }
                return "\(count(part, .correct))/\(part.count)"
            }
            let average = mine.map(\.seconds).reduce(0, +) / Double(max(mine.count, 1))
            report += "| \(provider) | \(score("tr")) | \(score("en")) | \(score("ro")) | \(count(mine, .correct))/\(mine.count) | "
                + "\(count(mine, .wrong)) | \(count(mine, .none)) | \(count(mine, .unavailable)) | \(String(format: "%.1f", average)) |\n"
        }
        report += "\n## Görevlere göre doğru\n\n| Model | " + Task.allCases.map(\.rawValue).joined(separator: " | ") + " |\n|---|"
            + Task.allCases.map { _ in "---|" }.joined() + "\n"
        for provider in providers.map(\.name) {
            let mine = rows.filter { $0.provider == provider }
            let cells = Task.allCases.map { task -> String in
                let part = mine.filter { $0.item.task == task }
                return "\(count(part, .correct))/\(part.count)" + (count(part, .wrong) > 0 ? " (\(count(part, .wrong)) yanlış)" : "")
            }
            report += "| \(provider) | " + cells.joined(separator: " | ") + " |\n"
        }
        report += "\n## Ayrıntı (doğru olmayanlar)\n\n| Model | Dil | Görev | Soru | Sonuç | Yanıt | Beklenen |\n|---|---|---|---|---|---|---|\n"
        for row in rows where row.outcome != .correct {
            let question = row.item.file.isEmpty ? row.item.examples.prefix(2).joined(separator: ", ") : row.item.file
            report += "| \(row.provider) | \(row.item.language) | \(row.item.task.rawValue) | \(question) | \(row.outcome.rawValue) | "
                + "\(row.answer.isEmpty ? "—" : "`\(row.answer)`") | \(row.item.expected.map { "`\($0)`" } ?? "yeni klasör") |\n"
        }
        for line in missing { report += "\n- ❌ \(line)" }
        print(report)
        if let path = ProcessInfo.processInfo.environment["COPIATOR_AI_EVAL_REPORT"] {
            try Data(report.utf8).write(to: URL(fileURLWithPath: path))
        }
        // Yerel modeller zorunlu: yerel sohbet modeli olmayan sağlayıcı başarısızdır.
        for line in missing { Issue.record("Yerel model zorunlu — \(line)") }
    }
}
