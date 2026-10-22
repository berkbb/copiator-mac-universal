// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Doğrulamada bulunan bir fark.
public struct DiffEntry: Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Kaynakta var, hedefte yok.
        case missing
        /// İçeriği (boyut, zaman ya da `-c` ile sağlama) farklı.
        case changed
        /// Yalnızca öznitelikleri (izin, zaman, sahip, ACL, xattr) farklı; klasör zamanları burada görünür.
        case attributes
        /// Hedefte var, kaynakta yok (`--delete` ile silinirdi).
        case extra
    }

    public var kind: Kind
    /// Aktarım köküne göre göreli yol; klasörlerde sonda "/" yok.
    public var path: String
    public var isDirectory: Bool
    /// rsync'in özet kodu (rsync 3.x: 11 karakter ">f.st......", openrsync: 9 karakter ">f.st...."); "fark yok"
    /// satırları listeye girmez.
    public var code: String

    public var id: String { kind.rawValue + "\u{0}" + path }

    public init(kind: Kind, path: String, isDirectory: Bool, code: String) {
        self.kind = kind
        self.path = path
        self.isDirectory = isDirectory
        self.code = code
    }
}

/// rsync `-i` (`--itemize-changes`) satırlarını okur.
///
/// Biçim: `YXcstpoguax ad` (11 karakter, boşluk, ad). Y: `>` alındı, `c` oluşturuldu/değişti, `h` sabit bağlantı,
/// `.` içerik aynı, `*` ileti (`*deleting`). X: f dosya, d klasör, L bağlantı, D aygıt, S özel. Yeni öğede öznitelik
/// sütunları `+`, değişmeyenler `.` (ya da boşluk). Yazdırılamayan karakterler `\#ooo` (sekizlik) olarak kaçışlanır.
public enum ItemizeParser {
    /// Özet kodunun genişliği motora göre değişir; ad, kodun ardından gelen tek boşluktan sonra başlar.
    public enum Format: Sendable {
        /// rsync 3.x: `YXcstpoguax` (11 karakter); "*deleting" 11 sütuna doldurulur.
        case rsync3
        /// macOS'un openrsync'i (rsync 2.6.9 uyumlu): `YXcstpogz` (9 karakter); "*deleting" doldurulmaz.
        case openrsync

        public var codeWidth: Int { self == .rsync3 ? 11 : 9 }

        public init(engine: EngineInfo) {
            self = engine.isOpenrsync ? .openrsync : .rsync3
        }
    }

    public static func parse(_ output: String, format: Format = .rsync3) -> [DiffEntry] {
        output.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { parseLine($0, format: format) }
    }

    public static func parseLine<S: StringProtocol>(_ line: S, format: Format = .rsync3) -> DiffEntry? {
        let characters = Array(line)
        let width = format.codeWidth
        // "*deleting   ad" (rsync 3.x, 11 sütuna doldurulur) ya da "*deleting ad" (openrsync).
        if line.hasPrefix("*deleting") {
            guard characters.count > width + 1 else { return nil }
            let rawName = String(characters[(width + 1)...])
            return entry(kind: .extra, rawName: rawName, code: "*deleting", typeCharacter: nil)
        }
        guard characters.count > width + 1, characters[width] == " " else { return nil }
        let code = String(characters[0..<width])
        let update = characters[0]
        let type = characters[1]
        guard "<>ch.".contains(update), "fdLDS".contains(type) else { return nil }
        // Öznitelik sütunları: c (sağlama), s (boyut), t (zaman), p, o, g, ardından u, a, x (rsync 3.x) ya da z (openrsync).
        let attributes = Array(characters[2..<width])
        let rawName = String(characters[(width + 1)...])
        let kind: DiffEntry.Kind
        if attributes.allSatisfy({ $0 == "+" }) {
            kind = .missing
        } else if type == "d" {
            // Klasörün içeriği satır satır listelenir; klasörün kendi farkı yalnızca özniteliktir (çoğunlukla zaman).
            guard attributes.contains(where: { $0 != "." && $0 != " " }) else { return nil }
            kind = .attributes
        } else if update == ">" || update == "<" || update == "c" || attributes[0] == "c" || attributes[1] == "s" {
            // Veri aktarılırdı ya da öğe yeniden oluşturulurdu (bağlantı hedefi değişti): içerik farkı.
            kind = .changed
        } else if attributes.contains(where: { $0 != "." && $0 != " " }) || update == "h" {
            kind = .attributes
        } else {
            // ".f         ad": rsync'in -i ile yazdığı ama farkı olmayan satır (ör. -vv); listeye girmez.
            return nil
        }
        return entry(kind: kind, rawName: rawName, code: code, typeCharacter: type)
    }

    private static func entry(kind: DiffEntry.Kind, rawName: String, code: String, typeCharacter: Character?) -> DiffEntry? {
        var name = rawName
        // Bağlantılar "ad -> hedef", sabit bağlantılar "ad => hedef" olarak yazılır.
        if typeCharacter == "L", let range = name.range(of: " -> ") { name = String(name[..<range.lowerBound]) }
        if code.first == "h", let range = name.range(of: " => ") { name = String(name[..<range.lowerBound]) }
        let isDirectory = typeCharacter == "d" || name.hasSuffix("/")
        while name.count > 1 && name.hasSuffix("/") { name.removeLast() }
        let decoded = unescape(name)
        guard !decoded.isEmpty, decoded != "." else { return nil }
        return DiffEntry(kind: kind, path: decoded, isDirectory: isDirectory, code: code)
    }

    /// rsync'in `\#ooo` kaçışlarını (sekizlik bayt) çözer; geçersiz kaçışlar olduğu gibi kalır.
    public static func unescape(_ text: String) -> String {
        guard text.contains("\\#") else { return text }
        var bytes: [UInt8] = []
        let utf8 = Array(text.utf8)
        var index = 0
        while index < utf8.count {
            // "\#012": ters bölü, "#", üç sekizlik basamak (index…index+4).
            if utf8[index] == UInt8(ascii: "\\"), index + 4 < utf8.count, utf8[index + 1] == UInt8(ascii: "#") {
                let digits = utf8[(index + 2)...(index + 4)]
                if digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "7") }) {
                    let value = digits.reduce(0) { $0 * 8 + Int($1 - UInt8(ascii: "0")) }
                    if value <= 255 {
                        bytes.append(UInt8(value))
                        index += 5
                        continue
                    }
                }
            }
            bytes.append(utf8[index])
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
