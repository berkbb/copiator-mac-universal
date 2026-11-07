// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Yerleştirilen rotada karar bekleyen dosyalar: "Klasörü sor"da hedef klasörü henüz seçilmemiş olanlar ve ad şablonunun
/// içerikten istediği bir değeri (`{c:…}`) metninde bulunmayanlar. İş bunlar için karar bekler ("karar bekliyor").
public struct PlacementReport: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        /// Kaynağa göre göreli yol.
        public var path: String
        /// Önerilen klasörler (hedefe göre göreli, en uygunu başta); boşsa hedefte uygun klasör bulunamadı.
        public var suggestions: [String]
        /// Klasör seçilmeli ("Klasörü sor" ve klasör henüz bilinmiyor); değilse yalnızca ad sorulur.
        public var needsFolder: Bool
        /// Klasörü önceden bilinen dosyada o klasör (öğrenilmiş ya da seçilmiş; hedefe göre göreli).
        public var folder: String?
        /// Metinde bulunamayan içerik alanları: bu dosyaya yeni ad yazılmalı ya da dosya atlanmalı.
        public var missingFields: [String]
        /// Bulunan içerik alanlarının değerleri (adın önizlemesi için).
        public var contentValues: [String: String]

        public init(path: String, suggestions: [String], needsFolder: Bool = true, folder: String? = nil, missingFields: [String] = [],
                    contentValues: [String: String] = [:]) {
            self.path = path
            self.suggestions = suggestions
            self.needsFolder = needsFolder
            self.folder = folder
            self.missingFields = missingFields
            self.contentValues = contentValues
        }

        private enum CodingKeys: String, CodingKey { case path, suggestions, needsFolder, folder, missingFields, contentValues }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            suggestions = (try? c.decodeIfPresent([String].self, forKey: .suggestions)) ?? []
            needsFolder = (try? c.decodeIfPresent(Bool.self, forKey: .needsFolder)) ?? true
            folder = (try? c.decodeIfPresent(String.self, forKey: .folder)) ?? nil
            missingFields = (try? c.decodeIfPresent([String].self, forKey: .missingFields)) ?? []
            contentValues = (try? c.decodeIfPresent([String: String].self, forKey: .contentValues)) ?? [:]
        }
    }

    public var items: [Item]
    /// Klasörü seçilmemiş dosya sayısı (listede en çok `maxItems` tanesi; kalanlar sonraki çalıştırmada sorulur).
    public var total: Int

    public static let maxItems = 100

    public init(items: [Item], total: Int) {
        self.items = items
        self.total = total
    }
}

/// Kullanıcının yerleştirme kararları: dosya → hedefteki klasör (göreli; "" hedefin kökü) ya da atla, isterse yeni adı.
/// İş bitince silinir.
public struct PlacementResolution: Codable, Equatable, Sendable {
    public var folders: [String: String]
    public var skipped: Set<String>
    /// Dosya → kullanıcının onayladığı yeni ad (uzantısız; uzantı her zaman korunur). Ad şablonunun ve düzeltmelerin
    /// yerine geçer; `RoutePlacement.component` ile güvenli bir ada dönüşür.
    public var names: [String: String]

    public init(folders: [String: String] = [:], skipped: Set<String> = [], names: [String: String] = [:]) {
        self.folders = folders
        self.skipped = skipped
        self.names = names
    }

    private enum CodingKeys: String, CodingKey { case folders, skipped, names }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folders = (try? c.decodeIfPresent([String: String].self, forKey: .folders)) ?? [:]
        skipped = (try? c.decodeIfPresent(Set<String>.self, forKey: .skipped)) ?? []
        names = (try? c.decodeIfPresent([String: String].self, forKey: .names)) ?? [:]
    }

    /// Seçilen ya da yazılan klasör hedefin içinde kalan güvenli bir göreli yola dönüşür ("../x/./y" → "x/y").
    public static func clean(_ folder: String) -> String {
        folder.split(separator: "/").map { RoutePlacement.component(String($0)) }.filter { !$0.isEmpty }.joined(separator: "/")
    }
}

/// Öğrenilmiş klasörler: benzer adlı dosyalar ("Enerjisa Ekim 2026.pdf", "enerjisa_kasim_26.pdf") aynı anahtara düşer ve
/// "Bunu hatırla" ile seçilen klasöre sorulmadan gider.
public enum PlacementMemory {
    /// Anahtar: adın katlanmış sözcükleri (rakamlar ve Türkçe, İngilizce, Rumence ay adları atılır) ve uzantı; sözcük
    /// kalmazsa nil (yalnızca tarihten oluşan adlar öğrenilmez).
    public static func key(for path: String) -> String? {
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension.lowercased()
        let base = ext.isEmpty ? file : (file as NSString).deletingPathExtension
        let words = ContentReader.fold(base.precomposedStringWithCanonicalMapping)
            .split { !$0.isLetter }
            .map(String.init)
            .filter { !months.contains($0) }
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ") + (ext.isEmpty ? "" : "." + ext)
    }

    private static let months = Set(TextDate.monthNames.map(\.0))
}

/// "Klasörü sor" rotasının planı: her dosyanın klasörü kullanıcının kararından, yoksa öğrenilmiş eşlemeden gelir; ikisi de
/// yoksa hedefteki klasörler adına ve içeriğine göre önerilir ve iş karar bekler. Hiçbir şey kendiliğinden seçilmez.
public enum PlacementQuestions {
    public struct Plan: Sendable {
        /// Kopyalanacak yollar (atlananlar ve kararsızlar yok).
        public var paths: [String]
        /// Yol → hedefteki klasör.
        public var folders: [String: String]
        /// Yol → kullanıcının onayladığı yeni ad (uzantısız).
        public var names: [String: String] = [:]
        /// Klasörü seçilmemiş dosyalar (yoksa nil).
        public var report: PlacementReport?
    }

    /// İş, klasörü seçilmemiş dosyalar için karar bekliyor.
    public struct DecisionNeeded: Error, Sendable {
        public var report: PlacementReport
    }

    /// - Parameters:
    ///   - contents: İçerik alanlarının dosyalardaki değerleri (yol → alan adı → değer; bkz. `ContentField.values`).
    ///   - decide: false ise (önizleme) kararsız dosyalar ilk öneriye (yoksa hedefin köküne) konur, bulunamayan değerler
    ///     boş yazılır, iş beklemez.
    public static func plan(
        paths: [String], source: URL, destination: URL, placement: RoutePlacement, resolution: PlacementResolution?,
        contents: [String: [String: String]] = [:], decide: Bool = true, isCancelled: () -> Bool = { false }
    ) throws -> Plan {
        let resolution = resolution ?? PlacementResolution()
        let required = placement.referencedFields
        var plan = Plan(paths: [], folders: [:], report: nil)
        // Kararsız dosya: klasörü bilinmiyor ("Klasörü sor") ya da içerikten istenen bir değer bulunamadı ve ad yazılmadı.
        var undecided: [(path: String, folder: String?, missing: [String])] = []
        for path in paths {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            if resolution.skipped.contains(path) { continue }
            let folder = placement.askFolder ? (resolution.folders[path] ?? learned(path, placement: placement, destination: destination)) : ""
            let name = resolution.names[path].flatMap { RoutePlacement.component($0).isEmpty ? nil : $0 }
            let missing = required.filter { (contents[path]?[$0] ?? "").isEmpty }
            if let folder, missing.isEmpty || name != nil {
                plan.paths.append(path)
                if placement.askFolder { plan.folders[path] = PlacementResolution.clean(folder) }
                if let name { plan.names[path] = name }
            } else {
                undecided.append((path, folder.map(PlacementResolution.clean), name == nil ? missing : []))
            }
        }
        guard !undecided.isEmpty else { return plan }
        let needsCandidates = undecided.contains { $0.folder == nil }
        let candidates = needsCandidates ? FolderSuggester.folders(in: destination, isCancelled: isCancelled) : []
        var items: [PlacementReport.Item] = []
        for entry in decide ? Array(undecided.prefix(PlacementReport.maxItems)) : undecided {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            var suggestions: [String] = []
            if entry.folder == nil {
                let url = source.appendingPathComponent(entry.path)
                let content = ContentReader.canRead(UTType(filenameExtension: url.pathExtension)) ? ContentReader.text(of: url) : nil
                suggestions = FolderSuggester.suggestions(for: entry.path, folders: candidates, content: content, limit: Suggestions.maxCandidates)
                    .map(\.path)
            }
            items.append(PlacementReport.Item(path: entry.path, suggestions: suggestions, needsFolder: entry.folder == nil,
                                              folder: placement.askFolder ? entry.folder : nil, missingFields: entry.missing,
                                              contentValues: contents[entry.path] ?? [:]))
        }
        guard decide else {
            for item in items {
                plan.paths.append(item.path)
                if placement.askFolder { plan.folders[item.path] = item.folder ?? item.suggestions.first ?? "" }
            }
            return plan
        }
        plan.report = PlacementReport(items: items, total: undecided.count)
        return plan
    }

    /// Öğrenilmiş klasör; hedefte artık yoksa (taşınmış ya da silinmişse) yeniden sorulur.
    static func learned(_ path: String, placement: RoutePlacement, destination: URL) -> String? {
        guard let key = PlacementMemory.key(for: path), let folder = placement.learnedFolders[key] else { return nil }
        let clean = PlacementResolution.clean(folder)
        var info = stat()
        guard clean.isEmpty || (lstat(destination.appendingPathComponent(clean).path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR)
        else { return nil }
        return clean
    }
}

/// Karar sayfasında dosya başına ad önerisi: seçilen klasördeki dosyaların adlarından önce kurala bağlı bir ad şablonu
/// çıkarılır (`TemplateInference`), çözülemezse ve model verildiyse model sorulur (`Suggestions.nameTemplate`; şablon
/// örnekleri yeniden üretmelidir); şablon dosyanın tarihiyle uygulanır. Yalnızca öneridir: kullanıcı "Uygula"ya basmadan
/// hiçbir ad kullanılmaz ve ad yine `RoutePlacement.component` ile güvenli bir ada dönüşür.
public enum PlacementNaming {
    /// - Parameters:
    ///   - path: Kaynağa göre göreli yol.
    ///   - folder: Dosyanın gideceği klasör (hedefte; örnek adlar buradan okunur).
    ///   - date: Dosyanın tarihi (şablonun tarih belirteçleri için).
    /// - Returns: Uzantısız yeni ad; şablon çıkmazsa ya da ad değişmiyorsa `noSuggestion`.
    public static func suggest(
        for path: String, in folder: URL, date: DateComponents?, model: (any SuggestionModel)?
    ) async -> SuggestionResult<String> {
        let examples = Suggestions.exampleNames(in: folder)
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        switch await Suggestions.nameTemplate(for: name, examples: examples, model: model) {
        case .value(let template):
            let language = Suggestions.nameLanguage(template, examples: examples) ?? "tr"
            let target = RoutePlacement(nameTemplate: template, language: language).target(for: name, date: date)
            let suggested = RoutePlacement.component(((target as NSString).lastPathComponent as NSString).deletingPathExtension)
            return suggested.isEmpty || suggested == base ? .noSuggestion : .value(suggested)
        case .noSuggestion: return .noSuggestion
        case .unavailable: return .unavailable
        }
    }
}
