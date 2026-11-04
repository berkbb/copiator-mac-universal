// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import UniformTypeIdentifiers

/// "Klasörü sor" rotasında hedef klasörü henüz seçilmemiş dosyalar: iş bunlar için karar bekler ("karar bekliyor").
public struct PlacementReport: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        /// Kaynağa göre göreli yol.
        public var path: String
        /// Önerilen klasörler (hedefe göre göreli, en uygunu başta); boşsa hedefte uygun klasör bulunamadı.
        public var suggestions: [String]

        public init(path: String, suggestions: [String]) {
            self.path = path
            self.suggestions = suggestions
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

/// Kullanıcının yerleştirme kararları: dosya → hedefteki klasör (göreli; "" hedefin kökü) ya da atla. İş bitince silinir.
public struct PlacementResolution: Codable, Equatable, Sendable {
    public var folders: [String: String]
    public var skipped: Set<String>

    public init(folders: [String: String] = [:], skipped: Set<String> = []) {
        self.folders = folders
        self.skipped = skipped
    }

    private enum CodingKeys: String, CodingKey { case folders, skipped }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folders = (try? c.decodeIfPresent([String: String].self, forKey: .folders)) ?? [:]
        skipped = (try? c.decodeIfPresent(Set<String>.self, forKey: .skipped)) ?? []
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
        /// Klasörü seçilmemiş dosyalar (yoksa nil).
        public var report: PlacementReport?
    }

    /// İş, klasörü seçilmemiş dosyalar için karar bekliyor.
    public struct DecisionNeeded: Error, Sendable {
        public var report: PlacementReport
    }

    /// - Parameter decide: false ise (önizleme) kararsız dosyalar ilk öneriye (yoksa hedefin köküne) konur, iş beklemez.
    public static func plan(
        paths: [String], source: URL, destination: URL, placement: RoutePlacement, resolution: PlacementResolution?,
        decide: Bool = true, isCancelled: () -> Bool = { false }
    ) throws -> Plan {
        let resolution = resolution ?? PlacementResolution()
        var plan = Plan(paths: [], folders: [:], report: nil)
        var undecided: [String] = []
        for path in paths {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            if resolution.skipped.contains(path) { continue }
            if let folder = resolution.folders[path] ?? learned(path, placement: placement, destination: destination) {
                plan.paths.append(path)
                plan.folders[path] = PlacementResolution.clean(folder)
            } else {
                undecided.append(path)
            }
        }
        guard !undecided.isEmpty else { return plan }
        let candidates = FolderSuggester.folders(in: destination, isCancelled: isCancelled)
        var items: [PlacementReport.Item] = []
        for path in decide ? Array(undecided.prefix(PlacementReport.maxItems)) : undecided {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            let url = source.appendingPathComponent(path)
            let content = ContentReader.canRead(UTType(filenameExtension: url.pathExtension)) ? ContentReader.text(of: url) : nil
            let suggestions = FolderSuggester.suggestions(for: path, folders: candidates, content: content, limit: Suggestions.maxCandidates)
            items.append(PlacementReport.Item(path: path, suggestions: suggestions.map(\.path)))
        }
        guard decide else {
            for item in items {
                plan.paths.append(item.path)
                plan.folders[item.path] = item.suggestions.first ?? ""
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
