// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// Windows ve Office artıkları: kalıplar harf duyarsızdır, seçenek açıkken (varsayılan, eski işlerde de) rsync'e ve
/// uygulamanın kendi taramalarına (kurallar, eşitleme, "Taşı") uygulanır; kapalıyken hiçbir şey dışlanmaz.
@Test func windowsLeftoverPatternsIgnoreCase() throws {
    #expect(RsyncCommand.caseInsensitivePattern("Thumbs.db") == "[Tt][Hh][Uu][Mm][Bb][Ss].[Dd][Bb]")
    #expect(RsyncCommand.caseInsensitivePattern("$recycle.bin") == "$[Rr][Ee][Cc][Yy][Cc][Ll][Ee].[Bb][Ii][Nn]")
    for name in ["Thumbs.db", "thumbs.db", "THUMBS.DB", "desktop.ini", "Desktop.ini", "~$rapor.docx", "$RECYCLE.BIN", "System Volume Information"] {
        #expect(RsyncCommand.isWindowsLeftover(name), "\(name)")
    }
    for name in ["rapor.docx", "Thumbs.db.bak", "my desktop.ini", "~rapor.docx", "$fatura.pdf"] {
        #expect(!RsyncCommand.isWindowsLeftover(name), "\(name)")
    }

    let source = URL(fileURLWithPath: "/Kaynak"), destination = URL(fileURLWithPath: "/Hedef")
    let environment = RsyncCommand.Environment(engine: fullEngine, destinationFileSystem: .exfat, sourceIsDirectory: true)
    let on = RsyncCommand.transfer(TransferJob(source: source, destination: destination), environment: environment)
    for pattern in RsyncCommand.windowsLeftoverPatterns { #expect(on.contains("--exclude=\(pattern)"), "\(pattern)") }
    let off = RsyncCommand.transfer(TransferJob(source: source, destination: destination, options: CopyOptions(excludeWindowsLeftovers: false)),
                                    environment: environment)
    #expect(!off.contains { $0.contains("humbs") || $0.contains("~$") })

    // Eski kayıtlarda alan yoktur: varsayılan (açık) gelir; kapatılan seçenek kaydedilip okununca kapalı kalır.
    #expect(try JSONDecoder().decode(CopyOptions.self, from: Data(#"{"copyMode": "folder"}"#.utf8)).excludeWindowsLeftovers)
    let saved = try JSONEncoder().encode(CopyOptions(excludeWindowsLeftovers: false))
    #expect(try JSONDecoder().decode(CopyOptions.self, from: saved).excludeWindowsLeftovers == false)
}

@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct LiveWindowsLeftoverTests {
    private func makeSource(_ w: Workspace) throws {
        try w.write("Kaynak/rapor.docx", "rapor")
        try w.write("Kaynak/thumbs.db", "önbellek")
        try w.write("Kaynak/Alt/Desktop.ini", "görünüm")
        try w.write("Kaynak/Alt/~$rapor.docx", "kilit")
        try w.write("Kaynak/$RECYCLE.BIN/S-1-5/silinen.txt", "çöp")
        try w.write("Kaynak/System Volume Information/kayit", "sistem")
        try w.write("Kaynak/Alt/not.txt", "not")
    }

    @Test func leftoversStayOutOnlyWhileTheOptionIsOn() async throws {
        let w = try Workspace("CopiatorWindowsLeftovers")
        try makeSource(w)
        var context = try await engineContext()
        context.scratchDirectory = try w.mkdir("Gecici")
        let on = TransferJob(source: w.url("Kaynak"), destination: try w.mkdir("Hedef"), options: CopyOptions(copyMode: .contents))
        #expect(await RsyncEngine().run(on, context: context) { _ in }.kind.isSuccess)
        #expect(w.read("Hedef/rapor.docx") == "rapor" && w.read("Hedef/Alt/not.txt") == "not")
        for path in ["thumbs.db", "Alt/Desktop.ini", "Alt/~$rapor.docx", "$RECYCLE.BIN", "System Volume Information"] {
            #expect(!w.exists("Hedef/" + path), "\(path)")
        }
        let off = TransferJob(source: w.url("Kaynak"), destination: try w.mkdir("Hepsi"),
                              options: CopyOptions(copyMode: .contents, excludeWindowsLeftovers: false))
        #expect(await RsyncEngine().run(off, context: context) { _ in }.kind.isSuccess)
        for path in ["thumbs.db", "Alt/Desktop.ini", "Alt/~$rapor.docx", "$RECYCLE.BIN/S-1-5/silinen.txt", "System Volume Information/kayit"] {
            #expect(w.exists("Hepsi/" + path), "\(path)")
        }
    }

    /// Kurallar uygulamada değerlendirilir: tarama artıklara (ve artık klasörlerin içine) hiç girmez.
    @Test func ruleScanSkipsLeftovers() async throws {
        let w = try Workspace("CopiatorWindowsLeftovers")
        try makeSource(w)
        let everything = RuleGroup()
        let skipped = try await RuleScanner.scan(w.url("Kaynak"), rules: everything, skipsWindowsLeftovers: true).paths
        #expect(Set(skipped) == ["rapor.docx", "Alt/not.txt"], "\(skipped)")
        let all = try await RuleScanner.scan(w.url("Kaynak"), rules: everything).paths
        #expect(all.contains("thumbs.db") && all.contains("Alt/~$rapor.docx"))
    }
}
