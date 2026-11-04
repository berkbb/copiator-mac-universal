// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CopiatorCore

/// Testlerde sabit "şimdi" ve takvim: göreli tarihler makinenin saatinden bağımsızdır.
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func rule(_ attribute: RuleAttribute, _ op: RuleOperator, value: String = "", number: Double = 0, unit: RuleUnit? = nil,
                  date: Date? = nil) -> RuleGroup {
    RuleGroup(conditions: [RuleCondition(attribute: attribute, op: op, value: value, number: number, unit: unit, date: date)])
}

private func matches(_ rules: RuleGroup, _ path: String = "a/b.dat", metadata: RuleItem.Metadata = .init(),
                     content: [UUID: Set<String>] = [:]) throws -> Bool {
    let item = RuleItem(relativePath: path, metadata: metadata)
    return try RuleEvaluator(rules, now: now, calendar: calendar, contentMatches: content).matches(item)
}

@Test func sizeAndDepthCompareWithUnits() throws {
    let big = RuleItem.Metadata(size: 150_000_000)
    #expect(try matches(rule(.size, .greaterThan, number: 100, unit: .megabytes), metadata: big))
    #expect(try !matches(rule(.size, .lessThan, number: 100, unit: .megabytes), metadata: big))
    #expect(try matches(rule(.size, .lessThan, number: 1, unit: .gigabytes), metadata: big))
    #expect(try matches(rule(.size, .greaterThan, number: 149_999, unit: .kilobytes), metadata: big))
    // Boyutu bilinmeyen öğe hiçbir boyut koşuluna uymaz.
    #expect(try !matches(rule(.size, .greaterThan, number: 0, unit: .megabytes)))
    #expect(try matches(rule(.depth, .atMost, number: 0), "kok.txt"))
    #expect(try !matches(rule(.depth, .atMost, number: 0), "a/b.txt"))
    #expect(try matches(rule(.depth, .atLeast, number: 2), "a/b/c.txt"))
    #expect(try matches(rule(.depth, .equals, number: 1), "a/c.txt"))
}

@Test func datesUseRelativeAndAbsoluteRanges() throws {
    let day: TimeInterval = 86_400
    let recent = RuleItem.Metadata(modified: now.addingTimeInterval(-3 * day), created: now.addingTimeInterval(-400 * day),
                                   added: now.addingTimeInterval(-10 * day))
    #expect(try matches(rule(.modified, .withinLast, number: 7, unit: .days), metadata: recent))
    #expect(try !matches(rule(.modified, .notWithinLast, number: 7, unit: .days), metadata: recent))
    #expect(try !matches(rule(.added, .withinLast, number: 1, unit: .weeks), metadata: recent))
    #expect(try matches(rule(.added, .withinLast, number: 1, unit: .months), metadata: recent))
    #expect(try matches(rule(.created, .notWithinLast, number: 1, unit: .years), metadata: recent))
    let cutoff = now.addingTimeInterval(-5 * day)
    #expect(try matches(rule(.modified, .after, date: cutoff), metadata: recent))
    #expect(try !matches(rule(.modified, .before, date: cutoff), metadata: recent))
    // "Sonra" seçilen günün sonundan sonrasıdır; aynı gün "sonra" sayılmaz.
    #expect(try !matches(rule(.modified, .after, date: now.addingTimeInterval(-3 * day)), metadata: recent))
    #expect(try !matches(rule(.modified, .withinLast, number: 7, unit: .days)))
}

@Test func tagsHiddenAndExtensionLists() throws {
    let tagged = RuleItem.Metadata(tags: ["Kırmızı", "Proje X"])
    #expect(try matches(rule(.tag, .equals, value: "KIRMIZI"), metadata: tagged))
    #expect(try matches(rule(.tag, .contains, value: "proje"), metadata: tagged))
    #expect(try !matches(rule(.tag, .equals, value: "Mavi"), metadata: tagged))
    #expect(try matches(rule(.tag, .isTrue), metadata: tagged) && !matches(rule(.tag, .isFalse), metadata: tagged))
    #expect(try matches(rule(.tag, .isFalse), metadata: .init(tags: [])))

    #expect(try matches(rule(.hidden, .isTrue), ".gizli"))
    #expect(try matches(rule(.hidden, .isTrue), ".git/config"))
    #expect(try matches(rule(.hidden, .isTrue), "Masaüstü/Simge", metadata: .init(hiddenFlag: true)))
    #expect(try matches(rule(.hidden, .isFalse), "belge.txt", metadata: .init(hiddenFlag: false)))

    let list = rule(.fileExtension, .isOneOf, value: "jpg, .HEIC; png")
    #expect(try matches(list, "a.heic") && matches(list, "b.JPG") && matches(list, "c.png") && !matches(list, "d.jpeg"))
    #expect(rule(.fileExtension, .isOneOf, value: " , ; ").problems() == [.emptyValue])
}

@Test func mediaAndContentCriteria() throws {
    let photo = RuleItem.Metadata(media: MediaInfo(captureDate: now.addingTimeInterval(-86_400), pixelWidth: 4032, pixelHeight: 3024,
                                                   cameraModel: "iPhone 17 Pro"))
    #expect(try matches(rule(.resolution, .greaterThan, number: 1920), "a.heic", metadata: photo))
    #expect(try !matches(rule(.resolution, .lessThan, number: 1920), "a.heic", metadata: photo))
    #expect(try matches(rule(.captureDate, .withinLast, number: 2, unit: .days), "a.heic", metadata: photo))
    #expect(try matches(rule(.cameraModel, .beginsWith, value: "iphone"), "a.heic", metadata: photo))
    #expect(try matches(rule(.cameraModel, .matchesRegex, value: #"iPhone \d+"#), "a.heic", metadata: photo))
    let video = RuleItem.Metadata(media: MediaInfo(duration: 95))
    #expect(try matches(rule(.duration, .greaterThan, number: 1, unit: .minutes), "v.mov", metadata: video))
    #expect(try !matches(rule(.duration, .greaterThan, number: 2, unit: .minutes), "v.mov", metadata: video))
    #expect(try !matches(rule(.cameraModel, .contains, value: "x"), "v.mov", metadata: video))

    let content = rule(.content, .contains, value: "fatura")
    let id = content.conditions[0].id
    #expect(try matches(content, "2026/Ocak/belge.pdf", content: [id: ["2026/Ocak/belge.pdf"]]))
    #expect(try !matches(content, "2026/Ocak/öteki.pdf", content: [id: ["2026/Ocak/belge.pdf"]]))
    #expect(Spotlight.query(for: #"a "b" \ *"#) == #"kMDItemTextContent == "*a \"b\" \\ \**"cd"#)
    // Türkçe bir Mac'te Spotlight "I"yı "ı" katlar: her i benzeri harf iki biçimde de aranır.
    #expect(Spotlight.query(for: "Isparta") == #"(kMDItemTextContent == "*isparta*"cd || kMDItemTextContent == "*ısparta*"cd)"#)
    #expect(Spotlight.query(for: "İİİİİİ").components(separatedBy: " || ").count == 64)
    let long = Spotlight.query(for: "Mississippi İzmir'i")
    #expect(!long.contains("||") && long.components(separatedBy: " && ").count == 7)
}

@Test func advancedConditionsValidateAndDecode() throws {
    #expect(rule(.size, .greaterThan, number: -1, unit: .megabytes).problems() == [.invalidNumber])
    #expect(rule(.modified, .before).problems() == [.missingDate])
    #expect(rule(.hidden, .isTrue).problems().isEmpty)
    #expect(rule(.content, .contains).problems() == [.emptyValue])
    // Uyumsuz birim ve karşılaştırma özelliğin varsayılanına döner.
    let fixed = RuleCondition(attribute: .size, op: .withinLast, number: 5, unit: .days)
    #expect(fixed.op == .greaterThan && fixed.unit == .megabytes)
    let json = #"{"attribute": "duration", "op": "lessThan", "number": 30, "unit": "seconds"}"#
    let decoded = try JSONDecoder().decode(RuleCondition.self, from: Data(json.utf8))
    #expect(decoded.attribute == .duration && decoded.op == .lessThan && decoded.number == 30 && decoded.unit == .seconds)
    let old = try JSONDecoder().decode(RuleCondition.self, from: Data(#"{"attribute": "name", "op": "contains", "value": "a"}"#.utf8))
    #expect(old.number == 0 && old.unit == nil && old.date == nil)
    for attribute in RuleAttribute.allCases {
        let start = RuleCondition.starting(attribute)
        #expect(attribute.operators.contains(start.op))
        if start.op.input(for: attribute) != .text { #expect(RuleGroup(conditions: [start]).problems().isEmpty, "\(attribute)") }
    }
    #expect(RuleAttribute.advanced.count + RuleAttribute.basic.count == RuleAttribute.allCases.count)
}

/// Gerçek dosyalarda: boyut, değiştirilme tarihi, Finder etiketi, gizli işareti ve resim bilgisi diskten okunur.
@Test func scannerReadsMetadataFromDisk() async throws {
    let workspace = try Workspace()
    try workspace.write("K/kucuk.txt", "x")
    try Data(repeating: 1, count: 300_000).write(to: try workspace.write("K/buyuk.bin", ""))
    try workspace.write("K/eski.txt", "eski")
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -40 * 86_400)], ofItemAtPath: workspace.url("K/eski.txt").path)
    var tagged = try workspace.write("K/etiketli.txt", "e")
    var values = URLResourceValues()
    values.tagNames = ["Kırmızı"]
    try tagged.setResourceValues(values)
    try workspace.write("K/Simge", "gizli")
    chflags(workspace.url("K/Simge").path, UInt32(UF_HIDDEN))
    try writeJPEG(workspace.url("K/foto.jpg"), width: 3000, height: 2000, taken: "2020:05:06 07:08:09", model: "TestCam 1")
    try writeJPEG(workspace.url("K/kucuk.jpg"), width: 640, height: 480, taken: nil, model: nil)

    func scan(_ rules: RuleGroup) async throws -> Set<String> {
        Set(try await RuleScanner.scan(workspace.url("K"), rules: rules).paths)
    }
    #expect(try await scan(rule(.size, .greaterThan, number: 100, unit: .kilobytes)) == ["buyuk.bin"])
    #expect(try await scan(rule(.modified, .notWithinLast, number: 30, unit: .days)) == ["eski.txt"])
    #expect(try await scan(rule(.tag, .equals, value: "kırmızı")) == ["etiketli.txt"])
    #expect(try await scan(rule(.hidden, .isTrue)) == ["Simge"])
    #expect(try await scan(rule(.resolution, .greaterThan, number: 1920)) == ["foto.jpg"])
    #expect(try await scan(rule(.cameraModel, .contains, value: "testcam")) == ["foto.jpg"])
    #expect(try await scan(rule(.captureDate, .before, date: Date(timeIntervalSince1970: 1_600_000_000))) == ["foto.jpg"])
    // Kurallar birleşir: büyük olmayan ve gizli olmayan metinler.
    let combined = RuleGroup(match: .all, conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "txt")],
                             groups: [RuleGroup(match: .none, conditions: [RuleCondition(attribute: .hidden, op: .isTrue),
                                                                           RuleCondition(attribute: .tag, op: .isTrue)])])
    #expect(try await scan(combined) == ["kucuk.txt", "eski.txt"])
}

/// Gelişmiş kurallarla gerçek kopya: son 7 günde değişmiş ve 1 KB'tan büyük dosyalar, yapı korunarak.
@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct AdvancedRuleEngineTests {
    @Test func copiesRecentLargeFiles() async throws {
        let workspace = try Workspace()
        try Data(repeating: 7, count: 5_000).write(to: try workspace.write("A/yeni/buyuk.dat", ""))
        try workspace.write("A/yeni/kucuk.dat", "k")
        try Data(repeating: 7, count: 5_000).write(to: try workspace.write("A/eski/buyuk.dat", ""))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -90 * 86_400)],
                                              ofItemAtPath: workspace.url("A/eski/buyuk.dat").path)
        try workspace.mkdir("B")
        let rules = RuleGroup(conditions: [RuleCondition(attribute: .modified, op: .withinLast, number: 7, unit: .days),
                                           RuleCondition(attribute: .size, op: .greaterThan, number: 1, unit: .kilobytes)])
        let job = TransferJob(source: workspace.url("A"), destination: workspace.url("B"), options: CopyOptions(rules: rules))
        let result = await RsyncEngine().run(job, context: try await engineContext()) { _ in }
        #expect(result.kind == .succeeded, "\(result)")
        #expect(workspace.exists("B/yeni/buyuk.dat"))
        #expect(!workspace.exists("B/yeni/kucuk.dat") && !workspace.exists("B/eski"))
    }
}
