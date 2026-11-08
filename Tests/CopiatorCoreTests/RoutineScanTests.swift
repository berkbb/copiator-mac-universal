// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// Birden çok kural kümesi tek geçişte taranır ve her küme tek başına taranmış gibi aynı sonucu verir.
@Test func oneWalkMatchesSeparateScans() async throws {
    let w = try Workspace("CopiatorRoutineScan")
    try w.write("Gelen/besa.txt", "BESA PAY ENERJİ\nISITMA TÜKETİM BİLGİLERİ")
    try w.write("Gelen/aski.txt", "ASKİ Su Bedeli")
    try w.write("Gelen/alt/not.md", "not")
    func content(_ text: String) -> RuleGroup { RuleGroup(conditions: [RuleCondition(attribute: .content, op: .contains, value: text)]) }
    let sets = [
        RuleScanner.RuleSet(rules: content("BESA PAY ENERJİ")), RuleScanner.RuleSet(rules: content("ASKİ")),
        RuleScanner.RuleSet(rules: content("ENERJİSA")),
        RuleScanner.RuleSet(rules: RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "md")])),
    ]
    let together = try await RuleScanner.scan(w.url("Gelen"), sets: sets)
    var separate: [RuleScanner.Result] = []
    for set in sets { separate.append(try await RuleScanner.scan(w.url("Gelen"), rules: set.rules)) }
    #expect(together == separate)
    #expect(together.map(\.paths) == [["besa.txt"], ["aski.txt"], [], ["alt/not.md"]])
    #expect(try await RuleScanner.scan(w.url("Gelen"), sets: []).isEmpty)
}

/// Ön tarama: kuralı olup hiçbir öğe bulamayan aday işsizdir; kuralsız ya da koşulsuz aday, takılı olmayan diskteki aday
/// ve seçili öğeleri kurala uyan aday işlidir. Seçili öğeler dışındaki dosyalar sayılmaz.
@Test func candidatesWithoutMatchesHaveNoWork() async throws {
    let w = try Workspace("CopiatorRoutineScan")
    try w.write("Gelen/besa.txt", "BESA PAY ENERJİ")
    try w.write("Gelen/foto.heic", "x")
    try w.mkdir("Hedef")
    let away = URL(fileURLWithPath: "/Volumes/CopiatorYok-\(UUID().uuidString)/Gelen")
    func candidate(_ rules: RuleGroup?, source: URL? = nil, selected: [String]? = nil) -> RoutineScan.Candidate {
        var options = CopyOptions()
        options.rules = rules
        options.selectedItems = selected
        return RoutineScan.Candidate(source: source ?? w.url("Gelen"), destination: w.url("Hedef"), options: options)
    }
    let besa = RuleGroup(conditions: [RuleCondition(attribute: .content, op: .contains, value: "BESA PAY ENERJİ")])
    let enerjisa = RuleGroup(conditions: [RuleCondition(attribute: .content, op: .contains, value: "ENERJİSA")])
    let candidates = [
        candidate(besa), candidate(enerjisa), candidate(nil), candidate(RuleGroup()), candidate(besa, source: away),
        candidate(besa, selected: ["foto.heic"]), candidate(enerjisa, selected: ["besa.txt"]), candidate(besa, selected: ["besa.txt"]),
    ]
    #expect(candidates.map(RoutineScan.canScan) == [true, true, false, false, false, true, true, true])
    #expect(try await RoutineScan.candidatesWithWork(candidates, sandboxHome: nil) == [0, 2, 3, 4, 7])
}
