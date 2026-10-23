// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Darwin
import Foundation

/// Arşiv bütünlüğü: hedefin köküne her dosyanın boyutunu, değiştirilme tarihini ve SHA-256 özetini içeren gizli bir liste
/// yazılır; sonraki denetimler dosyaları yeniden okur. Boyutu ve tarihi aynı kalıp içeriği değişen dosya bozuktur (diskteki
/// sessiz bozulma) ve liste düzeltilene kadar bildirilir; boyutu ya da tarihi değişen dosya meşru bir değişikliktir ve
/// listede güncellenir; listede olup diskte olmayan dosya bir kez kayıp olarak bildirilir ve listeden çıkar; yeni dosyalar
/// eklenir. Anlık görüntülerdeki sabit bağlantılı kopyalar bir kez okunur. Hiçbir dosya değiştirilmez; yalnızca liste yazılır.
public enum ArchiveIntegrity {
    public static let manifestName = ".copiator-integrity.json"

    public struct Entry: Codable, Equatable, Sendable {
        public var size: Int64
        public var modified: TimeInterval
        public var sha256: String
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public var version = 1
        public var checkedAt: Date
        public var files: [String: Entry]
    }

    public struct Report: Equatable, Sendable {
        /// Listeyle karşılaştırılan ve sağlam bulunan dosyalar.
        public var intact = 0
        /// Listeye ilk kez eklenen ve değiştiği için yeniden kaydedilen dosyalar.
        public var added = 0
        public var updated = 0
        /// Boyutu ve tarihi aynı, içeriği farklı (bozuk) dosyalar.
        public var corrupted: [String] = []
        /// Listede olup diskte olmayan dosyalar.
        public var missing: [String] = []
        /// Okunamayan dosyalar.
        public var unreadable: [String] = []
        /// İlk denetim (liste yoktu).
        public var isFirstCheck = false
        /// Okunan bayt.
        public var bytes: Int64 = 0

        public var hasProblems: Bool { !corrupted.isEmpty || !missing.isEmpty || !unreadable.isEmpty }
    }

    /// Okunmayan dosyalar: listenin kendisi ve macOS'un yardımcı dosyaları.
    static let skippedNames: Set<String> = [manifestName, ".DS_Store", ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems",
                                            ".DocumentRevisions-V100"]

    /// Hedefin listesi (yoksa ya da okunamıyorsa nil).
    public static func manifest(in root: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(manifestName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
    }

    /// Hedefi denetler ve listeyi günceller.
    /// - Parameters:
    ///   - progress: Okunan dosya sayısı ve bayt (ara sıra çağrılır).
    /// - Throws: İptalde `CancellationError` (liste yazılmaz); liste yazılamazsa yazma hatası.
    public static func check(
        _ root: URL, now: Date = Date(), progress: (Int, Int64) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }
    ) throws -> Report {
        let previous = manifest(in: root)
        var report = Report(isFirstCheck: previous == nil)
        var files: [String: Entry] = [:]
        var known = previous?.files ?? [:]
        var byInode: [String: String] = [:]
        var count = 0
        for (relative, url, info) in regularFiles(in: root) {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            let size = Int64(info.st_size)
            let modified = modifiedTime(info)
            let inode = "\(info.st_dev):\(info.st_ino)"
            let digest: String
            if let cached = byInode[inode] {
                digest = cached
            } else {
                do {
                    digest = try hash(url.path, isCancelled: isCancelled)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    report.unreadable.append(relative)
                    if let old = known.removeValue(forKey: relative) { files[relative] = old }
                    continue
                }
                byInode[inode] = digest
                report.bytes += size
            }
            count += 1
            if count % 64 == 0 { progress(count, report.bytes) }
            let entry = Entry(size: size, modified: modified, sha256: digest)
            guard let old = known.removeValue(forKey: relative) else {
                report.added += 1
                files[relative] = entry
                continue
            }
            if old.size == size, abs(old.modified - modified) < 0.001 {
                if old.sha256 == digest {
                    report.intact += 1
                } else {
                    // Bozuk: eski özet kalır, dosya düzeltilene (ya da değiştirilene) kadar her denetimde bildirilir.
                    report.corrupted.append(relative)
                }
                files[relative] = old
            } else {
                report.updated += 1
                files[relative] = entry
            }
        }
        report.missing = known.keys.sorted()
        report.corrupted.sort()
        report.unreadable.sort()
        progress(count, report.bytes)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Manifest(checkedAt: now, files: files)).write(to: root.appendingPathComponent(manifestName), options: .atomic)
        return report
    }

    /// Kökün altındaki düzenli dosyalar (bağlantılar izlenmez; gizli sistem dosyaları ve liste atlanır), göreli yollarıyla.
    static func regularFiles(in root: URL) -> [(String, URL, stat)] {
        var result: [(String, URL, stat)] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.producesRelativePathURLs])
        else { return [] }
        for case let url as URL in enumerator {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            // Atlanan bir klasörün içine girilmez (dosyada atlama çağrılmaz: numaralandırıcı o zaman klasörün geri kalanını atlar).
            if skippedNames.contains(url.lastPathComponent) {
                if info.st_mode & S_IFMT == S_IFDIR { enumerator.skipDescendants() }
                continue
            }
            guard info.st_mode & S_IFMT == S_IFREG else { continue }
            result.append((url.relativePath.precomposedStringWithCanonicalMapping, url, info))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// SHA-256; okuma hatası yarım bir özet değil hatadır.
    static func hash(_ path: String, isCancelled: () -> Bool) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
