// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

@Test func profileDeniesNetworkAndKeepsSourcesReadOnly() {
    let profile = SandboxProfile(
        writableDirectories: [URL(fileURLWithPath: "/private/tmp/hedef")],
        readOnlyDirectories: [URL(fileURLWithPath: "/private/tmp/hedef/kaynak")],
        deniedReadDirectories: [URL(fileURLWithPath: "/Users/x/.ssh")]
    )
    let text = profile.profileText
    #expect(text.contains("(deny network*)"))
    #expect(text.contains("(deny file-write*)"))
    #expect(text.contains("(allow file-write* (subpath \"/dev\") (subpath (param \"W0\")))"))
    // Kaynak yasağı yazma izninden SONRA gelir (son eşleşen kural kazanır).
    let allow = text.range(of: "(allow file-write*")!.lowerBound
    let deny = text.range(of: "(deny file-write* (subpath (param \"K0\")))")!.lowerBound
    #expect(allow < deny)
    #expect(text.contains("(deny file-read* (subpath (param \"R0\")))"))
    #expect(text.contains("(deny process-exec)"))
    #expect(text.contains("(deny mach-lookup)"))

    let args = profile.launchArguments(executable: URL(fileURLWithPath: "/a/rsync"), arguments: ["-rltDhX", "--", "/s", "/d/"])
    #expect(args.first == "-p")
    #expect(args.contains("W0=/private/tmp/hedef"))
    #expect(args.contains("K0=/private/tmp/hedef/kaynak"))
    #expect(args.contains("R0=/Users/x/.ssh"))
    #expect(args.suffix(5) == ["/a/rsync", "-rltDhX", "--", "/s", "/d/"])
}

@Test func resolvesPrivateAliases() {
    #expect(SandboxProfile.resolved(URL(fileURLWithPath: "/var/tmp")).path == "/private/var/tmp")
    #expect(SandboxProfile.resolved(URL(fileURLWithPath: "/tmp/henuz-yok/alt")).path == "/private/tmp/henuz-yok/alt")
}

/// Kişisel klasörler kaynak olarak seçilmedikçe okunamaz; seçilen kaynak yasaklı klasörün içindeyse yalnızca o açılır.
@Test func personalFoldersStayHiddenUnlessChosen() throws {
    let workspace = try Workspace()
    let home = workspace.url("ev")
    try workspace.mkdir("ev/.ssh")
    try workspace.mkdir("ev/Library/Keychains")
    try workspace.mkdir("ev/Belgeler")
    let destination = try workspace.mkdir("hedef")

    let documents = SandboxProfile.forTransfer(sources: [home.appendingPathComponent("Belgeler")], destination: destination, home: home)
    #expect(documents.deniedReadDirectories.contains { $0.path.hasSuffix("/ev/.ssh") })
    #expect(documents.deniedReadDirectories.contains { $0.path.hasSuffix("/Library/Keychains") })
    #expect(documents.readableDirectories.isEmpty)
    #expect(documents.writableDirectories.map(\.path) == [destination.path])
    #expect(documents.readOnlyDirectories.map(\.path) == [home.appendingPathComponent("Belgeler").path])

    // Ev klasörünün tamamı yedekleniyorsa kişisel klasörler dışlama olarak döner.
    let whole = SandboxProfile.forTransfer(sources: [home], destination: destination, home: home)
    #expect(whole.protectedPaths(inside: home).contains(".ssh"))
    #expect(whole.protectedPaths(inside: home).contains("Library/Keychains"))

    // ~/.ssh açıkça seçildiyse: yasak kalır ama seçilen klasör yasaktan sonra izinlidir.
    let ssh = SandboxProfile.forTransfer(sources: [home.appendingPathComponent(".ssh")], destination: destination, home: home)
    #expect(ssh.deniedReadDirectories.contains { $0.path.hasSuffix("/ev/.ssh") })
    #expect(ssh.readableDirectories.map(\.lastPathComponent) == [".ssh"])
    #expect(ssh.protectedPaths(inside: home.appendingPathComponent(".ssh")).isEmpty)

    let unprotected = SandboxProfile.forTransfer(sources: [home], destination: destination, protectPersonalData: false, home: home)
    #expect(unprotected.deniedReadDirectories.isEmpty)
}

// MARK: - Gerçek rsync ile

@Suite(.enabled(if: vendoredRsync != nil && SandboxProfile.isAvailable, "Vendor/rsync/rsync ya da sandbox-exec yok"))
struct LiveSandboxTests {
    /// Kum havuzundaki rsync yalnızca hedefe yazar; başka bir klasöre yazmaya çalışırsa reddedilir.
    @Test func sandboxedRsyncWritesOnlyToTheDestination() async throws {
        let workspace = try Workspace()
        try workspace.write("kaynak/a.txt", "merhaba\n")
        let allowed = try workspace.mkdir("izinli")
        let forbidden = try workspace.mkdir("yasak")
        let rsync = CommandRunner(executableURL: try #require(vendoredRsync))
        let profile = SandboxProfile.forTransfer(sources: [workspace.url("kaynak")], destination: allowed)

        let ok = try await rsync.sandboxed(profile).run(["-rltDhX", "--", workspace.url("kaynak").path, allowed.path + "/"])
        #expect(ok.exitCode == 0, "\(ok.stderr)")
        #expect(workspace.read("izinli/kaynak/a.txt") == "merhaba\n")

        let denied = try await rsync.sandboxed(profile).run(["-rltDhX", "--", workspace.url("kaynak").path, forbidden.path + "/"])
        #expect(denied.exitCode == 23)
        #expect(!workspace.exists("yasak/kaynak/a.txt"))
    }

    /// Kaynak hedefin içinde olsa bile salt okunurdur: --delete ile bile kaynaktan hiçbir şey silinemez.
    @Test func sourceIsReadOnlyEvenInsideTheDestination() async throws {
        let workspace = try Workspace()
        try workspace.write("hedef/kaynak/korunan.txt", "kalmalı\n")
        try workspace.write("bos/x.txt", "x\n")
        let rsync = CommandRunner(executableURL: try #require(vendoredRsync))
        let profile = SandboxProfile.forTransfer(sources: [workspace.url("hedef/kaynak")], destination: workspace.url("hedef"))
        // Kötü niyetli bir argüman: boş bir klasörü kaynağın üzerine --delete ile eşitlemek.
        let result = try await rsync.sandboxed(profile).run(["-rltD", "--delete", "--", workspace.url("bos").path + "/", workspace.url("hedef/kaynak").path + "/"])
        #expect(result.exitCode != 0)
        #expect(workspace.read("hedef/kaynak/korunan.txt") == "kalmalı\n")
        #expect(!workspace.exists("hedef/kaynak/x.txt"))
    }

    /// Kişisel klasörler okunamaz: kaynaktaki bir bağlantı ~/.ssh içini gösterse de anahtar kopyalanmaz.
    @Test func personalFoldersCannotBeReadThroughLinks() async throws {
        let workspace = try Workspace()
        let home = workspace.url("ev")
        try workspace.write("ev/.ssh/id_ed25519", "GİZLİ ANAHTAR\n")
        try workspace.write("ev/Proje/README", "proje\n")
        try FileManager.default.createSymbolicLink(atPath: workspace.url("ev/Proje/anahtar").path, withDestinationPath: workspace.url("ev/.ssh/id_ed25519").path)
        let destination = try workspace.mkdir("hedef")
        let rsync = CommandRunner(executableURL: try #require(vendoredRsync))
        let profile = SandboxProfile.forTransfer(sources: [home.appendingPathComponent("Proje")], destination: destination, home: home)
        // -L bağlantıların gösterdiğini kopyalar: kum havuzu olmasa anahtar hedefe giderdi.
        let result = try await rsync.sandboxed(profile).run(["-rL", "--", home.appendingPathComponent("Proje").path, destination.path + "/"])
        #expect(result.exitCode == 23)
        #expect(workspace.read("hedef/Proje/README") == "proje\n")
        #expect(workspace.read("hedef/Proje/anahtar") == nil)
    }

    /// Ağ kapalı: kum havuzundaki rsync bir sunucuya bağlanamaz.
    @Test func networkIsDenied() async throws {
        let workspace = try Workspace()
        let rsync = CommandRunner(executableURL: try #require(vendoredRsync))
        let profile = SandboxProfile.forTransfer(sources: [workspace.root], destination: workspace.root)
        let result = try await rsync.sandboxed(profile).run(["--contimeout=3", "rsync://127.0.0.1:9/modul/"], timeout: 20)
        #expect(result.exitCode != 0)
        // Kum havuzu bağlantıyı EPERM ile keser; kum havuzu olmasa "Connection refused" gelirdi.
        #expect(result.stderr.contains("Operation not permitted"), "\(result.stderr)")
        #expect(!result.stderr.contains("Connection refused"))
        let plain = try await rsync.run(["--contimeout=3", "rsync://127.0.0.1:9/modul/"], timeout: 20)
        #expect(plain.stderr.contains("Connection refused"), "\(plain.stderr)")
    }
}

/// sandbox-exec bulunmayan bir Mac (başlatıcı yolu var olmayan bir dosyaya çevrilir): kurallı çalıştırıcı programı
/// korumasız başlatmaz, `sandboxUnavailable` hatası verir; kuralsız çalıştırıcı (kullanıcı kum havuzunu bilerek kapattı)
/// eskisi gibi çalışır.
@Test func runnerRefusesToStartWithoutSandboxExec() async throws {
    let w = try Workspace()
    let marker = w.url("calisti")
    let profile = SandboxProfile(writableDirectories: [w.root], deniedReadDirectories: [])
    let runner = CommandRunner(executableURL: URL(fileURLWithPath: "/usr/bin/touch")).sandboxed(profile)
    #expect(runner.sandbox != nil)
    try await SandboxProfile.$launcher.withValue(w.url("yok/sandbox-exec")) {
        #expect(!SandboxProfile.isAvailable)
        await #expect(throws: EngineError.sandboxUnavailable) { try await runner.run([marker.path]) }
        // Başlatıcı yokken kurulan çalıştırıcı da kuralları korur (korumasız kopyaya dönmez).
        let inner = CommandRunner(executableURL: URL(fileURLWithPath: "/usr/bin/touch")).sandboxed(profile)
        #expect(inner.sandbox != nil)
        await #expect(throws: EngineError.sandboxUnavailable) { try await inner.run([marker.path]) }
        #expect(!w.exists("calisti"))
        _ = try await CommandRunner(executableURL: URL(fileURLWithPath: "/usr/bin/touch")).sandboxed(nil).run([marker.path])
    }
    #expect(w.exists("calisti"))
    #expect(SandboxProfile.isAvailable == FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"))
}

/// Gerçek rsync ile: sandbox-exec yokken kum havuzu açık bir iş ve doğrulaması hiçbir şey yazmadan
/// `sandboxUnavailable` ile reddedilir ve kullanıcıya ne yapacağı söylenir; kum havuzu kapalıysa iş kopyalar.
@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"))
struct SandboxFailClosedTests {
    @Test func jobsAreRefusedWithoutSandboxExec() async throws {
        let w = try Workspace()
        try w.write("Kaynak/a.txt", "a")
        let destination = try w.mkdir("Hedef")
        var context = try await engineContext(sandboxed: true)
        context.scratchDirectory = try w.mkdir("Gecici")
        let job = TransferJob(source: w.url("Kaynak"), destination: destination)
        let missing = w.url("yok/sandbox-exec")
        let refused = await SandboxProfile.$launcher.withValue(missing) { await RsyncEngine().run(job, context: context) { _ in } }
        #expect(refused.kind == .sandboxUnavailable && !w.exists("Hedef/Kaynak"))
        let report = await SandboxProfile.$launcher.withValue(missing) { await RsyncEngine().verify(job, context: context, checksum: false) }
        #expect(report.result.kind == .sandboxUnavailable && report.entries.isEmpty)
        let english = try #require(NSDictionary(contentsOf: packageRoot.appendingPathComponent("Resources/en.lproj/Localizable.strings"))
            as? [String: String])
        #expect(StringTable(tables: ["en": english]).resultMessage(refused, language: "en") { "\($0)" }.contains("Run rsync in a sandbox"))

        context.sandboxed = false
        let copied = await SandboxProfile.$launcher.withValue(missing) { await RsyncEngine().run(job, context: context) { _ in } }
        #expect(copied.kind.isSuccess && w.read("Hedef/Kaynak/a.txt") == "a")
    }
}
