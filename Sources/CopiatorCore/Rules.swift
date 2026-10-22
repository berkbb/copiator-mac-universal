// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UniformTypeIdentifiers

/// Finder'ın akıllı klasörlerindeki gibi dosya seçme kuralları. Kurallar her çalıştırmada kaynakta yeniden değerlendirilir
/// (`RuleScanner`); uyan dosyaların listesi rsync'e `--files-from` ile verilir. Klasör yapısı korunur.

/// Bir grubun koşullarının nasıl birleşeceği.
public enum RuleMatch: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Tümü doğru.
    case all
    /// Herhangi biri doğru.
    case any
    /// Hiçbiri doğru değil.
    case none

    public var id: String { rawValue }
}

/// Koşulun baktığı özellik.
public enum RuleAttribute: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Dosyanın adı, uzantısıyla ("satis_raporu_v3.xlsx").
    case name
    /// Uzantı, noktasız ("xlsx").
    case fileExtension
    /// Dosyanın bulunduğu klasörlerden birinin adı (kaynağın içinde, herhangi bir düzeyde).
    case folderName
    /// Kaynağa göre göreli yol ("2026/Raporlar/satis.xlsx").
    case path
    /// Dosya türü (resim, tablo, PDF…).
    case kind

    public var id: String { rawValue }

    /// Bu özellikte kullanılabilen karşılaştırmalar.
    public var operators: [RuleOperator] {
        self == .kind ? [.equals] : [.contains, .equals, .beginsWith, .endsWith, .matchesRegex]
    }
}

/// Karşılaştırma. Metin karşılaştırmaları büyük/küçük harfe duyarsızdır (Finder gibi; Türkçe I/ı/İ/i birbirine eşit
/// sayılır: "SATIŞ" "Satış"a, "IMG" "img"ye uyar); düzenli ifade yazıldığı gibi uygulanır (duyarsızlık için `(?i)`),
/// adın tamamına sabitlemek için `^…$` kullanılır.
public enum RuleOperator: String, Codable, CaseIterable, Identifiable, Sendable {
    case contains
    case equals
    case beginsWith
    case endsWith
    case matchesRegex

    public var id: String { rawValue }
}

/// Dosya türleri (Uniform Type Identifiers'a göre; uzantıdan belirlenir, dosya açılmaz).
public enum FileKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case image, movie, audio, pdf, document, spreadsheet, presentation, text, sourceCode, archive, application

    public var id: String { rawValue }

    /// Türü bu olan bir öğe mi? Belge; PDF, tablo ve sunum dışındaki zengin içerikli belgelerdir (Word, Pages, RTF…).
    public func matches(_ type: UTType?) -> Bool {
        guard let type else { return false }
        switch self {
        case .image: return type.conforms(to: .image)
        case .movie: return type.conforms(to: .movie) || type.conforms(to: .video)
        case .audio: return type.conforms(to: .audio)
        case .pdf: return type.conforms(to: .pdf)
        case .spreadsheet: return type.conforms(to: .spreadsheet)
        case .presentation: return type.conforms(to: .presentation)
        case .document:
            let rich = type.conforms(to: .compositeContent) || type.conforms(to: .rtf) || type.conforms(to: .rtfd)
            return rich && !type.conforms(to: .pdf) && !type.conforms(to: .spreadsheet) && !type.conforms(to: .presentation)
        case .text: return type.conforms(to: .text)
        case .sourceCode: return type.conforms(to: .sourceCode)
        case .archive: return type.conforms(to: .archive)
        case .application: return type.conforms(to: .application)
        }
    }
}

/// Tek bir koşul: "Uzantı eşittir xlsx", "Ad düzenli ifadeye uyar ^rapor_\d+".
public struct RuleCondition: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var attribute: RuleAttribute
    public var op: RuleOperator
    /// Karşılaştırılan metin; türde `FileKind` ham değeri.
    public var value: String

    public init(id: UUID = UUID(), attribute: RuleAttribute = .name, op: RuleOperator = .contains, value: String = "") {
        self.id = id
        self.attribute = attribute
        self.op = attribute.operators.contains(op) ? op : attribute.operators[0]
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case id, attribute, op, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        attribute = (try? c.decodeIfPresent(RuleAttribute.self, forKey: .attribute)) ?? .name
        let op = (try? c.decodeIfPresent(RuleOperator.self, forKey: .op)) ?? .contains
        self.op = attribute.operators.contains(op) ? op : attribute.operators[0]
        value = (try? c.decodeIfPresent(String.self, forKey: .value)) ?? ""
    }
}

/// Koşul grubu; gruplar iç içe olabilir (Finder'da ⌥ ile eklenen gruplar gibi). Koşulsuz bir grup her şeyi seçer.
public struct RuleGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var match: RuleMatch
    public var conditions: [RuleCondition]
    public var groups: [RuleGroup]

    public init(id: UUID = UUID(), match: RuleMatch = .all, conditions: [RuleCondition] = [], groups: [RuleGroup] = []) {
        self.id = id
        self.match = match
        self.conditions = conditions
        self.groups = groups
    }

    /// Hiç koşulu yok (alt gruplarında da): her dosya seçilir.
    public var isEmpty: Bool { conditions.isEmpty && groups.allSatisfy(\.isEmpty) }

    /// İç içe grupların en çok derinliği (kötü niyetli ya da bozuk bir kayıt yığını taşırmasın).
    public static let maxDepth = 8

    private enum CodingKeys: String, CodingKey { case id, match, conditions, groups }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        match = (try? c.decodeIfPresent(RuleMatch.self, forKey: .match)) ?? .all
        // Okunamayan tek bir koşul ya da grup ötekileri silmez.
        conditions = ((try? c.decodeIfPresent([Lossy<RuleCondition>].self, forKey: .conditions)) ?? nil)?.compactMap(\.value) ?? []
        groups = ((try? c.decodeIfPresent([Lossy<RuleGroup>].self, forKey: .groups)) ?? nil)?.compactMap(\.value) ?? []
    }

    // MARK: Sorunlar

    public enum Problem: Equatable, Sendable {
        /// Değeri boş bir koşul.
        case emptyValue
        /// Geçersiz düzenli ifade (ifade ve hata açıklaması).
        case invalidRegex(String)
        case unknownKind(String)
        case tooDeep
    }

    public func problems(depth: Int = 0) -> [Problem] {
        var problems: [Problem] = depth >= Self.maxDepth ? [.tooDeep] : []
        for condition in conditions {
            let value = condition.value.trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                problems.append(.emptyValue)
            } else if condition.attribute == .kind {
                if FileKind(rawValue: value) == nil { problems.append(.unknownKind(value)) }
            } else if condition.op == .matchesRegex {
                do {
                    _ = try NSRegularExpression(pattern: condition.value)
                } catch {
                    problems.append(.invalidRegex(condition.value))
                }
            }
        }
        if depth < Self.maxDepth {
            for group in groups { problems += group.problems(depth: depth + 1) }
        }
        return problems
    }
}

/// Dizideki okunamayan öğeyi atlayan sarmalayıcı.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Değerlendirme

/// Kurala sorulan öğe: ad ve yol karşılaştırma için Unicode NFC biçiminde (macOS adları ayrık biçimde de saklayabilir).
public struct RuleItem: Sendable {
    public var name: String
    public var fileExtension: String
    public var folders: [String]
    public var relativePath: String
    public var type: UTType?

    /// - Parameter relativePath: Kaynağa göre göreli yol ("2026/Raporlar/satis.xlsx").
    public init(relativePath: String, isDirectory: Bool = false) {
        let normalized = relativePath.precomposedStringWithCanonicalMapping
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        name = components.last ?? normalized
        folders = Array(components.dropLast())
        self.relativePath = normalized
        let ext = (name as NSString).pathExtension
        fileExtension = ext
        if isDirectory {
            type = ext.isEmpty ? .folder : UTType(filenameExtension: ext, conformingTo: .package) ?? UTType(filenameExtension: ext)
        } else {
            type = ext.isEmpty ? .data : UTType(filenameExtension: ext) ?? .data
        }
    }
}

/// Derlenmiş kurallar: düzenli ifadeler bir kez derlenir.
public struct RuleEvaluator: @unchecked Sendable {
    public let rules: RuleGroup
    private let regexes: [UUID: NSRegularExpression]

    public init(_ rules: RuleGroup) throws {
        self.rules = rules
        var regexes: [UUID: NSRegularExpression] = [:]
        func compile(_ group: RuleGroup, depth: Int) throws {
            guard depth < RuleGroup.maxDepth else { return }
            for condition in group.conditions where condition.op == .matchesRegex && condition.attribute != .kind {
                regexes[condition.id] = try NSRegularExpression(pattern: condition.value.precomposedStringWithCanonicalMapping)
            }
            for child in group.groups { try compile(child, depth: depth + 1) }
        }
        try compile(rules, depth: 0)
        self.regexes = regexes
    }

    public func matches(_ item: RuleItem) -> Bool { matches(item, rules, depth: 0) }

    private func matches(_ item: RuleItem, _ group: RuleGroup, depth: Int) -> Bool {
        guard depth < RuleGroup.maxDepth else { return false }
        let results = group.conditions.lazy.map { matches(item, $0) }
            + group.groups.lazy.filter { !$0.isEmpty }.map { matches(item, $0, depth: depth + 1) }
        switch group.match {
        case .all: return results.allSatisfy { $0 }
        case .any: return results.isEmpty || results.contains(true)
        case .none: return !results.contains(true)
        }
    }

    private func matches(_ item: RuleItem, _ condition: RuleCondition) -> Bool {
        switch condition.attribute {
        case .name: return compare(item.name, condition)
        case .fileExtension: return compare(item.fileExtension, condition, stripDot: true)
        case .folderName: return item.folders.contains { compare($0, condition) }
        case .path: return compare(item.relativePath, condition)
        case .kind: return FileKind(rawValue: condition.value.trimmingCharacters(in: .whitespaces))?.matches(item.type) ?? false
        }
    }

    private func compare(_ text: String, _ condition: RuleCondition, stripDot: Bool = false) -> Bool {
        if condition.op == .matchesRegex {
            guard let regex = regexes[condition.id] else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        var value = Self.fold(condition.value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces))
        if stripDot { while value.hasPrefix(".") { value.removeFirst() } }
        guard !value.isEmpty else { return false }
        let text = Self.fold(text)
        switch condition.op {
        case .contains: return text.range(of: value, options: .caseInsensitive) != nil
        case .equals: return text.compare(value, options: .caseInsensitive) == .orderedSame
        case .beginsWith: return text.range(of: value, options: [.caseInsensitive, .anchored]) != nil
        case .endsWith: return text.range(of: value, options: [.caseInsensitive, .anchored, .backwards]) != nil
        case .matchesRegex: return false
        }
    }

    /// Türkçe noktalı/noktasız i farkını kaldırır; büyük/küçük harf farkı karşılaştırmada ayrıca yok sayılır.
    static func fold(_ text: String) -> String {
        guard text.contains(where: { $0 == "ı" || $0 == "İ" }) else { return text }
        return text.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "i")
    }
}

// MARK: - Tarama

/// Kaynağı tarar ve kurallara uyan dosyaların göreli yollarını bulur. Klasörlerin kendisi listelenmez (rsync dosyaların
/// klasörlerini oluşturur); uygulama ve fotoğraf arşivi gibi paket klasörleri tek bir dosya gibi değerlendirilir.
public enum RuleScanner {
    public struct Result: Equatable, Sendable {
        /// Diskteki yazımıyla göreli yollar (rsync'e aynen verilir).
        public var paths: [String] = []
        /// Bakılan öğe sayısı.
        public var scanned = 0
    }

    /// - Parameters:
    ///   - skippedPaths: Hiç girilmeyecek göreli yollar (kum havuzunun okutmadığı kişisel klasörler).
    ///   - skippedNames: Hiçbir düzeyde girilmeyecek adlar (macOS sistem klasörleri).
    public static func scan(
        _ root: URL, rules: RuleGroup, skippedPaths: Set<String> = [], skippedNames: Set<String> = [],
        isCancelled: () -> Bool = { false }
    ) throws -> Result {
        let evaluator = try RuleEvaluator(rules)
        var result = Result()
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return result }
        while let relative = enumerator.nextObject() as? String {
            if result.scanned % 512 == 0, isCancelled() { throw CancellationError() }
            result.scanned += 1
            let type = enumerator.fileAttributes?[.type] as? FileAttributeType
            let isDirectory = type == .typeDirectory
            let name = (relative as NSString).lastPathComponent
            if skippedPaths.contains(relative) || skippedNames.contains(name) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            if isDirectory {
                let ext = (name as NSString).pathExtension
                guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .package), type.conforms(to: .package) else {
                    continue
                }
                enumerator.skipDescendants()
            }
            if evaluator.matches(RuleItem(relativePath: relative, isDirectory: isDirectory)) {
                result.paths.append(relative)
            }
        }
        return result
    }
}
