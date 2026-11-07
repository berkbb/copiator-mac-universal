// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// İçerik ölçütünde düzenli ifade: metne yazıldığı gibi uygulanır (sözcük sınırı gibi "içerir"in yapamadığı eşleşmeler),
/// Spotlight'a sorulmaz; adım sınırını aşan ifade taramayı hatayla bitirir (sessizce "uymaz" sayılmaz).
@Test func contentCriterionMatchesRegularExpressions() async throws {
    let w = try Workspace("CopiatorContentRegex")
    try w.write("Gelen/su.txt", "ASI tahsilat makbuzu")
    try w.write("Gelen/tasima.txt", "TAŞIMA ve ASIL belge")
    try w.write("Gelen/bos.bin", "ASI")
    #expect(RuleAttribute.content.operators == [.contains, .matchesRegex])
    let word = RuleGroup(conditions: [RuleCondition(attribute: .content, op: .matchesRegex, value: #"\bASI\b"#)])
    #expect(try await RuleScanner.scan(w.url("Gelen"), rules: word).paths == ["su.txt"], "okunamayan tür eşleşmez")
    let contains = RuleGroup(conditions: [RuleCondition(attribute: .content, op: .contains, value: "ASI")])
    #expect(Set(try await RuleScanner.scan(w.url("Gelen"), rules: contains).paths).isSuperset(of: ["su.txt", "tasima.txt"]))

    try w.write("Gelen/uzun.txt", String(repeating: "a", count: 40) + "b")
    let runaway = RuleGroup(conditions: [RuleCondition(attribute: .content, op: .matchesRegex, value: #"^(a+)+$"#)])
    await #expect(throws: RuleEvaluator.RunawayRegex.self) { try await RuleScanner.scan(w.url("Gelen"), rules: runaway) }
}
