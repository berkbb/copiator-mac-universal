// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

private let resources = packageRoot.appendingPathComponent("Resources")

private func table(_ code: String, _ name: String = "Localizable") throws -> [String: String] {
    try #require(StringTable.load(contentsOf: resources.appendingPathComponent("\(code).lproj/\(name).strings")))
}

/// "%@", "%ld", "%1$@" gibi biçim belirteçleri.
private func specifiers(_ text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: "%(\\d+\\$)?(@|ld|d)")
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) }.sorted()
}

@Test(arguments: AppLanguage.supportedCodes)
func everyKeyIsTranslated(code: String) throws {
    let strings = try table(code)
    let expected = Set(LKey.allCases.map(\.rawValue))
    let actual = Set(strings.keys)
    #expect(expected.subtracting(actual).sorted() == [], "\(code) dilinde eksik anahtarlar")
    #expect(actual.subtracting(expected).sorted() == [], "\(code) dilinde fazla anahtarlar")
    #expect(strings.values.allSatisfy { !$0.isEmpty })
}

@Test(arguments: ["tr", "ro"])
func formatSpecifiersMatchEnglish(code: String) throws {
    let english = try table("en")
    let other = try table(code)
    for key in LKey.allCases {
        #expect(specifiers(english[key.rawValue] ?? "") == specifiers(other[key.rawValue] ?? ""), "\(code): \(key.rawValue)")
    }
}

/// Çeviri yerine İngilizce bırakılmış metin yakalanır (ürün adları ve yalnızca biçim içeren metinler hariç).
@Test(arguments: ["tr", "ro"])
func translationsAreNotEnglishFallbacks(code: String) throws {
    let english = try table("en")
    let other = try table(code)
    // Dilde gerçekten aynı yazılan sözcükler: "OK", "General" (tr/ro), "Active" (ro, "etkin" çoğulu), "Disk" (tr).
    let sameEverywhere: Set<String> = ["appName", "buttonOK", "progressSpeed", "notifyFailedBody", "settingsGeneral", "filterActive", "settingsRsync",
                                       "consoleCategoryDisk",
                                       "fileKindPDF", "fileKindAudio", "fileKindText", "fileKindDocument",
                                       "unitKB", "unitMB", "unitGB", "unitTB"]
    let identical = LKey.allCases.map(\.rawValue).filter { key in
        guard let value = other[key], value == english[key], !sameEverywhere.contains(key) else { return false }
        return value.contains(where: \.isLetter)
    }
    #expect(identical == [], "\(code) tablosunda çevrilmemiş görünen metinler")
}

@Test func eachSupportedLanguageHasDedicatedFiles() throws {
    for code in AppLanguage.supportedCodes {
        for name in ["Localizable", "InfoPlist", "ServicesMenu", "AppShortcuts"] {
            let url = resources.appendingPathComponent("\(code).lproj/\(name).strings")
            #expect(FileManager.default.fileExists(atPath: url.path), "\(code).lproj/\(name).strings")
            #expect(!(try Data(contentsOf: url)).isEmpty)
        }
    }
}

@Test func resolvesSystemLanguage() {
    #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["ro-RO", "en-US"]) == "ro")
    #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["de-DE", "tr-TR"]) == "tr")
    #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["de-DE"]) == "en")
    #expect(AppLanguage.tr.resolvedCode(preferredLanguages: ["en-US"]) == "tr")
}

@Test func stringTableFallsBackToEnglish() {
    let strings = StringTable(tables: ["en": ["appName": "Copiator", "yes": "Yes"], "tr": ["yes": "Evet"]])
    #expect(strings.string(.yes, language: "tr") == "Evet")
    #expect(strings.string(.appName, language: "tr") == "Copiator")
    #expect(strings.string(.no, language: "tr") == "no")
}

/// Info.plist'te Finder'a görünen adlar ve servis menüsü başlığı her dilde birebir bulunur.
@Test func infoPlistAndServicesAreLocalized() throws {
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Support/Info.plist"))
    let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(Set(plist["CFBundleLocalizations"] as? [String] ?? []) == Set(AppLanguage.supportedCodes))
    let services = (plist["NSServices"] as? [[String: Any]] ?? []).compactMap { ($0["NSMenuItem"] as? [String: String])?["default"] }
    #expect(!services.isEmpty)
    var infoKeys: [Set<String>] = []
    for code in AppLanguage.supportedCodes {
        let info = try table(code, "InfoPlist")
        #expect(info["CFBundleDisplayName"] != nil && info["CFBundleName"] != nil && info["NSHumanReadableCopyright"] != nil)
        infoKeys.append(Set(info.keys))
        let menu = try table(code, "ServicesMenu")
        #expect(Set(menu.keys) == Set(services), "\(code) ServicesMenu.strings")
    }
    #expect(Set(infoKeys).count == 1)
}

/// macOS'un izin sorularındaki açıklamalar (Masaüstü, Belgeler, İndirilenler, harici ve ağ diskleri, bulut klasörleri)
/// Info.plist'te var ve her dilde çevrilmiş.
@Test func permissionPromptsAreExplainedInEveryLanguage() throws {
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Support/Info.plist"))
    let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let usage = Set(plist.keys.filter { $0.hasSuffix("UsageDescription") })
    #expect(usage == [
        "NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription", "NSDownloadsFolderUsageDescription",
        "NSRemovableVolumesUsageDescription", "NSNetworkVolumesUsageDescription", "NSFileProviderDomainUsageDescription",
    ])
    var texts: [String: Set<String>] = [:]
    for code in AppLanguage.supportedCodes {
        let info = try table(code, "InfoPlist")
        for key in usage {
            let text = try #require(info[key], "\(code) \(key)")
            #expect(text.contains("Copiator") && !text.isEmpty)
            texts[key, default: []].insert(text)
        }
    }
    // Her dil kendi metnini taşır (İngilizce kopya kalmamış).
    for key in usage { #expect(texts[key]?.count == AppLanguage.supportedCodes.count, "\(key)") }
}

/// Her sonuç sınıfı her dilde, biçim belirteci kalmadan ve sayılarla gösterilir.
@Test(arguments: AppLanguage.supportedCodes)
func resultMessagesAreLocalizedAndFormatted(code: String) throws {
    let strings = StringTable(tables: Dictionary([(code, try table(code)), ("en", try table("en"))]) { first, _ in first })
    for kind in JobResultKind.allCases {
        let message = strings.resultMessage(JobResult(kind: kind, exitCode: 42, noteCount: 7), language: code) { "\($0) B" }
        #expect(!message.isEmpty)
        #expect(!message.contains("%"), "\(code) \(kind)")
    }
    let full = strings.resultMessage(JobResult(kind: .destinationFull, requiredBytes: 100, availableBytes: 5), language: code) { "\($0) B" }
    #expect(full.contains("100 B") && full.contains("5 B"))
    let filling = strings.resultMessage(JobResult(kind: .destinationFull, availableBytes: 9), language: code) { "\($0) B" }
    #expect(filling.contains("9 B"))
    #expect(strings.resultMessage(JobResult(kind: .failed, exitCode: 12), language: code) { "\($0)" }.contains("12"))
    let entry = JobLogEntry(level: .info, key: .logHarmlessNotes, arguments: ["3", "exfat"])
    let text = strings.logText(entry, language: code)
    #expect(text.contains("3") && text.contains("exfat") && !text.contains("%"))
    #expect(strings.logText(JobLogEntry(level: .error, raw: "rsync: ham"), language: code) == "rsync: ham")
}

/// Siri ve Kestirmeler ifadeleri: koddaki her ifade her dilin AppShortcuts.strings tablosunda bulunur; çeviriler uygulama
/// adını ve iş parametresini korur (Siri ifadeyi bunlarla eşleştirir).
@Test func appShortcutPhrasesAreLocalized() throws {
    let source = try String(contentsOf: packageRoot.appendingPathComponent("Sources/Copiator/Intents.swift"), encoding: .utf8)
    let regex = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*\\\(\.applicationName\)(?:[^"\\]|\\.)*)""#)
    let phrases = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { match in
        String(source[Range(match.range(at: 1), in: source)!])
            .replacingOccurrences(of: #"\(\.$job)"#, with: "${job}")
            .replacingOccurrences(of: #"\(\.$routine)"#, with: "${routine}")
            .replacingOccurrences(of: #"\(.applicationName)"#, with: "${applicationName}")
    }
    #expect(phrases.count >= 4)
    for code in AppLanguage.supportedCodes {
        let table = try table(code, "AppShortcuts")
        #expect(Set(table.keys) == Set(phrases), "\(code) AppShortcuts.strings")
        for (key, value) in table {
            #expect(value.contains("${applicationName}"), "\(code): \(key)")
            #expect(key.contains("${job}") == value.contains("${job}"), "\(code): \(key)")
            #expect(key.contains("${routine}") == value.contains("${routine}"), "\(code): \(key)")
        }
    }
}
