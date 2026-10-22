// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

private func condition(_ attribute: RuleAttribute, _ op: RuleOperator, _ value: String) -> RuleCondition {
    RuleCondition(attribute: attribute, op: op, value: value)
}

private func matches(_ path: String, _ rules: RuleGroup, directory: Bool = false) throws -> Bool {
    try RuleEvaluator(rules).matches(RuleItem(relativePath: path, isDirectory: directory))
}

// MARK: - Koşullar

@Test func textOperatorsAreCaseInsensitiveAndUnicodeNormalized() throws {
    let name = { (op: RuleOperator, value: String) in RuleGroup(conditions: [condition(.name, op, value)]) }
    #expect(try matches("2026/Satış Raporu.XLSX", name(.contains, "rapor")))
    #expect(try matches("2026/Satış Raporu.XLSX", name(.beginsWith, "SATIŞ")))
    #expect(try matches("2026/Satış Raporu.XLSX", name(.endsWith, ".xlsx")))
    #expect(try matches("2026/Satış Raporu.XLSX", name(.equals, "satış raporu.xlsx")))
    #expect(try !matches("2026/Satış Raporu.XLSX", name(.equals, "satış raporu")))
    #expect(try !matches("2026/Satış Raporu.XLSX", name(.beginsWith, "rapor")))
    // macOS adları ayrık (NFD) biçimde saklayabilir: "Ş" = "S" + U+0327.
    let decomposed = "S\u{0327}irket/Dekont1.pdf"
    #expect(try matches(decomposed, RuleGroup(conditions: [condition(.folderName, .equals, "şirket")])))
    #expect(try matches(decomposed, RuleGroup(conditions: [condition(.path, .beginsWith, "Şirket/")])))
    #expect(try matches("IMG_0001.JPG", name(.beginsWith, "img")) && matches("ışık.png", name(.beginsWith, "IŞIK")))
    #expect(try matches("İzmir.txt", name(.contains, "izmir")))
    // Boş değer hiçbir şeye uymaz.
    #expect(try !matches("a.txt", name(.contains, "  ")))
}

/// Kullanıcının örneği: "satis_raporu_2026-10-22_v3.xlsx" biçimindeki adlar.
@Test func regexMatchesTheReportNamingScheme() throws {
    let strict = RuleGroup(conditions: [condition(.name, .matchesRegex, #"^[a-z_]+_\d{4}-\d{2}-\d{2}_v\d+\.xlsx?$"#)])
    #expect(try matches("Raporlar/satis_raporu_2026-10-22_v3.xlsx", strict))
    #expect(try matches("satis_raporu_2026-10-22_v12.xls", strict))
    #expect(try !matches("Satis_raporu_2026-10-22_v3.xlsx", strict), "regex is case-sensitive unless (?i) is used")
    #expect(try !matches("satis_raporu_2026-10-22.xlsx", strict))
    #expect(try !matches("satis_raporu_2026-10-22_v3.xlsx.bak", strict))
    let any = RuleGroup(conditions: [condition(.name, .matchesRegex, #"^.+\.xlsx?$"#)])
    #expect(try matches("x/bütçe.xlsx", any) && matches("eski.xls", any) && !matches("notlar.txt", any))
    let insensitive = RuleGroup(conditions: [condition(.name, .matchesRegex, #"(?i)^satis_"#)])
    #expect(try matches("SATIS_ocak.xlsx", insensitive))
    // Geçersiz ifade kaydedilmeden yakalanır.
    let broken = RuleGroup(conditions: [condition(.name, .matchesRegex, "([a-z")])
    #expect(broken.problems() == [.invalidRegex("([a-z")])
    #expect(throws: (any Error).self) { try RuleEvaluator(broken) }
}

@Test func extensionFolderAndKindConditions() throws {
    let ext = RuleGroup(conditions: [condition(.fileExtension, .equals, ".JPG")])
    #expect(try matches("Tatil/IMG_1.jpg", ext) && !matches("Tatil/IMG_1.jpeg", ext) && !matches("jpg", ext))
    // Klasör adı, yoldaki klasörlerden herhangi birine bakar (dosyanın kendi adına değil).
    let folder = RuleGroup(conditions: [condition(.folderName, .contains, "tatil")])
    #expect(try matches("2025/Yaz Tatili/Gün 1/a.heic", folder))
    #expect(try !matches("2025/tatil.jpg", folder))
    for (path, kind, expected) in [
        ("a.heic", FileKind.image, true), ("a.mov", .movie, true), ("a.m4a", .audio, true), ("a.pdf", .pdf, true),
        ("a.pdf", .document, false), ("a.docx", .document, true), ("a.xlsx", .spreadsheet, true), ("a.xlsx", .document, false),
        ("a.key", .presentation, true), ("a.swift", .sourceCode, true), ("a.swift", .text, true), ("a.zip", .archive, true),
        ("bilinmeyen.qqq", .image, false), ("README", .text, false),
    ] {
        #expect(try matches(path, RuleGroup(conditions: [condition(.kind, .equals, kind.rawValue)])) == expected, "\(path) \(kind)")
    }
    #expect(try matches("Araçlar/Hesap.app", RuleGroup(conditions: [condition(.kind, .equals, "application")]), directory: true))
    #expect(RuleCondition(attribute: .kind, op: .contains, value: "image").op == .equals)
}

/// Finder gibi: Tümü / Herhangi biri / Hiçbiri ve iç içe gruplar.
@Test func groupsCombineAllAnyNoneAndNest() throws {
    // (uzantı jpg VEYA heic) VE klasör adı "Tatil" içerir VE hiçbiri: ad "kopya" içerir
    let photos = RuleGroup(match: .any, conditions: [condition(.fileExtension, .equals, "jpg"), condition(.fileExtension, .equals, "heic")])
    let notCopies = RuleGroup(match: .none, conditions: [condition(.name, .contains, "kopya")])
    let rules = RuleGroup(match: .all, conditions: [condition(.folderName, .contains, "tatil")], groups: [photos, notCopies])
    #expect(try matches("Tatil 2026/a.jpg", rules))
    #expect(try matches("Tatil 2026/b.HEIC", rules))
    #expect(try !matches("Tatil 2026/a kopya.jpg", rules))
    #expect(try !matches("Tatil 2026/video.mov", rules))
    #expect(try !matches("İş/a.jpg", rules))
    // Boş grup her şeyi seçer; boş alt gruplar yok sayılır.
    #expect(try matches("x/y.z", RuleGroup()))
    #expect(try matches("x/y.z", RuleGroup(match: .any, groups: [RuleGroup()])))
    #expect(try matches("x/y.z", RuleGroup(match: .none)))
    #expect(RuleGroup(groups: [RuleGroup(), RuleGroup(groups: [RuleGroup()])]).isEmpty)
}

@Test func rulesDecodeTolerantlyAndLimitDepth() throws {
    let json = """
    {"match": "any", "conditions": [{"attribute": "name", "op": "contains", "value": "a"}, {"attribute": "colour", "value": "x"},
     {"attribute": "kind", "op": "beginsWith", "value": "image"}], "groups": [{"match": "maybe"}, 42]}
    """
    let rules = try JSONDecoder().decode(RuleGroup.self, from: Data(json.utf8))
    #expect(rules.match == .any)
    #expect(rules.conditions.count == 3)
    #expect(rules.conditions[1].attribute == .name)
    #expect(rules.conditions[2].op == .equals)
    #expect(rules.groups.count == 1 && rules.groups[0].match == .all)
    var deep = RuleGroup(conditions: [condition(.name, .contains, "x")])
    for _ in 0..<(RuleGroup.maxDepth + 2) { deep = RuleGroup(groups: [deep]) }
    #expect(deep.problems().contains(.tooDeep))
    #expect(try !matches("x", deep))
}

// MARK: - Tarama

@Test func scannerFindsMatchingFilesAndSkipsFoldersAndPackages() async throws {
    let workspace = try Workspace()
    for path in ["Kaynak/2026/Ocak/satis_raporu_2026-01-31_v1.xlsx", "Kaynak/2026/Ocak/notlar.txt", "Kaynak/eski.xlsx",
                 "Kaynak/.Spotlight-V100/kayit.xlsx", "Kaynak/Gizli/.gizli.xlsx", "Kaynak/Araç.app/Contents/Info.xlsx",
                 "Kaynak/Kişisel/sir.xlsx"] {
        try workspace.write(path, "x")
    }
    let rules = RuleGroup(match: .any, conditions: [condition(.fileExtension, .equals, "xlsx"), condition(.kind, .equals, "application")])
    let result = try await RuleScanner.scan(workspace.url("Kaynak"), rules: rules, skippedPaths: ["Kişisel"],
                                      skippedNames: Set(RsyncCommand.systemExclusions))
    #expect(Set(result.paths) == ["2026/Ocak/satis_raporu_2026-01-31_v1.xlsx", "eski.xlsx", "Gizli/.gizli.xlsx", "Araç.app"])
    #expect(result.scanned >= 8)
    await #expect(throws: CancellationError.self) {
        try await RuleScanner.scan(workspace.url("Kaynak"), rules: rules, isCancelled: { true })
    }
}

// MARK: - Rutin modeli ve kayıt

@Test func routineValidationAndJobOptions() throws {
    let workspace = try Workspace()
    try workspace.write("A/rapor.xlsx", "x")
    try workspace.write("dosya.txt", "x")
    try workspace.mkdir("B")
    var routine = Routine(name: "  ", routes: [])
    #expect(routine.problems().contains(.emptyName) && routine.problems().contains(.noRoutes))
    routine.name = "Raporlar"
    routine.routes = [RoutineRoute(source: workspace.url("A"), destination: workspace.url("B"),
                                   rules: RuleGroup(conditions: [condition(.fileExtension, .equals, "xlsx")])),
                      RoutineRoute(source: workspace.url("dosya.txt"), destination: workspace.url("B")),
                      RoutineRoute(source: workspace.url("A"), destination: nil),
                      RoutineRoute(source: workspace.url("A"), destination: workspace.url("A/alt"), rules: RuleGroup(conditions: [condition(.name, .matchesRegex, "[")]))]
    let problems = routine.problems()
    #expect(problems.contains(.sourceNotFolder(route: 1)))
    #expect(problems.contains(.missingDestination(route: 2)))
    #expect(problems.contains(.rules(route: 3, .invalidRegex("["))))
    #expect(problems.contains { if case .path(route: 3, _) = $0 { true } else { false } })
    #expect(!problems.contains { if case .path(route: 0, _) = $0 { true } else { false } })
    #expect(!routine.problems(checkPaths: false).contains(.sourceNotFolder(route: 1)))

    routine.options = CopyOptions(copyMode: .folder, deleteExtraneous: true, verifyAfterCopy: .quick)
    let options = routine.jobOptions(for: routine.routes[0])
    #expect(options.copyMode == .contents && !options.deleteExtraneous && options.verifyAfterCopy == .quick)
    #expect(options.rules == routine.routes[0].rules)
}

@Test func routineStoreRoundTripsAndToleratesBadEntries() throws {
    let workspace = try Workspace()
    let store = RoutineStore(url: workspace.url("Destek/routines.json"))
    #expect(try store.load().isEmpty)
    // Kayıt saniye çözünürlüğündedir (ISO 8601): karşılaştırma için tam saniyelik bir zaman.
    var routine = Routine(name: "Fotoğraflar", routes: [RoutineRoute(source: URL(fileURLWithPath: "/Users/x/Resimler"),
                                                                     destination: URL(fileURLWithPath: "/Volumes/Yedek/Resimler"))],
                          createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    routine.routes[0].rules = RuleGroup(match: .any, conditions: [condition(.kind, .equals, "image")], groups: [RuleGroup(match: .none)])
    routine.options.verifyAfterCopy = .checksum
    try store.save([routine])
    #expect(try store.load() == [routine])

    let json = """
    {"version": 1, "routines": [
      {"id": "8B0F5C9E-3E1B-4D57-9D44-2D1D7C1D2A31", "name": "Eski", "routes": [{"source": "file:///a/", "rules": {"match": "none"}}, "bozuk"],
       "options": {"copyMode": "folder", "future": 1}},
      {"name": "kimliksiz"}
    ]}
    """
    try Data(json.utf8).write(to: store.url)
    let loaded = try store.load()
    #expect(loaded.count == 1)
    #expect(loaded[0].name == "Eski" && loaded[0].routes.count == 1 && loaded[0].routes[0].rules.match == .none)
    #expect(loaded[0].routes[0].destination == nil)
    try Data("bozuk".utf8).write(to: store.url)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(store.quarantineCorruptFile() != nil)
    #expect(try store.load().isEmpty)
}

// MARK: - Gerçek rsync ile

@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct RuleEngineTests {
    private func makeSource(_ workspace: Workspace) throws {
        for path in ["A/2026/Ocak/satis_raporu_2026-01-31_v1.xlsx", "A/2026/Ocak/fatura.pdf", "A/2026/Şubat/satis_raporu_2026-02-28_v2.xlsx",
                     "A/Tatil/IMG_1.HEIC", "A/Tatil/IMG_1 kopya.HEIC", "A/notlar.txt", "A/satır\nsonu.xlsx"] {
            try workspace.write(path, path)
        }
        try workspace.mkdir("B")
        try workspace.mkdir("Y/Fotoğraflar")
    }

    private func run(_ job: TransferJob, sandboxed: Bool = true) async throws -> (JobResult, [JobLogEntry]) {
        let events = Collected<TransferEvent>()
        let result = await RsyncEngine().run(job, context: try await engineContext(sandboxed: sandboxed)) { events.add($0) }
        let logs = events.values.compactMap { event -> JobLogEntry? in if case .log(let entry) = event { entry } else { nil } }
        return (result, logs)
    }

    /// Rotalar: raporlar B'ye, tatil fotoğrafları (kopyalar hariç) Y diskine; klasör yapısı korunur, öteki dosyalar
    /// kopyalanmaz, hedefteki ilgisiz dosyalar silinmez.
    @Test(arguments: [true, false])
    func routesCopyOnlyMatchingFilesKeepingStructure(sandboxed: Bool) async throws {
        let workspace = try Workspace()
        try makeSource(workspace)
        try workspace.write("B/onceden.txt", "kalır")
        let reports = RuleGroup(conditions: [condition(.name, .matchesRegex, #"^[a-z_]+_\d{4}-\d{2}-\d{2}_v\d+\.xlsx?$"#)])
        let photos = RuleGroup(match: .all, conditions: [condition(.folderName, .equals, "tatil"), condition(.kind, .equals, "image")],
                               groups: [RuleGroup(match: .none, conditions: [condition(.name, .contains, "kopya")])])
        let routine = Routine(name: "Ofis", routes: [
            RoutineRoute(source: workspace.url("A"), destination: workspace.url("B"), rules: reports),
            RoutineRoute(source: workspace.url("A"), destination: workspace.url("Y/Fotoğraflar"), rules: photos),
        ], options: CopyOptions(deleteExtraneous: true, verifyAfterCopy: .quick))
        for route in routine.routes {
            let job = TransferJob(source: try #require(route.source), destination: try #require(route.destination),
                                  options: routine.jobOptions(for: route))
            let (result, logs) = try await run(job, sandboxed: sandboxed)
            #expect(result.kind == .succeeded, "\(result)")
            #expect(result.differenceCount == 0)
            #expect(logs.contains { $0.key == LKey.logRulesMatched.rawValue })
        }
        #expect(workspace.exists("B/2026/Ocak/satis_raporu_2026-01-31_v1.xlsx"))
        #expect(workspace.exists("B/2026/Şubat/satis_raporu_2026-02-28_v2.xlsx"))
        #expect(!workspace.exists("B/2026/Ocak/fatura.pdf") && !workspace.exists("B/notlar.txt") && !workspace.exists("B/Tatil"))
        #expect(workspace.read("B/onceden.txt") == "kalır")
        #expect(workspace.exists("Y/Fotoğraflar/Tatil/IMG_1.HEIC"))
        #expect(!workspace.exists("Y/Fotoğraflar/Tatil/IMG_1 kopya.HEIC") && !workspace.exists("Y/Fotoğraflar/2026"))
    }

    /// Adında satır sonu olan dosya NUL ile ayrılmış listeyle (`--from0`) kopyalanır.
    @Test func namesWithNewlinesAreCopied() async throws {
        let workspace = try Workspace()
        try makeSource(workspace)
        let job = TransferJob(source: workspace.url("A"), destination: workspace.url("B"),
                              options: CopyOptions(rules: RuleGroup(conditions: [condition(.name, .contains, "sonu")])))
        let (result, _) = try await run(job)
        #expect(result.kind == .succeeded, "\(result)")
        #expect(workspace.read("B/satır\nsonu.xlsx") == "A/satır\nsonu.xlsx")
    }

    /// Önizleme ve doğrulama da yalnızca seçilen dosyalara bakar; hiçbir şey yazılmaz.
    @Test func previewListsOnlyMatchingFiles() async throws {
        let workspace = try Workspace()
        try makeSource(workspace)
        let job = TransferJob(source: workspace.url("A"), destination: workspace.url("B"),
                              options: CopyOptions(rules: RuleGroup(conditions: [condition(.fileExtension, .equals, "pdf")])))
        let report = await RsyncEngine().verify(job, context: try await engineContext(), checksum: false)
        #expect(report.result.kind == .succeeded, "\(report.result)")
        #expect(report.entries.filter { $0.kind == .missing && !$0.isDirectory }.map(\.path) == ["2026/Ocak/fatura.pdf"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.url("B").path).isEmpty)
    }

    /// Hiçbir dosya kurallara uymuyorsa iş yine başarıyla biter ve hiçbir şey kopyalanmaz.
    @Test func noMatchesIsASuccessfulEmptyRun() async throws {
        let workspace = try Workspace()
        try makeSource(workspace)
        let job = TransferJob(source: workspace.url("A"), destination: workspace.url("B"),
                              options: CopyOptions(rules: RuleGroup(conditions: [condition(.fileExtension, .equals, "psd")])))
        let (result, logs) = try await run(job)
        #expect(result.kind == .succeeded, "\(result)")
        #expect(logs.contains { $0.key == LKey.logRulesMatched.rawValue && $0.arguments.first == "0" })
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.url("B").path).isEmpty)
    }
}
