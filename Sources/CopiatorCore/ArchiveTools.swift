// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

// MARK: - Hedefte kopyası var mı

/// Hedefteki dosyaların içerik dizini ("hedefte kopyası var" ölçütü): dosyalar boyuta göre gruplanır, yalnızca boyutu
/// tutanların içeriği (SHA-256) karşılaştırılır ve her dosyanın özeti bir kez hesaplanır. Adı ya da yeri farklı olsa da
/// aynı içerikli dosya "var" sayılır.
public final class DestinationIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var bySize: [Int64: [String]] = [:]
    private var digests: [String: Data] = [:]
    /// Dizindeki dosya sayısı.
    public private(set) var count = 0

    /// Hedefi tarar (gizli dosyalar ve macOS sistem klasörleri dışında).
    public init(root: URL, isCancelled: () -> Bool = { false }) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return
        }
        for case let url as URL in enumerator {
            if count % 256 == 0, isCancelled() || Task.isCancelled { throw CancellationError() }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, let size = values.fileSize else { continue }
            bySize[Int64(size), default: []].append(url.path)
            count += 1
        }
    }

    /// Dosyanın aynısı (boyut ve içerik) hedefte var mı?
    public func contains(_ url: URL, size: Int64) -> Bool {
        let candidates = lock.withLock { bySize[size] ?? [] }
        guard !candidates.isEmpty, let digest = Self.digest(of: url.path) else { return false }
        return candidates.contains { path in
            guard path != url.path else { return false }
            let known = lock.withLock { digests[path] }
            let other = known ?? Self.digest(of: path)
            if known == nil, let other { lock.withLock { digests[path] = other } }
            return other == digest
        }
    }

    static func digest(of path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize())
    }
}

// MARK: - Hedef özeti

/// Bir hedef klasörün özeti: birimin doluluğu, dosya ve klasör sayısı, üst klasörlere ve uzantılara göre boyut.
public struct DestinationSummary: Equatable, Sendable {
    public struct Share: Equatable, Sendable {
        /// Klasör adı ya da uzantı (küçük harf); boşsa kökteki dosyalar / uzantısız dosyalar.
        public var name: String
        public var bytes: Int64
        public var files: Int
    }

    public var totalCapacity: Int64?
    public var availableCapacity: Int64?
    /// Klasördeki dosyaların toplamı.
    public var bytes: Int64 = 0
    public var files = 0
    public var folders = 0
    /// Birinci düzey klasörler (büyükten küçüğe).
    public var topFolders: [Share] = []
    /// En çok yer kaplayan uzantılar (en çok `maxExtensions` tanesi).
    public var topExtensions: [Share] = []

    public static let maxExtensions = 5

    public static func compute(at root: URL, isCancelled: () -> Bool = { false }) throws -> DestinationSummary {
        var summary = DestinationSummary(totalCapacity: DiskSpace.totalCapacity(at: root), availableCapacity: DiskSpace.availableCapacity(at: root))
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .producesRelativePathURLs]) else { return summary }
        var byFolder: [String: Share] = [:]
        var byExtension: [String: Share] = [:]
        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            if seen % 256 == 0, isCancelled() || Task.isCancelled { throw CancellationError() }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                summary.folders += 1
                continue
            }
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            summary.files += 1
            summary.bytes = summary.bytes.saturatingAdding(size)
            let components = url.relativePath.split(separator: "/")
            let folder = components.count > 1 ? String(components[0]) : ""
            byFolder[folder, default: Share(name: folder, bytes: 0, files: 0)].add(size)
            let ext = url.pathExtension.lowercased()
            byExtension[ext, default: Share(name: ext, bytes: 0, files: 0)].add(size)
        }
        func ordered(_ shares: [String: Share]) -> [Share] {
            shares.values.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
        }
        summary.topFolders = ordered(byFolder)
        summary.topExtensions = Array(ordered(byExtension).prefix(maxExtensions))
        return summary
    }
}

extension DestinationSummary.Share {
    mutating func add(_ size: Int64) {
        bytes = bytes.saturatingAdding(size)
        files += 1
    }
}

// MARK: - Klasör önerisi

/// Bir dosya adına (ve varsa içeriğine) göre hedefteki en uygun klasörleri önerir: ad benzerliği (Ratcliff/Obershelp
/// oranı), Türkçe karakterler ve büyük/küçük harf yok sayılarak; addaki kısaltmalar ("sgrt" → "sigorta"), klasör adının adda ya
/// da içerikte geçmesi puanı artırır; en iyi eşleşmelerin kardeş ve benzer adlı klasörleri de eklenir.
public enum FolderSuggester {
    public struct Suggestion: Equatable, Sendable {
        /// Köke göre göreli yol ("Özel/Ev/Tapu").
        public var path: String
        public var score: Double

        public init(path: String, score: Double) {
            self.path = path
            self.score = score
        }
    }

    /// Kökün altındaki klasörler (göreli yollar; gizli klasörler ve paketlerin içi hariç).
    public static func folders(in root: URL, maxCount: Int = 20_000, isCancelled: () -> Bool = { false }) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants,
                                                                        .producesRelativePathURLs]) else { return [] }
        var folders: [String] = []
        for case let url as URL in enumerator {
            if folders.count >= maxCount || isCancelled() { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true, values.isPackage != true else { continue }
            folders.append(url.relativePath.precomposedStringWithCanonicalMapping)
        }
        return folders.sorted()
    }

    public static func suggestions(for name: String, folders: [String], content: String? = nil, limit: Int = 5) -> [Suggestion] {
        let base = fold(((name as NSString).lastPathComponent as NSString).deletingPathExtension)
        guard !base.isEmpty, !folders.isEmpty else { return [] }
        let tokens = base.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let text = content.map(fold) ?? ""
        var scored: [(Double, String)] = folders.map { path in
            let parts = path.split(separator: "/").map { fold(String($0)) }
            let leaf = parts.last ?? ""
            var bonus = 0.0
            if leaf.contains(base) || base.contains(leaf) || tokens.contains(where: { isAbbreviation($0, of: leaf) }) {
                bonus = 0.2
            } else if parts.contains(where: { base.contains($0) }) || parts.contains(where: { part in tokens.contains { isAbbreviation($0, of: part) } }) {
                bonus = 0.1
            }
            if !text.isEmpty {
                if leaf.count > 3, text.contains(leaf) {
                    bonus = max(bonus, 0.2)
                } else if parts.contains(where: { $0.count > 3 && text.contains($0) }) {
                    bonus = max(bonus, 0.1)
                }
            }
            return (max(similarity(base, leaf), similarity(base, parts.joined(separator: "/"))) + bonus, path)
        }
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        // En iyi eşleşmelerin kardeşleri ve benzer adlı klasörler (biraz düşük puanla) eklenir.
        let top = scored.prefix(15)
        var included = Set(top.map(\.1))
        var extra: [(Double, String)] = []
        for (score, path) in top {
            let parent = (path as NSString).deletingLastPathComponent
            let leaf = fold((path as NSString).lastPathComponent)
            for other in folders where !included.contains(other) {
                let otherLeaf = fold((other as NSString).lastPathComponent)
                let sibling = (other as NSString).deletingLastPathComponent == parent
                let alike = leaf.count > 3 && otherLeaf.count > 3
                    && (leaf.contains(otherLeaf) || otherLeaf.contains(leaf) || similarity(leaf, otherLeaf) > 0.6)
                if sibling || alike {
                    extra.append((score - 0.05, other))
                    included.insert(other)
                }
            }
        }
        return (scored + extra).sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            .prefix(limit).map { Suggestion(path: $0.1, score: $0.0) }
    }

    /// Küçük harf, Türkçe karakterler ve aksanlar yok (ş → s, İ/ı → i).
    static func fold(_ text: String) -> String { ContentReader.fold(text.precomposedStringWithCanonicalMapping) }

    /// Benzerlik oranı (0–1): ortak bloklar en uzun ortak alt dizgiyle bulunur, sağı ve solu için yinelenir;
    /// 2 × eşleşen / toplam uzunluk.
    static func similarity(_ a: String, _ b: String) -> Double {
        let left = Array(a), right = Array(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return 2 * Double(matches(left[...], right[...])) / Double(left.count + right.count)
    }

    private static func matches(_ a: ArraySlice<Character>, _ b: ArraySlice<Character>) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var best = (length: 0, a: a.startIndex, b: b.startIndex)
        var previous = [Int](repeating: 0, count: b.count + 1)
        for i in a.indices {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (offset, j) in b.indices.enumerated() where a[i] == b[j] {
                current[offset + 1] = previous[offset] + 1
                if current[offset + 1] > best.length {
                    best = (current[offset + 1], i - current[offset + 1] + 1, j - current[offset + 1] + 1)
                }
            }
            previous = current
        }
        guard best.length > 0 else { return 0 }
        return best.length + matches(a[a.startIndex..<best.a], b[b.startIndex..<best.b])
            + matches(a[(best.a + best.length)...], b[(best.b + best.length)...])
    }

    /// `abbreviation` adın kısaltması mı: en az 3 harf, adın baş harfiyle başlar ve harfleri adda sırayla geçer ("sgrt" →
    /// "sigorta", "ankr" → "ankara"). Sayılar kısaltma sayılmaz.
    static func isAbbreviation(_ abbreviation: String, of full: String) -> Bool {
        let short = Array(fold(abbreviation)), long = Array(fold(full))
        guard short.count >= 3, short.count < long.count, !short.allSatisfy(\.isNumber), short.first == long.first else { return false }
        var index = long.startIndex
        for character in short {
            guard let found = long[index...].firstIndex(of: character) else { return false }
            index = found + 1
        }
        return true
    }
}
