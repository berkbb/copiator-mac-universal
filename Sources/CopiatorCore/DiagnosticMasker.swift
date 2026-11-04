// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

/// Tanılama raporundaki kişisel bilgileri maskeler: ev klasörü "~" olur; kullanıcı adı ‹user›; disk, klasör ve dosya
/// adları rapor başına rastgele bir tuzla kısa özetlere (‹name-3fa2c1›.pdf) dönüşür. Aynı ad bir raporda hep aynı
/// özeti alır (satırlar birbirine bağlanabilir), ama tuz raporla birlikte saklanmadığından ad geri bulunamaz. macOS'un
/// standart klasör adları (Users, Volumes, Library, Documents…), anlık görüntü adları ve kısa uzantılar tanı için açık
/// kalır.
public struct DiagnosticMasker: Sendable {
    /// Açık kalan standart klasör adları.
    public static let keptNames: Set<String> = [
        "Users", "Volumes", "Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public",
        "Applications", "Application Support", "Containers", "Group Containers", "Mobile Documents", "CloudStorage", "Caches",
        "Preferences", "Mail", "Messages", "Safari", "Cookies", ".Trash", ".ssh", "private", "var", "tmp", "folders", "System",
        "opt", "usr", "bin", "sbin", "etc", "dev", "Latest", "Copiator", "rsync", "sandbox-exec",
    ]

    let home: String
    let userNames: [String]
    let salt: Data

    /// - Parameters:
    ///   - home: Ev klasörünün yolu ("~" ile değiştirilir).
    ///   - userNames: Kullanıcının kısa ve tam adı; tam adın üç harften uzun parçaları da maskelenir.
    ///   - salt: Özetlerin tuzu (testler sabit verir; uygulama her rapor için rastgele üretir).
    public init(home: String, userNames: [String], salt: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) })) {
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        let parts = userNames.flatMap { [$0] + $0.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" }).map(String.init) }
        self.userNames = Array(Set(parts.filter { $0.count >= 3 })).sorted { $0.count > $1.count }
        self.salt = salt
    }

    /// Bir yolun maskelenmiş hâli: ev klasörü "~", her öteki bileşen ayrı ayrı maskelenir.
    public func path(_ path: String) -> String {
        var rest = Substring(path)
        var prefix = ""
        if path == home || path.hasPrefix(home + "/") {
            prefix = "~"
            rest = path.dropFirst(home.count)
        } else if path.hasPrefix("~") {
            prefix = "~"
            rest = path.dropFirst()
        }
        let components = rest.split(separator: "/", omittingEmptySubsequences: false).map { component -> String in
            component.isEmpty ? "" : name(String(component))
        }
        return prefix + components.joined(separator: "/")
    }

    /// Tek bir ad (dosya, klasör ya da disk adı).
    public func name(_ name: String) -> String {
        if Self.keptNames.contains(name) || SnapshotStore.isSnapshotName(name) || name.hasSuffix(".partial") && SnapshotStore.isSnapshotName(String(name.dropLast(8))) {
            return name
        }
        let ext = (name as NSString).pathExtension
        let keepsExtension = !ext.isEmpty && ext.count <= 10 && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let digest = SHA256.hash(data: salt + Data(name.precomposedStringWithCanonicalMapping.utf8))
        let token = "‹name-" + digest.prefix(3).map { String(format: "%02x", $0) }.joined() + "›"
        return keepsExtension ? token + "." + ext : token
    }

    /// Serbest metin (günlük satırı, hata iletisi): ev klasörü, kullanıcı adları, tırnak içindeki yollar ve adlar,
    /// tırnaksız yollar ve verilen bilinen yollar (boşluk içerseler de) maskelenir.
    public func text(_ text: String, knownPaths: [String] = []) -> String {
        var result = text
        // Bilinen yollar (iş kaynakları ve hedefleri) önce, uzundan kısaya: boşluk içeren adlar da bütün olarak maskelenir.
        for known in Set(knownPaths).sorted(by: { $0.count > $1.count }) where known.count > 1 {
            result = result.replacingOccurrences(of: known, with: path(known))
        }
        // Tırnak içleri: yol ise yol, değilse ad olarak. Düz kesme işareti eşlenmez: "Copiator'ı … rsync'in" gibi
        // metinlerde iki kesme işaretinin arası bir ad değildir.
        for (open, close) in [("\"", "\""), ("“", "”"), ("‘", "’"), ("«", "»")] {
            result = replaceQuoted(result, open: open, close: close)
        }
        // Tırnaksız yollar: "/" ya da "~/" ile başlayan, boşluğa kadar süren parçalar.
        result = replacePaths(result)
        for user in userNames {
            result = result.replacingOccurrences(of: user, with: "‹user›", options: [.caseInsensitive, .diacriticInsensitive])
        }
        return result
    }

    /// rsync komutunun bir argümanı: yollar maskelenir; süzgeç desenleri (kullanıcının yazdığı adlar içerebilir) gizlenir.
    public func argument(_ argument: String) -> String {
        if argument.hasPrefix("/") || argument.hasPrefix("~") { return path(argument) }
        guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else { return argument }
        let option = String(argument[..<equals])
        let value = String(argument[argument.index(after: equals)...])
        if value.hasPrefix("/") || value.hasPrefix("~") { return option + "=" + path(value) }
        if ["--include", "--exclude", "--filter", "--suffix"].contains(option) { return option + "=‹pattern›" }
        return argument
    }

    private func isPath(_ text: Substring) -> Bool { text.hasPrefix("/") || text.hasPrefix("~/") || text == "~" }

    private func replaceQuoted(_ text: String, open: String, close: String) -> String {
        var output = ""
        var rest = Substring(text)
        while let start = rest.range(of: open) {
            output += rest[..<start.upperBound]
            let afterOpen = rest[start.upperBound...]
            guard let end = afterOpen.range(of: close) else {
                rest = afterOpen
                continue
            }
            let inner = afterOpen[..<end.lowerBound]
            output += inner.isEmpty ? "" : (isPath(inner) ? path(String(inner)) : maskedWords(inner))
            output += close
            rest = afterOpen[end.upperBound...]
        }
        return output + rest
    }

    /// Tırnak içindeki yol olmayan metin: bir dosya ya da klasör adı olabilir; tek parça ise ad olarak maskelenir.
    private func maskedWords(_ inner: Substring) -> String {
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        // Zaten maskelenmiş ya da sayı olan içerik olduğu gibi kalır.
        if trimmed.hasPrefix("‹") || trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) { return String(inner) }
        return name(String(inner))
    }

    private func replacePaths(_ text: String) -> String {
        var output = ""
        var token = ""
        var inPath = false
        var previous: Character = " "
        func flush() {
            if inPath { output += path(token) } else { output += token }
            token = ""
            inPath = false
        }
        for character in text {
            if inPath {
                if character.isWhitespace || "\"“”'‘’«»(),;".contains(character) {
                    flush()
                    output.append(character)
                } else {
                    token.append(character)
                }
            } else if (character == "/" || character == "~") && (previous.isWhitespace || "\"“'‘«(=".contains(previous)) {
                output += token
                token = String(character)
                inPath = true
            } else {
                output.append(character)
            }
            previous = character
        }
        flush()
        return output
    }
}
