// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import Testing
@testable import CopiatorCore

private func date(_ text: String) -> [Int?]? {
    TextDate.find(in: text).map { [$0.year, $0.month, $0.day] }
}

/// Metinde (dosya adı ya da içerik) tarih: Türkçe, İngilizce ve Rumence ay adları, sayısal biçimler, iki haneli yıllar;
/// öncelik sırası ay adı → gün.ay.yıl → yıl-ay-gün → yıl ay → ay yıl → yy aa → aa yy.
@Test func findsDatesInNamesAndText() {
    #expect(date("Enerjisa Ekim 2026") == [2026, 10, nil])
    #expect(date("Son ödeme: 15 Ağustos 2026") == [2026, 8, 15])
    #expect(date("AĞUSTOS 26") == [2026, 8, nil])
    #expect(date("dekont-Agustos-26") == [2026, 8, nil])
    #expect(date("ŞUBAT 2027 dönemi") == [2027, 2, nil])
    #expect(date("ARALIK 2026") == [2026, 12, nil])
    #expect(date("October 2026 statement") == [2026, 10, nil])
    #expect(date("factură octombrie 2026") == [2026, 10, nil])
    #expect(date("mai 2026") == [2026, 5, nil])
    #expect(date("martie 2026") == [2026, 3, nil])
    #expect(date("Tarih: 15.08.2026") == [2026, 8, 15])
    #expect(date("15/08/26") == [2026, 8, 15])
    #expect(date("2026-08-15 rapor") == [2026, 8, 15])
    #expect(date("rapor 2026 08") == [2026, 8, nil])
    #expect(date("08-2026") == [2026, 8, nil])
    #expect(date("123456789_El_10_26") == [2026, 10, nil])
    #expect(date("123456789_ASKI_01_26") == [2026, 1, nil])
    #expect(date("Fatura 123456789") == nil)
    #expect(date("13.13.2026") == nil)
    #expect(date("tarih yok") == nil)
    // Ay adı sayısal biçimden önce gelir.
    #expect(date("01.02.2026 tarihli Mart 2026 faturası") == [2026, 3, nil])
}

/// PDF'nin metni PDFKit ile, düz metin (Türkçe Windows kod sayfası dahil) doğrudan okunur; arama harf, aksan ve
/// I/ı/İ/i farkı gözetmez.
@Test func readsTextFromPDFsAndPlainFiles() throws {
    let workspace = try Workspace()
    let pdf = workspace.url("fatura.pdf")
    try writePDF(pdf, lines: ["ENERJİSA Başkent Elektrik", "Fatura dönemi: Ekim 2026", "Tutar: 1.234,56 TL"])
    let text = try #require(ContentReader.text(of: pdf))
    #expect(text.contains("Ekim 2026"))
    #expect(ContentReader.contains(text, "enerjisa"))
    #expect(ContentReader.contains(text, "ENERJISA"))
    #expect(ContentReader.contains(text, "baskent"))
    #expect(!ContentReader.contains(text, "su faturası"))
    #expect(TextDate.find(in: text)?.month == 10)

    let legacy = workspace.url("eski.txt")
    try #require("Şubat 2026 aidat".data(using: .windowsCP1254)).write(to: legacy)
    #expect(ContentReader.text(of: legacy)?.contains("Şubat") == true)
    try workspace.write("resim.jpg", "değil")
    #expect(ContentReader.text(of: workspace.url("resim.jpg")) == nil)
    #expect(!ContentReader.canRead(.rtf) && ContentReader.canRead(.pdf) && ContentReader.canRead(.commaSeparatedText))
}

/// Spotlight dizini olmayan bir klasörde (geçici klasörler dizinlenmez) "içerikte geçen metin" PDF ve metin dosyalarını
/// doğrudan okuyarak bulur.
@Test func contentConditionWorksWithoutSpotlight() async throws {
    let workspace = try Workspace()
    try writePDF(workspace.url("Kaynak/2026/elektrik.pdf"), lines: ["ENERJİSA", "Ekim 2026"])
    try writePDF(workspace.url("Kaynak/2026/su.pdf"), lines: ["ASKİ", "Ekim 2026"])
    try workspace.write("Kaynak/notlar.md", "enerjisa aboneliği")
    try workspace.write("Kaynak/enerjisa.jpg", "resim")
    let rules = RuleGroup(conditions: [RuleCondition(attribute: .content, op: .contains, value: "Enerjisa")])
    let paths = try await RuleScanner.scan(workspace.url("Kaynak"), rules: rules).paths
    #expect(Set(paths) == ["2026/elektrik.pdf", "notlar.md"])
}

/// Şablonlar: tarih klasörleri, ad şablonu, uzantının korunması, yapı korumalı ve düz yerleşim, güvenli adlar.
@Test func placementRendersTargets() {
    let october = DateComponents(year: 2026, month: 10, day: 7)
    var placement = RoutePlacement(folderTemplate: "{year}/{month}-{monthName}", nameTemplate: "123456789_El_{month}_{yy}")
    #expect(placement.isActive && placement.usesDate && placement.problems().isEmpty)
    #expect(placement.target(for: "Faturalar/Enerjisa Ekim.pdf", date: october) == "2026/10-Ekim/123456789_El_10_26.pdf")
    placement.keepStructure = true
    #expect(placement.target(for: "Faturalar/Enerjisa Ekim.pdf", date: october) == "2026/10-Ekim/Faturalar/123456789_El_10_26.pdf")
    placement.language = "en"
    #expect(placement.target(for: "a.pdf", date: october) == "2026/10-October/123456789_El_10_26.pdf")
    placement.language = "ro"
    #expect(placement.target(for: "a.pdf", date: DateComponents(year: 2026, month: 2)) == "2026/02-Februarie/123456789_El_02_26.pdf")

    // Yalnızca ad şablonu: klasör yapısı korunur; yalnızca klasör şablonu: ad korunur; {day} yoksa 01.
    let rename = RoutePlacement(nameTemplate: "{folder}_{name}_{year}{month}{day}")
    #expect(rename.target(for: "2026/Faturalar/elektrik.pdf", date: DateComponents(year: 2026, month: 3))
        == "2026/Faturalar/Faturalar_elektrik_20260301.pdf")
    #expect(RoutePlacement(folderTemplate: "{year}").target(for: "x/Paket.app", date: october) == "2026/Paket.app")
    #expect(!RoutePlacement().isActive)

    // Değerler ve şablon güvenli ada dönüşür: "/" ve ":" tire olur, baştaki noktalar ve denetim karakterleri atılır;
    // ad boş kalırsa asıl ad kullanılır.
    #expect(RoutePlacement(nameTemplate: "a:b").target(for: "x.txt", date: nil) == "a-b.txt")
    #expect(RoutePlacement(nameTemplate: "..{name}").target(for: "..gizli.txt", date: nil) == "gizli.txt")
    #expect(RoutePlacement(nameTemplate: "{year}").target(for: "x.txt", date: nil) == "x.txt")
    #expect(RoutePlacement(folderTemplate: "../{year}/./ /\n").target(for: "x.txt", date: october) == "2026/x.txt")
    #expect(RoutePlacement.component("  .\u{0}a/b\nc  ") == "a-bc")
    #expect(RoutePlacement.component(". ..") == "" && RoutePlacement.component(" . . .x") == "x")
    #expect(RoutePlacement(folderTemplate: ". ../. ../{year}").target(for: "x.txt", date: october) == "2026/x.txt")
}

@Test func placementProblemsAndDecoding() throws {
    #expect(RoutePlacement(folderTemplate: "{yil}/{year}", nameTemplate: "{ay}_{yil}").problems() == [.unknownToken("{yil}"), .unknownToken("{ay}")])
    #expect(RoutePlacement(nameTemplate: "a/b").problems() == [.slashInName])
    #expect(RoutePlacement(folderTemplate: "{year}/../x").problems() == [.parentFolder])
    let route = RoutineRoute(rules: RuleGroup(), placement: RoutePlacement(folderTemplate: "{year}", keepStructure: true, nameTemplate: "{name}",
                                                                          dateSource: .contents, language: "en"))
    #expect(try JSONDecoder().decode(RoutineRoute.self, from: JSONEncoder().encode(route)) == route)
    // Eski rota ve iş seçenekleri: yerleşim yok.
    let legacy = try JSONDecoder().decode(RoutineRoute.self, from: Data(#"{"id": "8B0F5C9E-3E1B-4D57-9D44-2D1D7C1D2A41"}"#.utf8))
    #expect(!legacy.placement.isActive)
    #expect(try JSONDecoder().decode(CopyOptions.self, from: Data(#"{"copyMode": "contents"}"#.utf8)).placement == nil)
    var routine = Routine(name: "R", routes: [route])
    #expect(routine.jobOptions(for: route).placement == route.placement)
    routine.routes[0].placement = RoutePlacement()
    #expect(routine.jobOptions(for: routine.routes[0]).placement == nil)
    routine.routes[0].placement.folderTemplate = "../x"
    routine.routes[0].source = URL(fileURLWithPath: "/tmp/kaynak")
    routine.routes[0].destination = URL(fileURLWithPath: "/tmp/hedef")
    #expect(routine.problems(checkPaths: false).contains(.placement(route: 0, .parentFolder)))
    #expect(PlacementToken.monthName(10, language: "tr") == "Ekim" && PlacementToken.monthName(13, language: "tr") == "13")
}

/// Adlandırma kipleri: `{name}`in önündeki ve ardındaki metin adda zaten varsa yeniden eklenmez, hedef belirteçleri hedefin
/// yolundan gelir, ad düzeltmeleri sırayla ve rotanın dilinin harf kurallarıyla uygulanır.
@Test func namingModes() {
    let october = DateComponents(year: 2026, month: 10, day: 7)
    // Önek ve sonek yinelenmez (harf büyüklüğü ve aksan fark etmez); şablon iki kez uygulansa da ad uzamaz.
    let prefixed = RoutePlacement(nameTemplate: "123456789_El_{name}_{yy}")
    let once = prefixed.target(for: "Ekim.pdf", date: october)
    #expect(once == "123456789_El_Ekim_26.pdf")
    #expect(prefixed.target(for: once, date: october) == once)
    #expect(prefixed.target(for: "123456789_el_Ekim.pdf", date: october) == "123456789_el_Ekim_26.pdf")
    #expect(RoutePlacement(nameTemplate: "Özet {name}").target(for: "ozet rapor.txt", date: nil) == "ozet rapor.txt")
    #expect(RoutePlacement(nameTemplate: "{name}-{name}").target(for: "a.txt", date: nil) == "a-a.txt")

    // Hedef belirteçleri: klasör şablonunda rotanın hedefi; ad şablonunda dosyanın düştüğü en derin klasör ve parantez
    // içindeki en derin numara.
    let destination = "/Volumes/Arsiv/Abonelikler/Elektrik (123456789)"
    let both = RoutePlacement(folderTemplate: "{year}", nameTemplate: "{targetNumber}_{targetFolder}_{month}")
    #expect(both.target(for: "fatura.pdf", date: october, destination: destination) == "2026/123456789_2026_10.pdf")
    let numbered = RoutePlacement(nameTemplate: "{targetNumber}_{name}")
    #expect(numbered.target(for: "fatura.pdf", date: nil, destination: destination) == "123456789_fatura.pdf")
    #expect(numbered.target(for: "Su (55)/fatura.pdf", date: nil, destination: destination) == "Su (55)/55_fatura.pdf")
    #expect(RoutePlacement(folderTemplate: "{targetFolder} {year}").target(for: "a.pdf", date: october, destination: destination)
        == "Elektrik (123456789) 2026/a.pdf")
    #expect(!RoutePlacement(nameTemplate: "{targetNumber}").usesDate)
    // Şablon ve düzeltme yoksa ad hiç değişmez (gizli dosya ve ":" içeren ad dahil).
    #expect(RoutePlacement(folderTemplate: "{year}").target(for: "x/.gizli", date: october, destination: destination) == "2026/.gizli")
    #expect(RoutePlacement(folderTemplate: "{year}").target(for: "a:b.txt", date: october) == "2026/a:b.txt")

    // Ad düzeltmeleri: hazır düzeltmeler sırayla; yalnızca düzeltmesi olan yerleşim de etkindir.
    var fixes = RoutePlacement(nameFixes: NameFix.presets)
    #expect(fixes.isActive && !fixes.usesDate && fixes.problems().isEmpty)
    #expect(fixes.target(for: "Klasör/ab1234 Ekim   fatura.pdf", date: nil) == "Klasör/AB1234_Ekim_fatura.pdf")
    // Harf dönüşümü rotanın dilinde: Türkçede i → İ, İngilizcede i → I.
    fixes.nameFixes = [NameFix(pattern: "^(\\w+)", replacement: "${1:upper}")]
    #expect(fixes.target(for: "istanbul.txt", date: nil) == "İSTANBUL.txt")
    fixes.language = "en"
    #expect(fixes.target(for: "istanbul.txt", date: nil) == "ISTANBUL.txt")
    fixes.nameFixes = [NameFix(pattern: "(\\w+)_(\\w+)", replacement: "${2:title}-$1 $$ $0 ${1:lower}")]
    #expect(fixes.target(for: "A_rapor.txt", date: nil) == "Rapor-A $ A_rapor a.txt")
    // Ad boşalırsa korunur; "/" tireye döner ve baştaki noktalar atılır (hedefin dışına çıkılamaz).
    fixes.nameFixes = [NameFix(pattern: ".*", replacement: "")]
    #expect(fixes.target(for: "a.txt", date: nil) == "a.txt")
    fixes.nameFixes = [NameFix(pattern: "a", replacement: "../x/")]
    #expect(fixes.target(for: "a.txt", date: nil) == "-x-.txt")
    // Adım sınırını aşan ifade adı değiştirmez (tarama asılı kalmaz).
    let long = String(repeating: "a", count: 40) + "!"
    fixes.nameFixes = [NameFix(pattern: "(a+)+$", replacement: "x")]
    #expect(fixes.target(for: long + ".txt", date: nil) == long + ".txt")

    #expect(NameFix.pieces("x$1${2:lower}$$${a}$") == [.text("x"), .group(1, nil), .group(2, "lower"), .text("$${a}$")])
}

@Test func nameFixProblemsAndDecoding() throws {
    #expect(RoutePlacement(nameFixes: [NameFix(pattern: "([a-z", replacement: "")]).problems() == [.invalidFix("([a-z")])
    #expect(RoutePlacement(nameFixes: [NameFix(pattern: "(a)", replacement: "$2 ${1:shout} ${1:upper} $$3")]).problems()
        == [.fixReplacement("$2"), .fixReplacement("${1:shout}")])
    #expect(!RoutePlacement(nameFixes: [NameFix()]).isActive && RoutePlacement(nameFixes: [NameFix()]).problems().isEmpty)
    let saved = RoutePlacement(nameTemplate: "{name}", nameFixes: [NameFix(pattern: "a", replacement: "b")])
    #expect(try JSONDecoder().decode(RoutePlacement.self, from: JSONEncoder().encode(saved)) == saved)
    // Eski yerleşimde düzeltme yoktur; eksik alanlar boş kalır.
    #expect(try JSONDecoder().decode(RoutePlacement.self, from: Data(#"{"nameTemplate": "{name}"}"#.utf8)).nameFixes.isEmpty)
    #expect(try JSONDecoder().decode(NameFix.self, from: Data(#"{"pattern": "a"}"#.utf8)).replacement == "")
}

/// Pakette kalan göreli bağlantılar kurulur, dışarı çıkanlar kurulmaz.
@Test func linksInsidePackagesMustStayInside() {
    #expect(PlacementStaging.staysInside("A", at: 1))
    #expect(PlacementStaging.staysInside("../Resources/x", at: 1))
    #expect(!PlacementStaging.staysInside("../../x", at: 1))
    #expect(!PlacementStaging.staysInside("/etc/passwd", at: 3))
    #expect(!PlacementStaging.staysInside("..", at: 0))
}

/// Yerleştirmeli rotalar gerçek rsync ile: yeni adlar ve tarih klasörleri, karantina ve Finder etiketi, paketler,
/// aynı hedefe düşen dosyalar, aynı adlı dosya kararları, doğrulama ve kaynak hiç değişmeden.
@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct LivePlacementTests {
    private func run(_ job: inout TransferJob, _ context: EngineContext) async -> JobResult {
        let events = Collected<TransferEvent>()
        let result = await RsyncEngine().run(job, context: context) { events.add($0) }
        for event in events.values { JobQueue.apply(event, to: &job) }
        return result
    }

    private func listing(_ root: URL) -> [String: String] {
        var result: [String: String] = [:]
        for path in (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [] {
            var info = stat()
            let full = root.appendingPathComponent(path).path
            guard lstat(full, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFREG: result[path.precomposedStringWithCanonicalMapping] = String(decoding: (try? Data(contentsOf: URL(fileURLWithPath: full))) ?? Data(), as: UTF8.self)
            case S_IFLNK: result[path.precomposedStringWithCanonicalMapping] = "→ " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: full)) ?? "")
            default: continue
            }
        }
        return result
    }

    /// Adlandırma kipleri gerçek kopyada: hedefin parantez içindeki numarası ada yazılır, adda zaten olan önek yinelenmez,
    /// ad düzeltmeleri uygulanır; kaynak değişmez.
    @Test func namingModesApplyInARealCopy() async throws {
        let workspace = try Workspace("CopiatorPlacement")
        var context = try await engineContext()
        context.scratchDirectory = try workspace.mkdir("Gecici")
        try workspace.write("Kaynak/ab12 rapor.txt", "rapor")
        try workspace.write("Kaynak/42_eski.txt", "eski")
        try workspace.mkdir("Hedef (42)")
        let placement = RoutePlacement(nameTemplate: "{targetNumber}_{name}", nameFixes: [NameFix.presets[1]])
        let route = RoutineRoute(source: workspace.url("Kaynak"), destination: workspace.url("Hedef (42)"), rules: RuleGroup(), placement: placement)
        var job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef (42)"),
                              options: Routine(name: "Adlar", routes: [route]).jobOptions(for: route))
        let result = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result)")
        #expect(listing(workspace.url("Hedef (42)")) == ["42_ab12_rapor.txt": "rapor", "42_eski.txt": "eski"])
        #expect(listing(workspace.url("Kaynak")) == ["ab12 rapor.txt": "rapor", "42_eski.txt": "eski"])
    }

    @Test func placedRouteRenamesIntoDateFoldersAndKeepsEverythingElse() async throws {
        let workspace = try Workspace("CopiatorPlacement")
        let scratch = try workspace.mkdir("Gecici")
        var context = try await engineContext()
        context.scratchDirectory = scratch
        // Kaynak: içerikte tarihli iki fatura (biri adında da), etiketli ve karantinalı; içinde bağlantılar olan bir paket;
        // kurala uymayan bir dosya.
        try writePDF(workspace.url("Kaynak/Faturalar/enerjisa_fatura.pdf"), lines: ["ENERJİSA", "Fatura dönemi: Ekim 2026"])
        try writePDF(workspace.url("Kaynak/Faturalar/2026/fatura (1).pdf"), lines: ["ENERJİSA", "Dönem: Kasım 2026"])
        try writePDF(workspace.url("Kaynak/Eski/enerjisa_kopya.pdf"), lines: ["ENERJİSA", "Fatura dönemi: Ekim 2026"])
        try workspace.write("Kaynak/Faturalar/su.pdf", "ASKİ")
        let tagged = workspace.url("Kaynak/Faturalar/enerjisa_fatura.pdf")
        try (tagged as NSURL).setResourceValue(["Fatura"], forKey: .tagNamesKey)
        #expect(Quarantine.set("0083;65f00000;Safari;", on: tagged))
        try workspace.write("Kaynak/Araclar/Enerjisa.app/Contents/Versions/A/ikili", "ikili")
        try FileManager.default.createSymbolicLink(atPath: workspace.url("Kaynak/Araclar/Enerjisa.app/Contents/Versions/Current").path,
                                                   withDestinationPath: "A")
        try workspace.write("Disari/gizli.txt", "gizli")
        try FileManager.default.createSymbolicLink(atPath: workspace.url("Kaynak/Araclar/Enerjisa.app/Contents/kacak").path,
                                                   withDestinationPath: workspace.url("Disari/gizli.txt").path)
        try FileManager.default.createSymbolicLink(atPath: workspace.url("Kaynak/Faturalar/baglanti-enerjisa.pdf").path,
                                                   withDestinationPath: tagged.path)
        let sourceBefore = listing(workspace.url("Kaynak"))
        try workspace.mkdir("Hedef")

        let rules = RuleGroup(match: .any, conditions: [
            RuleCondition(attribute: .content, op: .contains, value: "enerjisa"),
            RuleCondition(attribute: .name, op: .beginsWith, value: "enerjisa"),
        ])
        let placement = RoutePlacement(folderTemplate: "{year}/{month}-{monthName}", nameTemplate: "123456789_El_{month}_{yy}",
                                       dateSource: .contents)
        let routine = Routine(name: "Faturalar", routes: [RoutineRoute(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"),
                                                                       rules: rules, placement: placement)])
        var options = routine.jobOptions(for: routine.routes[0])
        options.verifyAfterCopy = .quick
        var job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"), options: options)
        // Paketin içeriğinde tarih yok: "İçerikteki tarih" seçiliyken değiştirilme tarihine geçilmez, hiçbir şey kopyalanmadan
        // tarih sorulur.
        let waiting = await run(&job, context)
        #expect(waiting.kind == .awaitingDecision && waiting.detail == JobResult.placementsDetail, "\(waiting)")
        #expect(job.pendingPlacements?.items.map(\.path) == ["Araclar/Enerjisa.app"] && job.pendingPlacements?.items.first?.missingDate != nil)
        #expect(listing(workspace.url("Hedef")).isEmpty)
        let today = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        job.placementResolution = PlacementResolution(dates: ["Araclar/Enerjisa.app": PlacementDate.string(today)])
        job.pendingPlacements = nil
        let result = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result) \(job.log.suffix(6).map { $0.raw ?? $0.key ?? "" })")

        let copied = listing(workspace.url("Hedef"))
        // Aynı hedefe düşen iki Ekim faturası numaralanır; paket seçilen tarihle (bugün) adlanır.
        let packageFolder = try #require(copied.keys.first { $0.hasSuffix("/123456789_El_\(String(format: "%02d", Calendar.current.component(.month, from: Date())))_\(Calendar.current.component(.year, from: Date()) % 100).app/Contents/Versions/A/ikili") })
        #expect(copied["2026/10-Ekim/123456789_El_10_26.pdf"]?.isEmpty == false)
        #expect(copied["2026/10-Ekim/123456789_El_10_26 2.pdf"]?.isEmpty == false)
        #expect(copied["2026/11-Kasım/123456789_El_11_26.pdf"]?.isEmpty == false)
        #expect(copied[packageFolder] == "ikili")
        let packageRoot = (packageFolder as NSString).deletingLastPathComponent.replacingOccurrences(of: "/A", with: "")
        #expect(copied[packageRoot + "/Current"] == "→ A")
        #expect(!copied.keys.contains { $0.hasSuffix("kacak") || $0.contains("baglanti") || $0.hasSuffix("su.pdf") })
        #expect(copied.values.allSatisfy { $0 != "gizli" })
        #expect(job.log.contains { $0.key == LKey.logPlacementLinksSkipped.rawValue && $0.arguments == ["2"] })
        #expect(job.log.contains { $0.key == LKey.logVerifyAfterCopyPassed.rawValue })

        // Öznitelikler yeni ada geçti; kaynak hiç değişmedi; geçici klasör boş.
        let renamed = try #require(["2026/10-Ekim/123456789_El_10_26.pdf", "2026/10-Ekim/123456789_El_10_26 2.pdf"]
            .map { workspace.url("Hedef/" + $0) }.first { Quarantine.value(of: $0) != nil })
        #expect(try renamed.resourceValues(forKeys: [.tagNamesKey]).tagNames == ["Fatura"])
        #expect(listing(workspace.url("Kaynak")) == sourceBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)

        // İkinci çalıştırma: hedefteki aynı adlı dosyalar hedefteki adlarıyla sorulur; "ikisini de sakla" numaralı kopya yazar.
        job.conflictResolution = nil
        job.result = nil
        #expect(await run(&job, context).kind == .awaitingDecision)
        let asked = Set(job.pendingConflicts?.items.map(\.path) ?? [])
        #expect(asked.contains("2026/11-Kasım/123456789_El_11_26.pdf") && asked.contains("2026/10-Ekim/123456789_El_10_26.pdf"))
        job.conflictResolution = ConflictResolution(decisions: ["2026/11-Kasım/123456789_El_11_26.pdf": .keepBoth], others: .skip)
        #expect(await run(&job, context).kind == .succeeded)
        #expect(listing(workspace.url("Hedef"))["2026/11-Kasım/123456789_El_11_26 2.pdf"]?.isEmpty == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    /// Önizleme (kuru çalıştırma) hedefteki yeni yolları listeler, hiçbir şey yazmaz.
    @Test func previewListsPlacedTargets() async throws {
        let workspace = try Workspace("CopiatorPlacement")
        var context = try await engineContext()
        context.scratchDirectory = try workspace.mkdir("Gecici")
        try workspace.mkdir("Kaynak")
        try writeJPEG(workspace.url("Kaynak/IMG_0001.jpg"), width: 8, height: 8, taken: "2024:07:15 10:00:00", model: nil)
        try workspace.mkdir("Hedef")
        let route = RoutineRoute(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"), rules: RuleGroup(),
                                 placement: RoutePlacement(folderTemplate: "{year}/{month}-{monthName}", nameTemplate: "{year}-{month}-{day}_{name}"))
        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"),
                              options: Routine(name: "Fotoğraflar", routes: [route]).jobOptions(for: route))
        let report = await RsyncEngine().verify(job, context: context, checksum: false)
        #expect(report.result.kind.isSuccess, "\(report.result)")
        #expect(report.entries.map(\.path).contains("2024/07-Temmuz/2024-07-15_IMG_0001.jpg"), "\(report.entries.map(\.path))")
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.url("Hedef").path).isEmpty)
    }
}
