// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// openrsync karşı tarafı kendi yoluyla başlatır; rsync 3.x'e ve göreli yollara `--rsync-path` verilmez.
@Test func openrsyncGetsItsOwnPathForTheReceiver() {
    let job = TransferJob(source: URL(fileURLWithPath: "/Users/x/A"), destination: URL(fileURLWithPath: "/Volumes/B"))
    func environment(_ engine: EngineInfo, _ path: String?) -> RsyncCommand.Environment {
        RsyncCommand.Environment(engine: engine, destinationFileSystem: .apfs, sourceIsDirectory: true, enginePath: path)
    }
    let open = environment(openrsyncEngine, "/usr/bin/rsync")
    for arguments in [RsyncCommand.transfer(job, environment: open), RsyncCommand.verify(job, environment: open, checksum: true)] {
        #expect(arguments.contains("--rsync-path=/usr/bin/rsync"))
        // Seçenek yolların ayırıcısından ("--") önce gelir.
        #expect(arguments.firstIndex(of: "--rsync-path=/usr/bin/rsync")! < arguments.firstIndex(of: "--")!)
    }
    #expect(!RsyncCommand.transfer(job, environment: environment(fullEngine, "/Applications/Copiator.app/Contents/MacOS/rsync"))
        .contains { $0.hasPrefix("--rsync-path") })
    #expect(!RsyncCommand.transfer(job, environment: environment(openrsyncEngine, nil)).contains { $0.hasPrefix("--rsync-path") })
    #expect(!RsyncCommand.transfer(job, environment: environment(openrsyncEngine, "rsync")).contains { $0.hasPrefix("--rsync-path") })
    // Düşürülen seçenekler listesinde görünmez (motorun desteklediği bir seçenektir).
    #expect(!RsyncCommand.droppedOptions(job, environment: open).contains { $0.hasPrefix("--rsync-path") })
}

/// macOS'un kendi rsync'i (openrsync, kısıtlı kip) gerçekten kopyalar ve doğrular; kum havuzunda ve dışında.
/// PATH'in başına "rsync" adlı sahte bir program konur: openrsync karşı tarafı PATH'ten başlatsaydı kum havuzunda
/// "Operation not permitted" ile, kum havuzu dışında sahte programın hatasıyla biterdi.
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/rsync"), "/usr/bin/rsync yok"), .serialized)
struct SystemRsyncTests {
    private func context(sandboxed: Bool) async throws -> EngineContext? {
        let url = URL(fileURLWithPath: "/usr/bin/rsync")
        guard let info = await EngineLocator.probe(url), info.isOpenrsync else { return nil }
        return EngineContext(executable: url, info: info, sandboxed: sandboxed)
    }

    /// PATH'in başına sahte bir rsync koyar; iş bitince eski PATH geri gelir.
    private func withDecoyRsync<T>(_ workspace: Workspace, _ body: () async throws -> T) async throws -> T {
        let decoy = try workspace.write("tuzak/rsync", "#!/bin/sh\necho 'tuzak rsync çalıştı' >&2\nexit 99\n")
        chmod(decoy.path, 0o755)
        let original = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", decoy.deletingLastPathComponent().path + ":" + original, 1)
        defer { setenv("PATH", original, 1) }
        return try await body()
    }

    @Test(arguments: [true, false])
    func copiesAndVerifiesWithMacOSRsync(sandboxed: Bool) async throws {
        guard let context = try await context(sandboxed: sandboxed) else { return }
        let workspace = try Workspace()
        try workspace.write("Kaynak/not.txt", "merhaba\n")
        // İndirilmiş bir dosya: öznitelikler kopyalanmasa da karantina işareti hedefe aktarılmalı.
        let downloaded = try workspace.write("Kaynak/indirilen.zip", "zip\n")
        #expect(Quarantine.set("0083;00000000;Safari;", on: downloaded))
        try workspace.write("Kaynak/alt/b.txt", "alt\n")
        try workspace.write("Şirket/Dekont1.pdf", "pdf\n")
        try workspace.mkdir("Hedef")
        let folder = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"))
        let file = TransferJob(source: workspace.url("Şirket/Dekont1.pdf"), destination: workspace.url("Hedef"))
        try await withDecoyRsync(workspace) {
            for job in [folder, file] {
                let result = await RsyncEngine().run(job, context: context) { _ in }
                #expect(result.kind.isSuccess, "\(result)")
            }
            #expect(workspace.read("Hedef/Kaynak/not.txt") == "merhaba\n")
            #expect(workspace.read("Hedef/Kaynak/alt/b.txt") == "alt\n")
            #expect(workspace.read("Hedef/Dekont1.pdf") == "pdf\n")
            #expect(Quarantine.value(of: workspace.url("Hedef/Kaynak/indirilen.zip")) != nil)
            // Kaynakta "._" dosyası kalmaz, hedefe de "._" öğesi yazılmaz.
            #expect(!workspace.exists("Kaynak/._not.txt") && !workspace.exists("Hedef/Kaynak/._not.txt"))
            try workspace.write("Kaynak/yeni.txt", "yeni\n")
            let report = await RsyncEngine().verify(folder, context: context, checksum: false)
            #expect(report.result.kind.isSuccess, "\(report.result)")
            #expect(report.entries.contains { $0.kind == .missing && $0.path.hasSuffix("yeni.txt") }, "\(report.entries)")
        }
    }

    /// openrsync'te (satır sonuyla ayrılmış seçim listesi) rutin klasör kararları yalnızca seçilen dosyalara uygulanır.
    @Test(arguments: [true, false])
    func routineFolderConflictsWithMacOSRsync(sandboxed: Bool) async throws {
        guard let context = try await context(sandboxed: sandboxed) else { return }
        let w = try Workspace()
        try w.write("Kaynak/kok.txt", "kök\n")
        for name in ["Birlestir", "Ikisi", "Atla"] {
            try w.write("Kaynak/\(name)/yeni.txt", "\(name)-yeni\n")
            try w.write("Kaynak/\(name)/disari.log", "kurala uymaz\n")
            try w.write("Hedef/\(name)/eski.txt", "\(name)-eski\n")
        }
        let rules = RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "txt")])
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"),
                              options: CopyOptions(copyMode: .contents, rules: rules))
        job.routineID = UUID()
        let asked = await RsyncEngine().run(job, context: context) { _ in }
        #expect(asked.kind == .awaitingDecision && asked.detail == JobResult.foldersDetail && asked.noteCount == 3, "\(asked)")
        job.folderConflictResolution = FolderConflictResolution(decisions: ["Birlestir": .merge, "Ikisi": .keepBoth, "Atla": .skip])
        let done = try await withDecoyRsync(w) { await RsyncEngine().run(job, context: context) { _ in } }
        #expect(done.kind.isSuccess, "\(done)")
        #expect(w.read("Hedef/kok.txt") == "kök\n")
        #expect(w.read("Hedef/Birlestir/yeni.txt") == "Birlestir-yeni\n" && w.read("Hedef/Birlestir/eski.txt") == "Birlestir-eski\n")
        #expect(!w.exists("Hedef/Ikisi/yeni.txt") && w.read("Hedef/Ikisi 2/yeni.txt") == "Ikisi-yeni\n")
        #expect(!w.exists("Hedef/Ikisi 2/disari.log") && !w.exists("Hedef/Birlestir/disari.log"))
        #expect(!w.exists("Hedef/Atla/yeni.txt") && w.read("Hedef/Atla/eski.txt") == "Atla-eski\n")
    }
}
