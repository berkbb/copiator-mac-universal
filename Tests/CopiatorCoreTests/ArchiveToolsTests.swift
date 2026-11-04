// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// "Hedefte aynı içerikli kopya": adı ve yeri farklı olsa da içeriği aynı dosya var sayılır; boyutu aynı ama içeriği
/// farklı dosya sayılmaz; hedef verilmezse hiçbir dosya "var" değildir.
@Test func inDestinationMatchesByContentAnywhere() async throws {
    let workspace = try Workspace()
    try workspace.write("Kaynak/fatura.pdf", "aynı içerik\n")
    try workspace.write("Kaynak/yeni.pdf", "farklı içer\n")
    try workspace.write("Kaynak/alt/ozet.txt", "özet\n")
    try workspace.write("Hedef/Arsiv/2025/eski_adi.pdf", "aynı içerik\n")
    try workspace.write("Hedef/ozet.txt", "özet\n")
    try workspace.write("Hedef/.gizli", "farklı içer\n")
    let index = try DestinationIndex(root: workspace.url("Hedef"))
    #expect(index.count == 2)

    func scan(_ op: RuleOperator, destination: URL?) async throws -> Set<String> {
        let rules = RuleGroup(conditions: [RuleCondition(attribute: .inDestination, op: op)])
        return Set(try await RuleScanner.scan(workspace.url("Kaynak"), rules: rules, destination: destination).paths)
    }
    #expect(try await scan(.isTrue, destination: workspace.url("Hedef")) == ["fatura.pdf", "alt/ozet.txt"])
    #expect(try await scan(.isFalse, destination: workspace.url("Hedef")) == ["yeni.pdf"])
    #expect(try await scan(.isFalse, destination: nil) == ["fatura.pdf", "yeni.pdf", "alt/ozet.txt"])
    #expect(RuleCondition.starting(.inDestination).op == .isFalse && RuleAttribute.inDestination.isAdvanced)
}

/// Finder'da seçilen öğeler: yalnızca kökteki bu öğeler (ve klasörse içleri) taranır.
@Test func scanCanBeLimitedToSelectedItems() async throws {
    let workspace = try Workspace()
    for path in ["İndirilenler/a.pdf", "İndirilenler/b.pdf", "İndirilenler/Klasör/c.pdf", "İndirilenler/Öteki/d.pdf"] {
        try workspace.write(path, path)
    }
    let paths = try await RuleScanner.scan(workspace.url("İndirilenler"), rules: RuleGroup(),
                                           onlyItems: ["a.pdf", "Klasör".decomposedStringWithCanonicalMapping]).paths
    #expect(Set(paths) == ["a.pdf", "Klasör/c.pdf"])
    let options = try JSONDecoder().decode(CopyOptions.self, from: JSONEncoder().encode(CopyOptions(selectedItems: ["a.pdf"])))
    #expect(options.selectedItems == ["a.pdf"])
}

/// Hedef özeti: dosya ve klasör sayısı, toplam, üst klasörlere ve uzantılara göre boyut (gizli dosyalar sayılmaz).
@Test func destinationSummaryCountsFoldersAndExtensions() throws {
    let workspace = try Workspace()
    try workspace.write("Hedef/Fotoğraflar/2026/a.jpg", String(repeating: "x", count: 3000))
    try workspace.write("Hedef/Fotoğraflar/b.JPG", String(repeating: "x", count: 1000))
    try workspace.write("Hedef/Belgeler/c.pdf", String(repeating: "x", count: 500))
    try workspace.write("Hedef/Belgeler/d", String(repeating: "x", count: 10))
    try workspace.write("Hedef/kok.txt", String(repeating: "x", count: 20))
    try workspace.write("Hedef/.gizli", String(repeating: "x", count: 9999))
    for index in 0..<6 { try workspace.write("Hedef/Diğer/f.e\(index)", String(repeating: "x", count: index + 1)) }
    let summary = try DestinationSummary.compute(at: workspace.url("Hedef"))
    #expect(summary.files == 11 && summary.folders == 4)
    #expect(summary.bytes == 3000 + 1000 + 500 + 10 + 20 + 21)
    #expect(summary.topFolders.map(\.name) == ["Fotoğraflar", "Belgeler", "Diğer", ""])
    #expect(summary.topFolders.first?.bytes == 4000 && summary.topFolders.first?.files == 2)
    #expect(summary.topExtensions.count == DestinationSummary.maxExtensions)
    #expect(summary.topExtensions.prefix(4).map(\.name) == ["jpg", "pdf", "txt", ""])
    #expect(summary.totalCapacity != nil && summary.availableCapacity != nil)
}

/// Klasör önerisi: kısaltmalar ("sgrt" → Sigorta), Türkçe karakterler, klasör adının içerikte geçmesi, kardeş klasörler;
/// gizli klasörler ve paketlerin içi aday değildir.
@Test func folderSuggestionsRankArchiveFolders() throws {
    let folders = ["Özel", "Özel/Ev", "Özel/Ev/Tapu", "Özel/Ev/Faturalar", "Özel/Ev/Faturalar/Elektrik", "Özel/Ev/Faturalar/Su",
                   "Özel/Araba", "Özel/Araba/Sigorta", "Multimedya/Fotoğraflar/2026", "Multimedya/Müzik"]
    #expect(FolderSuggester.suggestions(for: "tapu_cankaya.pdf", folders: folders).first?.path == "Özel/Ev/Tapu")
    #expect(FolderSuggester.suggestions(for: "sgrt_police.pdf", folders: folders).first?.path == "Özel/Araba/Sigorta")
    #expect(FolderSuggester.suggestions(for: "elektrik_ekim_2026.pdf", folders: folders).first?.path == "Özel/Ev/Faturalar/Elektrik")
    #expect(FolderSuggester.suggestions(for: "MUZIK listesi", folders: folders).first?.path == "Multimedya/Müzik")
    let byContent = FolderSuggester.suggestions(for: "belge_0001.pdf", folders: folders, content: "Zorunlu trafik SİGORTA poliçesi")
    #expect(byContent.first?.path == "Özel/Araba/Sigorta")
    // Kardeşler de eklenir: Elektrik önerilince Su da listede.
    #expect(FolderSuggester.suggestions(for: "elektrik", folders: folders, limit: 10).map(\.path).contains("Özel/Ev/Faturalar/Su"))
    #expect(FolderSuggester.suggestions(for: "", folders: folders).isEmpty)

    #expect(FolderSuggester.similarity("tapu", "tapu") == 1 && FolderSuggester.similarity("", "a") == 0)
    #expect(abs(FolderSuggester.similarity("abcd", "abxd") - 0.75) < 0.0001)
    #expect(FolderSuggester.isAbbreviation("sgrt", of: "Sigorta") && FolderSuggester.isAbbreviation("ankr", of: "ankara"))
    #expect(!FolderSuggester.isAbbreviation("tp", of: "tapu") && !FolderSuggester.isAbbreviation("123", of: "1234")
        && !FolderSuggester.isAbbreviation("ptu", of: "tapu") && !FolderSuggester.isAbbreviation("tps", of: "tapu"))

    let workspace = try Workspace()
    for path in ["Arsiv/Ev/Tapu/x", "Arsiv/.gizli/x", "Arsiv/Uygulama.app/Contents/x"] { try workspace.write(path, "x") }
    #expect(FolderSuggester.folders(in: workspace.url("Arsiv")) == ["Ev", "Ev/Tapu"])
}

/// Seçili öğelerle ve "hedefte kopyası yok" kuralıyla gerçek kopya: yalnızca seçilen ve hedefte henüz olmayan dosyalar.
@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct LiveArchiveToolsTests {
    @Test func copiesOnlySelectedItemsThatAreNotArchivedYet() async throws {
        let workspace = try Workspace("CopiatorArchive")
        var context = try await engineContext()
        context.scratchDirectory = try workspace.mkdir("Gecici")
        try workspace.write("İndirilenler/fatura.pdf", "zaten arşivde\n")
        try workspace.write("İndirilenler/yeni.pdf", "yeni belge\n")
        try workspace.write("İndirilenler/seçilmeyen.pdf", "seçilmedi\n")
        try workspace.write("Arşiv/2025/eski_ad.pdf", "zaten arşivde\n")
        let rules = RuleGroup(conditions: [RuleCondition(attribute: .inDestination, op: .isFalse)])
        let options = CopyOptions(copyMode: .contents, rules: rules, selectedItems: ["fatura.pdf", "yeni.pdf"])
        let job = TransferJob(source: workspace.url("İndirilenler"), destination: workspace.url("Arşiv"), options: options)
        let result = await RsyncEngine().run(job, context: context) { _ in }
        #expect(result.kind == .succeeded, "\(result)")
        #expect(workspace.read("Arşiv/yeni.pdf") == "yeni belge\n")
        #expect(!workspace.exists("Arşiv/fatura.pdf") && !workspace.exists("Arşiv/seçilmeyen.pdf"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.url("Gecici").path).isEmpty)
    }
}
