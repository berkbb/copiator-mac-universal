// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

/// Arayüz metinleri yalnızca dil tablolarından gelmelidir (tr/en/ro birebir). Bu bekçi, SwiftUI görünümlerinde
/// doğrudan yazılmış metni ("Yedekle", "Copy") arar. Simgeler, ayırıcılar ("•", "—") ve yalnızca kod eklemeleri serbesttir.
@Suite struct HardcodedTextGuardTests {
    static let sourceFolders = ["Sources/Copiator"]
    /// Her dilde aynı yazılan özel adlar (program ve ürün adları); çevrilmezler.
    static let untranslatableNames: Set<String> = ["rsync", "Copiator"]

    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:\b(?:Text|Label|Button|Toggle|Section|Picker|Menu|TextField|SecureField|ContentUnavailableView|LabeledContent|TableColumn)|\.(?:help|navigationTitle|navigationSubtitle|alert|confirmationDialog|accessibilityLabel))\(\s*"((?:[^"\\]|\\.)*)""#
    )

    /// Dizedeki "\(…)" eklemelerini (iç içe ayraçlarla) atar; geriye kalan görünür metindir.
    static func visibleText(of literal: String) -> String {
        var result = ""
        var characters = Array(literal)[...]
        while let character = characters.popFirst() {
            if character == "\\", characters.first == "(" {
                characters.removeFirst()
                var depth = 1
                while depth > 0, let next = characters.popFirst() {
                    if next == "(" { depth += 1 } else if next == ")" { depth -= 1 }
                }
            } else {
                result.append(character)
            }
        }
        return result
    }

    static func violations(in source: String) -> [String] {
        var found: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let literalRange = Range(match.range(at: 1), in: text) else { continue }
                let visible = visibleText(of: String(text[literalRange]))
                if visible.contains(where: \.isLetter), !untranslatableNames.contains(visible) {
                    found.append(text.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return found
    }

    private static func swiftFiles() -> [URL] {
        sourceFolders.flatMap { folder in
            FileManager.default.enumerator(at: packageRoot.appendingPathComponent(folder), includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        }
    }

    @Test func viewsHaveNoHardcodedText() throws {
        let files = Self.swiftFiles()
        #expect(!files.isEmpty)
        var report: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            report += Self.violations(in: source).map { "\(file.lastPathComponent): \($0)" }
        }
        #expect(report.isEmpty, "Dil tablosu yerine gömülü metin:\n\(report.joined(separator: "\n"))")
    }

    /// Yalnızca simgeden oluşan düğmeler ("label: { Image(…) }"): VoiceOver'ın okuyacağı bir ad olmalı.
    static func unlabeledIconButtons(in source: String) -> [String] {
        let lines = source.components(separatedBy: "\n")
        var found: [String] = []
        for (index, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces).hasSuffix("} label: {") {
            var depth = 1
            var body: [String] = []
            var end = index + 1
            while end < lines.count, depth > 0 {
                for character in lines[end] {
                    if character == "{" { depth += 1 } else if character == "}" { depth -= 1 }
                }
                if depth > 0 { body.append(lines[end]) }
                end += 1
            }
            let content = body.joined(separator: "\n")
            guard content.contains("Image("), !content.contains("Text("), !content.contains("Label(") else { continue }
            var modifiers: [String] = []
            var next = end
            while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).hasPrefix(".") {
                modifiers.append(lines[next])
                next += 1
            }
            if !modifiers.contains(where: { $0.contains(".accessibilityLabel(") }) {
                found.append("\(index + 1): \(body.first?.trimmingCharacters(in: .whitespaces) ?? "")")
            }
        }
        return found
    }

    @Test func iconOnlyButtonsHaveAccessibilityLabels() throws {
        var report: [String] = []
        for file in Self.swiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            report += Self.unlabeledIconButtons(in: source).map { "\(file.lastPathComponent):\($0)" }
        }
        #expect(report.isEmpty, "Erişilebilirlik adı olmayan simge düğmeleri:\n\(report.joined(separator: "\n"))")
    }

    /// Her Swift kaynağı GPL lisans tanımlayıcısıyla başlar.
    @Test func everySwiftFileHasSPDXHeader() throws {
        var missing: [String] = []
        for folder in ["Sources", "Tests", "Scripts"] {
            let files = FileManager.default.enumerator(at: packageRoot.appendingPathComponent(folder), includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files where !(try String(contentsOf: file, encoding: .utf8)).hasPrefix("// SPDX-License-Identifier: GPL-3.0-only\n") {
                missing.append(file.path.replacingOccurrences(of: packageRoot.path + "/", with: ""))
            }
        }
        let manifest = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(manifest.contains("// SPDX-License-Identifier: GPL-3.0-only"))
        #expect(missing.isEmpty, "SPDX satırı eksik:\n\(missing.joined(separator: "\n"))")
    }

    @Test func guardCatchesLiteralsAndIgnoresAllowedPatterns() {
        #expect(Self.violations(in: #"Text("Yedekleniyor")"#).count == 1)
        #expect(Self.violations(in: #"Label("Kopyala", systemImage: "doc")"#).count == 1)
        #expect(Self.violations(in: #".help("Pause job")"#).count == 1)
        #expect(Self.violations(in: #"Text("\(count) dosya")"#).count == 1)
        #expect(Self.violations(in: #"Text(settings.t(.appName))"#).isEmpty)
        #expect(Self.violations(in: #"Text("•")"#).isEmpty)
        #expect(Self.violations(in: #"Text("\(language.flag)  \(language.nativeName ?? settings.t(.languageSystem))")"#).isEmpty)
        #expect(Self.violations(in: #"// Text("Eski metin")"#).isEmpty)
        #expect(Self.violations(in: #"LabeledContent("rsync") {"#).isEmpty)
        #expect(Self.violations(in: #"Text("rsync bulunamadı")"#).count == 1)
        #expect(Self.unlabeledIconButtons(in: "Button {\n    go()\n} label: {\n    Image(systemName: \"x\")\n}\n.buttonStyle(.plain)").count == 1)
    }
}
