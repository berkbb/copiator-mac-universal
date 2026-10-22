// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Hedefte aynı adlı bir dosya varken ne yapılacağı (iş ve rutin ayarı). Varsayılan: sor.
public enum ConflictPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// İş "karar bekliyor" olarak duraklar; kullanıcı dosya dosya ya da hepsi için seçer.
    case ask
    case replace
    case keepBoth
    case skip

    public var id: String { rawValue }

    /// Sormadan uygulanan karar (sor kipinde nil).
    public var decision: ConflictDecision? {
        switch self {
        case .ask: nil
        case .replace: .replace
        case .keepBoth: .keepBoth
        case .skip: .skip
        }
    }
}

/// Tek bir çakışma için karar.
public enum ConflictDecision: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 1 · Hedefteki dosyanın üzerine yaz.
    case replace
    /// 2 · İkisini de sakla: hedefteki kalır, yeni gelen numaralı adla kopyalanır ("rapor 2.xlsx").
    case keepBoth
    /// 3 · Bu dosyayı kopyalama.
    case skip

    public var id: String { rawValue }

    public var policy: ConflictPolicy {
        switch self {
        case .replace: .replace
        case .keepBoth: .keepBoth
        case .skip: .skip
        }
    }
}

/// Hedefte aynı adla bulunan bir dosya.
public struct FileConflict: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Hedefe göre göreli yol, rsync'in yazdığı gibi ("Kaynak/2026/rapor.xlsx").
    public var path: String
    /// İçerik aynı (rsync'e göre aktarılacak veri yok).
    public var identical: Bool

    public var id: String { path }

    public init(path: String, identical: Bool) {
        self.path = path
        self.identical = identical
    }
}

/// Bir çalıştırmada bulunan çakışmalar (gösterim için en çok `ConflictDetector.maxListed` tanesi) ve toplam sayı.
public struct ConflictReport: Codable, Equatable, Sendable {
    public var items: [FileConflict]
    public var total: Int

    public init(items: [FileConflict], total: Int) {
        self.items = items
        self.total = total
    }

    public var isTruncated: Bool { total > items.count }
}

/// Kullanıcının bir sonraki çalıştırma için verdiği kararlar: dosya dosya ve listede olmayanlar için tek karar.
public struct ConflictResolution: Codable, Equatable, Sendable {
    public var decisions: [String: ConflictDecision]
    /// Listede olmayan çakışmalar (listelenmeyenler ya da sonradan ortaya çıkanlar) için; nil ise onlar yeniden sorulur.
    public var others: ConflictDecision?

    public init(decisions: [String: ConflictDecision] = [:], others: ConflictDecision? = nil) {
        self.decisions = decisions
        self.others = others
    }

    public func decision(for path: String) -> ConflictDecision? { decisions[path] ?? others }
}

/// Çakışmaları bulur ve "ikisini de sakla" adlarını üretir.
public enum ConflictDetector {
    /// Bir işte en çok bu kadar çakışma saklanır ve gösterilir (kayıt dosyası şişmesin); fazlası için tek karar uygulanır.
    public static let maxListed = 5_000

    /// `-n -ii` çıktısından hedefte zaten bulunan dosyalar. `-ii` değişmemiş dosyaları da yazar: içerik aynı olsa da aynı
    /// adlı her dosya bir çakışmadır. Yeni dosyalar (`>f+++…`), klasörler, bağlantılar ve silme satırları çakışma değildir.
    public static func conflicts(in output: String, format: ItemizeParser.Format) -> [FileConflict] {
        let width = format.codeWidth
        var result: [FileConflict] = []
        for line in output.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let characters = Array(line)
            guard characters.count > width + 1, characters[width] == " ", characters[1] == "f", "<>c.".contains(characters[0]) else { continue }
            let attributes = characters[2..<width]
            guard !attributes.allSatisfy({ $0 == "+" }) else { continue }
            let path = ItemizeParser.unescape(String(characters[(width + 1)...]))
            guard !path.isEmpty else { continue }
            result.append(FileConflict(path: path, identical: characters[0] == "."))
        }
        return result
    }

    /// Finder gibi numaralı ad: "rapor.xlsx" → "rapor 2.xlsx", "rapor 3.xlsx"…; uzantısız "Notlar" → "Notlar 2".
    /// - Parameter isTaken: Bu ad hedefte (ya da bu çalıştırmada başka bir kopya için) kullanılıyor mu?
    public static func numberedName(for name: String, isTaken: (String) -> Bool) -> String {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".") ? name : (name as NSString).deletingPathExtension
        let suffix = stem == name ? "" : "." + ext
        var number = 2
        while true {
            let candidate = "\(stem) \(number)\(suffix)"
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// Atlanacak ve numaralı kopyalanacak dosyaların ana kopyalamadan dışlanması için rsync süzgeç kalıpları: aktarım
    /// köküne sabitlenmiş, özel karakterleri kaçışlanmış ("/Kaynak/a\*.txt").
    public static func excludePatterns(for paths: [String]) -> [String] {
        paths.map { "/" + RsyncCommand.escapePattern($0) }
    }
}

/// `-ii` çıktısını satır satır okuyup çakışmaları toplar (çıktı bellekte biriktirilmez; büyük ağaçlarda megabaytlarca olur).
final class ConflictCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let format: ItemizeParser.Format
    private var found: [FileConflict] = []

    init(format: ItemizeParser.Format) {
        self.format = format
    }

    func consume(_ record: String) {
        let items = ConflictDetector.conflicts(in: record, format: format)
        guard !items.isEmpty else { return }
        lock.withLock { found += items }
    }

    var conflicts: [FileConflict] { lock.withLock { found } }
}
