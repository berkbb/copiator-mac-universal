// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Öneri üreten dil modeli. Uygulama yalnızca bu Mac'te çalışan modelleri kullanır: Apple Intelligence'ın cihaz üstü modeli
/// ya da 127.0.0.1'deki yerel bir sunucu (Ollama, LM Studio; bkz. `LocalModelServer`). Bulut modeli (Private Cloud Compute,
/// Ollama'nın bulut modelleri) ve dış hizmetler kullanılmaz. Testler sahte bir model verir.
public protocol SuggestionModel: Sendable {
    var isAvailable: Bool { get }
    func respond(instructions: String, prompt: String) async throws -> String
    /// Listeden seçim: yanıt `choices`tan biri olmalıdır. Yönlendirilmiş üretimi destekleyen model (Apple) yalnızca
    /// listedekilerden birini üretebilir; öbürleri serbest yanıt verir (çağıran doğrular).
    func choose(instructions: String, prompt: String, choices: [String]) async throws -> String
    /// Klasörler numarayla değil adıyla ve yönlendirilmiş üretimle sorulur (bkz. `Suggestions.placeFile`).
    var choosesByName: Bool { get }
}

extension SuggestionModel {
    public func choose(instructions: String, prompt: String, choices: [String]) async throws -> String {
        try await respond(instructions: instructions, prompt: prompt)
    }

    public var choosesByName: Bool { false }
}

/// macOS'un cihaz üstü dil modeli (Foundation Models, `SystemLanguageModel.default`). Değerlendirmede (AIEvaluationTests)
/// aday numarasını içeriğe değil listedeki konuma göre seçtiği görüldü; bu yüzden klasörler adıyla ve yönlendirilmiş
/// üretimle (yanıt yalnızca listedekilerden biri olabilir) sorulur, yanıtlar rastgelelik olmadan (greedy) üretilir.
public struct OnDeviceSuggestionModel: SuggestionModel {
    public init() {}

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    public var choosesByName: Bool { true }

    public func respond(instructions: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        return try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy)).content
        #else
        throw LocalModelServer.Failure.unavailable
        #endif
    }

    public func choose(instructions: String, prompt: String, choices: [String]) async throws -> String {
        #if canImport(FoundationModels)
        guard !choices.isEmpty, Set(choices).count == choices.count else { throw LocalModelServer.Failure.badResponse }
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Choice", anyOf: choices), dependencies: [])
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        let response = try await session.respond(to: prompt, schema: schema, options: GenerationOptions(samplingMode: .greedy))
        return try response.content.value(String.self)
        #else
        throw LocalModelServer.Failure.unavailable
        #endif
    }
}

/// Bir öneri isteğinin sonucu. Hata hiçbir zaman dışarı taşmaz: model hata verse, yanıt vermese ya da zaman aşımına uğrasa
/// da sonuç `unavailable` olur ve kural tabanlı öneriler kalır.
public enum SuggestionResult<Value: Sendable>: Sendable {
    case value(Value)
    /// En az bir model yanıt verdi ama geçerli bir öneri çıkmadı.
    case noSuggestion
    /// Hiçbir model yanıt veremedi (kapalı, erişilemedi, hata verdi ya da zaman aşımı): öneri motoru kullanılamıyor.
    case unavailable

    public var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }
}

extension SuggestionResult: Equatable where Value: Equatable {}

/// Dil modeliyle klasör sıralaması, dosyanın yeri ve şablon önerisi. Model yalnızca öneri verir: yanıt ayrıştırılır ve
/// doğrulanır (var olmayan klasör, bilinmeyen belirteç, "/" içeren ad, örnek adları yeniden üretmeyen şablon kabul
/// edilmez); kullanıcı onaylamadan hiçbir şey uygulanmaz. Her çağrı `timeout` ile sınırlıdır; hata ve zaman aşımı
/// `SuggestionResult.unavailable` olur, geçersiz yanıt `noSuggestion`; ikisinde de kural tabanlı öneri kalır.
public enum Suggestions {
    /// Modele gösterilen en çok aday klasör.
    public static let maxCandidates = 10
    /// Bir model çağrısının en uzun süresi (yerel sunucuda model ilk yüklenirken şablonlar 40 saniyeyi aşabiliyor).
    @TaskLocal public static var timeout: Duration = .seconds(90)
    /// Uygunluk denetimi ve Otomatik'te çapraz denetim yapılır mı (değerlendirmede karşılaştırma için kapatılabilir).
    @TaskLocal static var checksFit = true
    @TaskLocal static var crossChecks = true
    /// Adla seçimde "hiçbiri uymuyor" seçeneği.
    static let noneChoice = "(none of these)"
    /// İstemde içerikten gösterilen en çok karakter.
    static let maxContent = 600

    // İstemlerde örnek yanıt (aday numarası, klasör yolu) yazılmaz: modeller örneği kopyalıyordu (bkz. AIEvaluationTests).
    static let rankingInstructions = """
        You choose the best destination folder for a file in a personal archive. You get the file name, optionally the \
        beginning of its contents, and a numbered list of existing folders. Answer only with the numbers of the most \
        suitable folders from that list, best first, separated by commas. Do not explain.
        """

    static let templateInstructions = """
        You help name files in a personal archive. You get example file names that already exist in a folder and the name \
        of a new file. Write a naming template so that the new file gets a name like the examples. Copy the text that is \
        the same in all examples exactly, including accented letters, underscores and hyphens. Do not use words from the \
        new file's name; it only identifies the file. Replace only the parts that change between the examples with these \
        tokens: {year} (2026), {yy} (26), {month} (two-digit month 01 to 12, when the examples write the month as a \
        number), {monthName} (only when the examples write the month as a word), {day} (01 to 31), {name} (only when the \
        examples contain the original file name). Do not write a file extension, quotes or brackets. Answer with the \
        template only. Example: for Rapor_2025-01.xlsx and Rapor_2025-02.xlsx the template is Rapor_{year}-{month}.
        """

    static let folderTemplateInstructions = """
        You help organize a personal archive. You get example folder paths that already exist inside a destination folder. \
        Write a subfolder template for new files that follows their pattern. Keep fixed folder names exactly. Where the \
        examples contain a date, use only these tokens: {year} (2026), {yy} (26), {month} (01 to 12), {monthName} (month \
        name), {day} (01 to 31). Separate folders with /. Do not write quotes or brackets. Answer with the template only. \
        Example: for Reports-2024/03 and Reports-2025/11 the template is Reports-{year}/{month}.
        """

    static let placementInstructions = """
        You choose where a file goes in a personal archive. You get the file name, optionally the beginning of its \
        contents, and a numbered list of existing folders. Answer only with the numbers of the suitable folders from that \
        list, best first, separated by commas. If none of them fits, answer NEW: followed by a short folder path for the \
        file inside the archive (one or two folder names separated by /), reusing an existing folder as the parent when \
        one fits. Do not explain.
        """

    static let choiceInstructions = """
        You choose the folder where a file belongs in a personal archive. You get the file name, optionally the beginning \
        of its contents, and the existing folders. Choose the folder whose name matches what the file is about. Choose \
        \(noneChoice) only when no folder fits.
        """

    static let newFolderInstructions = """
        You name a folder for a file in a personal archive. You get the file name, optionally the beginning of its \
        contents, and the existing folders, none of which fits. Answer only with a short folder path for the file (one or \
        two folder names separated by /), reusing an existing parent folder when one fits, in the language of the file \
        name. Do not explain.
        """

    static let fitInstructions = """
        You check whether a file belongs in a folder of a personal archive. You get the file name, optionally the \
        beginning of its contents, and one folder. Answer yes only if the folder is the right place for this file; \
        otherwise answer no.
        """

    /// Bir dosya için modelin önerisi: aday klasörlerin sırası ve (hiçbiri uymuyorsa) hedefte yeni bir klasör yolu.
    public struct FilePlacement: Equatable, Sendable {
        /// Modelin seçtiği aday klasörler, en uygunu başta.
        public var order: [String]
        /// Önerilen yeni klasör (hedefe göre göreli, güvenli; adaylardan biriyle aynıysa nil ve o aday `order`da başta).
        public var newFolder: String?
    }

    /// Kural tabanlı önerileri modelin seçtiği sıraya dizer; modelin seçmedikleri ardından gelir. Adla seçen model (Apple)
    /// yalnızca en uygun klasörü seçer ve o başa geçer.
    public static func rankFolders(
        _ suggestions: [FolderSuggester.Suggestion], for name: String, content: String?, model: any SuggestionModel
    ) async -> SuggestionResult<[FolderSuggester.Suggestion]> {
        let candidates = Array(suggestions.prefix(maxCandidates))
        guard candidates.count > 1 else { return .noSuggestion }
        let paths = candidates.map(\.path)
        let header = header(name, content)
        let result: SuggestionResult<[String]> = await ask(model) { member in
            if member.choosesByName {
                switch await chooseByName(header, paths, member) {
                case .value(let chosen?): return .value([chosen])
                case .value(nil), .invalid: return .invalid
                case .failed: return .failed
                }
            }
            let prompt = header + "Folders:\n" + paths.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            guard let answer = await reply(member, instructions: rankingInstructions, prompt: prompt) else { return .failed }
            let order = parseOrder(answer, count: paths.count).map { paths[$0 - 1] }
            return order.isEmpty ? .invalid : .value(order)
        }
        switch result {
        case .value(let order):
            let chosen = order.compactMap { path in candidates.first { $0.path == path } }
            return .value(chosen + suggestions.filter { suggestion in !chosen.contains { $0.path == suggestion.path } })
        case .noSuggestion: return .noSuggestion
        case .unavailable: return .unavailable
        }
    }

    /// Bir dosyanın hedefteki yerini önerir: adaylardan seçer ya da hiçbiri uymuyorsa yeni bir klasör yolu yazar. Yanıt
    /// doğrulanır; yeni yol hedefin içinde kalır (`PlacementResolution.clean`) ve belirteç içeremez.
    public static func placeFile(
        _ name: String, content: String?, candidates: [String], model: any SuggestionModel
    ) async -> SuggestionResult<FilePlacement> {
        let shown = Array(candidates.prefix(maxCandidates))
        let header = header(name, content)
        return await ask(model) { member, next in
            let attempt = await placeOnce(header, shown, member)
            // Otomatik: Apple'ın seçtiği var olan klasörü sıradaki hazır model de onaylamalı. "Hayır" derse Apple'ın yanıtı
            // kullanılmaz ve sıradaki modelin kararı geçer; "evet" derse ya da yanıt veremezse Apple'ın seçimi kalır.
            if crossChecks, member.choosesByName, let next, case .value(let placement) = attempt, placement.newFolder == nil,
               let chosen = placement.order.first, await fits(header, chosen, next) == false {
                return .invalid
            }
            return attempt
        }
    }

    /// Bir modelin tek başına kararı: adla ya da numarayla seçim, ardından uygunluk denetimi.
    static func placeOnce(_ header: String, _ shown: [String], _ member: any SuggestionModel) async -> Attempt<FilePlacement> {
        let placement: FilePlacement
        if member.choosesByName {
            switch await chooseByName(header, shown, member) {
            case .value(let chosen?): placement = FilePlacement(order: [chosen], newFolder: nil)
            case .value(nil): return await newFolder(header, shown, member)
            case .invalid: return .invalid
            case .failed: return .failed
            }
        } else {
            let list = shown.isEmpty ? "(none)" : shown.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            guard let answer = await reply(member, instructions: placementInstructions, prompt: header + "Folders:\n" + list) else { return .failed }
            guard let parsed = parsePlacement(answer, candidates: shown) else { return .invalid }
            placement = parsed
        }
        // Uygunluk denetimi: seçilen klasöre "hayır" denirse uygun klasör yoktur, yeni klasör sorulur.
        if checksFit, placement.newFolder == nil, let chosen = placement.order.first, await fits(header, chosen, member) == false {
            return await newFolder(header, shown, member)
        }
        return .value(placement)
    }

    /// Seçilen klasörün dosyaya gerçekten uyup uymadığı (evet/hayır; adla seçen model yalnızca "yes" ya da "no" üretebilir).
    /// Yanıt yoksa ya da anlaşılmazsa nil: modelin seçimi korunur.
    static func fits(_ header: String, _ folder: String, _ model: any SuggestionModel) async -> Bool? {
        guard let answer = await reply(model, instructions: fitInstructions, prompt: header + "Folder: \(folder)\nAnswer yes or no.",
                                       choices: model.choosesByName ? ["yes", "no"] : nil)
        else { return nil }
        let word = answer.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        if ["yes", "evet", "da"].contains(where: { word.hasPrefix($0) }) { return true }
        if ["no", "hayır", "nu"].contains(where: { word.hasPrefix($0) }) { return false }
        return nil
    }

    static func header(_ name: String, _ content: String?) -> String {
        var header = "File: \(name)\n"
        if let content, !content.isEmpty { header += "Contents: \(content.prefix(maxContent))\n" }
        return header
    }

    /// Adla seçim (Apple): klasörler listede bir kez verilen, bir kez ters sırayla sorulur; iki yanıt aynı değilse model
    /// konuma göre seçiyordur ve öneri kabul edilmez. Sonuç: seçilen klasör, "hiçbiri" için nil.
    static func chooseByName(_ header: String, _ folders: [String], _ model: any SuggestionModel) async -> Attempt<String?> {
        guard !folders.isEmpty else { return .value(nil) }
        func listing(_ folders: [String]) -> String { "Folders:\n" + folders.map { "- \($0)" }.joined(separator: "\n") }
        guard let first = await reply(model, instructions: choiceInstructions, prompt: header + listing(folders), choices: folders + [noneChoice]),
              let second = await reply(model, instructions: choiceInstructions, prompt: header + listing(folders.reversed()),
                                       choices: folders.reversed() + [noneChoice])
        else { return .failed }
        guard first == second else { return .invalid }
        if first == noneChoice { return .value(nil) }
        return folders.contains(first) ? .value(first) : .invalid
    }

    /// Hiçbir klasör uymuyorsa yeni klasör yolu (adla seçen model için ayrı soru).
    static func newFolder(_ header: String, _ folders: [String], _ model: any SuggestionModel) async -> Attempt<FilePlacement> {
        let existing = folders.isEmpty ? "(none)" : folders.map { "- \($0)" }.joined(separator: "\n")
        guard let answer = await reply(model, instructions: newFolderInstructions, prompt: header + "Existing folders:\n" + existing)
        else { return .failed }
        let line = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return parsePlacement("NEW: " + line, candidates: folders).map { .value($0) } ?? .invalid
    }

    /// "NEW: yol" satırı yeni klasör olur (aday klasörlerden biriyle aynıysa o aday seçilir); öbür satırlardaki aday
    /// numaraları sırayı verir. İkisi de yoksa nil.
    static func parsePlacement(_ answer: String, candidates: [String]) -> FilePlacement? {
        var numbers = ""
        var newFolder: String?
        for line in answer.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-*•")))
            guard trimmed.range(of: "NEW:", options: [.caseInsensitive, .anchored]) != nil else {
                numbers += trimmed + "\n"
                continue
            }
            let raw = String(trimmed.dropFirst(4)).unicodeScalars.filter { !"`\"'“”‘’<>*".unicodeScalars.contains($0) }
            let folder = PlacementResolution.clean(String(String.UnicodeScalarView(raw)).trimmingCharacters(in: .whitespaces))
            if !folder.isEmpty, !folder.contains("{"), folder.count <= 160, folder.split(separator: "/").count <= 6 { newFolder = folder }
        }
        var order = parseOrder(numbers, count: candidates.count).map { candidates[$0 - 1] }
        if let folder = newFolder, let existing = candidates.first(where: { FolderSuggester.fold($0) == FolderSuggester.fold(folder) }) {
            order.removeAll { $0 == existing }
            order.insert(existing, at: 0)
            newFolder = nil
        }
        guard !order.isEmpty || newFolder != nil else { return nil }
        return FilePlacement(order: order, newFolder: newFolder)
    }

    /// Hedefteki örnek klasör yollarına bakarak alt klasör şablonu önerir (ör. "{year}/{month}-{monthName}").
    /// Önce kurala bağlı çıkarım (`TemplateInference`); çözemezse (ve model verildiyse) model sorulur. Şablon, örnek
    /// klasörleri yeniden üretmelidir (`reproducesFolders`).
    public static func folderTemplate(examples: [String], model: (any SuggestionModel)?) async -> SuggestionResult<String> {
        let shown = Array(examples.prefix(12))
        guard !shown.isEmpty else { return .noSuggestion }
        if let inferred = TemplateInference.folderTemplate(from: shown), reproducesFolders(inferred, examples: shown) { return .value(inferred) }
        guard let model else { return .noSuggestion }
        let prompt = "Examples:\n" + shown.map { "- \($0)" }.joined(separator: "\n") + "\nTemplate:"
        return await ask(model) { member in
            guard let answer = await reply(member, instructions: folderTemplateInstructions, prompt: prompt) else { return .failed }
            guard let template = cleanFolderTemplate(answer), reproducesFolders(template, examples: shown) else { return .invalid }
            return .value(template)
        }
    }

    /// Model yanıtından geçerli bir alt klasör şablonu: ilk dolu satır; tırnak ve ayraçlar, "Template:" gibi önek, baştaki
    /// ve sondaki "/" atılır. En az bir tarih belirteci olmalı; bilinmeyen belirteç ya da ".." kabul edilmez.
    static func cleanFolderTemplate(_ answer: String) -> String? {
        guard var line = answer.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return nil }
        if let colon = line.range(of: ":"), !line[..<colon.lowerBound].contains("{"), line[..<colon.lowerBound].count < 20 {
            line = String(line[colon.upperBound...])
        }
        line = String(line.unicodeScalars.filter { !"`\"'“”‘’()[]<>*".unicodeScalars.contains($0) })
        let parts = line.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        line = parts.joined(separator: "/")
        guard !line.isEmpty, line.count <= 160, !parts.contains(where: { $0 == "." || $0 == ".." }), !line.contains("{}") else { return nil }
        guard RoutePlacement(folderTemplate: line).problems().isEmpty,
              PlacementToken.tokens(in: line).contains(where: { $0?.isDate == true }) else { return nil }
        return line
    }

    /// Hedefteki örnek klasör yolları: dosya içeren klasörler (en çok 4 düzey; gizliler ve paketlerin içi hariç), en yeni
    /// değişenler önce.
    public static func exampleFolders(in destination: URL, limit: Int = 12) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants, .producesRelativePathURLs])
        else { return [] }
        var folders: [String: Date] = [:]
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 20_000 { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true, values.isPackage != true {
                // Derinlik sınırı yalnızca klasörde uygulanır (dosyada atlama klasörün geri kalanını atlardı).
                if enumerator.level > 5 { enumerator.skipDescendants() }
                continue
            }
            let folder = (url.relativePath as NSString).deletingLastPathComponent
            guard !folder.isEmpty else { continue }
            let date = values.contentModificationDate ?? .distantPast
            folders[folder] = max(folders[folder] ?? .distantPast, date)
        }
        return folders.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key.precomposedStringWithCanonicalMapping)
    }

    /// Bir modelle tek deneme: geçerli öneri, geçersiz yanıt ya da yanıt yok (hata, zaman aşımı).
    enum Attempt<Value> {
        case value(Value)
        case invalid
        case failed
    }

    /// Modele sorar. "Otomatik"te (`FallbackSuggestionModel`) modeller sırayla denenir: kullanılamayan atlanır, hata veren,
    /// zaman aşımına uğrayan ya da geçersiz yanıt veren modelden sonra sıradaki sorulur. Hiçbir model yanıt veremediyse
    /// `unavailable`, yanıt verip geçerli öneri çıkmadıysa `noSuggestion`; hata dışarı taşmaz.
    static func ask<Value: Sendable>(
        _ model: any SuggestionModel, attempt: (any SuggestionModel) async -> Attempt<Value>
    ) async -> SuggestionResult<Value> {
        await ask(model) { member, _ in await attempt(member) }
    }

    /// `ask` ile aynı; deneme sıradaki hazır modeli de alır (Otomatik'te çapraz denetim için; tek modelde nil).
    static func ask<Value: Sendable>(
        _ model: any SuggestionModel, attempt: (any SuggestionModel, (any SuggestionModel)?) async -> Attempt<Value>
    ) async -> SuggestionResult<Value> {
        let chain = model as? FallbackSuggestionModel
        var answered = false
        let members = (chain?.members ?? [(name: "", model: model)]).filter { $0.model.isAvailable }
        for (index, member) in members.enumerated() {
            switch await attempt(member.model, members.dropFirst(index + 1).first?.model) {
            case .value(let value):
                chain?.record(member.name)
                return .value(value)
            case .invalid:
                answered = true
            case .failed:
                continue
            }
        }
        return answered ? .noSuggestion : .unavailable
    }

    /// Tek bir model çağrısı, `timeout` ile sınırlı: hata ya da zaman aşımında nil. Süre dolunca çağrı iptal edilir ve
    /// beklenmez (modelin iptali dinlemesi gerekmez).
    static func reply(_ model: any SuggestionModel, instructions: String, prompt: String, choices: [String]? = nil) async -> String? {
        let limit = timeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = Once(continuation)
            let work = Task {
                let answer: String?
                if let choices {
                    answer = try? await model.choose(instructions: instructions, prompt: prompt, choices: choices)
                } else {
                    answer = try? await model.respond(instructions: instructions, prompt: prompt)
                }
                once.resume(answer)
            }
            Task {
                try? await Task.sleep(for: limit)
                work.cancel()
                once.resume(nil)
            }
        }
    }

    /// Devamı yalnızca bir kez sürdürür (yanıt ile zaman aşımı yarışır).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?

        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

        func resume(_ value: String?) {
            let pending = lock.withLock { () -> CheckedContinuation<String?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }

    /// Yanıttaki 1…count arası sayılar, ilk geçiş sırasıyla, tekrarsız.
    static func parseOrder(_ answer: String, count: Int) -> [Int] {
        var order: [Int] = []
        for token in answer.split(whereSeparator: { !$0.isNumber }) {
            guard let number = Int(token), (1...count).contains(number), !order.contains(number) else { continue }
            order.append(number)
        }
        return order
    }

    /// Hedefteki örnek adlara bakarak yeni dosya için ad şablonu önerir.
    /// Önce kurala bağlı çıkarım (`TemplateInference`); çözemezse (ve model verildiyse) model sorulur. Şablon, örnek adları
    /// yeniden üretmelidir (`reproducesNames`).
    public static func nameTemplate(for name: String, examples: [String], model: (any SuggestionModel)?) async -> SuggestionResult<String> {
        let shown = Array(examples.prefix(10))
        guard !shown.isEmpty else { return .noSuggestion }
        if let inferred = TemplateInference.nameTemplate(from: shown), reproducesNames(inferred, examples: shown) { return .value(inferred) }
        guard let model else { return .noSuggestion }
        let prompt = "Examples:\n" + shown.map { "- \($0)" }.joined(separator: "\n") + "\nNew file: \(name)\nTemplate:"
        return await ask(model) { member in
            guard let answer = await reply(member, instructions: templateInstructions, prompt: prompt) else { return .failed }
            guard let template = cleanTemplate(answer), reproducesNames(template, examples: shown) else { return .invalid }
            return .value(template)
        }
    }

    /// Ad şablonu örnek adları yeniden üretiyor mu: her örneğin tarihi adından bulunur ve şablon o tarihle uygulanınca
    /// örneğin adı çıkmalıdır (`{name}` herhangi bir metne uyar; ay adları Türkçe, İngilizce ya da Rumence olabilir). Tarihi
    /// bulunan örnek yoksa ya da şablon bilinemeyen bir değer (`{folder}`, hedef belirteçleri) istiyorsa kabul edilmez.
    static func reproducesNames(_ template: String, examples: [String]) -> Bool { nameLanguage(template, examples: examples) != nil }

    /// Alt klasör şablonu örnek klasör yollarını yeniden üretiyor mu (bkz. `reproducesNames`).
    static func reproducesFolders(_ template: String, examples: [String]) -> Bool { folderLanguage(template, examples: examples) != nil }

    /// Ad şablonunun örnekleri yeniden ürettiği ay adı dili ("tr", "en", "ro"); üretmiyorsa nil. Şablon ay adı içeriyorsa
    /// yerleşimin dili buna ayarlanmalıdır (yoksa Türkçe örneklerden çıkan şablon İngilizce ay adı yazardı).
    public static func nameLanguage(_ template: String, examples: [String]) -> String? {
        let bases = examples.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        return reproducingLanguage(examples: bases) { language, date in
            RoutePlacement(nameTemplate: template, language: language).target(for: placeholder, date: date)
        } usable: { !PlacementToken.tokens(in: template).contains { [.folder, .targetFolder, .targetNumber].contains($0) } }
    }

    /// Alt klasör şablonunun örnekleri yeniden ürettiği ay adı dili (bkz. `nameLanguage`).
    public static func folderLanguage(_ template: String, examples: [String]) -> String? {
        reproducingLanguage(examples: examples) { language, date in
            (RoutePlacement(folderTemplate: template, language: language).target(for: "x", date: date) as NSString).deletingLastPathComponent
        } usable: { !PlacementToken.tokens(in: template).contains { [.name, .folder, .targetFolder, .targetNumber].contains($0) } }
    }

    /// `{name}` yerine konan, ardından herhangi bir metne uyan yer tutucu.
    private static let placeholder = "copiatornameplaceholder"

    private static func reproducingLanguage(
        examples: [String], render: (String, DateComponents) -> String, usable: () -> Bool
    ) -> String? {
        // Yalnızca yılı olan örnekte ay 1 sayılır: ay belirteci içeren şablon o örneği üretemez ve reddedilir.
        let dated = examples.compactMap { example in
            TemplateInference.date(of: example).map { date -> (String, DateComponents) in
                var date = date
                if date.month == nil { date.month = 1 }
                return (FolderSuggester.fold(example), date)
            }
        }
        guard !dated.isEmpty, usable() else { return nil }
        return ["tr", "en", "ro"].first { language in
            dated.allSatisfy { example, date in
                let rendered = FolderSuggester.fold(render(language, date))
                let pattern = "^" + NSRegularExpression.escapedPattern(for: rendered).replacingOccurrences(of: placeholder, with: ".+") + "$"
                return example.range(of: pattern, options: .regularExpression) != nil
            }
        }
    }

    /// Model yanıtından geçerli bir ad şablonu: ilk dolu satır; tırnak, köşeli ve yuvarlak ayraçlar, "Template:" gibi önek
    /// ve dosya uzantısı atılır. Bilinmeyen belirteç, "/" ya da boş sonuç kabul edilmez.
    static func cleanTemplate(_ answer: String) -> String? {
        guard var line = answer.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return nil }
        if let colon = line.range(of: ":"), !line[..<colon.lowerBound].contains("{"), line[..<colon.lowerBound].count < 20 {
            line = String(line[colon.upperBound...])
        }
        line = String(line.unicodeScalars.filter { !"`\"'“”‘’()[]<>*".unicodeScalars.contains($0) })
        // Sondaki nokta ve boşluklar ("…{monthName}." ya da "….pdf.") atılır, ardından uzantı.
        func trimEnd() { while line.hasSuffix(".") || line.hasSuffix(" ") { line.removeLast() } }
        line = line.trimmingCharacters(in: .whitespaces)
        trimEnd()
        if let dot = line.range(of: ".", options: .backwards) {
            let ext = line[dot.upperBound...]
            if (1...5).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }), !ext.contains("{") { line = String(line[..<dot.lowerBound]) }
        }
        trimEnd()
        guard !line.isEmpty, line.count <= 120 else { return nil }
        let placement = RoutePlacement(nameTemplate: line)
        guard placement.problems().isEmpty, !line.contains("{}") else { return nil }
        return line
    }

    /// Bir klasördeki örnek dosya adları (gizliler hariç, en yeni değişenler önce); klasörde dosya yoksa en yeni alt
    /// klasörünkiler.
    public static func exampleNames(in folder: URL, limit: Int = 10) -> [String] {
        func files(_ url: URL) -> [(String, Date)] {
            let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            return items.compactMap { item in
                guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
                return (item.lastPathComponent, values.contentModificationDate ?? .distantPast)
            }
        }
        var found = files(folder)
        if found.isEmpty {
            let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
            let folders = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            if let newest = folders.first { found = files(newest) }
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
