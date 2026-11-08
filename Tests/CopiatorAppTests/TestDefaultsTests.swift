// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

/// Test ayar alanları yalnızca `TestDefaults` ile açılır; böylece `~/Library/Preferences` içinde dosya kalmaz.
struct TestDefaultsTests {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func suiteLivesInATemporaryFolderAndRemoveDeletesIt() throws {
        let store = try TestDefaults("CopiatorDefaultsProbe")
        #expect(store.suite.hasPrefix("/"))
        #expect(store.suite.hasPrefix(FileManager.default.temporaryDirectory.path) || store.suite.hasPrefix("/private"))
        #expect(store.name.hasPrefix("CopiatorDefaultsProbe-"))
        store.defaults.set("x", forKey: "probe")
        #expect(try TestDefaults(reopening: store.suite).defaults.string(forKey: "probe") == "x")
        store.remove()
        #expect(!FileManager.default.fileExists(atPath: store.folder.path))
        #expect(!FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/Library/Preferences/\(store.name).plist"))
    }

    @Test func plainSuiteNamesAreRefused() {
        #expect(throws: (any Error).self) { try TestDefaults(reopening: "CopiatorPlainName-\(UUID().uuidString)") }
    }

    /// Düz adlı bir ayar alanı açan ya da standart alana yazan test kalmasın; alanlar yalnızca `TestDefaults` ile açılır.
    @Test func everyTestOpensItsSettingsThroughTestDefaults() throws {
        let forbidden = try NSRegularExpression(pattern: #"(UserDefaults|NSUserDefaults)\s*(\.init)?\s*\(\s*suiteName|CFPreferencesSet(App)?Value|UserDefaults\.standard\.(set|removeObject|setValue)"#)
        let tests = packageRoot.appendingPathComponent("Tests", isDirectory: true)
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 20, "the scan reaches the test sources")
        var offenders: [String] = []
        for file in files where file.lastPathComponent != "TestDefaults.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard ["suiteName", "CFPreferencesSet", "UserDefaults.standard"].contains(where: { text.contains($0) }) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if forbidden.firstMatch(in: line, range: range) != nil {
                    offenders.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders.isEmpty, "open test settings with TestDefaults:\n\(offenders.joined(separator: "\n"))")
    }
}
