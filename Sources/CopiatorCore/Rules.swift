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

/// Koşulun baktığı özellik. İlk beşi temel ölçütlerdir; ötekiler arayüzde "Gelişmiş" başlığı altında sunulur ve dosyanın
/// üst verisini okur (yalnızca bir koşul gerçekten ona baktığında).
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

    // MARK: Gelişmiş
    case size
    /// Değiştirilme, oluşturulma ve Finder'daki eklenme tarihi.
    case modified
    case created
    case added
    /// Finder etiketleri (renkler ve özel etiketler).
    case tag
    /// Gizli: adı nokta ile başlayan (kendisi ya da bulunduğu bir klasör) ya da gizli işaretli.
    case hidden
    /// Kaynağın altındaki klasör düzeyi (kökteki dosya 0).
    case depth
    /// Fotoğraf ve video: çekim tarihi, uzun kenarın piksel sayısı, süre, kamera modeli.
    case captureDate
    case resolution
    case duration
    case cameraModel
    /// Dosyanın içinde geçen metin (Spotlight dizininden; PDF ve metin dosyaları doğrudan da okunur).
    case content
    /// Aynı içerikte bir dosya hedefte zaten var (adı ya da yeri farklı olsa da; bkz. `DestinationIndex`).
    case inDestination

    public var id: String { rawValue }

    public static let basic: [RuleAttribute] = [.name, .fileExtension, .folderName, .path, .kind]
    public static let advanced: [RuleAttribute] = allCases.filter { !basic.contains($0) }

    /// Arayüzde "Gelişmiş" başlığı altında sunulur.
    public var isAdvanced: Bool { !Self.basic.contains(self) }

    /// Değerin biçimi.
    public enum ValueKind: Sendable {
        case text, kind, number, date, flag
    }

    public var valueKind: ValueKind {
        switch self {
        case .name, .fileExtension, .folderName, .path, .tag, .cameraModel, .content: .text
        case .kind: .kind
        case .size, .depth, .resolution, .duration: .number
        case .modified, .created, .added, .captureDate: .date
        case .hidden, .inDestination: .flag
        }
    }

    /// Fotoğraf ya da video üst verisi gerekir (tarama sırasında ayrıca okunur).
    public var needsMedia: Bool { [.captureDate, .resolution, .duration, .cameraModel].contains(self) }

    /// Bu özellikte kullanılabilen karşılaştırmalar (ilki varsayılandır).
    public var operators: [RuleOperator] {
        switch self {
        case .name, .folderName, .path, .cameraModel: [.contains, .equals, .beginsWith, .endsWith, .matchesRegex]
        case .fileExtension: [.equals, .isOneOf, .contains, .beginsWith, .endsWith, .matchesRegex]
        case .kind: [.equals]
        case .size, .resolution, .duration: [.greaterThan, .lessThan]
        case .depth: [.atMost, .atLeast, .equals]
        case .modified, .created, .added, .captureDate: [.withinLast, .notWithinLast, .before, .after]
        case .tag: [.equals, .contains, .isTrue, .isFalse]
        case .hidden, .inDestination: [.isTrue, .isFalse]
        case .content: [.contains]
        }
    }

    /// Sayı ve göreli tarih karşılaştırmalarında kullanılabilen birimler (ilki varsayılandır).
    public var units: [RuleUnit] {
        switch self {
        case .size: [.megabytes, .kilobytes, .gigabytes, .terabytes]
        case .duration: [.minutes, .seconds, .hours]
        case .resolution: [.pixels]
        case .depth: [.levels]
        case .modified, .created, .added, .captureDate: [.days, .weeks, .months, .years]
        default: []
        }
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
    /// Virgülle ayrılmış listeden biri ("jpg, heic, png").
    case isOneOf
    case greaterThan
    case lessThan
    case atMost
    case atLeast
    /// Son N gün/hafta/ay/yıl içinde (ya da değil).
    case withinLast
    case notWithinLast
    /// Seçilen günden önce / sonra.
    case before
    case after
    /// Var / yok (gizli, etiketli).
    case isTrue
    case isFalse

    public var id: String { rawValue }

    /// Değer alanı: metin, sayı ve birim, tarih ya da hiçbiri.
    public enum Input: Sendable { case text, number, date, none }

    public func input(for attribute: RuleAttribute) -> Input {
        switch self {
        case .isTrue, .isFalse: .none
        case .before, .after: .date
        case .withinLast, .notWithinLast, .greaterThan, .lessThan, .atMost, .atLeast: .number
        case .equals where attribute.valueKind == .number: .number
        default: .text
        }
    }
}

/// Birim. Boyutlar Finder gibi 1000 tabanlıdır.
public enum RuleUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case kilobytes, megabytes, gigabytes, terabytes
    case seconds, minutes, hours
    case days, weeks, months, years
    case pixels, levels

    public var id: String { rawValue }

    /// Bayt ya da saniye karşılığı (göreli tarihlerde takvim kullanılır).
    var multiplier: Double {
        switch self {
        case .kilobytes: 1e3
        case .megabytes: 1e6
        case .gigabytes: 1e9
        case .terabytes: 1e12
        case .seconds, .pixels, .levels, .days, .weeks, .months, .years: 1
        case .minutes: 60
        case .hours: 3600
        }
    }

    var calendarComponent: (Calendar.Component, Int)? {
        switch self {
        case .days: (.day, 1)
        case .weeks: (.day, 7)
        case .months: (.month, 1)
        case .years: (.year, 1)
        default: nil
        }
    }
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

/// Tek bir koşul: "Uzantı eşittir xlsx", "Boyut büyüktür 100 MB", "Değiştirilme son 7 gün içinde".
public struct RuleCondition: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var attribute: RuleAttribute
    public var op: RuleOperator
    /// Metin, liste ("jpg, heic") ya da türde `FileKind` ham değeri.
    public var value: String
    /// Sayı (boyut, süre, piksel, düzey ya da "son N …").
    public var number: Double
    public var unit: RuleUnit?
    /// "Önce" ve "sonra" karşılaştırmalarının günü.
    public var date: Date?

    public init(
        id: UUID = UUID(), attribute: RuleAttribute = .name, op: RuleOperator = .contains, value: String = "",
        number: Double = 0, unit: RuleUnit? = nil, date: Date? = nil
    ) {
        self.id = id
        self.attribute = attribute
        self.op = attribute.operators.contains(op) ? op : attribute.operators[0]
        self.value = value
        self.number = number
        self.unit = unit.flatMap { attribute.units.contains($0) ? $0 : nil } ?? attribute.units.first
        self.date = date
    }

    /// Arayüzde özellik seçilince başlanan koşul (anlamlı bir varsayılanla).
    public static func starting(_ attribute: RuleAttribute, now: Date = Date()) -> RuleCondition {
        switch attribute {
        case .kind: RuleCondition(attribute: .kind, op: .equals, value: FileKind.image.rawValue)
        case .size: RuleCondition(attribute: .size, op: .greaterThan, number: 100, unit: .megabytes)
        case .modified, .created, .added: RuleCondition(attribute: attribute, op: .withinLast, number: 7, unit: .days)
        case .captureDate: RuleCondition(attribute: .captureDate, op: .withinLast, number: 30, unit: .days)
        case .resolution: RuleCondition(attribute: .resolution, op: .greaterThan, number: 1920, unit: .pixels)
        case .duration: RuleCondition(attribute: .duration, op: .greaterThan, number: 1, unit: .minutes)
        case .depth: RuleCondition(attribute: .depth, op: .atMost, number: 0, unit: .levels)
        case .hidden: RuleCondition(attribute: .hidden, op: .isTrue)
        case .inDestination: RuleCondition(attribute: .inDestination, op: .isFalse)
        case .tag: RuleCondition(attribute: .tag, op: .equals)
        default: RuleCondition(attribute: attribute)
        }
    }

    private enum CodingKeys: String, CodingKey { case id, attribute, op, value, number, unit, date }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let attribute = (try? c.decodeIfPresent(RuleAttribute.self, forKey: .attribute)) ?? .name
        self.init(
            id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
            attribute: attribute,
            op: (try? c.decodeIfPresent(RuleOperator.self, forKey: .op)) ?? attribute.operators[0],
            value: (try? c.decodeIfPresent(String.self, forKey: .value)) ?? "",
            number: (try? c.decodeIfPresent(Double.self, forKey: .number)) ?? 0,
            unit: (try? c.decodeIfPresent(RuleUnit.self, forKey: .unit)) ?? nil,
            date: (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? nil
        )
    }

    /// "jpg, .HEIC; png" → ["jpg", "heic", "png"].
    var listItems: [String] {
        value.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
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

    /// Tüm koşullar (alt gruplarınkiler dahil, derinlik sınırına kadar).
    public var allConditions: [RuleCondition] {
        func collect(_ group: RuleGroup, _ depth: Int) -> [RuleCondition] {
            guard depth < Self.maxDepth else { return [] }
            return group.conditions + group.groups.flatMap { collect($0, depth + 1) }
        }
        return collect(self, 0)
    }

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
        /// Geçersiz düzenli ifade.
        case invalidRegex(String)
        case unknownKind(String)
        /// Eksi ya da sayı olmayan bir değer.
        case invalidNumber
        /// "Önce" ya da "sonra" için gün seçilmemiş.
        case missingDate
        case tooDeep
    }

    public func problems(depth: Int = 0) -> [Problem] {
        var problems: [Problem] = depth >= Self.maxDepth ? [.tooDeep] : []
        for condition in conditions {
            let value = condition.value.trimmingCharacters(in: .whitespaces)
            switch condition.op.input(for: condition.attribute) {
            case .none:
                break
            case .number:
                if !condition.number.isFinite || condition.number < 0 { problems.append(.invalidNumber) }
            case .date:
                if condition.date == nil { problems.append(.missingDate) }
            case .text:
                if value.isEmpty || (condition.op == .isOneOf && condition.listItems.isEmpty) {
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
