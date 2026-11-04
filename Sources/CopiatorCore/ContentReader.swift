// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Dosyanın metnini doğrudan okur: PDF'ler PDFKit ile, düz metin dosyaları baştan bir bölümüyle. Spotlight dizini
/// olmayan birimlerde (harici diskler, ağ paylaşımları) "içerikte geçen metin" ölçütü ve tarih belirteçleri bununla çalışır.
public enum ContentReader {
    /// Okunacak en çok karakter (uzun belgelerde arama ve tarih için baştaki bölüm yeter).
    public static let maxCharacters = 1_000_000
    /// PDF'lerde okunacak en çok sayfa.
    public static let maxPages = 50
    /// Düz metinde okunacak en çok bayt.
    static let maxTextBytes = 1 << 20

    /// Bu türün metni okunabilir mi (PDF ya da zengin biçimli olmayan metin)?
    public static func canRead(_ type: UTType?) -> Bool {
        guard let type else { return false }
        if type.conforms(to: .pdf) { return true }
        return type.conforms(to: .text) && !type.conforms(to: .rtf) && !type.conforms(to: .rtfd)
    }

    /// Dosyanın metni; okunamıyorsa (şifreli PDF, desteklenmeyen tür, okuma hatası) nil.
    public static func text(of url: URL, type: UTType? = nil) -> String? {
        let type = type ?? UTType(filenameExtension: url.pathExtension)
        guard canRead(type), let type else { return nil }
        if type.conforms(to: .pdf) { return pdfText(url) }
        return plainText(url)
    }

    static func pdfText(_ url: URL) -> String? {
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        var text = ""
        for index in 0..<min(document.pageCount, maxPages) {
            guard let page = document.page(at: index)?.string else { continue }
            text += page + "\n"
            if text.count >= maxCharacters { break }
        }
        return text.isEmpty ? nil : String(text.prefix(maxCharacters))
    }

    static func plainText(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxTextBytes), !data.isEmpty else { return nil }
        // UTF-8 değilse Türkçe Windows kod sayfası (eski .txt ve .csv dosyaları), o da olmazsa kayıplı UTF-8.
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1254) ?? String(decoding: data, as: UTF8.self)
        return String(text.prefix(maxCharacters))
    }

    /// Metin, aranan değeri içeriyor mu: büyük/küçük harf ve aksan duyarsız, Türkçe I/ı/İ/i farkı yok.
    public static func contains(_ text: String, _ value: String) -> Bool {
        let needle = fold(value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return false }
        return fold(text).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Küçük harfe, aksansız biçime ve noktalı i'ye indirir (ş → s, ğ → g, İ/ı → i, ș → s).
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ı", with: "i")
    }
}

/// Metinde (dosya adında ya da içeriğinde) geçen ilk tarih. Öncelik sırası: ay adı ve yıl ("15 Ağustos 2026",
/// "Agustos 26"), gün.ay.yıl, yıl-ay-gün, yıl ay, ay yıl, iki haneli yıl ve ay, ay ve iki haneli yıl ("El_10_26").
/// Ay adları Türkçe, İngilizce ve Rumence; harf ve aksan farkı gözetilmez. İki haneli yıllar 2020–2099'dur.
public enum TextDate {
    /// Katlanmış (bkz. `ContentReader.fold`) ay adları → ay numarası.
    static let monthNames: [(String, Int)] = {
        var names: [(String, Int)] = []
        for identifier in ["tr_TR", "en_US", "ro_RO"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: identifier)
            for symbols in [formatter.monthSymbols ?? [], formatter.standaloneMonthSymbols ?? []] {
                for (index, symbol) in symbols.enumerated() {
                    let folded = ContentReader.fold(symbol)
                    if !names.contains(where: { $0.0 == folded }) { names.append((folded, index + 1)) }
                }
            }
        }
        // Uzun adlar önce: "martie" "mart"tan önce denensin.
        return names.sorted { $0.0.count > $1.0.count }
    }()

    static let year4 = "(19[89]\\d|20\\d\\d)"
    static let year2 = "([2-9]\\d)"

    private enum Order { case dayMonthYear, yearMonthDay, yearMonth, monthYear }

    private static let patterns: [(NSRegularExpression, Order)] = {
        let months = monthNames.map { NSRegularExpression.escapedPattern(for: $0.0) }.joined(separator: "|")
        let sources: [(String, Order)] = [
            ("\\b(?:(\\d{1,2})[\\s./-]*)?(\(months))[\\s.,/-]*(?:\(year4)|\(year2))\\b", .dayMonthYear),
            ("\\b(\\d{1,2})[./-](\\d{1,2})[./-](?:\(year4)|\(year2))\\b", .dayMonthYear),
            ("\\b(?:\(year4)|\(year2))[./-](\\d{1,2})[./-](\\d{1,2})\\b", .yearMonthDay),
            ("\\b\(year4)[\\s./-](\\d{2})\\b", .yearMonth),
            ("\\b(\\d{2})[\\s./-]\(year4)\\b", .monthYear),
            ("\\b\(year2)[\\s./-](\\d{2})\\b", .yearMonth),
            ("\\b(\\d{2})[\\s./-]\(year2)\\b", .monthYear),
        ]
        return sources.compactMap { source, order in (try? NSRegularExpression(pattern: source)).map { ($0, order) } }
    }()

    /// - Returns: Yıl ve ay (gün varsa o da); bulunamazsa nil.
    public static func find(in text: String) -> DateComponents? {
        // Alt çizgi dosya adlarında ayraçtır ("El_10_26"); düzenli ifadede harf sayılırdı.
        let folded = ContentReader.fold(text).replacingOccurrences(of: "_", with: " ")
        let range = NSRange(folded.startIndex..., in: folded)
        for (pattern, order) in patterns {
            for match in pattern.matches(in: folded, range: range) {
                let groups = (1..<match.numberOfRanges).map { index -> String? in
                    let range = match.range(at: index)
                    return range.location == NSNotFound ? nil : Range(range, in: folded).map { String(folded[$0]) }
                }
                if let date = components(groups, order) { return date }
            }
        }
        return nil
    }

    private static func components(_ groups: [String?], _ order: Order) -> DateComponents? {
        func year(_ value: String?) -> Int? {
            guard let value, let number = Int(value) else { return nil }
            return value.count == 2 ? 2000 + number : number
        }
        func month(_ value: String?) -> Int? {
            guard let value else { return nil }
            if let number = Int(value) { return (1...12).contains(number) ? number : nil }
            return monthNames.first { $0.0 == value }?.1
        }
        let present = groups.compactMap { $0 }
        var result = DateComponents()
        switch order {
        case .dayMonthYear:
            // [gün?, ay, yıl4 | yıl2]
            guard groups.count >= 3, let m = month(groups[1]), let y = year(groups.dropFirst(2).compactMap { $0 }.first) else { return nil }
            result.year = y
            result.month = m
            if let day = groups[0].flatMap(Int.init) {
                guard (1...31).contains(day) else { return nil }
                result.day = day
            }
        case .yearMonthDay:
            // [yıl4 | yıl2, ay, gün]
            guard present.count == 3, let y = year(present[0]), let m = month(present[1]), let d = Int(present[2]), (1...31).contains(d) else { return nil }
            result.year = y
            result.month = m
            result.day = d
        case .yearMonth:
            guard present.count == 2, let y = year(present[0]), let m = month(present[1]) else { return nil }
            result.year = y
            result.month = m
        case .monthYear:
            guard present.count == 2, let m = month(present[0]), let y = year(present[1]) else { return nil }
            result.year = y
            result.month = m
        }
        return result
    }
}
