// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Hedefte aynı adlı bir dosya varken ne yapılacağı (iş ve rutin ayarı). Varsayılan: sor. Eşitlemede (iki yönlü)
/// "değiştir" A'dakinin B'ye yazılması, "ters" B'dekinin A'ya yazılması, "yenisi" değişiklik zamanı yeni olanın kazanmasıdır.
public enum ConflictPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// İş "karar bekliyor" olarak duraklar; kullanıcı dosya dosya ya da hepsi için seçer.
    case ask
    case replace
    case keepBoth
    case skip
    /// Yalnızca eşitleme: B'deki kazanır.
    case reverse
    /// Yalnızca eşitleme: değişiklik zamanı yeni olan kazanır (eşitse atlanır).
    case newer

    public var id: String { rawValue }

    /// İş türünde sunulan seçenekler.
    public static func choices(for kind: JobKind) -> [ConflictPolicy] {
        kind == .sync ? [.ask, .newer, .replace, .reverse, .skip] : [.ask, .replace, .keepBoth, .skip]
    }

    /// Sormadan uygulanan karar (sor kipinde ve dosyaya göre değişen "yenisi"nde nil).
    public var decision: ConflictDecision? {
        switch self {
        case .ask, .newer: nil
        case .replace: .replace
        case .keepBoth: .keepBoth
        case .skip: .skip
        case .reverse: .reverse
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
    /// Yalnızca eşitleme: B'deki dosya A'dakinin yerine geçer.
    case reverse

    public var id: String { rawValue }

    /// İş türünde sunulan kararlar (sayfadaki sırayla; numara sıradan gelir).
    public static func choices(for kind: JobKind) -> [ConflictDecision] {
        kind == .sync ? [.replace, .reverse, .skip] : [.replace, .keepBoth, .skip]
    }

    public var policy: ConflictPolicy {
        switch self {
        case .replace: .replace
        case .keepBoth: .keepBoth
        case .skip: .skip
        case .reverse: .reverse
        }
    }
}

/// Hedefte aynı adla bulunan bir dosya (ya da gelen öğeyle aynı adlı, başka türde bir öğe).
public struct FileConflict: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Hedefe göre göreli yol, rsync'in yazdığı gibi ("Kaynak/2026/rapor.xlsx").
    public var path: String
    /// İçerik aynı (rsync'e göre aktarılacak veri yok).
    public var identical: Bool
    /// Gelen bir klasör, hedefte aynı adlı bir dosyanın (ya da bağlantının) yerine geçecek. rsync bu dosyayı sormadan
    /// silerdi. "İkisini de sakla"da hedefteki öğe numaralı adla yeniden adlandırılır; klasör yerinde kalır.
    public var incomingFolder: Bool

    public var id: String { path }

    public init(path: String, identical: Bool, incomingFolder: Bool = false) {
        self.path = path
        self.identical = identical
        self.incomingFolder = incomingFolder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        identical = try container.decode(Bool.self, forKey: .identical)
        incomingFolder = try container.decodeIfPresent(Bool.self, forKey: .incomingFolder) ?? false
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
        conflicts(in: output, format: format, existsAtDestination: { _ in false })
    }

    /// Hedefte başka türde bir öğenin yerine geçecek "yeni" öğeler de sayılır: rsync hedefte aynı adla klasör yerine dosya,
    /// dosya yerine klasör ya da bağlantı bulunca gelen öğeyi yeni (`>f+++…`, `cd+++…`, `cL+++…`) gösterir ve oradakini
    /// sessizce siler. - Parameter existsAtDestination: Göreli yolda hedefte bir öğe var mı (`lstat`; bağlantı izlenmez)?
    public static func conflicts(in output: String, format: ItemizeParser.Format, existsAtDestination: (String) -> Bool) -> [FileConflict] {
        let width = format.codeWidth
        var result: [FileConflict] = []
        for line in output.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let characters = Array(line)
            guard characters.count > width + 1, characters[width] == " ", "<>c.".contains(characters[0]) else { continue }
            let attributes = characters[2..<width]
            let isNew = attributes.allSatisfy { $0 == "+" }
            // Yeni öğe yalnızca hedefte aynı adla (başka türde) bir şey varsa çakışmadır: o silinecekti.
            guard isNew ? "fdL".contains(characters[1]) && characters[0] != "." : characters[1] == "f" else { continue }
            var raw = String(characters[(width + 1)...])
            if characters[1] == "L", let arrow = raw.range(of: " -> ") { raw = String(raw[..<arrow.lowerBound]) }
            var path = ItemizeParser.unescape(raw)
            while path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty, path != ".", !path.hasPrefix("./") || path.count > 2 else { continue }
            if isNew {
                guard existsAtDestination(path) else { continue }
                result.append(FileConflict(path: path, identical: false, incomingFolder: characters[1] == "d"))
            } else {
                result.append(FileConflict(path: path, identical: characters[0] == "."))
            }
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
        paths.map { RsyncCommand.escapePattern("/" + $0) }
    }
}

/// `-ii` çıktısını satır satır okuyup çakışmaları toplar (çıktı bellekte biriktirilmez; büyük ağaçlarda megabaytlarca olur).
final class ConflictCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let format: ItemizeParser.Format
    private let destination: String?
    private var found: [FileConflict] = []

    /// - Parameter destination: Verilirse "yeni" görünen öğelerin hedefte başka türde bir karşılığı olup olmadığına bakılır.
    init(format: ItemizeParser.Format, destination: URL? = nil) {
        self.format = format
        self.destination = destination.map { $0.standardizedFileURL.path }
    }

    func consume(_ record: String) {
        let items = ConflictDetector.conflicts(in: record, format: format) { [destination] path in
            guard let destination else { return false }
            // Üst klasörlerden biri gerçek bir klasör değilse (bağlantı, dosya) rsync onu değiştirecek; altındaki yol
            // bağlantı üzerinden bulunsa da hedefte "var" sayılmaz (bağlantı izlenmez).
            var info = stat()
            var current = destination
            let components = path.split(separator: "/")
            for component in components.dropLast() {
                current = (current as NSString).appendingPathComponent(String(component))
                guard lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
            }
            return lstat((destination as NSString).appendingPathComponent(path), &info) == 0
        }
        guard !items.isEmpty else { return }
        lock.withLock { found += items }
    }

    var conflicts: [FileConflict] { lock.withLock { found } }
}
