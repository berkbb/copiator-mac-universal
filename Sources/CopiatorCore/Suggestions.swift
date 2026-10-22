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
}

/// macOS'un cihaz üstü dil modeli (Foundation Models, `SystemLanguageModel.default`).
public struct OnDeviceSuggestionModel: SuggestionModel {
    public init() {}

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    public func respond(instructions: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        return try await session.respond(to: prompt).content
        #else
        throw CancellationError()
        #endif
    }
}

/// Dil modeliyle klasör sıralaması ve ad şablonu önerisi. Model yalnızca öneri verir: yanıt ayrıştırılır ve doğrulanır
/// (var olmayan klasör, bilinmeyen belirteç, "/" içeren ad kabul edilmez); kullanıcı onaylamadan hiçbir şey uygulanmaz.
/// Model kullanılamıyorsa ya da yanıt geçersizse nil döner ve kural tabanlı öneri olduğu gibi kalır.
public enum Suggestions {
    /// Modele gösterilen en çok aday klasör.
    public static let maxCandidates = 10
    /// İstemde içerikten gösterilen en çok karakter.
    static let maxContent = 600

    static let rankingInstructions = """
        You choose the best destination folder for a file in a personal archive. You get the file name, optionally the \
        beginning of its contents, and a numbered list of existing folders. Answer with the numbers of the most suitable \
        folders, best first, separated by commas, for example: 3, 1, 4. Use only numbers from the list. Do not explain.
        """

    static let templateInstructions = """
        You help name files in a personal archive. You get example file names that already exist in a folder and the name \
        of a new file. Write a naming template for the new file that follows the pattern of the examples. Keep the fixed \
        parts of the examples (numbers, words, underscores, hyphens) exactly. Where the examples contain a date or the \
        original name, use only these tokens: {name} (original file name without extension), {year} (2026), {yy} (26), \
        {month} (01 to 12), {monthName} (month name), {day} (01 to 31). Do not write a file extension, quotes or brackets. \
        Answer with the template only. Example: for Rapor_2025-01.xlsx and Rapor_2025-02.xlsx the template is Rapor_{year}-{month}.
        """

    static let folderTemplateInstructions = """
        You help organize a personal archive. You get example folder paths that already exist inside a destination folder. \
        Write a subfolder template for new files that follows their pattern. Keep fixed folder names exactly. Where the \
        examples contain a date, use only these tokens: {year} (2026), {yy} (26), {month} (01 to 12), {monthName} (month \
        name), {day} (01 to 31). Separate folders with /. Do not write quotes or brackets. Answer with the template only. \
        Example: for 2025/01-January and 2025/02-February the template is {year}/{month}-{monthName}.
        """

    static let placementInstructions = """
        You choose where a file goes in a personal archive. You get the file name, optionally the beginning of its \
        contents, and a numbered list of existing folders. Answer with the numbers of the suitable folders, best first, \
        separated by commas, for example: 3, 1. If none of them fits, answer NEW: followed by a short folder path for the \
        file inside the archive, reusing an existing folder as the parent when one fits, for example NEW: Bills/Water. \
        Do not explain.
        """

    /// Bir dosya için modelin önerisi: aday klasörlerin sırası ve (hiçbiri uymuyorsa) hedefte yeni bir klasör yolu.
    public struct FilePlacement: Equatable, Sendable {
        /// Modelin seçtiği aday klasörler, en uygunu başta.
        public var order: [String]
        /// Önerilen yeni klasör (hedefe göre göreli, güvenli; adaylardan biriyle aynıysa nil ve o aday `order`da başta).
        public var newFolder: String?
    }

    /// Kural tabanlı önerileri modelin seçtiği sıraya dizer; modelin seçmedikleri ardından gelir.
    public static func rankFolders(
        _ suggestions: [FolderSuggester.Suggestion], for name: String, content: String?, model: any SuggestionModel
    ) async -> [FolderSuggester.Suggestion]? {
        let candidates = Array(suggestions.prefix(maxCandidates))
        guard candidates.count > 1 else { return nil }
        var prompt = "File: \(name)\n"
        if let content, !content.isEmpty { prompt += "Contents: \(content.prefix(maxContent))\n" }
        prompt += "Folders:\n" + candidates.enumerated().map { "\($0.offset + 1). \($0.element.path)" }.joined(separator: "\n")
        let count = candidates.count
        guard let order = await ask(model, instructions: rankingInstructions, prompt: prompt, parse: { answer -> [Int]? in
            let order = parseOrder(answer, count: count)
            return order.isEmpty ? nil : order
        }) else { return nil }
        let chosen = order.map { candidates[$0 - 1] }
        return chosen + suggestions.filter { suggestion in !chosen.contains { $0.path == suggestion.path } }
    }

    /// Bir dosyanın hedefteki yerini önerir: adaylardan seçer ya da hiçbiri uymuyorsa yeni bir klasör yolu yazar. Yanıt
    /// doğrulanır; yeni yol hedefin içinde kalır (`PlacementResolution.clean`) ve belirteç içeremez.
    public static func placeFile(
        _ name: String, content: String?, candidates: [String], model: any SuggestionModel
    ) async -> FilePlacement? {
        let shown = Array(candidates.prefix(maxCandidates))
        var prompt = "File: \(name)\n"
        if let content, !content.isEmpty { prompt += "Contents: \(content.prefix(maxContent))\n" }
        prompt += "Folders:\n" + (shown.isEmpty ? "(none)" : shown.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        return await ask(model, instructions: placementInstructions, prompt: prompt) { parsePlacement($0, candidates: shown) }
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
    public static func folderTemplate(examples: [String], model: any SuggestionModel) async -> String? {
        guard !examples.isEmpty else { return nil }
        let prompt = "Examples:\n" + examples.prefix(12).map { "- \($0)" }.joined(separator: "\n") + "\nTemplate:"
        return await ask(model, instructions: folderTemplateInstructions, prompt: prompt, parse: cleanFolderTemplate)
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
            if enumerator.level > 5 { enumerator.skipDescendants() }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true, values.isPackage != true { continue }
            let folder = (url.relativePath as NSString).deletingLastPathComponent
            guard !folder.isEmpty else { continue }
            let date = values.contentModificationDate ?? .distantPast
            folders[folder] = max(folders[folder] ?? .distantPast, date)
        }
        return folders.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key.precomposedStringWithCanonicalMapping)
    }

    /// Modele sorar ve yanıtı doğrular. "Otomatik"te (`FallbackSuggestionModel`) modeller sırayla denenir: erişilemeyen, hata
    /// veren ya da geçersiz yanıt veren modelden sonra sıradaki sorulur. Hiçbiri olmazsa nil (hata gösterilmez).
    static func ask<T>(
        _ model: any SuggestionModel, instructions: String, prompt: String, parse: (String) -> T?
    ) async -> T? {
        guard let chain = model as? FallbackSuggestionModel else {
            guard model.isAvailable, let answer = try? await model.respond(instructions: instructions, prompt: prompt) else { return nil }
            return parse(answer)
        }
        for member in chain.members where member.model.isAvailable {
            guard let answer = try? await member.model.respond(instructions: instructions, prompt: prompt), let value = parse(answer)
            else { continue }
            chain.record(member.name)
            return value
        }
        return nil
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
    public static func nameTemplate(for name: String, examples: [String], model: any SuggestionModel) async -> String? {
        guard !examples.isEmpty else { return nil }
        let prompt = "Examples:\n" + examples.prefix(10).map { "- \($0)" }.joined(separator: "\n") + "\nNew file: \(name)\nTemplate:"
        return await ask(model, instructions: templateInstructions, prompt: prompt, parse: cleanTemplate)
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
            .trimmingCharacters(in: .whitespaces)
        if let dot = line.range(of: ".", options: .backwards) {
            let ext = line[dot.upperBound...]
            if (1...5).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }), !ext.contains("{") { line = String(line[..<dot.lowerBound]) }
        }
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
