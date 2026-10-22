// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

/// Spotlight dizini açık mı (`mdutil -s /System/Volumes/Data`)?
private let spotlightEnabled: Bool = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
    process.arguments = ["-s", "/System/Volumes/Data"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return output.contains("Indexing enabled")
}()

/// Gerçek Spotlight diziniyle içerik araması: dizinlenen bir klasörde (paketin build/ klasörü; geçici klasörler
/// dizinlenmez) yalnızca içinde aranan sözcük geçen dosya bulunur ve kurala uyar.
@Suite(.enabled(if: spotlightEnabled, "Spotlight dizini kapalı"), .serialized)
struct SpotlightContentTests {
    @Test func contentSearchFindsIndexedText() async throws {
        let root = packageRoot.appendingPathComponent("build/spotlight-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let number = Int.random(in: 1000...9999)
        let word = "copiatorzebra\(number)"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Alt Klasör"), withIntermediateDirectories: true)
        try Data("Bu belgede \(word) sözcüğü geçiyor. ISPARTA\(number) da.\n".utf8).write(to: root.appendingPathComponent("Alt Klasör/belge.txt"))
        try Data("Başka bir şey.\n".utf8).write(to: root.appendingPathComponent("diger.txt"))
        _ = try await CommandRunner(executableURL: URL(fileURLWithPath: "/usr/bin/mdimport")).run([root.path], timeout: 30)

        // Dizinleme birkaç saniye sürebilir.
        var found = Set<String>()
        for _ in 0..<40 {
            found = Spotlight.relativePaths(containing: word, in: root)
            if !found.isEmpty { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(found == ["Alt Klasör/belge.txt"])
        // Büyük/küçük harf duyarsız; başka bir sözcük hiçbir şey bulmaz.
        #expect(Spotlight.relativePaths(containing: word.uppercased(), in: root) == ["Alt Klasör/belge.txt"])
        // Türkçe bir Mac'te Spotlight "I"yı "ı" katlar; I/ı/İ/i farkı yine de gözetilmez.
        for text in ["isparta\(number)", "Isparta\(number)", "İSPARTA\(number)", "ısparta\(number)"] {
            #expect(Spotlight.relativePaths(containing: text, in: root) == ["Alt Klasör/belge.txt"], "\(text)")
        }
        #expect(Spotlight.relativePaths(containing: "\(word)yok", in: root).isEmpty)
        let paths = try await RuleScanner.scan(root, rules: RuleGroup(conditions: [RuleCondition(attribute: .content, op: .contains, value: word)])).paths
        #expect(paths == ["Alt Klasör/belge.txt"])
    }
}
