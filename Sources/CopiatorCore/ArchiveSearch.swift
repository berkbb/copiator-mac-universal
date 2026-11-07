// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import UniformTypeIdentifiers

/// Bir hedefte (arşivde) arama: dosyanın adında, PDF ve metin dosyalarının içeriğinde ya da fotoğrafın çekim tarihinde
/// ve kamera modelinde. Dosyalar yalnızca okunur; gizli öğeler, sembolik bağlantılar ve paketlerin içi taranmaz (paketin
/// kendisi adıyla bulunur). İçerik, birimin Spotlight dizini varsa oradan, yoksa dosyalar doğrudan okunarak aranır.
/// Harf büyüklüğü, aksanlar ve Türkçe I/ı/İ/i farkı gözetilmez.
public enum ArchiveSearch {
    public enum Match: String, Sendable, Equatable, CaseIterable {
        case name, content, photo
    }

    public struct Hit: Equatable, Sendable, Identifiable {
        /// Aranan köke göre göreli yol.
        public var relativePath: String
        public var match: Match
        /// İçerikte ya da fotoğraf bilgisinde eşleşen yerin çevresi; adda eşleşmede boş.
        public var snippet: String
        public var size: Int64
        public var modified: Date?
        public var id: String { relativePath }
    }

    public struct Results: Equatable, Sendable {
        public var hits: [Hit] = []
        /// Sınıra ulaşıldı: daha fazla eşleşme olabilir.
        public var limited = false
        /// Bakılan dosya sayısı.
        public var scanned = 0
    }

    /// Eşleşen yerin iki yanında gösterilen en çok karakter.
    public static let snippetRadius = 40
    /// Doğrudan okunan en büyük dosya (daha büyük PDF ve metinler yalnızca adıyla bulunur).
    public static let maxReadBytes: Int64 = 200 << 20

    /// - Parameters:
    ///   - contents: Dosyaların içinde ve fotoğraf bilgisinde de aransın mı (yavaş olabilir).
    ///   - limit: En çok sonuç.
    public static func search(
        _ query: String, in root: URL, contents: Bool, limit: Int = 500, isCancelled: () -> Bool = { false }
    ) -> Results {
        var results = Results()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return results }
        let base = SandboxProfile.resolved(root)
        // Dizini olan birimde içerik Spotlight'tan gelir; sonuç boşsa (dizin yok ya da eşleşme yok) dosyalar okunur.
        let indexed = contents ? Spotlight.relativePaths(containing: needle, in: base) : []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return results }
        for case let url as URL in enumerator {
            if results.scanned % 128 == 0, isCancelled() { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            let isPackage = values.isPackage == true
            if isPackage { enumerator.skipDescendants() }
            guard values.isRegularFile == true || isPackage else { continue }
            results.scanned += 1
            let relative = relativePath(url, base: base)
            let name = url.lastPathComponent
            let size = Int64(values.fileSize ?? 0)
            func hit(_ match: Match, _ snippet: String = "") -> Hit {
                Hit(relativePath: relative, match: match, snippet: snippet, size: size, modified: values.contentModificationDate)
            }
            var found: Hit?
            if ContentReader.contains(name, needle) {
                found = hit(.name)
            } else if contents, !isPackage {
                found = contentHit(url, relative: relative, needle: needle, indexed: indexed, size: size).map { hit(.content, $0) }
                    ?? photoHit(url, needle: needle).map { hit(.photo, $0) }
            }
            guard let found else { continue }
            if results.hits.count >= limit {
                results.limited = true
                break
            }
            results.hits.append(found)
        }
        let order = Dictionary(uniqueKeysWithValues: Match.allCases.enumerated().map { ($1, $0) })
        results.hits.sort { ($0.match == $1.match) ? $0.relativePath < $1.relativePath : order[$0.match, default: 0] < order[$1.match, default: 0] }
        return results
    }

    /// İçerikte eşleşme: çevresindeki metin (bulunamazsa boş metin); eşleşme yoksa nil.
    static func contentHit(_ url: URL, relative: String, needle: String, indexed: Set<String>, size: Int64) -> String? {
        let type = UTType(filenameExtension: url.pathExtension)
        if !indexed.isEmpty {
            guard indexed.contains(relative.precomposedStringWithCanonicalMapping) else { return nil }
            // Spotlight Office belgelerini de bulur; okunabiliyorsa çevresi gösterilir.
            guard ContentReader.canRead(type), size <= maxReadBytes, let text = ContentReader.text(of: url, type: type) else { return "" }
            return snippet(in: text, around: needle) ?? ""
        }
        guard ContentReader.canRead(type), size <= maxReadBytes, let text = ContentReader.text(of: url, type: type),
              ContentReader.contains(text, needle) else { return nil }
        return snippet(in: text, around: needle) ?? ""
    }

    /// Fotoğrafın çekim tarihi ("2026-08-15 14:03") ve kamera modeli içinde eşleşme.
    static func photoHit(_ url: URL, needle: String) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), let info = MediaInfo.image(url) else { return nil }
        var parts: [String] = []
        if let date = info.captureDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            parts.append(formatter.string(from: date))
        }
        if let camera = info.cameraModel, !camera.isEmpty { parts.append(camera) }
        let text = parts.joined(separator: " · ")
        return ContentReader.contains(text, needle) ? text : nil
    }

    /// Eşleşen yerin çevresi tek satırda ("…önceki metin ARANAN sonraki…"); harf büyüklüğü ve aksan gözetilmeden bulunur.
    static func snippet(in text: String, around needle: String) -> String? {
        guard let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -snippetRadius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: snippetRadius, limitedBy: text.endIndex) ?? text.endIndex
        let piece = text[start..<end].split(whereSeparator: \.isNewline).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + piece + (end < text.endIndex ? "…" : "")
    }

    /// Köke göre göreli yol (`standardizedFileURL` "/private/var"ı "/var"a çevirdiği için ham yol kullanılır).
    private static func relativePath(_ url: URL, base: URL) -> String {
        let path = url.path
        return path.hasPrefix(base.path + "/") ? String(path.dropFirst(base.path.count + 1)) : url.lastPathComponent
    }
}
