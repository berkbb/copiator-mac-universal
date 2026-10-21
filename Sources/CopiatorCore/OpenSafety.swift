// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UniformTypeIdentifiers

/// Kopyalanan dosyaların ve yolların güvenle gösterilmesi: riskli türler ve adın gerçek uzantısını gizleyen karakterler.
/// Günlükte ve doğrulama farklarında adlar `visibleName` ile gösterilir.
public enum OpenSafety {
    /// Açıldığında kod çalıştırabilen ya da sistem ayarı değiştirebilen türler.
    static let riskyTypes: [UTType] = [
        .executable, .script, .application, .applicationBundle, .unixExecutable, .internetLocation,
        .diskImage,
    ] + [
        "com.apple.installer-package-archive",
        "com.apple.mobileconfig",
        "com.apple.terminal.settings",
        "com.apple.terminal.session",
        "com.apple.automator-workflow",
        "com.apple.applescript.script",
        "com.apple.applescript.text",
        "com.apple.applescript.script-bundle",
        "com.apple.shortcut",
        "com.apple.systempreference.prefpane",
        "com.apple.quicklook.generator",
    ].compactMap { UTType($0) }

    /// Sistemin tür tanımı olmayabilen (dinamik UTI) riskli uzantılar: AppleScript, Kestirmeler, sistem eklentileri,
    /// Automator iş akışları ve eylemleri, betik ekleri (.osax) ve internet konumları (.url, .webloc). macOS 26'da
    /// ör. "workflow" uzantısı com.apple.automator-workflow'a değil dinamik bir türe çözülür.
    static let riskyExtensions: Set<String> = [
        "scpt", "scptd", "applescript", "shortcut", "prefpane", "qlgenerator",
        "workflow", "action", "osax", "url", "webloc", "term", "terminal",
    ]

    /// Dosya çalıştırılabilir ya da riskli bir türdeyse türün okunur adını (yoksa tanımlayıcısını) döndürür.
    public static func executableKind(of url: URL) -> String? {
        let resolved = url.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey])
        if let type = values?.contentType, riskyTypes.contains(where: { type.conforms(to: $0) }) {
            return type.localizedDescription ?? type.identifier
        }
        if riskyExtensions.contains(resolved.pathExtension.lowercased()) {
            return values?.contentType?.localizedDescription ?? resolved.pathExtension
        }
        // Uzantısız Mach-O ya da betikler: çalıştırma (x) biti olan sıradan dosyalar.
        if values?.isRegularFile == true,
           let permissions = (try? FileManager.default.attributesOfItem(atPath: resolved.path))?[.posixPermissions] as? NSNumber,
           permissions.uint16Value & 0o111 != 0 {
            return values?.contentType?.localizedDescription ?? "Unix executable"
        }
        return nil
    }

    /// Görünmez ya da yön değiştiren karakterler (ör. U+202E) bir adın gerçek uzantısını gizleyebilir:
    /// "fatura\u{202E}fdp.command", Finder'da "faturadnammoc.pdf" gibi görünür.
    public static func hasDeceptiveCharacters(_ name: String) -> Bool {
        var previous: Unicode.Scalar?
        for scalar in name.unicodeScalars {
            if isDeceptive(scalar, after: previous) { return true }
            previous = scalar
        }
        return false
    }

    /// Gizli karakterleri görünür yer tutucularla değiştirir: "fatura⟦U+202E⟧fdp.command".
    public static func visibleName(_ name: String) -> String {
        var result = ""
        var previous: Unicode.Scalar?
        for scalar in name.unicodeScalars {
            if isDeceptive(scalar, after: previous) {
                result += String(format: "⟦U+%04X⟧", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
            previous = scalar
        }
        return result
    }

    /// Görünmeyen ama "harf" ya da "sembol" sayılan doldurma karakterleri: Braille boşluğu, Hangul dolgu harfleri.
    /// Bir adın sonundaki gerçek uzantıyı boşlukla itip gizleyebilirler ("fatura.pdf⠀⠀⠀⠀.app").
    static let blankFillers: Set<UInt32> = [0x2800, 0x3164, 0x115F, 0x1160, 0xFFA0]

    /// Emoji biçimini seçen değişke seçiciler (U+FE0E, U+FE0F) bir emojiden sonra görünür karakterin parçasıdır.
    static let emojiVariationSelectors: Set<UInt32> = [0xFE0E, 0xFE0F]

    /// - Parameter previous: Adda bu karakterden önceki karakter (emoji değişke seçicileri için).
    static func isDeceptive(_ scalar: Unicode.Scalar, after previous: Unicode.Scalar? = nil) -> Bool {
        if blankFillers.contains(scalar.value) { return true }
        switch scalar.properties.generalCategory {
        case .format, .control, .lineSeparator, .paragraphSeparator:
            return true
        default:
            break
        }
        // Varsayılan olarak yok sayılan (görünmez) karakterler: birleştirme işareti sayılan U+034F, U+17B4/U+17B5
        // gibi karakterler "format" kategorisinde değildir ama hiç çizilmez.
        guard scalar.properties.isDefaultIgnorableCodePoint else { return false }
        if emojiVariationSelectors.contains(scalar.value), previous?.properties.isEmoji == true { return false }
        return true
    }
}
