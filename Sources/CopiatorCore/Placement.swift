// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Rotanın seçtiği dosyaların hedefe nasıl yerleşeceği: hedefte alt klasör şablonu (ör. "{year}/{month}-{monthName}")
/// ve ad şablonu (ör. "123456789_El_{month}_{yy}"). İkisi de boşsa kaynağın klasör yapısı ve adları olduğu gibi kalır.
public struct RoutePlacement: Codable, Equatable, Sendable {
    /// Hedefin içindeki alt klasör şablonu; "/" ile alt klasörler. Boşsa kaynağın klasör yapısı korunur.
    public var folderTemplate: String
    /// Klasör şablonu varken kaynağın klasör yapısı da şablonun altında korunsun mu (yoksa dosyalar şablonun klasörüne
    /// düz konur).
    public var keepStructure: Bool
    /// Ad şablonu; boşsa ad değişmez. Uzantı her zaman korunur ve şablona yazılmaz.
    public var nameTemplate: String
    /// Tarih belirteçlerinin ({year}, {month}…) kaynağı.
    public var dateSource: PlacementDateSource
    /// Ay adlarının dili ("tr", "en", "ro"). Şablon kurulurken uygulamanın dili yazılır; arayüz dili sonradan değişse de
    /// klasör adları değişmez.
    public var language: String
    /// Ad şablonundan sonra, sırayla uygulanan ad düzeltmeleri (ör. baştaki kodu büyük harf yapmak).
    public var nameFixes: [NameFix]
    /// Her dosyanın hedefteki klasörü sorulur: klasörler önerilir, kullanıcı onaylar (bkz. `PlacementQuestions`).
    /// Alt klasör şablonu seçilen klasörün altında uygulanır.
    public var askFolder: Bool
    /// "Bunu hatırla" ile öğrenilen klasörler: `PlacementMemory.key` → hedefe göre göreli klasör.
    public var learnedFolders: [String: String]
    /// Dosyanın metninden yakalanan değerler; ad şablonunda `{c:ad}` olarak kullanılır (bkz. `ContentField`).
    public var contentFields: [ContentField]

    public init(folderTemplate: String = "", keepStructure: Bool = false, nameTemplate: String = "",
                dateSource: PlacementDateSource = .automatic, language: String = "tr", nameFixes: [NameFix] = [],
                askFolder: Bool = false, learnedFolders: [String: String] = [:], contentFields: [ContentField] = []) {
        self.folderTemplate = folderTemplate
        self.keepStructure = keepStructure
        self.nameTemplate = nameTemplate
        self.dateSource = dateSource
        self.language = language
        self.nameFixes = nameFixes
        self.askFolder = askFolder
        self.learnedFolders = learnedFolders
        self.contentFields = contentFields
    }

    private enum CodingKeys: String, CodingKey {
        case folderTemplate, keepStructure, nameTemplate, dateSource, language, nameFixes, askFolder, learnedFolders, contentFields
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folderTemplate = (try? c.decodeIfPresent(String.self, forKey: .folderTemplate)) ?? ""
        keepStructure = (try? c.decodeIfPresent(Bool.self, forKey: .keepStructure)) ?? false
        nameTemplate = (try? c.decodeIfPresent(String.self, forKey: .nameTemplate)) ?? ""
        dateSource = (try? c.decodeIfPresent(PlacementDateSource.self, forKey: .dateSource)) ?? .automatic
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? "tr"
        nameFixes = (try? c.decodeIfPresent([NameFix].self, forKey: .nameFixes)) ?? []
        askFolder = (try? c.decodeIfPresent(Bool.self, forKey: .askFolder)) ?? false
        learnedFolders = (try? c.decodeIfPresent([String: String].self, forKey: .learnedFolders)) ?? [:]
        contentFields = (try? c.decodeIfPresent([ContentField].self, forKey: .contentFields)) ?? []
    }

    /// Hazır alt klasör şablonları: yıl/ay adı, yıl/ay, yıl.
    public static let folderPresets = ["{year}/{month}-{monthName}", "{year}/{month}", "{year}"]

    /// Şablonlardan biri dolu, bir ad düzeltmesi var ya da klasör sorulur: dosyalar yerleştirilerek kopyalanır.
    public var isActive: Bool {
        askFolder || !folderTemplate.trimmingCharacters(in: .whitespaces).isEmpty || !nameTemplate.trimmingCharacters(in: .whitespaces).isEmpty
            || nameFixes.contains { !$0.pattern.isEmpty }
    }

    /// Şablonlarda bir tarih belirteci var (dosyanın tarihi bulunmalı).
    public var usesDate: Bool {
        PlacementToken.tokens(in: folderTemplate + nameTemplate).contains { $0?.isDate == true }
    }

    /// Klasör ya da ad şablonu tarih istiyor (yeni ad yazılan dosyada ad şablonu kullanılmaz).
    public var folderUsesDate: Bool { PlacementToken.tokens(in: folderTemplate).contains { $0?.isDate == true } }
    public var nameUsesDate: Bool { PlacementToken.tokens(in: nameTemplate).contains { $0?.isDate == true } }

    /// Ad şablonunun kullandığı içerik alanlarının adları (`{c:abone}` → "abone"), sırasıyla ve tekrarsız; yalnızca
    /// tanımlı alanlar.
    public var referencedFields: [String] {
        var names: [String] = []
        for name in ContentField.names(in: nameTemplate) where !names.contains(name) && contentFields.contains(where: { $0.name == name }) {
            names.append(name)
        }
        return names
    }

    /// Ad şablonu içerikten bir değer istiyor: dosyaların metni okunmalı, değeri bulunamayan dosya için ad sorulur.
    public var usesContent: Bool { !referencedFields.isEmpty }

    public enum Problem: Equatable, Sendable {
        /// Bilinmeyen belirteç ("{yil}").
        case unknownToken(String)
        /// Ad şablonunda "/" (alt klasör klasör şablonuna yazılır).
        case slashInName
        /// Klasör şablonunda "..": hedefin dışına çıkılamaz.
        case parentFolder
        /// Ad düzeltmesinin düzenli ifadesi geçersiz.
        case invalidFix(String)
        /// Ad düzeltmesinin yerine yazılacak metninde anlaşılmayan bölüm: ifadede olmayan grup ("$3") ya da bilinmeyen
        /// dönüşüm ("${1:foo}").
        case fixReplacement(String)
        /// İçerik alanının adı geçersiz (harf, rakam ve alt çizgi dışında karakter, boş ya da başka bir alanla aynı).
        case contentFieldName(String)
        /// İçerik alanının düzenli ifadesi geçersiz ya da yakalama grubu yok.
        case contentFieldPattern(String)
        /// İçerik belirteci klasör şablonunda: yalnızca ad şablonunda kullanılabilir.
        case contentTokenInFolder(String)
    }

    public func problems() -> [Problem] {
        var problems: [Problem] = []
        func add(_ problem: Problem) { if !problems.contains(problem) { problems.append(problem) } }
        for (raw, token) in PlacementToken.raw(in: folderTemplate) where token == nil {
            add(ContentField.name(ofToken: raw) != nil ? .contentTokenInFolder(raw) : .unknownToken(raw))
        }
        for (raw, token) in PlacementToken.raw(in: nameTemplate) where token == nil {
            if let name = ContentField.name(ofToken: raw), contentFields.contains(where: { $0.name == name }) { continue }
            add(.unknownToken(raw))
        }
        var seen = Set<String>()
        for field in contentFields {
            if !ContentField.isValidName(field.name) || !seen.insert(field.name).inserted { add(.contentFieldName(field.name)) }
            if field.regex.map({ $0.numberOfCaptureGroups < 1 }) ?? true { add(.contentFieldPattern(field.pattern)) }
        }
        if nameTemplate.contains("/") { problems.append(.slashInName) }
        if folderTemplate.split(separator: "/").contains(where: { $0.trimmingCharacters(in: .whitespaces) == ".." }) {
            problems.append(.parentFolder)
        }
        for fix in nameFixes where !fix.pattern.isEmpty {
            guard let regex = fix.regex else {
                problems.append(.invalidFix(fix.pattern))
                continue
            }
            problems += fix.replacementProblems(groups: regex.numberOfCaptureGroups).map(Problem.fixReplacement)
        }
        return problems
    }

    /// Bir dosyanın hedefe göre göreli yolu.
    /// - Parameters:
    ///   - relativePath: Kaynağa göre göreli yol ("2026/Faturalar/fatura.pdf").
    ///   - date: Dosyanın tarihi (yıl ve ay; gün yoksa "01").
    ///   - destination: Rotanın hedefinin yolu (`{targetFolder}` ve `{targetNumber}` için).
    ///   - folder: "Klasörü sor"da seçilen, hedefe göre göreli klasör; dosya (klasör yapısı korunmuyorsa) doğrudan oraya,
    ///     alt klasör şablonu varsa onun altına düşer.
    ///   - name: Kullanıcının onayladığı yeni ad (uzantısız); şablonun ve düzeltmelerin yerine geçer, uzantı korunur.
    ///   - content: İçerik alanlarının bu dosyadaki değerleri (alan adı → değer); bulunmayan alan boş yazılır.
    public func target(
        for relativePath: String, date: DateComponents?, destination: String = "", folder: String? = nil, name chosenName: String? = nil,
        content: [String: String] = [:]
    ) -> String {
        let components = relativePath.split(separator: "/").map(String.init)
        let name = components.last ?? relativePath
        let folders = Array(components.dropLast())
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let destinationFolders = destination.split(separator: "/").map(String.init)
        var values = PlacementToken.values(base: base, folder: folders.last ?? "", date: date, language: language)

        // Klasör şablonunda hedef belirteçleri rotanın hedefini (ve seçilen klasörü) anlatır; ad şablonunda dosyanın düştüğü
        // en derin klasörü.
        let chosen = folder.map { $0.split(separator: "/").map { Self.component(String($0)) }.filter { !$0.isEmpty } }
        var placedFolders = chosen.map { $0 + (keepStructure ? folders : []) } ?? folders
        if !folderTemplate.trimmingCharacters(in: .whitespaces).isEmpty {
            PlacementToken.addTarget(destinationFolders + (chosen ?? []), to: &values)
            let templateFolders = PlacementToken.render(folderTemplate, values).split(separator: "/")
                .map { Self.component(String($0)) }.filter { !$0.isEmpty }
            placedFolders = (chosen ?? []) + templateFolders + (keepStructure ? folders : [])
        }
        PlacementToken.addTarget(destinationFolders + placedFolders, to: &values)

        // Şablon ve düzeltme yoksa ad olduğu gibi kalır (".gizli" ya da "a:b.txt" de).
        var newName = name
        let hasTemplate = !nameTemplate.trimmingCharacters(in: .whitespaces).isEmpty
        let fixes = nameFixes.filter { !$0.pattern.isEmpty }
        if let chosen = chosenName.map(Self.component), !chosen.isEmpty {
            newName = ext.isEmpty ? chosen : chosen + "." + ext
        } else if hasTemplate || !fixes.isEmpty {
            var newBase = base
            if hasTemplate {
                let template = ContentField.substitute(nameTemplate, values: content)
                newBase = Self.component(Self.renderName(template, values, base: base))
                if newBase.isEmpty { newBase = base }
            }
            if !fixes.isEmpty {
                let fixed = Self.component(NameFix.apply(fixes, to: newBase, language: language))
                if !fixed.isEmpty { newBase = fixed }
            }
            newName = ext.isEmpty ? newBase : newBase + "." + ext
        }
        return (placedFolders + [newName]).joined(separator: "/")
    }

    /// Ad şablonu; `{name}`in önündeki ya da ardındaki metin adda zaten varsa yeniden eklenmez ("128_El_{name}" ile
    /// "128_El_Ekim" yine "128_El_Ekim" olur; harf büyüklüğü ve aksan fark etmez). Böylece aynı dosyaya şablon iki kez
    /// uygulansa da ad uzamaz.
    static func renderName(_ template: String, _ values: [PlacementToken: String], base: String) -> String {
        let parts = template.components(separatedBy: PlacementToken.name.text)
        guard parts.count == 2 else { return PlacementToken.render(template, values) }
        var prefix = PlacementToken.render(parts[0], values)
        var suffix = PlacementToken.render(parts[1], values)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
        if !trimmedPrefix.isEmpty, base.range(of: trimmedPrefix, options: options.union(.anchored)) != nil { prefix = "" }
        let trimmedSuffix = suffix.trimmingCharacters(in: .whitespaces)
        if !trimmedSuffix.isEmpty, base.range(of: trimmedSuffix, options: options.union([.anchored, .backwards])) != nil { suffix = "" }
        return prefix + base + suffix
    }

    /// Ad ya da klasör adı olarak güvenli metin: "/" ve ":" tireye döner, denetim karakterleri silinir, baştaki boşluk ve
    /// noktalar değer değişmeyene kadar atılır (". .." gibi bir değer ".." bırakıp hedefin dışına çıkmasın; gizli dosya
    /// olmaz), en çok 240 bayt.
    public static func component(_ text: String) -> String {
        var value = text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        value = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        var previous: String
        repeat {
            previous = value
            value = value.trimmingCharacters(in: .whitespaces)
            while value.hasPrefix(".") { value.removeFirst() }
        } while value != previous
        while value.utf8.count > 240 { value.removeLast() }
        return value.trimmingCharacters(in: .whitespaces)
    }
}

/// Ad düzeltmesi: adın düzenli ifadeye uyan her parçası yerine yazılacak metinle değişir (uzantıya dokunulmaz). Yerine
/// yazılacak metinde `$1` ya da `${1}` grubun kendisi; `${1:upper}`, `${1:lower}`, `${1:title}` büyük harfli, küçük harfli
/// ya da sözcük başları büyük hali (rotanın dilinde: Türkçede "i" → "İ"); `$0` uyan parçanın tamamı, `$$` dolar işareti.
/// İfade harf büyüklüğüne duyarlıdır; adım sınırını aşan bir ifade adı değiştirmez.
public struct NameFix: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var pattern: String
    public var replacement: String

    public init(id: UUID = UUID(), pattern: String = "", replacement: String = "") {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
    }

    private enum CodingKeys: String, CodingKey { case id, pattern, replacement }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        pattern = (try? c.decodeIfPresent(String.self, forKey: .pattern)) ?? ""
        replacement = (try? c.decodeIfPresent(String.self, forKey: .replacement)) ?? ""
    }

    /// Hazır düzeltmeler: baştaki harf ve rakam kodunu büyük harf yapmak ("ab1234 fatura" → "AB1234 fatura"), boşlukları
    /// alt çizgiye çevirmek, art arda gelen alt çizgileri teke indirmek. Eklenirken yeni bir kimlikle kopyalanır.
    public static let presets = [
        NameFix(pattern: "^([A-Za-z]+[0-9]+)", replacement: "${1:upper}"),
        NameFix(pattern: "\\s+", replacement: "_"),
        NameFix(pattern: "_{2,}", replacement: "_"),
    ]

    /// Büyük-küçük harf dönüşümü.
    public enum Case: String, Sendable { case upper, lower, title }

    /// Yerine yazılacak metnin parçaları.
    enum Piece: Equatable {
        case text(String)
        /// Grup numarası ve dönüşüm adı (`${1:upper}` → 1, "upper").
        case group(Int, String?)
    }

    var regex: NSRegularExpression? { try? NSRegularExpression(pattern: pattern.precomposedStringWithCanonicalMapping) }

    /// Yerine yazılacak metinde anlaşılmayan bölümler: ifadede olmayan grup ya da bilinmeyen dönüşüm ("${1:foo}").
    func replacementProblems(groups: Int) -> [String] {
        Self.pieces(replacement).compactMap { piece in
            guard case .group(let number, let name) = piece else { return nil }
            let known = name.map { Case(rawValue: $0) != nil } ?? true
            guard number > groups || !known else { return nil }
            return name.map { "${\(number):\($0)}" } ?? "$\(number)"
        }
    }

    static func pieces(_ replacement: String) -> [Piece] {
        var pieces: [Piece] = []
        var text = ""
        func flush() {
            if !text.isEmpty { pieces.append(.text(text)) }
            text = ""
        }
        var index = replacement.startIndex
        while index < replacement.endIndex {
            let character = replacement[index]
            let next = replacement.index(after: index)
            guard character == "$", next < replacement.endIndex else {
                text.append(character)
                index = next
                continue
            }
            if replacement[next] == "$" {
                text.append("$")
                index = replacement.index(after: next)
                continue
            }
            let digits = replacement[next...].prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty {
                flush()
                pieces.append(.group(Int(digits) ?? Int.max, nil))
                index = digits.endIndex
                continue
            }
            if replacement[next] == "{", let close = replacement[next...].firstIndex(of: "}") {
                let inner = replacement[replacement.index(after: next)..<close].split(separator: ":", maxSplits: 1,
                                                                                    omittingEmptySubsequences: false)
                if let first = inner.first, !first.isEmpty, first.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    flush()
                    pieces.append(.group(Int(first) ?? Int.max, inner.count > 1 ? String(inner[1]) : nil))
                    index = replacement.index(after: close)
                    continue
                }
            }
            text.append(character)
            index = next
        }
        flush()
        return pieces
    }

    /// Düzeltmeleri sırayla uygular; geçersiz ifade atlanır.
    static func apply(_ fixes: [NameFix], to name: String, language: String) -> String {
        let locale = Locale(identifier: language)
        var result = name.precomposedStringWithCanonicalMapping
        for fix in fixes where !fix.pattern.isEmpty {
            guard let regex = fix.regex else { continue }
            result = fix.replace(in: result, regex: regex, locale: locale)
        }
        return result
    }

    /// Adım sınırlı değiştirme (bkz. `RuleEvaluator.regexStepBudget`): sınır aşılırsa ad olduğu gibi kalır.
    private func replace(in text: String, regex: NSRegularExpression, locale: Locale) -> String {
        var ticks = 0
        var matches: [NSTextCheckingResult] = []
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            if let match { matches.append(match) } else { ticks += 1 }
            if ticks > RuleEvaluator.regexStepBudget || matches.count > 1_000 { stop.pointee = true }
        }
        guard ticks <= RuleEvaluator.regexStepBudget, !matches.isEmpty else { return text }
        let pieces = Self.pieces(replacement)
        var result = ""
        var last = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text), range.lowerBound >= last else { continue }
            result += text[last..<range.lowerBound]
            for piece in pieces {
                switch piece {
                case .text(let value):
                    result += value
                case .group(let number, let name):
                    guard number <= match.numberOfRanges - 1, let group = Range(match.range(at: number), in: text) else { continue }
                    let value = String(text[group])
                    switch name.flatMap(Case.init(rawValue:)) {
                    case .upper?: result += value.uppercased(with: locale)
                    case .lower?: result += value.lowercased(with: locale)
                    case .title?: result += value.capitalized(with: locale)
                    case nil: result += value
                    }
                }
            }
            last = range.upperBound
        }
        return result + text[last...]
    }
}

/// İçerikten alınan değer: dosyanın metninde (PDF ve düz metin; `ContentReader`) düzenli ifadenin ilk eşleşmesinin ilk
/// grubu, ad şablonunda `{c:ad}` olarak yazılır ("Abone No:\s*(\d+)" → "128820964"). İfade yazıldığı gibi uygulanır (harf
/// duyarsızlık için `(?i)`) ve adım sınırlıdır (`RuleEvaluator.regexStepBudget`); değer tek satıra iner, güvenli bir ad
/// parçasına dönüşür (`RoutePlacement.component`, "{" ve "}" atılır) ve kısaltılır. Taranmış belgelerde metin olmadığı için
/// değer bulunmaz; o zaman dosya için ad sorulur (`PlacementQuestions`).
public struct ContentField: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Belirteçteki ad: İngilizce harf, rakam ve alt çizgi ("abone").
    public var name: String
    public var pattern: String

    /// Yazılan en uzun değer (karakter).
    public static let maxValueLength = 80

    public init(id: UUID = UUID(), name: String = "", pattern: String = "") {
        self.id = id
        self.name = name
        self.pattern = pattern
    }

    private enum CodingKeys: String, CodingKey { case id, name, pattern }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        pattern = (try? c.decodeIfPresent(String.self, forKey: .pattern)) ?? ""
    }

    /// Şablona yazılan belirteç ("{c:abone}").
    public var token: String { "{c:\(name)}" }

    var regex: NSRegularExpression? {
        pattern.isEmpty ? nil : try? NSRegularExpression(pattern: pattern.precomposedStringWithCanonicalMapping)
    }

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 32 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// Belirtecin alan adı ("{c:abone}" → "abone"); içerik belirteci değilse nil.
    static func name(ofToken raw: String) -> String? {
        guard raw.hasPrefix("{c:"), raw.hasSuffix("}") else { return nil }
        return String(raw.dropFirst(3).dropLast())
    }

    /// Şablondaki içerik belirteçlerinin alan adları, geçiş sırasıyla.
    static func names(in template: String) -> [String] {
        PlacementToken.raw(in: template).compactMap { name(ofToken: $0.0) }
    }

    /// Şablondaki içerik belirteçlerini değerleriyle değiştirir; değeri olmayan belirteç boşalır, öteki belirteçlere
    /// dokunulmaz.
    static func substitute(_ template: String, values: [String: String]) -> String {
        var result = ""
        var rest = Substring(template)
        for (raw, _) in PlacementToken.raw(in: template) {
            guard let name = name(ofToken: raw), let range = rest.range(of: raw) else { continue }
            result += rest[..<range.lowerBound] + clean(values[name] ?? "")
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    /// Değer ad parçası olarak: tek satır, tek boşluk, güvenli bileşen, belirteç ayraçları yok, en çok `maxValueLength`.
    static func clean(_ value: String) -> String {
        let line = value.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            .replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return RoutePlacement.component(String(RoutePlacement.component(line).prefix(maxValueLength)))
    }

    /// Metindeki değer: ilk eşleşmenin boş olmayan ilk grubu (temizlenmiş); eşleşme yoksa, ifade geçersizse ya da adım
    /// sınırı aşılırsa nil.
    public func value(in text: String) -> String? {
        guard let regex, regex.numberOfCaptureGroups >= 1 else { return nil }
        let text = text.precomposedStringWithCanonicalMapping
        var ticks = 0
        var found: String?
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            if let match {
                if let range = Range(match.range(at: 1), in: text) {
                    let value = Self.clean(String(text[range]))
                    if !value.isEmpty {
                        found = value
                        stop.pointee = true
                    }
                }
            } else {
                ticks += 1
                if ticks > RuleEvaluator.regexStepBudget { stop.pointee = true }
            }
        }
        return found
    }

    /// Bir dosyanın alanlardaki değerleri (metin bir kez okunur); okunamayan dosyada ve eşleşmeyen alanda değer yoktur.
    public static func values(of url: URL, fields: [ContentField], only names: [String]) -> [String: String] {
        let wanted = fields.filter { names.contains($0.name) }
        guard !wanted.isEmpty, let text = ContentReader.text(of: url) else { return [:] }
        var values: [String: String] = [:]
        for field in wanted where values[field.name] == nil {
            if let value = field.value(in: text) { values[field.name] = value }
        }
        return values
    }
}

/// Tarih belirteçlerinin kaynağı.
public enum PlacementDateSource: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Çekim tarihi, yoksa dosya adındaki, yoksa içerikteki tarih, o da yoksa değiştirilme tarihi.
    case automatic
    case fileName
    case contents
    case captureDate
    case modified
    case created

    public var id: String { rawValue }

    /// Açıkça seçilen kaynak (dosya adı, içerik, çekim tarihi): tarih bulunamazsa değiştirilme tarihine geçilmez, dosyanın
    /// tarihi kopyalamadan önce sorulur. Otomatik kaynak son adımda değiştirilme tarihini kullanır; dosya tarihleri hep vardır.
    public var asksWhenMissing: Bool { [.fileName, .contents, .captureDate].contains(self) }
}

/// Şablon belirteçleri: `{name}` dosyanın uzantısız adı, `{folder}` bulunduğu klasörün adı, `{year}` 2026, `{yy}` 26,
/// `{month}` 01–12, `{monthName}` ay adı (rotanın dilinde), `{day}` 01–31, `{targetFolder}` hedefte düştüğü klasörün adı,
/// `{targetNumber}` hedef yolundaki parantez içi numara ("Elektrik (123456789)" → 123456789; en derindeki).
public enum PlacementToken: String, CaseIterable, Identifiable, Sendable {
    case name, folder, year, yy, month, monthName, day, targetFolder, targetNumber

    public var id: String { rawValue }
    public var text: String { "{\(rawValue)}" }
    var isDate: Bool { ![.name, .folder, .targetFolder, .targetNumber].contains(self) }

    private static let numberPattern = try? NSRegularExpression(pattern: "\\(\\s*([0-9]+)\\s*\\)")

    /// Hedef belirteçleri: yolun son klasörü ve parantez içindeki en derin numara.
    static func addTarget(_ folders: [String], to values: inout [PlacementToken: String]) {
        values[.targetFolder] = folders.last ?? ""
        values[.targetNumber] = ""
        guard let numberPattern else { return }
        for folder in folders.reversed() {
            let matches = numberPattern.matches(in: folder, range: NSRange(folder.startIndex..., in: folder))
            if let match = matches.last, let range = Range(match.range(at: 1), in: folder) {
                values[.targetNumber] = String(folder[range])
                return
            }
        }
    }

    /// "{year}" ya da içerik belirteci "{c:abone}".
    private static let pattern = try? NSRegularExpression(pattern: "\\{([A-Za-z]+(?::[A-Za-z0-9_]*)?)\\}")

    /// Şablondaki belirteçler (bilinmeyenler nil).
    static func tokens(in template: String) -> [PlacementToken?] { raw(in: template).map(\.1) }

    static func raw(in template: String) -> [(String, PlacementToken?)] {
        guard let pattern else { return [] }
        return pattern.matches(in: template, range: NSRange(template.startIndex..., in: template)).compactMap { match in
            guard let whole = Range(match.range, in: template), let name = Range(match.range(at: 1), in: template) else { return nil }
            return (String(template[whole]), PlacementToken(rawValue: String(template[name])))
        }
    }

    static func values(base: String, folder: String, date: DateComponents?, language: String) -> [PlacementToken: String] {
        var values: [PlacementToken: String] = [.name: base, .folder: folder]
        if let date, let year = date.year, let month = date.month {
            values[.year] = String(format: "%04d", year)
            values[.yy] = String(format: "%02d", year % 100)
            values[.month] = String(format: "%02d", month)
            values[.day] = String(format: "%02d", date.day ?? 1)
            values[.monthName] = monthName(month, language: language)
        }
        return values
    }

    /// Ayın adı, dilin kendi yazımıyla ("Ekim", "October", "Octombrie").
    public static func monthName(_ month: Int, language: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        let symbols = formatter.standaloneMonthSymbols ?? formatter.monthSymbols ?? []
        guard month >= 1, month <= symbols.count else { return String(format: "%02d", month) }
        let locale = Locale(identifier: language)
        return symbols[month - 1].prefix(1).uppercased(with: locale) + symbols[month - 1].dropFirst()
    }

    /// Belirteçleri değerleriyle değiştirir; bilinmeyen belirteç ve değeri olmayan belirteç olduğu gibi kalmaz, boşalır.
    static func render(_ template: String, _ values: [PlacementToken: String]) -> String {
        var result = ""
        var rest = Substring(template)
        for (raw, token) in raw(in: template) {
            guard let range = rest.range(of: raw) else { continue }
            result += rest[..<range.lowerBound]
            if let token { result += values[token] ?? "" }
            rest = rest[range.upperBound...]
        }
        return result + rest
    }
}

/// Yerleştirilen rotanın kopyası için geçici bir "hazırlık" ağacı: hedefteki düzen (yeni adlar, şablon klasörleri) kaynak
/// dosyalara mutlak sembolik bağlantılarla kurulur ve rsync `--copy-unsafe-links` ile bağlantıların gösterdiği dosyaları
/// kopyalar. Böylece aynı adlı dosya denetimi, "ikisini de sakla", doğrulama, karantina ve sürdürme tek bir rsync
/// çalıştırmasıyla olduğu gibi çalışır. rsync öznitelikleri bağlantının kendisinden okuduğu için kaynağın öznitelikleri
/// (karantina, Finder etiketleri) bağlantılara yazılır. Kaynak yalnızca okunur.
public enum PlacementStaging {
    public struct Result: Sendable {
        public var root: URL
        /// Her seçilen yolun hedefe göre göreli yolu (sırası aynı); atlananlar listede yoktur.
        public var targets: [String]
        /// Hazırlanan (atlanmayan) kaynak yolları.
        public var paths: [String]
        /// Kaynakta sembolik bağlantı olan ya da paket içinde dışarıyı gösteren, kopyalanmayan öğeler.
        public var skippedLinks: Int
    }

    /// - Parameters:
    ///   - paths: Kaynağa göre göreli seçilen yollar (dosyalar ve paketler).
    ///   - folder: Hazırlık ağacının kurulacağı, var olmayan klasör (işin özel geçici klasörünün içinde).
    ///   - destination: Rotanın hedefi (`{targetFolder}` ve `{targetNumber}` için).
    ///   - folders: "Klasörü sor"da her yol için seçilen klasör (bkz. `PlacementQuestions`).
    ///   - names: Kullanıcının onayladığı yeni adlar (uzantısız).
    ///   - contents: İçerik alanlarının dosyalardaki değerleri (yol → alan adı → değer).
    ///   - dates: Önceden bulunan ya da kullanıcının seçtiği tarihler (yoksa tarih kaynağından okunur).
    public static func build(
        paths: [String], source: URL, placement: RoutePlacement, in folder: URL, destination: URL? = nil,
        folders: [String: String]? = nil, names: [String: String] = [:], contents: [String: [String: String]] = [:],
        dates: [String: DateComponents] = [:], isCancelled: () -> Bool = { false }
    ) async throws -> Result {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = SandboxProfile.resolved(folder)
        var result = Result(root: root, targets: [], paths: [], skippedLinks: 0)
        var taken = Set<String>()
        for path in paths {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            let url = source.appendingPathComponent(path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else {
                if kind == S_IFLNK { result.skippedLinks += 1 }
                continue
            }
            var date: DateComponents?
            if placement.usesDate {
                if let known = dates[path] { date = known } else { date = await PlacementDate.resolve(url, relativePath: path, source: placement.dateSource) }
            }
            var target = placement.target(for: path, date: date, destination: destination?.path ?? "", folder: folders?[path], name: names[path],
                                          content: contents[path] ?? [:])
            // Aynı hedefe düşen iki dosya: sonraki Finder gibi numaralanır ("ad 2.pdf").
            if taken.contains(target.lowercased()) {
                let directory = (target as NSString).deletingLastPathComponent
                let name = ConflictDetector.numberedName(for: (target as NSString).lastPathComponent) { candidate in
                    taken.contains((directory.isEmpty ? candidate : directory + "/" + candidate).lowercased())
                }
                target = directory.isEmpty ? name : directory + "/" + name
            }
            // İkinci savunma: şablon güvenli bileşenler üretir; yine de hedefin dışını gösteren bir yol hiç kurulmaz.
            guard !target.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { continue }
            taken.insert(target.lowercased())
            let staged = root.appendingPathComponent(target)
            try fileManager.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            if kind == S_IFREG {
                try link(staged, to: url)
            } else {
                result.skippedLinks += try mirror(url, into: staged, isCancelled: isCancelled)
            }
            result.targets.append(target)
            result.paths.append(path)
        }
        // Kaynakta karşılığı olan klasörlerin zamanları kaynağınkiyle aynı olsun (rsync `-t` bunları hedefe yazar).
        copyFolderTimes(root: root, source: source)
        return result
    }

    /// Bağlantı + kaynağın öznitelikleri (bağlantının kendisinde).
    static func link(_ staged: URL, to url: URL) throws {
        try FileManager.default.createSymbolicLink(atPath: staged.path, withDestinationPath: url.path)
        ExtendedAttributes.copy(from: url.path, to: staged.path)
    }

    /// Paket klasörünü (ör. .app) yeniden kurar: klasörler gerçek, dosyalar bağlantı. Paketin içinde kalan göreli
    /// bağlantılar ("Versions/Current → A") aynen kurulur ve rsync onları bağlantı olarak kopyalar; paketin dışını
    /// gösterenler kurulmaz (rsync onları izleyip içeriklerini kopyalardı). - Returns: Kurulmayan bağlantı sayısı.
    static func mirror(_ folder: URL, into staged: URL, isCancelled: () -> Bool) throws -> Int {
        let fileManager = FileManager.default
        var skipped = 0
        var directories: [(URL, URL)] = [(folder, staged)]
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
        var queue = [(folder, staged, 0)]
        while let (current, target, depth) = queue.popLast() {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            for name in try fileManager.contentsOfDirectory(atPath: current.path) {
                let item = current.appendingPathComponent(name)
                let copy = target.appendingPathComponent(name)
                var info = stat()
                guard lstat(item.path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    try fileManager.createDirectory(at: copy, withIntermediateDirectories: false)
                    directories.append((item, copy))
                    queue.append((item, copy, depth + 1))
                case S_IFREG:
                    try link(copy, to: item)
                case S_IFLNK:
                    guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: item.path),
                          staysInside(destination, at: depth) else {
                        skipped += 1
                        continue
                    }
                    try fileManager.createSymbolicLink(atPath: copy.path, withDestinationPath: destination)
                default:
                    continue
                }
            }
        }
        for (original, copy) in directories {
            ExtendedAttributes.copy(from: original.path, to: copy.path)
            copyTimes(from: original.path, to: copy.path)
        }
        return skipped
    }

    /// Göreli bağlantı, `depth` düzey içerideki konumundan paketin köküne çıkmadan çözülüyor mu?
    static func staysInside(_ destination: String, at depth: Int) -> Bool {
        guard !destination.hasPrefix("/") else { return false }
        var level = depth
        for component in destination.split(separator: "/") {
            if component == ".." { level -= 1 } else if component != "." { level += 1 }
            if level < 0 { return false }
        }
        return true
    }

    /// Hazırlık ağacında kaynaktaki bir klasöre karşılık gelen klasörlerin zamanlarını kaynaktan alır.
    static func copyFolderTimes(root: URL, source: URL) {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                              options: [.producesRelativePathURLs]) else { return }
        for case let url as URL in enumerator {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            let original = source.appendingPathComponent(url.relativePath)
            var originalInfo = stat()
            if lstat(original.path, &originalInfo) == 0, originalInfo.st_mode & S_IFMT == S_IFDIR {
                copyTimes(from: original.path, to: url.path)
            }
        }
    }

    static func copyTimes(from source: String, to target: String) {
        var info = stat()
        guard lstat(source, &info) == 0 else { return }
        var times = [info.st_atimespec, info.st_mtimespec]
        _ = utimensat(AT_FDCWD, target, &times, AT_SYMLINK_NOFOLLOW)
    }
}

/// Dosyanın şablon tarihini bulur (bkz. `PlacementDateSource`).
public enum PlacementDate {
    private static let calendar = Calendar(identifier: .gregorian)

    /// Dosyanın tarihi; açıkça seçilen kaynak tarih bulamazsa değiştirilme tarihi (önizleme ve eski davranış).
    public static func resolve(_ url: URL, relativePath: String, source: PlacementDateSource) async -> DateComponents {
        await find(url, relativePath: relativePath, source: source) ?? modified(of: url)
    }

    /// Kaynağın bulduğu tarih: açıkça seçilen kaynak (dosya adı, içerik, çekim tarihi) bulamazsa nil; otomatik kaynak ve
    /// dosya tarihleri her zaman bir tarih verir.
    public static func find(_ url: URL, relativePath: String, source: PlacementDateSource) async -> DateComponents? {
        func components(_ date: Date?) -> DateComponents? {
            date.map { calendar.dateComponents([.year, .month, .day], from: $0) }
        }
        let name = (relativePath as NSString).lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        func capture() async -> DateComponents? {
            guard let type, type.conforms(to: .image) || type.conforms(to: .audiovisualContent) else { return nil }
            return components(await MediaInfo.load(url, type: type)?.captureDate)
        }
        func contents() -> DateComponents? { ContentReader.text(of: url, type: type).flatMap(TextDate.find) }
        switch source {
        case .automatic:
            if let date = await capture() { return date }
            if let date = TextDate.find(in: (name as NSString).deletingPathExtension) { return date }
            if let date = contents() { return date }
            return modified(of: url)
        case .fileName: return TextDate.find(in: (name as NSString).deletingPathExtension)
        case .contents: return contents()
        case .captureDate: return await capture()
        case .modified: return modified(of: url)
        case .created: return components((try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate) ?? modified(of: url)
        }
    }

    /// Değiştirilme tarihi (okunamazsa bugün).
    public static func modified(of url: URL) -> DateComponents {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    /// Kararda saklanan biçim: "2026-10-01".
    public static func string(_ date: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", date.year ?? 0, date.month ?? 1, date.day ?? 1)
    }

    /// "2026-10-01" → yıl, ay, gün; geçersiz ya da 1900–2999 dışındaysa nil.
    public static func components(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1900...2999).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }
}

/// Genişletilmiş öznitelikleri (karantina, Finder etiketleri, yorumlar…) bir öğeden ötekine kopyalar; bağlantı izlenmez.
enum ExtendedAttributes {
    static func copy(from source: String, to target: String) {
        let size = listxattr(source, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(source, &names, size, XATTR_NOFOLLOW) == size else { return }
        for name in names.split(separator: 0, omittingEmptySubsequences: true).map({ Array($0) + [0] }) {
            let length = getxattr(source, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { continue }
            var value = [UInt8](repeating: 0, count: length)
            guard getxattr(source, name, &value, length, 0, XATTR_NOFOLLOW) == length else { continue }
            _ = setxattr(target, name, value, length, 0, XATTR_NOFOLLOW)
        }
    }
}
