// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// İçerikten alınan değer ({c:ad}): ilk eşleşmenin boş olmayan ilk grubu, tek satıra inmiş ve güvenli bir ad parçası olarak;
/// adım sınırını aşan ifade değer vermez; grup yoksa ya da ifade geçersizse değer yok.
@Test func contentFieldCapturesTheFirstGroupSafely() {
    let invoice = """
    ENERJİSA Başkent Elektrik
    Abone No:   128820964
    Fatura No: EBK/2026:00042
    Son ödeme 15.11.2026
    """
    #expect(ContentField(name: "abone", pattern: #"Abone No:\s*(\d+)"#).value(in: invoice) == "128820964")
    #expect(ContentField(name: "fatura", pattern: #"Fatura No:\s*(\S+)"#).value(in: invoice) == "EBK-2026-00042", "/ ve : tireye döner")
    #expect(ContentField(name: "x", pattern: #"^Son (\S+)"#).value(in: invoice) == nil, "çok satırlı kip açılmadan ^ yalnızca metnin başıdır")
    #expect(ContentField(name: "x", pattern: #"(?m)^Son (\S+)"#).value(in: invoice) == "ödeme")
    #expect(ContentField(name: "firma", pattern: #"^(\S+)\s+Başkent"#).value(in: invoice) == "ENERJİSA")
    #expect(ContentField(name: "abone", pattern: #"(?i)abone no:\s*(\d+)"#).value(in: invoice) == "128820964")
    #expect(ContentField(name: "x", pattern: #"Abone No:\s*\d+"#).value(in: invoice) == nil, "grup yok")
    #expect(ContentField(name: "x", pattern: #"(Abone"#).value(in: invoice) == nil, "geçersiz ifade")
    #expect(ContentField(name: "x", pattern: #"Yok:\s*(\d+)"#).value(in: invoice) == nil)
    // Boş grup atlanır, sonraki eşleşme kullanılır; satır sonları ve "{…}" temizlenir; uzun değer kısalır.
    #expect(ContentField(name: "x", pattern: #"Kod:(\w*)"#).value(in: "Kod:\nKod:A1") == "A1")
    #expect(ContentField(name: "x", pattern: #"Ad: ([^;]+);"#).value(in: "Ad: Ali\n  {year} Veli;") == "Ali year Veli")
    #expect(ContentField(name: "x", pattern: #"(\d+)"#).value(in: String(repeating: "7", count: 300))?.count == ContentField.maxValueLength)
    #expect(ContentField(name: "x", pattern: #"Ad: (\.\.\/etc)"#).value(in: "Ad: ../etc") == "-etc", "baştaki noktalar ve / atılır")
    // Felaket geri izleme: adım sınırı aşılır, değer yok (uygulama donmaz).
    let start = Date()
    #expect(ContentField(name: "x", pattern: #"^(a+)+$"#).value(in: String(repeating: "a", count: 40) + "b") == nil)
    #expect(Date().timeIntervalSince(start) < 5)
}

/// Şablon ve alan sorunları; içerik belirteci yalnızca ad şablonunda ve tanımlı bir alan için geçerli; eski kayıtlar
/// alansız okunur; örnek hedef yolda değer yerini alır, değer yoksa boşalır.
@Test func contentTokensAreValidatedAndRendered() throws {
    let abone = ContentField(name: "abone", pattern: #"Abone No:\s*(\d+)"#)
    var placement = RoutePlacement(nameTemplate: "{c:abone}_El_{month}_{yy}", contentFields: [abone])
    #expect(placement.problems().isEmpty && placement.usesContent && placement.referencedFields == ["abone"] && placement.isActive)
    let date = DateComponents(year: 2026, month: 10, day: 1)
    #expect(placement.target(for: "fatura.pdf", date: date, content: ["abone": "128820964"]) == "128820964_El_10_26.pdf")
    #expect(placement.target(for: "fatura.pdf", date: date) == "_El_10_26.pdf")

    placement.nameTemplate = "{c:yok}_{c:abone}"
    #expect(placement.problems() == [.unknownToken("{c:yok}")] && placement.referencedFields == ["abone"])
    placement.folderTemplate = "{c:abone}/{year}"
    #expect(placement.problems().contains(.contentTokenInFolder("{c:abone}")))
    placement = RoutePlacement(nameTemplate: "{c:abone}", contentFields: [abone, ContentField(name: "abone", pattern: "(x)"),
                                                                           ContentField(name: "ş-ad", pattern: "x"), ContentField(name: "", pattern: "")])
    #expect(placement.problems() == [.contentFieldName("abone"), .contentFieldName("ş-ad"), .contentFieldPattern("x"),
                                     .contentFieldName(""), .contentFieldPattern("")])
    // Alanı olmayan belirteç içeriği istemez; "{c:}" bilinmeyen belirteçtir.
    #expect(!RoutePlacement(nameTemplate: "{c:abone}").usesContent)
    #expect(RoutePlacement(nameTemplate: "{c:}").problems() == [.unknownToken("{c:}")])

    let old = try JSONDecoder().decode(RoutePlacement.self, from: Data(#"{"nameTemplate":"{name}"}"#.utf8))
    #expect(old.contentFields.isEmpty)
    let saved = try JSONDecoder().decode(RoutePlacement.self, from: JSONEncoder().encode(RoutePlacement(nameTemplate: "{c:abone}", contentFields: [abone])))
    #expect(saved.contentFields == [abone])
    let item = try JSONDecoder().decode(PlacementReport.Item.self, from: Data(#"{"path":"a.pdf","suggestions":["Ev"]}"#.utf8))
    #expect(item.needsFolder && item.missingFields.isEmpty && item.folder == nil && item.contentValues.isEmpty)
}

/// Karar planı: değeri bulunan dosya kopyalanır; bulunmayan için ad sorulur (klasör sorulmaz); ad yazılınca ya da dosya
/// atlanınca karar biter. "Klasörü sor"da klasörü bilinen ama değeri bulunmayan dosya için yalnızca ad sorulur.
@Test func missingContentValuesAskForANameOnly() throws {
    let w = try Workspace("CopiatorContentFields")
    try w.mkdir("Arsiv/Elektrik")
    let placement = RoutePlacement(nameTemplate: "{c:abone}_El", contentFields: [ContentField(name: "abone", pattern: #"Abone No:\s*(\d+)"#)])
    let contents = ["a.txt": ["abone": "128820964"], "b.txt": [:]]
    let plan = try PlacementQuestions.plan(paths: ["a.txt", "b.txt"], source: w.url("Gelen"), destination: w.url("Arsiv"), placement: placement,
                                           resolution: nil, contents: contents)
    let item = try #require(plan.report?.items.first)
    #expect(plan.paths == ["a.txt"] && plan.report?.total == 1)
    #expect(item.path == "b.txt" && !item.needsFolder && item.folder == nil && item.missingFields == ["abone"] && item.suggestions.isEmpty)
    let named = try PlacementQuestions.plan(paths: ["a.txt", "b.txt"], source: w.url("Gelen"), destination: w.url("Arsiv"), placement: placement,
                                            resolution: PlacementResolution(names: ["b.txt": "128820964_El_elle"]), contents: contents)
    #expect(named.report == nil && named.paths == ["a.txt", "b.txt"] && named.names == ["b.txt": "128820964_El_elle"] && named.folders.isEmpty)
    let skipped = try PlacementQuestions.plan(paths: ["a.txt", "b.txt"], source: w.url("Gelen"), destination: w.url("Arsiv"), placement: placement,
                                              resolution: PlacementResolution(skipped: ["b.txt"]), contents: contents)
    #expect(skipped.report == nil && skipped.paths == ["a.txt"])
    let preview = try PlacementQuestions.plan(paths: ["a.txt", "b.txt"], source: w.url("Gelen"), destination: w.url("Arsiv"), placement: placement,
                                              resolution: nil, contents: contents, decide: false)
    #expect(preview.report == nil && preview.paths == ["a.txt", "b.txt"], "önizleme beklemez")

    var asking = placement
    asking.askFolder = true
    let known = try PlacementQuestions.plan(paths: ["b.txt"], source: w.url("Gelen"), destination: w.url("Arsiv"), placement: asking,
                                            resolution: PlacementResolution(folders: ["b.txt": "Elektrik"]), contents: contents)
    let knownItem = try #require(known.report?.items.first)
    #expect(!knownItem.needsFolder && knownItem.folder == "Elektrik" && knownItem.missingFields == ["abone"])
}

/// Gerçek hazırlık: metinden alınan değer adda; değeri bulunmayan dosyada iş karar bekler (hiçbir şey hazırlanmaz); ad
/// yazılınca o adla hazırlanır.
@Test func stagingUsesValuesFromTheText() async throws {
    let w = try Workspace("CopiatorContentFields")
    try w.write("Gelen/enerjisa ekim.txt", "ENERJİSA\nAbone No: 128820964\nEkim 2026")
    try w.write("Gelen/taranmis.txt", "metin yok")
    try w.mkdir("Arsiv")
    let placement = RoutePlacement(nameTemplate: "{c:abone}_El_{month}_{yy}", dateSource: .contents,
                                   contentFields: [ContentField(name: "abone", pattern: #"Abone No:\s*(\d+)"#)])
    let rules = RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "txt")])
    var job = TransferJob(source: w.url("Gelen"), destination: w.url("Arsiv"), options: CopyOptions(copyMode: .contents, rules: rules, placement: placement))
    var waiting = job
    do {
        _ = try await RuleSelection.prepare(&waiting, zeroTerminated: true, skippedPaths: [], scratch: try w.mkdir("Gecici"), isCancelled: { false })
        Issue.record("karar beklenmeliydi")
    } catch let needed as PlacementQuestions.DecisionNeeded {
        #expect(needed.report.items.map(\.path) == ["taranmis.txt"] && needed.report.items.first?.missingFields == ["abone"])
    }
    job.placementResolution = PlacementResolution(names: ["taranmis.txt": "elle_adlandirildi"])
    let prepared = try #require(try await RuleSelection.prepare(&job, zeroTerminated: true, skippedPaths: [], scratch: try w.mkdir("Gecici2"),
                                                                 isCancelled: { false }))
    #expect(Set(prepared.targets) == ["128820964_El_10_26.txt", "elle_adlandirildi.txt"])
}
