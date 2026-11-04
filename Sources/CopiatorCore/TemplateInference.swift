// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Hedefteki örnek adlardan ya da klasör yollarından şablonu yapay zekâsız, kurala bağlı çıkarır
/// ("Elektrik_Faturası_2026-08.pdf" → "Elektrik_Faturası_{year}-{month}", "2025/01-Ocak" → "{year}/{month}-{monthName}").
/// Her örnek harf, rakam ve ayraç parçalarına bölünür; örneğin tarihine uyan parçalar belirteç olur (dört haneli yıl
/// `{year}`, iki haneli yıl `{yy}`, ay `{month}`, ay adı `{monthName}` (Türkçe, İngilizce, Rumence), gün `{day}`); bütün
/// örneklerde aynı olan parçalar sabit metin kalır; ad şablonunda örnekten örneğe değişen orta kısım `{name}` olur.
/// Örnekler farklı biçimdeyse en kalabalık biçim grubu kullanılır. Tarihi olmayan örneklerden şablon çıkarılmaz.
public enum TemplateInference {
    enum Role: Hashable, CaseIterable {
        case year, monthName, month, day, yy

        var token: PlacementToken {
            switch self {
            case .year: .year
            case .monthName: .monthName
            case .month: .month
            case .day: .day
            case .yy: .yy
            }
        }
    }

    enum Symbol: Hashable {
        case literal(String)
        case date(Set<Role>)
    }

    /// Ad şablonu (örnekler dosya adlarıdır; uzantılar atılır).
    public static func nameTemplate(from examples: [String]) -> String? {
        let bases = examples.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        guard let template = infer(bases, allowName: true), RoutePlacement(nameTemplate: template).problems().isEmpty else { return nil }
        return template
    }

    /// Alt klasör şablonu (örnekler hedefe göre göreli klasör yollarıdır).
    public static func folderTemplate(from examples: [String]) -> String? {
        guard let template = infer(examples, allowName: false), RoutePlacement(folderTemplate: template).problems().isEmpty else { return nil }
        return template
    }

    /// Metindeki tarih: önce `TextDate`; bulamazsa parçalardan (dört haneli yıl ile ay adı ya da yılın yanındaki iki haneli
    /// ay; "2026_Ağustos", "2026 08"); ay yoksa yalnızca yıl ("Faturalar/2026").
    static func date(of text: String) -> DateComponents? {
        if let date = TextDate.find(in: text) { return date }
        let parts = tokens(text)
        guard let yearIndex = parts.firstIndex(where: { yearValue($0) != nil }), let year = yearValue(parts[yearIndex]) else { return nil }
        if let month = parts.lazy.compactMap({ monthNameValue($0)?.month }).first { return DateComponents(year: year, month: month) }
        for index in [yearIndex + 2, yearIndex - 2] where parts.indices.contains(index) && parts.indices.contains((index + yearIndex) / 2) {
            let separator = parts[(index + yearIndex) / 2]
            if separator.count == 1, !separator.first!.isLetter, !separator.first!.isNumber, parts[index].count == 2,
               let month = Int(parts[index]), (1...12).contains(month) {
                return DateComponents(year: year, month: month)
            }
        }
        return DateComponents(year: year)
    }

    /// Harf dizileri, rakam dizileri ve tek tek ayraçlar.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        func kind(_ character: Character) -> Int { character.isLetter ? 0 : character.isNumber && character.isASCII ? 1 : 2 }
        for character in text.precomposedStringWithCanonicalMapping {
            if let last = current.last, kind(last) == kind(character), kind(character) != 2 {
                current.append(character)
            } else {
                if !current.isEmpty { result.append(current) }
                current = String(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func yearValue(_ token: String) -> Int? {
        guard token.count == 4, let value = Int(token), (1980...2099).contains(value) else { return nil }
        return value
    }

    /// Ay adı parçası: ay numarası ve uyduğu diller.
    static func monthNameValue(_ token: String) -> (month: Int, languages: Set<String>)? {
        guard token.first?.isLetter == true else { return nil }
        let folded = ContentReader.fold(token)
        var languages: Set<String> = []
        var month: Int?
        for language in ["tr", "en", "ro"] {
            for number in 1...12 where ContentReader.fold(PlacementToken.monthName(number, language: language)) == folded {
                languages.insert(language)
                month = number
            }
        }
        return month.map { ($0, languages) }
    }

    /// Örneğin parçaları: tarihe uyan parçalar olası rolleriyle, öbürleri sabit metin; tarihi yoksa nil.
    static func symbols(_ text: String) -> [Symbol]? {
        guard let date = date(of: text), let year = date.year else { return nil }
        let month = date.month
        let parts = tokens(text)
        let hasYear = parts.contains { yearValue($0) == year }
        let symbols = parts.map { part -> Symbol in
            if yearValue(part) == year { return .date([.year]) }
            if let name = monthNameValue(part), name.month == month { return .date([.monthName]) }
            guard let month, part.count == 2, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return .literal(part) }
            var roles: Set<Role> = []
            if value == month { roles.insert(.month) }
            if let day = date.day, value == day { roles.insert(.day) }
            if !hasYear, value == year % 100 { roles.insert(.yy) }
            return roles.isEmpty ? .literal(part) : .date(roles)
        }
        return symbols.contains { if case .date = $0 { true } else { false } } ? symbols : nil
    }

    static func infer(_ texts: [String], allowName: Bool) -> String? {
        let parsed = texts.compactMap(symbols)
        guard !parsed.isEmpty else { return nil }
        if let template = attempt(parsed, allowName: allowName) { return template }
        // Farklı biçimler: tek başına en kalabalık biçim grubu. Bütün örnekleri kapsamadığı ve tek başına en büyük olduğu
        // için en az iki örneklidir (tek bir örnek öbürlerini yok sayamaz).
        var groups: [[Symbol]: [[Symbol]]] = [:]
        var order: [[Symbol]] = []
        for symbols in parsed {
            let key = symbols.map { symbol -> Symbol in
                if case .literal(let text) = symbol { return .literal(FolderSuggester.fold(text)) }
                return .date([])
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(symbols)
        }
        let counts = order.map { groups[$0, default: []].count }
        guard let most = counts.max(), most < parsed.count, counts.filter({ $0 == most }).count == 1,
              let largest = order.first(where: { groups[$0, default: []].count == most }) else { return nil }
        return attempt(groups[largest, default: []], allowName: allowName)
    }

    private static func merge(_ symbols: [Symbol]) -> Symbol? {
        guard let first = symbols.first else { return nil }
        switch first {
        case .literal(let text):
            let folded = FolderSuggester.fold(text)
            return symbols.allSatisfy { if case .literal(let other) = $0 { FolderSuggester.fold(other) == folded } else { false } } ? first : nil
        case .date:
            var roles = Set(Role.allCases)
            for symbol in symbols {
                guard case .date(let own) = symbol else { return nil }
                roles.formIntersection(own)
            }
            return roles.isEmpty ? nil : .date(roles)
        }
    }

    /// Ortak baş ve son; aradaki farklı kısım `{name}` (yalnızca ad şablonunda ve birden çok örnekte).
    private static func attempt(_ group: [[Symbol]], allowName: Bool) -> String? {
        guard let shortest = group.map(\.count).min() else { return nil }
        var prefix: [Symbol] = []
        while prefix.count < shortest, let symbol = merge(group.map { $0[prefix.count] }) { prefix.append(symbol) }
        var suffix: [Symbol] = []
        while prefix.count + suffix.count < shortest, let symbol = merge(group.map { $0[$0.count - 1 - suffix.count] }) {
            suffix.insert(symbol, at: 0)
        }
        let hasMiddle = group.contains { $0.count > prefix.count + suffix.count }
        guard !hasMiddle || (allowName && group.count > 1) else { return nil }
        var used: Set<Role> = []
        var result = ""
        func append(_ symbol: Symbol) -> Bool {
            switch symbol {
            case .literal(let text):
                guard !text.contains("{"), !text.contains("}") else { return false }
                result += text
            case .date(let roles):
                guard let role = Role.allCases.first(where: { roles.contains($0) && !used.contains($0) }) else { return false }
                used.insert(role)
                result += role.token.text
            }
            return true
        }
        for symbol in prefix { guard append(symbol) else { return nil } }
        if hasMiddle { result += PlacementToken.name.text }
        for symbol in suffix { guard append(symbol) else { return nil } }
        guard !used.isEmpty else { return nil }
        return result
    }
}
