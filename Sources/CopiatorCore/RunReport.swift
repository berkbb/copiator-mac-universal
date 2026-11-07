// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Son çalıştırmanın raporu: hangi dosya hedefe eklendi, güncellendi ya da hedeften silindi, kurallı ve yerleştirilen
/// işte kaynakta hangi dosyadan geldi (adı ya da klasörü değiştiyse), "Taşı" ile hangi kaynaklar Çöp'e gitti. Yalnızca
/// son çalıştırmada tutulur (`JobQueue.finish`) ve kullanıcı isteyince metin olarak kaydedilir (`text`).
public struct RunReport: Codable, Equatable, Sendable {
    /// Kaydedilen en çok öğe; fazlası rapora girmez ve rapor bunu söyler.
    public static let maxItems = 5_000

    public enum Action: String, Codable, Sendable, CaseIterable {
        case added, updated, deleted
    }

    public struct Item: Codable, Equatable, Sendable {
        public var action: Action
        /// Hedefe (anlık görüntüde anlık görüntü klasörüne) göre göreli yol, rsync'in yazdığı gibi.
        public var path: String
        /// Kaynağa göre göreli yol; yalnızca hedefteki yoldan farklıysa (yeniden adlandırma ya da yerleştirme).
        public var source: String?

        public init(action: Action, path: String, source: String? = nil) {
            self.action = action
            self.path = path
            self.source = source
        }
    }

    public var items: [Item]
    /// Sınır aşıldı: liste eksik.
    public var truncated: Bool
    /// "Taşı" ile Çöp Sepeti'ne taşınan kaynak dosyalar (kaynağa göre göreli).
    public var trashedSources: [String]

    public init(items: [Item] = [], truncated: Bool = false, trashedSources: [String] = []) {
        self.items = items
        self.truncated = truncated
        self.trashedSources = trashedSources
    }

    private enum CodingKeys: String, CodingKey { case items, truncated, trashedSources }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([Item].self, forKey: .items)) ?? []
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        trashedSources = (try? c.decodeIfPresent([String].self, forKey: .trashedSources)) ?? []
    }

    /// Bir değişiklik satırını ekler: klasörlerin eklenmesi ve güncellenmesi (yalnızca tarih) listeye girmez, silinen
    /// klasörler girer; öznitelik değişiklikleri girmez.
    mutating func add(_ change: DiffEntry) {
        let action: Action
        switch change.kind {
        case .missing where !change.isDirectory: action = .added
        case .changed where !change.isDirectory: action = .updated
        case .extra: action = .deleted
        default: return
        }
        guard items.count < Self.maxItems else {
            truncated = true
            return
        }
        items.append(Item(action: action, path: change.path))
    }

    /// Kurallı işte hedefteki yollara kaynaktaki yolları ekler (yalnızca farklı olanlara).
    /// - Parameters:
    ///   - paths: Seçilen dosyalar, kaynağa göre göreli.
    ///   - targets: Aynı sırayla hedefteki yolları (rsync'in yazdığı yollar).
    mutating func attachSources(paths: [String], targets: [String]) {
        var sources: [String: String] = [:]
        for (path, target) in zip(paths, targets) where path != target {
            sources[target.precomposedStringWithCanonicalMapping] = path
        }
        guard !sources.isEmpty else { return }
        for index in items.indices {
            items[index].source = sources[items[index].path.precomposedStringWithCanonicalMapping]
        }
    }

    /// Raporun metni.
    /// - Parameters:
    ///   - text: Çeviri işlevi (anahtar ve metin olarak değişkenler).
    ///   - date: Tarih biçimi; `result`: sonucun açıklaması.
    ///   - problems: Çalıştırma sırasında yazılan uyarı ve hata satırları (çevrilmiş).
    public static func text(
        title: String, job: TransferJob, run: JobRun, result: String, problems: [String],
        text: (LKey, [String]) -> String, date: (Date) -> String
    ) -> String {
        let report = run.result.report ?? RunReport()
        func line(_ value: String) -> String { OpenSafety.visibleName(value) }
        var destination = job.destination.path
        if let snapshot = run.result.snapshot { destination += "/" + snapshot }
        var lines = [
            text(.reportTitle, [line(title)]),
            text(.reportSource, [line(job.source.path)]),
            text(.reportDestination, [line(destination)]),
            text(.reportStarted, [date(run.startedAt)]),
            text(.reportFinished, [date(run.finishedAt)]),
            text(.reportResult, [result]),
        ]
        let sections: [(LKey, Action)] = [(.reportAdded, .added), (.reportUpdated, .updated), (.reportDeleted, .deleted)]
        for (key, action) in sections {
            let items = report.items.filter { $0.action == action }
            guard !items.isEmpty else { continue }
            lines += ["", text(key, [String(items.count)])]
            for item in items {
                if let source = item.source {
                    lines.append("  " + line(source) + "  →  " + line(item.path))
                } else {
                    lines.append("  " + line(item.path))
                }
            }
        }
        if report.items.isEmpty { lines += ["", text(.reportNoChanges, [])] }
        if report.truncated { lines += ["", text(.reportTruncated, [String(maxItems)])] }
        if !report.trashedSources.isEmpty {
            lines += ["", text(.reportTrashed, [String(report.trashedSources.count)])]
            lines += report.trashedSources.map { "  " + line($0) }
        }
        if !problems.isEmpty {
            lines += ["", text(.reportProblems, [String(problems.count)])]
            lines += problems.map { "  " + $0 }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
