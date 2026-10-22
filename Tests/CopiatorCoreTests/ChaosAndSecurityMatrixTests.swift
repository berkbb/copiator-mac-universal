// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing
@testable import CopiatorCore

// 11 disiplinli güvenlik ve dayanıklılık matrisi. Her test bir güvenceyi uçtan uca kanıtlar: güvence kaldırılırsa test
// başarısız olur. Canlı testler projenin rsync'iyle (Vendor/rsync/rsync) gerçek dosyalar üzerinde çalışır. Rastgelelik
// tohumludur (SplitMix64); hiçbir test saat süresine bağlı bir sınır koymaz (yalnızca asılı kalmaya karşı `timeLimit`).

private let live = vendoredRsync != nil

/// Tohumlanabilir, deterministik üreteç (SplitMix64).
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Motorun geçici listelerini testin kendi klasörüne yazdıran bağlam: başka testlerin geçici dosyaları karışmaz.
private func matrixContext(_ workspace: Workspace, sandboxed: Bool = true) async throws -> (EngineContext, URL) {
    var context = try await engineContext(sandboxed: sandboxed)
    let scratch = try workspace.mkdir("Gecici")
    context.scratchDirectory = scratch
    return (context, scratch)
}

/// İşi çalıştırır ve olayları uygulamadaki gibi işe uygular (kararlar, günlük, bekleyen çakışmalar).
@discardableResult
private func run(_ job: inout TransferJob, _ context: EngineContext) async -> JobResult {
    let events = Collected<TransferEvent>()
    let result = await RsyncEngine().run(job, context: context) { events.add($0) }
    for event in events.values { JobQueue.apply(event, to: &job) }
    return result
}

/// Klasördeki düzenli dosyalar ve içerikleri (göreli yol → metin); bağlantılar izlenmez.
private func files(_ root: URL) -> [String: String] {
    var result: [String: String] = [:]
    for path in (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [] {
        var info = stat()
        let full = root.appendingPathComponent(path).path
        guard lstat(full, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
        result[path.precomposedStringWithCanonicalMapping] = (try? Data(contentsOf: URL(fileURLWithPath: full))).map { String(decoding: $0, as: UTF8.self) }
    }
    return result
}

private func entries(_ url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
}

private func mode(_ url: URL) -> mode_t {
    var info = stat()
    return lstat(url.path, &info) == 0 ? info.st_mode & 0o777 : 0
}

private func isLink(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
}

/// Bu süreçte açık olup verilen klasörün altını gösteren dosya tanımlayıcıları. Yalnızca testin kendi klasörüne bakılır:
/// paralel çalışan başka testlerin tanımlayıcıları sonucu bozmaz.
private func openDescriptors(under root: URL) -> [String] {
    var paths: [String] = []
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    for descriptor in 0..<getdtablesize() where fcntl(descriptor, F_GETPATH, &buffer) != -1 {
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if path.hasPrefix(root.path + "/") { paths.append(path) }
    }
    return paths
}

private func hasLog(_ job: TransferJob, _ key: LKey) -> Bool {
    job.log.contains { $0.key == key.rawValue }
}

/// rsync yerine çalışan sahte motor (C): her çağrıyı günlüğe yazar, `outside` klasörüne yazmayı dener ve aynı adlı dosya
/// denetiminde (`-ii`) `conflictLine` satırını basar. `hangOnConflictCheck` ile denetimde SIGTERM'i yok sayıp bekler.
private func decoyEngine(
    _ workspace: Workspace, log: URL, outside: URL, conflictLine: String, hangOnConflictCheck: Bool = false
) async throws -> URL {
    let source = workspace.url("sahte.c")
    let binary = workspace.url("sahte-rsync")
    let code = """
    #include <signal.h>
    #include <stdio.h>
    #include <string.h>
    #include <unistd.h>
    int main(int argc, char **argv) {
        FILE *log = fopen("\(log.path)", "a");
        if (log) {
            fprintf(log, "%d", (int)getpid());
            for (int i = 1; i < argc; i++) fprintf(log, " %s", argv[i]);
            fprintf(log, "\\n");
            fclose(log);
        }
        char path[4096];
        snprintf(path, sizeof path, "%s/kacis-%d", "\(outside.path)", (int)getpid());
        FILE *escape = fopen(path, "w");
        if (escape) { fputs("kacis", escape); fclose(escape); }
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "-ii") == 0) {
                if (\(hangOnConflictCheck ? 1 : 0)) { signal(SIGTERM, SIG_IGN); for (;;) pause(); }
                printf("%s\\n", "\(conflictLine)");
                break;
            }
        }
        return 0;
    }
    """
    try Data(code.utf8).write(to: source)
    let result = try await CommandRunner(executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"))
        .run(["clang", "-O0", "-o", binary.path, source.path], timeout: 120)
    try #require(result.exitCode == 0, "\(result.stderr)")
    return binary
}

/// 11 sütunlu (rsync 3) `-ii` satırı: değişmemiş, aynı adlı dosya.
private func unchangedLine(_ path: String) -> String { ".f" + String(repeating: " ", count: 9) + " " + path }

@Suite("Kapsamlı Güvenlik, Stres, Kırma, Sızma, Yük, Hacim, Dayanıklılık, Zafiyet, Kırmızı Takım, Fuzz ve Kaos Test Matrisi", .serialized)
struct ChaosAndSecurityMatrixTests {
    // MARK: 01 Güvenlik

    /// Motorun her çağrısı (aynı adlı dosya denetimi, aktarım, numaralı kopya, doğrulama) kum havuzunda çalışır: sahte
    /// motor hedefin dışına yazamaz; doğrulama hedefe bile yazamaz (salt okunur), bu yüzden onun çağrısı günlükte yoktur ama
    /// doğrulama geçmiştir. Kum havuzu kapalıyken aynı motorun dışarı yazabildiği görülür (testin kendisi sınanır).
    @Test(.enabled(if: SandboxProfile.isAvailable), arguments: [true, false])
    func securityEveryEngineCallRunsInTheSandbox(sandboxed: Bool) async throws {
        let w = try Workspace("CopiatorMatrix")
        try w.write("Kaynak/rapor.txt", "yeni\n")
        try w.write("Hedef/rapor.txt", "eski\n")
        let outside = try w.mkdir("Disari")
        let log = w.url("Hedef/cagrilar.log")
        let engine = try await decoyEngine(w, log: log, outside: outside, conflictLine: unchangedLine("rapor.txt"))
        let context = EngineContext(executable: engine, info: fullEngine, sandboxed: sandboxed, scratchDirectory: try w.mkdir("Gecici"))
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"),
                              options: CopyOptions(copyMode: .contents, verifyAfterCopy: .quick, conflictPolicy: .keepBoth))
        let result = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result) \(job.log.suffix(5))")

        #expect(hasLog(job, .logVerifyAfterCopyPassed))
        let calls = (w.read("Hedef/cagrilar.log") ?? "").split(separator: "\n").map(String.init)
        #expect(calls.count == (sandboxed ? 3 : 4), "\(calls)")
        #expect(calls.contains { $0.contains(" -ii ") })
        #expect(calls.contains { $0.hasSuffix("rapor 2.txt") })
        #expect(calls.contains { $0.contains(" -n -i ") } == !sandboxed)
        #expect(entries(outside).count == (sandboxed ? 0 : 4))
    }

    /// Seçilen dosyalar ve dışlananlar listeleri kullanıcıya özel (0700) klasörlerdedir ve iş bitince silinir; liste
    /// kopyaları, aynı adlı dosya kararları ve doğrulama da geride dosya bırakmaz.
    @Test(.enabled(if: live))
    func securityGeneratedListsArePrivateAndRemoved() async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, scratch) = try await matrixContext(w)
        try w.write("Kaynak/a.txt", "yeni a\n")
        try w.write("Kaynak/b.txt", "yeni b\n")
        try w.write("Kaynak/c.log", "günlük\n")
        try w.write("Kaynak/d.tmp", "geçici\n")
        try w.write("Hedef/a.txt", "eski a\n")
        try w.write("Hedef/b.txt", "eski b\n")
        let userList = try w.write("dislama.txt", "*.tmp\n")

        // Kural listesi.
        let rules = RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .isOneOf, value: "txt, tmp")])
        var probe = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"), options: CopyOptions(copyMode: .contents, rules: rules))
        let prepared = try #require(try await RuleSelection.prepare(&probe, zeroTerminated: true, skippedPaths: [], scratch: scratch, isCancelled: { false }))
        #expect(prepared.folder.path.hasPrefix(scratch.path))
        #expect(mode(prepared.folder) == 0o700)
        try FileManager.default.removeItem(at: prepared.folder)

        // Dışlama listesi (atla / ikisini de sakla).
        var planned = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"), options: CopyOptions(copyMode: .contents, conflictPolicy: .skip))
        let environment = RsyncCommand.Environment(engine: context.info, destinationFileSystem: FileSystemKind.of(planned.destination),
                                                   sourceIsDirectory: true, enginePath: context.executable.path)
        let plan = try await RsyncEngine().planConflicts(&planned, environment: environment, runner: CommandRunner(executableURL: context.executable),
                                                         context: context, snapshot: false)
        let folder = try #require(plan.folder)
        #expect(plan.skipped == 2)
        #expect(folder.path.hasPrefix(scratch.path))
        #expect(mode(folder) == 0o700)
        try FileManager.default.removeItem(at: folder)

        // Tam çalıştırma: kurallar, kararlar, kullanıcının listesi (kum havuzunda kopyalanır) ve doğrulama.
        var advanced = AdvancedOptions()
        advanced.excludeFromFile = userList.path
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"),
                              options: CopyOptions(copyMode: .contents, advanced: advanced, verifyAfterCopy: .quick, rules: rules))
        job.conflictResolution = ConflictResolution(decisions: ["a.txt": .keepBoth, "b.txt": .skip])
        let result = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result) \(job.log.suffix(5))")
        #expect(files(w.url("Hedef")) == ["a.txt": "eski a\n", "a 2.txt": "yeni a\n", "b.txt": "eski b\n"])
        #expect(entries(scratch).isEmpty)
    }

    // MARK: 02 Stres

    /// Binlerce dosyalık bir ağaçta iç içe kurallar (Herhangi biri + Hiçbiri, uzantı listesi, düzenli ifade, klasör adı)
    /// tam olarak bağımsız hesaplanan kümeyi seçer ve rsync yalnızca onları, klasör yapısını koruyarak kopyalar.
    @Test(.enabled(if: live))
    func stressRoutineSelectsAndCopiesThousandsOfFiles() async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, scratch) = try await matrixContext(w)
        var generator = SplitMix64(seed: 0x5EED_0002)
        let kinds = ["jpg", "HEIC", "txt", "md", "png"]
        try w.mkdir("Hedef")
        var expected = Set<String>()
        var total = 0
        for top in 0..<3 {
            for sub in 0..<10 {
                let folder = sub == 7 ? "cache" : "klasör\(sub)"
                let directory = try w.mkdir("Kaynak/yıl\(top)/\(folder)")
                for index in 0..<100 {
                    let ext = kinds[Int(generator.next() % UInt64(kinds.count))]
                    let number = String(format: "%03d", index)
                    let name = ext == "txt" ? (index.isMultiple(of: 2) ? "rapor_\(number).txt" : "not_\(number).txt") : "dosya_\(number).\(ext)"
                    let path = "yıl\(top)/\(folder)/\(name)"
                    FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data(path.utf8))
                    total += 1
                    let wanted = ["jpg", "heic"].contains(ext.lowercased()) || name.hasPrefix("rapor_")
                    if wanted, folder != "cache" { expected.insert(path) }
                }
            }
        }
        let rules = RuleGroup(match: .all, groups: [
            RuleGroup(match: .any, conditions: [
                RuleCondition(attribute: .fileExtension, op: .isOneOf, value: "jpg, heic"),
                RuleCondition(attribute: .name, op: .matchesRegex, value: #"^rapor_\d{3}\.txt$"#),
            ]),
            RuleGroup(match: .none, conditions: [RuleCondition(attribute: .folderName, op: .equals, value: "cache")]),
        ])
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"), options: CopyOptions(copyMode: .contents, rules: rules))
        let result = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result) \(job.log.suffix(5))")
        let copied = files(w.url("Hedef"))
        #expect(Set(copied.keys) == expected)
        #expect(copied.allSatisfy { $0.value == $0.key })
        #expect(job.log.contains { $0.key == LKey.logRulesMatched.rawValue && $0.arguments.first == String(expected.count) })
        #expect(total == 3000 && expected.count > 500)
        #expect(entries(scratch).isEmpty)
    }

    /// Aynı adlı dosya sayısı karar sayfasının sınırını aşar: liste kısaltılır ama toplam doğrudur; dosya dosya kararlar
    /// ve "listede olmayanlar" kararı binlerce kalıplık dışlama listesiyle eksiksiz uygulanır.
    @Test(.enabled(if: live))
    func stressConflictsBeyondTheSheetLimitAreAllDecided() async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, scratch) = try await matrixContext(w)
        let count = ConflictDetector.maxListed + 200
        let source = try w.mkdir("Kaynak")
        let destination = try w.mkdir("Hedef")
        for index in 0..<count {
            FileManager.default.createFile(atPath: source.appendingPathComponent("d\(index).txt").path, contents: Data("yeni\n".utf8))
            FileManager.default.createFile(atPath: destination.appendingPathComponent("d\(index).txt").path, contents: Data("eski içerik\n".utf8))
        }
        for index in 0..<10 { try w.write("Kaynak/ek\(index).txt", "ek\n") }

        var job = TransferJob(source: source, destination: destination, options: CopyOptions(copyMode: .contents))
        #expect(await run(&job, context).kind == .awaitingDecision)
        let report = try #require(job.pendingConflicts)
        #expect(report.items.count == ConflictDetector.maxListed && report.total == count && report.isTruncated)

        let chosen = Set(report.items.prefix(3).map(\.path))
        job.conflictResolution = ConflictResolution(decisions: Dictionary(uniqueKeysWithValues: chosen.map { ($0, .replace) }), others: .skip)
        let result = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result) \(job.log.suffix(5))")
        let copied = files(destination)
        let wrong = (0..<count).filter { copied["d\($0).txt"] != (chosen.contains("d\($0).txt") ? "yeni\n" : "eski içerik\n") }
        #expect(wrong.isEmpty, "\(wrong.prefix(10))")
        #expect((0..<10).allSatisfy { copied["ek\($0).txt"] == "ek\n" })
        #expect(entries(scratch).isEmpty)
    }

    // MARK: 03 Kırma

    /// Okunamayan bir kaynak dosya yalnızca kendisini düşürür: öbürleri kopyalanır, hedefteki eski kopyası bozulmaz,
    /// sonuç başarı sayılmaz ve günlükte o dosya geçer.
    @Test(.enabled(if: live))
    func destructiveUnreadableSourceFileFailsOnlyItself() async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, _) = try await matrixContext(w)
        try w.write("Kaynak/a.txt", "a\n")
        try w.write("Kaynak/b.txt", "yeni b\n")
        try w.write("Kaynak/c.txt", "c\n")
        try w.write("Hedef/b.txt", "eski b\n")
        chmod(w.url("Kaynak/b.txt").path, 0)
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"), options: CopyOptions(copyMode: .contents, conflictPolicy: .replace))
        let result = await run(&job, context)
        #expect([.partial, .permissionDenied].contains(result.kind), "\(result)")
        #expect(files(w.url("Hedef")) == ["a.txt": "a\n", "b.txt": "eski b\n", "c.txt": "c\n"])
        #expect(job.log.contains { $0.raw?.contains("b.txt") == true })
    }

    /// Listede olup kopyalanmadan önce kaybolan dosya işi düşürmez: var olanlar kopyalanır, sonuç kısmi başarıdır.
    @Test(.enabled(if: live))
    func destructiveListedFileVanishesBeforeTheCopy() async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, _) = try await matrixContext(w)
        try w.write("Kaynak/var.txt", "var\n")
        let list = try w.write("liste.txt", "var.txt\nyok.txt\n")
        var advanced = AdvancedOptions()
        advanced.filesFromFile = list.path
        var job = TransferJob(source: w.url("Kaynak"), destination: try w.mkdir("Hedef"), options: CopyOptions(copyMode: .contents, advanced: advanced))
        let result = await run(&job, context)
        #expect(result.kind == .sourceFilesVanished, "\(result)")
        #expect(files(w.url("Hedef")) == ["var.txt": "var\n"])
    }

    /// Finder'da kilitli (uchg) bir hedef dosya değiştirilemez: "değiştir" seçilse de o dosya olduğu gibi kalır, iş başarı
    /// sayılmaz, öbür dosyalar kopyalanır. (Salt okunur bir klasör engel değildir: rsync sahibi olduğu klasöre yazmak için
    /// izni geçici olarak açar.)
    @Test(.enabled(if: live))
    func destructiveLockedDestinationFileIsNeverReplaced() async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, _) = try await matrixContext(w)
        try w.write("Kaynak/kilitli.txt", "yeni\n")
        try w.write("Kaynak/serbest.txt", "serbest\n")
        let locked = try w.write("Hedef/kilitli.txt", "eski içerik\n")
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(locked.path, 0) }
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"), options: CopyOptions(copyMode: .contents, conflictPolicy: .replace))
        let result = await run(&job, context)
        #expect(!result.kind.isSuccess, "\(result)")
        #expect(files(w.url("Hedef")) == ["kilitli.txt": "eski içerik\n", "serbest.txt": "serbest\n"])
    }

    // MARK: 04 Sızma

    /// Hedefe yerleştirilmiş bağlantılar ("rapor 2.txt" → dışarıdaki bir dosya, "rapor 3.txt" → olmayan bir dosya)
    /// numaralı kopya için izlenmez: dolu adlar atlanır, dışarıdaki dosyalar değişmez, bağlantılar yerinde kalır.
    @Test(.enabled(if: live), arguments: [true, false])
    func penetrationKeepBothNeverFollowsPlantedLinks(sandboxed: Bool) async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, _) = try await matrixContext(w, sandboxed: sandboxed)
        try w.write("Kaynak/rapor.txt", "yeni\n")
        try w.write("Hedef/rapor.txt", "eski\n")
        let secret = try w.write("Disari/gizli.txt", "gizli\n")
        try FileManager.default.createSymbolicLink(atPath: w.url("Hedef/rapor 2.txt").path, withDestinationPath: secret.path)
        try FileManager.default.createSymbolicLink(atPath: w.url("Hedef/rapor 3.txt").path, withDestinationPath: w.url("Disari/yok.txt").path)
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"), options: CopyOptions(copyMode: .contents, conflictPolicy: .keepBoth))
        let result = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result) \(job.log.suffix(5))")
        #expect(w.read("Hedef/rapor 4.txt") == "yeni\n")
        #expect(w.read("Hedef/rapor.txt") == "eski\n")
        #expect(files(w.url("Disari")) == ["gizli.txt": "gizli\n"])
        #expect(isLink(w.url("Hedef/rapor 2.txt")) && isLink(w.url("Hedef/rapor 3.txt")))
    }

    /// Hedefte kaynak klasörle aynı adlı bir bağlantı dışarıyı gösterir: bu bir çakışmadır (rsync bağlantıyı sessizce
    /// silerdi); "ikisini de sakla" bağlantıyı numaralı adla saklar, klasörü yerine kopyalar, dışarıya hiçbir şey yazılmaz.
    @Test(.enabled(if: live), arguments: [true, false])
    func penetrationLinkedDestinationFolderIsNeverWrittenThrough(sandboxed: Bool) async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, _) = try await matrixContext(w, sandboxed: sandboxed)
        try w.write("Kaynak/alt/rapor.txt", "yeni\n")
        let outside = try w.mkdir("Disari")
        try w.write("Disari/rapor.txt", "dışarıdaki\n")
        try w.mkdir("Hedef")
        try FileManager.default.createSymbolicLink(atPath: w.url("Hedef/alt").path, withDestinationPath: outside.path)
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"), options: CopyOptions(copyMode: .contents))
        #expect(await run(&job, context).kind == .awaitingDecision)
        #expect(job.pendingConflicts?.items == [FileConflict(path: "alt", identical: false, incomingFolder: true)])

        job.conflictResolution = ConflictResolution(others: .keepBoth)
        let result = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result) \(job.log.suffix(5))")
        #expect(files(outside) == ["rapor.txt": "dışarıdaki\n"])
        #expect(!isLink(w.url("Hedef/alt")) && w.read("Hedef/alt/rapor.txt") == "yeni\n")
        #expect(isLink(w.url("Hedef/alt 2")))
        #expect(hasLog(job, .logKeptBothRenamed))
    }

    /// İnternetten inmiş bir dosyanın numaralı kopyası da karantina işaretini taşır (öznitelikler kopyalansa da
    /// kopyalanmasa da); yoksa kopya Gatekeeper denetimi olmadan açılırdı.
    @Test(.enabled(if: live), arguments: [true, false])
    func penetrationQuarantineReachesNumberedCopies(extendedAttributes: Bool) async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, _) = try await matrixContext(w)
        let script = try w.write("Kaynak/kur.command", "echo merhaba\n")
        let value = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));Safari;"
        #expect(Quarantine.set(value, on: script))
        try w.write("Hedef/kur.command", "eski\n")
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"),
                              options: CopyOptions(copyMode: .contents, preserveExtendedAttributes: extendedAttributes, conflictPolicy: .keepBoth))
        let result = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result) \(job.log.suffix(5))")
        #expect(w.read("Hedef/kur 2.command") == "echo merhaba\n")
        #expect(Quarantine.value(of: w.url("Hedef/kur 2.command"))?.hasPrefix("0083;") == true)
    }

    // MARK: 05 Yük

    /// Binlerce değişiklik satırı ve on binlerce ilerleme kaydı: günlük sınırda kalır, ilerleme olayları seyreltilir
    /// (gönderilen olay sayısı geçen sürenin aralığa bölümünü aşmaz).
    @Test(.enabled(if: live))
    func loadChangeLinesAndProgressFloodStayBounded() async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, _) = try await matrixContext(w)
        let source = try w.mkdir("Kaynak")
        for index in 0..<3000 {
            FileManager.default.createFile(atPath: source.appendingPathComponent("f\(index).txt").path, contents: Data("\(index)\n".utf8))
        }
        var advanced = AdvancedOptions()
        advanced.logChanges = true
        var job = TransferJob(source: source, destination: try w.mkdir("Hedef"), options: CopyOptions(copyMode: .contents, advanced: advanced))
        let result = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result)")
        #expect(files(w.url("Hedef")).count == 3000)
        #expect(job.log.count <= TransferJob.maxLogEntries)

        let sent = Collected<TransferEvent>()
        let throttle = ProgressThrottle(interval: RsyncEngine.progressInterval) { sent.add($0) }
        let started = Date()
        for index in 0..<20_000 {
            throttle.offer(TransferProgress(bytesTransferred: Int64(index), fraction: Double(index) / 20_000, filesTransferred: index))
        }
        throttle.flush()
        let windows = Int(Date().timeIntervalSince(started) / RsyncEngine.progressInterval)
        #expect(sent.values.count <= windows + 3, "\(sent.values.count) olay, \(windows) aralık")
        if case .progress(let last)? = sent.values.last { #expect(last.filesTransferred == 19_999) } else { Issue.record("son ilerleme yok") }
    }

    // MARK: 06 Hacim

    /// Çok büyük sayılı ölçütler ("son 10^19 gün içinde", 10^300 TB) tuzağa düşmez (taşma çökmesi yok) ve anlamlı sonuç verir.
    @Test func volumeHugeRuleNumbersNeverTrap() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let item = RuleItem(relativePath: "a/b/c.txt", metadata: .init(size: 10, modified: now.addingTimeInterval(-86_400),
                                                                      media: MediaInfo(pixelWidth: 10, pixelHeight: 10, duration: 5)))
        func holds(_ condition: RuleCondition) throws -> Bool {
            try RuleEvaluator(RuleGroup(conditions: [condition]), now: now, calendar: Calendar(identifier: .gregorian)).matches(item)
        }
        for unit in [RuleUnit.days, .weeks, .months, .years] {
            for number in [1e19, 9.3e18, Double(Int.max), 1e300, .greatestFiniteMagnitude] {
                #expect(try holds(RuleCondition(attribute: .modified, op: .withinLast, number: number, unit: unit)))
                #expect(try !holds(RuleCondition(attribute: .modified, op: .notWithinLast, number: number, unit: unit)))
            }
        }
        #expect(try !holds(RuleCondition(attribute: .size, op: .greaterThan, number: 1e300, unit: .terabytes)))
        #expect(try holds(RuleCondition(attribute: .size, op: .lessThan, number: .greatestFiniteMagnitude, unit: .terabytes)))
        #expect(try holds(RuleCondition(attribute: .depth, op: .atMost, number: 1e308)))
        #expect(try holds(RuleCondition(attribute: .duration, op: .lessThan, number: 1e308, unit: .hours)))
        #expect(try !holds(RuleCondition(attribute: .resolution, op: .greaterThan, number: 1e308)))
    }

    /// Bozuk bir videonun sonsuz, NaN ya da devasa boyutu piksel sayısına çevrilirken çökertmez.
    @Test func volumeMediaPixelSizesAreRangeChecked() {
        #expect(MediaInfo.pixels(.nan) == nil)
        #expect(MediaInfo.pixels(.infinity) == nil)
        #expect(MediaInfo.pixels(-.infinity) == nil)
        #expect(MediaInfo.pixels(1e30) == nil)
        #expect(MediaInfo.pixels(-1280.4) == 1280)
        #expect(MediaInfo.pixels(0) == 0)
    }

    /// Exabaytlarca görünen (seyrek) bir kaynak: toplam taşmadan en büyük değere doyar ve iş rsync başlamadan "hedef dolu"
    /// olarak durur; hedefe hiçbir şey yazılmaz.
    @Test(.enabled(if: live))
    func volumeExabyteSourceIsRefusedBeforeCopying() async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, scratch) = try await matrixContext(w)
        let source = try w.mkdir("Kaynak")
        // 8200 × (2^50 − 1) bayt > Int64.max: toplam doymazsa taşma tuzağı çökertirdi.
        for index in 0..<8200 {
            let url = source.appendingPathComponent("seyrek\(index).bin")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: (1 << 50) - 1)
            try handle.close()
        }
        var job = TransferJob(source: source, destination: try w.mkdir("Hedef"), options: CopyOptions(copyMode: .contents))
        let result = await run(&job, context)
        #expect(result.kind == .destinationFull, "\(result)")
        #expect(result.requiredBytes == .max)
        #expect(entries(w.url("Hedef")).isEmpty)
        #expect(entries(scratch).isEmpty)
    }

    // MARK: 07 Dayanıklılık

    /// Aynı iş art arda 20 kez (kurallar, dosya dosya kararlar, numaralı kopyalar, doğrulama): her turdan sonra geçici
    /// klasör boş, testin klasöründe açık dosya tanımlayıcısı yok; numaralı kopyalar birbirinin üzerine yazılmaz.
    @Test(.enabled(if: live))
    func enduranceRepeatedRunsLeaveNothingBehind() async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, scratch) = try await matrixContext(w)
        try w.write("Kaynak/rapor.txt", "ilk\n")
        try w.write("Kaynak/not.txt", "ilk not\n")
        try w.write("Kaynak/alt/veri.txt", "veri 0\n")
        try w.write("Kaynak/resim.png", "png\n")
        try w.write("Hedef/rapor.txt", "hedefteki rapor\n")
        try w.write("Hedef/not.txt", "hedefteki not\n")
        let rules = RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .isOneOf, value: "txt")])
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"),
                              options: CopyOptions(copyMode: .contents, verifyAfterCopy: .quick, rules: rules))
        let cycles = 20
        for cycle in 1...cycles {
            try w.write("Kaynak/rapor.txt", "sürüm \(cycle)\n")
            try w.write("Kaynak/alt/veri.txt", "veri " + String(repeating: "+", count: cycle) + "\n")
            job.conflictResolution = ConflictResolution(decisions: ["rapor.txt": .keepBoth, "not.txt": .skip], others: .replace)
            let result = await run(&job, context)
            #expect(result.kind == .succeeded, "tur \(cycle): \(result) \(job.log.suffix(5))")
            #expect(entries(scratch).isEmpty, "tur \(cycle)")
            #expect(openDescriptors(under: w.root).isEmpty, "tur \(cycle)")
        }
        let copied = files(w.url("Hedef"))
        for number in 2...(cycles + 1) { #expect(copied["rapor \(number).txt"] == "sürüm \(number - 1)\n") }
        #expect(copied["rapor.txt"] == "hedefteki rapor\n")
        #expect(copied["not.txt"] == "hedefteki not\n")
        #expect(copied["alt/veri.txt"] == "veri " + String(repeating: "+", count: cycles) + "\n")
        #expect(copied["resim.png"] == nil)
        #expect(copied.count == cycles + 3)
    }

    // MARK: 08 Zafiyet

    /// Geri izlemesi katlanarak büyüyen bir düzenli ifade ("(a+)+$") taramayı kilitlemez: adım sınırında durdurulur ve
    /// bildirilir. Olağan ifadeler uzun yollarda bile sınıra yaklaşmaz.
    @Test(.timeLimit(.minutes(1)))
    func vulnerabilityRunawayRegexIsStoppedNotHung() throws {
        let runaway = try RuleEvaluator(RuleGroup(conditions: [RuleCondition(attribute: .name, op: .matchesRegex, value: "^(a+)+$")]))
        #expect(!runaway.matches(RuleItem(relativePath: String(repeating: "a", count: 40) + "b")))
        #expect(runaway.runawayPattern == "^(a+)+$")

        let ordinary = try RuleEvaluator(RuleGroup(conditions: [RuleCondition(attribute: .path, op: .matchesRegex, value: #"rapor[0-9]+\.pdf$"#)]))
        #expect(!ordinary.matches(RuleItem(relativePath: String(repeating: "klasör/", count: 140) + "x.txt")))
        #expect(ordinary.matches(RuleItem(relativePath: "a/b/rapor12.pdf")))
        let typical = try RuleEvaluator(RuleGroup(conditions: [
            RuleCondition(attribute: .name, op: .matchesRegex, value: #"^[a-z_]+_\d{4}-\d{2}-\d{2}_v\d+\.xlsx?$"#),
        ]))
        #expect(typical.matches(RuleItem(relativePath: "satis_raporu_2026-10-22_v3.xlsx")))
        #expect(ordinary.runawayPattern == nil && typical.runawayPattern == nil)
    }

    /// Aynı ifadeyle çalışan iş asılı kalmaz: tarama hatayla biter, günlükte açıklanır, hedefe ve geçici klasöre hiçbir şey
    /// yazılmaz.
    @Test(.enabled(if: live), .timeLimit(.minutes(1)))
    func vulnerabilityRunawayRegexFailsTheJobCleanly() async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, scratch) = try await matrixContext(w)
        try w.write("Kaynak/" + String(repeating: "a", count: 40) + "b", "x\n")
        try w.write("Kaynak/normal.txt", "y\n")
        let rules = RuleGroup(conditions: [RuleCondition(attribute: .name, op: .matchesRegex, value: "^(a+)+$")])
        var job = TransferJob(source: w.url("Kaynak"), destination: try w.mkdir("Hedef"), options: CopyOptions(copyMode: .contents, rules: rules))
        let result = await run(&job, context)
        #expect(result.kind == .failed && result.detail == "^(a+)+$", "\(result)")
        #expect(hasLog(job, .logRuleRegexTooComplex))
        #expect(entries(w.url("Hedef")).isEmpty)
        #expect(entries(scratch).isEmpty)
        let preview = await RsyncEngine().verify(job, context: context, checksum: false)
        #expect(preview.result.kind == .failed)
    }

    /// Seçenek gibi görünen dosya adları ("--delete", "-e", "--rsync-path=…") yalnızca dosyadır: aynı adlı dosya kararı
    /// ve numaralı kopya dahil hiçbiri rsync'e seçenek olarak geçmez; hedefteki fazla dosya silinmez.
    @Test(.enabled(if: live))
    func vulnerabilityOptionLikeNamesStayFiles() async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, _) = try await matrixContext(w)
        let names = ["--delete", "-e", "--rsync-path=sahte", "-n.txt", "--files-from=liste"]
        for name in names { try w.write("Kaynak/" + name, "yeni \(name)\n") }
        try w.write("Hedef/--delete", "eski\n")
        try w.write("Hedef/fazla.txt", "fazla\n")
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"), options: CopyOptions(copyMode: .contents, conflictPolicy: .keepBoth))
        let result = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result) \(job.log.suffix(5))")
        var expected = Dictionary(uniqueKeysWithValues: names.map { ($0, "yeni \($0)\n") })
        expected["--delete"] = "eski\n"
        expected["--delete 2"] = "yeni --delete\n"
        expected["fazla.txt"] = "fazla\n"
        #expect(files(w.url("Hedef")) == expected)
    }

    // MARK: 09 Kırmızı Takım

    /// Joker karakter ve kaçış içeren adlar ("*.txt", "[ab].txt", "a?c.txt", ters bölü, satır sonu, "**") atlanınca
    /// yalnızca kendileri dışlanır: kalıp olarak yorumlansalardı "a.txt", "b.txt", "abc.txt", "x" de dışlanırdı.
    @Test(.enabled(if: live))
    func redTeamWildcardNamesAreExcludedLiterally() async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, _) = try await matrixContext(w)
        let skipped = ["*.txt", "[ab].txt", "a?c.txt", "ters\\bölü.txt", "satır\nsonu.txt", "**"]
        let replaced = ["a.txt", "b.txt", "abc.txt", "tersbölü.txt", "satırsonu.txt", "x"]
        for name in skipped + replaced {
            try w.write("Kaynak/" + name, "yeni\n")
            try w.write("Hedef/" + name, "eski içerik\n")
        }
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"), options: CopyOptions(copyMode: .contents))
        #expect(await run(&job, context).kind == .awaitingDecision)
        #expect(Set(job.pendingConflicts?.items.map(\.path) ?? []) == Set((skipped + replaced).map { $0.precomposedStringWithCanonicalMapping }))
        let decisions = job.pendingConflicts?.items.filter { item in skipped.contains { $0.precomposedStringWithCanonicalMapping == item.path } }
            .map { ($0.path, ConflictDecision.skip) } ?? []
        job.conflictResolution = ConflictResolution(decisions: Dictionary(uniqueKeysWithValues: decisions), others: .replace)
        let result = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result) \(job.log.suffix(5))")
        let copied = files(w.url("Hedef"))
        for name in skipped { #expect(copied[name.precomposedStringWithCanonicalMapping] == "eski içerik\n", "\(name)") }
        for name in replaced { #expect(copied[name.precomposedStringWithCanonicalMapping] == "yeni\n", "\(name)") }
    }

    /// Gelen öğe hedefte başka türde, aynı adlı bir öğenin yerine geçecekse (klasör ↔ dosya, dosya ↔ boş klasör, dosya ↔
    /// bağlantı) rsync oradakini sessizce silerdi: bunlar da sorulur ve her karar tam olarak uygulanır.
    @Test(.enabled(if: live), arguments: ConflictDecision.allCases)
    func redTeamItemsOfAnotherTypeAreAskedAbout(decision: ConflictDecision) async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, _) = try await matrixContext(w)
        try w.write("Kaynak/belgeler/x.txt", "yeni klasördeki\n")
        try w.write("Kaynak/bos", "yeni dosya\n")
        try w.write("Kaynak/baglanti.txt", "yeni bağlantı yerine\n")
        try w.write("Hedef/belgeler", "önemli dosya\n")
        try w.mkdir("Hedef/bos")
        let target = try w.write("Disari/hedef.txt", "bağlantının gösterdiği\n")
        try FileManager.default.createSymbolicLink(atPath: w.url("Hedef/baglanti.txt").path, withDestinationPath: target.path)

        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"), options: CopyOptions(copyMode: .contents))
        #expect(await run(&job, context).kind == .awaitingDecision)
        #expect(Set(job.pendingConflicts?.items ?? []) == [
            FileConflict(path: "belgeler", identical: false, incomingFolder: true),
            FileConflict(path: "bos", identical: false),
            FileConflict(path: "baglanti.txt", identical: false),
        ])
        #expect(w.read("Hedef/belgeler") == "önemli dosya\n")

        job.conflictResolution = ConflictResolution(others: decision)
        let result = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result) \(job.log.suffix(5))")
        let copied = files(w.url("Hedef"))
        switch decision {
        case .replace:
            #expect(copied == ["belgeler/x.txt": "yeni klasördeki\n", "bos": "yeni dosya\n", "baglanti.txt": "yeni bağlantı yerine\n"])
        case .keepBoth:
            #expect(copied == ["belgeler/x.txt": "yeni klasördeki\n", "belgeler 2": "önemli dosya\n", "bos 2": "yeni dosya\n",
                               "baglanti 2.txt": "yeni bağlantı yerine\n"])
            #expect(entries(w.url("Hedef/bos")).isEmpty && isLink(w.url("Hedef/baglanti.txt")))
        case .skip:
            #expect(copied == ["belgeler": "önemli dosya\n"])
            #expect(entries(w.url("Hedef/bos")).isEmpty && isLink(w.url("Hedef/baglanti.txt")))
        }
        #expect(files(w.url("Disari")) == ["hedef.txt": "bağlantının gösterdiği\n"])
    }

    /// Hedef kaynağın içindeyse (doğrudan ya da bir bağlantı üzerinden) iş hiç başlamaz: aksi hâlde her çalıştırma
    /// önceki kopyayı yeniden kopyalayıp iç içe büyürdü.
    @Test(.enabled(if: live))
    func redTeamDestinationInsideTheSourceIsRefused() async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, scratch) = try await matrixContext(w)
        try w.write("Kaynak/rapor.txt", "rapor\n")
        try w.mkdir("Kaynak/Yedek")
        try FileManager.default.createSymbolicLink(atPath: w.url("Yedek-baglanti").path, withDestinationPath: w.url("Kaynak/Yedek").path)
        let rules = RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "txt")])
        for destination in [w.url("Kaynak/Yedek"), w.url("Yedek-baglanti"), w.url("Kaynak")] {
            var job = TransferJob(source: w.url("Kaynak"), destination: destination, options: CopyOptions(copyMode: .contents, rules: rules))
            #expect(await run(&job, context).kind == .overlapping, "\(destination.lastPathComponent)")
        }
        #expect(entries(w.url("Kaynak/Yedek")).isEmpty)
        #expect(entries(scratch).isEmpty)
    }

    // MARK: 10 Fuzz

    /// `-ii` çıktısı bozulsa da (rastgele kodlar, kesik satırlar, kaçışlar) aynı adlı dosya ayrıştırıcısı çökmez, boş ya
    /// da "/" ile biten yol üretmez, satır sayısından fazla çakışma bulmaz ve her seferinde aynı sonucu verir.
    @Test(arguments: [UInt64(11), 0xC0FFEE, 0xDEC0DE])
    func fuzzDryRunOutputNeverInventsConflicts(seed: UInt64) {
        var generator = SplitMix64(seed: seed)
        let codes = [".f         ", ">f.st......", ">f+++++++++", "cd+++++++++", ".d..t......", "cL+++++++++", "*deleting  ", "<f+++++++++",
                     ".f       ", ">f+++++++", "cd+++++++", "hf+++++++++", "", "??", ".f", "cS+++++++++", ">fcsTpoguax"]
        let paths = ["rapor.txt", "a/b/c.txt", "alt/", "./", "\\#012satır", "bağlantı -> hedef", " ", "", "a\\#", "//", "-n", "*", "ğüş/ıöç.txt"]
        for format in [ItemizeParser.Format.rsync3, .openrsync] {
            for _ in 0..<300 {
                var lines: [String] = []
                for _ in 0..<Int(generator.next() % 12) {
                    var line = codes[Int(generator.next() % UInt64(codes.count))]
                    if generator.next() % 3 > 0 { line += " " }
                    line += paths[Int(generator.next() % UInt64(paths.count))]
                    if generator.next() % 7 == 0 { line = String(line.prefix(Int(generator.next() % UInt64(line.count + 1)))) }
                    lines.append(line)
                }
                let output = lines.joined(separator: generator.next() % 2 == 0 ? "\n" : "\r")
                let existing = generator.next() % 2 == 0
                let first = ConflictDetector.conflicts(in: output, format: format) { _ in existing }
                let second = ConflictDetector.conflicts(in: output, format: format) { _ in existing }
                #expect(first == second)
                #expect(first.count <= lines.count)
                #expect(first.allSatisfy { !$0.path.isEmpty && !$0.path.hasSuffix("/") && $0.path != "." })
                #expect(ConflictDetector.conflicts(in: output, format: format).allSatisfy { !$0.incomingFolder })
            }
        }
    }

    /// Rastgele kurallar ve öğelerle kural cebiri: Hiçbiri = Herhangi biri'nin değili, Tümü = koşulların hepsi, Herhangi
    /// biri = en az biri, iç içe Tümü düzleştirilmiş Tümü'ye eşit. Değerlendirici hiçbir girdide çökmez.
    @Test(arguments: [UInt64(5), 77, 0xFACADE])
    func fuzzRuleAlgebraHolds(seed: UInt64) throws {
        var generator = SplitMix64(seed: seed)
        let words = ["rapor", "RAPOR", "ı", "İ", "i", "I", ".txt", "txt", "jpg, png", "a", "", " ", "klasör", "ğ", "*", "\\", "2026"]
        let regexes = ["^r", "x$", "[0-9]+", "(a|b)c", ".*", "^$"]
        let names = ["rapor.txt", "Rapor.TXT", "İzmir/ısparta.jpg", "a/b/c/d.png", ".gizli", "klasör/alt/2026.pdf", "x", "ac", "bc.md"]
        func randomCondition() -> RuleCondition {
            let attribute = [RuleAttribute.name, .fileExtension, .folderName, .path, .size, .depth, .hidden, .modified][Int(generator.next() % 8)]
            let operators = attribute.operators
            let op = operators[Int(generator.next() % UInt64(operators.count))]
            let value = op == .matchesRegex ? regexes[Int(generator.next() % UInt64(regexes.count))] : words[Int(generator.next() % UInt64(words.count))]
            return RuleCondition(attribute: attribute, op: op, value: value, number: Double(generator.next() % 5), unit: attribute.units.first)
        }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for _ in 0..<400 {
            let conditions = (0..<(1 + Int(generator.next() % 4))).map { _ in randomCondition() }
            let item = RuleItem(relativePath: names[Int(generator.next() % UInt64(names.count))],
                                metadata: .init(size: Int64(generator.next() % 5_000_000), modified: now.addingTimeInterval(-Double(generator.next() % 10_000_000)),
                                                hiddenFlag: generator.next() % 2 == 0))
            func holds(_ group: RuleGroup) throws -> Bool { try RuleEvaluator(group, now: now).matches(item) }
            let singles = try conditions.map { try holds(RuleGroup(conditions: [$0])) }
            #expect(try holds(RuleGroup(match: .all, conditions: conditions)) == singles.allSatisfy { $0 })
            #expect(try holds(RuleGroup(match: .any, conditions: conditions)) == singles.contains(true))
            #expect(try holds(RuleGroup(match: .none, conditions: conditions)) == !singles.contains(true))
            let nested = RuleGroup(match: .all, conditions: [conditions[0]], groups: [RuleGroup(match: .all, conditions: Array(conditions.dropFirst()))])
            #expect(try holds(nested) == singles.allSatisfy { $0 })
        }
    }

    /// Bozuk rutin dosyası (rastgele bayt değişikliği, silme, ekleme) kayıt deposunu, doğrulamayı ya da kural
    /// değerlendiricisini çökertmez: dosya ya okunamaz ya da okunan rutinler güvenle kullanılabilir.
    @Test(arguments: [UInt64(3), 2024])
    func fuzzDamagedRoutineFilesNeverCrash(seed: UInt64) throws {
        let w = try Workspace("CopiatorMatrix")
        let store = RoutineStore(url: w.url("routines.json"))
        let rules = RuleGroup(match: .any, conditions: [
            RuleCondition(attribute: .name, op: .matchesRegex, value: #"^rapor_\d+\.txt$"#),
            RuleCondition(attribute: .modified, op: .withinLast, number: 7, unit: .days),
            RuleCondition(attribute: .size, op: .greaterThan, number: 5, unit: .megabytes),
        ], groups: [RuleGroup(match: .none, conditions: [RuleCondition(attribute: .folderName, op: .equals, value: "cache")])])
        let routines = (0..<3).map { index in
            Routine(name: "Rutin \(index)", routes: [RoutineRoute(source: w.url("Kaynak"), destination: w.url("Hedef\(index)"), rules: rules)])
        }
        try store.save(routines)
        let original = try Data(contentsOf: store.url)
        var generator = SplitMix64(seed: seed)
        var loaded = 0
        for _ in 0..<300 {
            var bytes = [UInt8](original)
            for _ in 0..<(1 + Int(generator.next() % 4)) {
                let index = Int(generator.next() % UInt64(bytes.count))
                switch generator.next() % 3 {
                case 0: bytes[index] = UInt8(truncatingIfNeeded: generator.next())
                case 1: bytes.remove(at: index)
                default: bytes.insert(UInt8(truncatingIfNeeded: generator.next()), at: index)
                }
            }
            try Data(bytes).write(to: store.url)
            guard let result = try? store.load() else { continue }
            loaded += 1
            for routine in result {
                _ = routine.problems()
                for route in routine.routes {
                    _ = route.rules.problems()
                    if let evaluator = try? RuleEvaluator(route.rules) {
                        _ = evaluator.matches(RuleItem(relativePath: "cache/rapor_1.txt"))
                    }
                }
            }
        }
        #expect(loaded > 0)
    }

    // MARK: 11 Kaos

    /// Aynı adlı dosya denetimi sırasında iptal: SIGTERM'i yok sayan motor da 2 saniye sonra durdurulur, iş iptal olur,
    /// hedefe dokunulmaz, geçici klasör boş kalır, süreç ortada kalmaz.
    @Test(.enabled(if: SandboxProfile.isAvailable), .timeLimit(.minutes(1)))
    func chaosCancelDuringTheConflictCheck() async throws {
        let w = try Workspace("CopiatorMatrix")
        try w.write("Kaynak/rapor.txt", "yeni\n")
        try w.write("Hedef/rapor.txt", "eski\n")
        let log = w.url("Hedef/cagrilar.log")
        let engine = try await decoyEngine(w, log: log, outside: try w.mkdir("Disari"), conflictLine: unchangedLine("rapor.txt"),
                                           hangOnConflictCheck: true)
        let scratch = try w.mkdir("Gecici")
        let context = EngineContext(executable: engine, info: fullEngine, sandboxed: true, scratchDirectory: scratch)
        let job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"), options: CopyOptions(copyMode: .contents))
        let task = Task { await RsyncEngine().run(job, context: context) { _ in } }
        while !(w.read("Hedef/cagrilar.log") ?? "").contains(" -ii ") { try await Task.sleep(for: .milliseconds(20)) }
        task.cancel()
        #expect(await task.value.kind == .cancelled)
        let pid = try #require(Int32((w.read("Hedef/cagrilar.log") ?? "").split(separator: " ").first ?? ""))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(w.read("Hedef/rapor.txt") == "eski\n")
        #expect(entries(scratch).isEmpty)
        #expect(openDescriptors(under: w.root).isEmpty)
    }

    /// Kararın ardından hedefte yeni bir aynı adlı dosya belirir: yalnızca o sorulur, verilmiş karar korunur, hiçbir
    /// dosya sormadan değişmez.
    @Test(.enabled(if: live))
    func chaosNewSameNameFileAfterTheDecisionIsAskedAbout() async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, _) = try await matrixContext(w)
        try w.write("Kaynak/a.txt", "yeni a\n")
        try w.write("Kaynak/b.txt", "yeni b\n")
        try w.write("Hedef/a.txt", "eski a\n")
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"), options: CopyOptions(copyMode: .contents))
        #expect(await run(&job, context).kind == .awaitingDecision)
        #expect(job.pendingConflicts?.items.map(\.path) == ["a.txt"])

        job.conflictResolution = ConflictResolution(decisions: ["a.txt": .skip])
        try w.write("Hedef/b.txt", "başka b\n")
        #expect(await run(&job, context).kind == .awaitingDecision)
        #expect(job.pendingConflicts?.items.map(\.path) == ["b.txt"])
        #expect(files(w.url("Hedef")) == ["a.txt": "eski a\n", "b.txt": "başka b\n"])

        job.conflictResolution?.decisions["b.txt"] = .keepBoth
        let result = await run(&job, context)
        #expect(result.kind == .succeeded, "\(result) \(job.log.suffix(5))")
        #expect(files(w.url("Hedef")) == ["a.txt": "eski a\n", "b.txt": "başka b\n", "b 2.txt": "yeni b\n"])
    }

    /// Aynı kaynaktan dört hedefe eşzamanlı çalışan işler (kurallar, kararlar, numaralı kopyalar) birbirinin geçici
    /// listelerine ve sonuçlarına karışmaz: her hedef, aynı işin tek başına çalıştırıldığı hedefle birebir aynıdır.
    @Test(.enabled(if: live))
    func chaosParallelRunsMatchTheSerialResult() async throws {
        let w = try Workspace("CopiatorMatrix")
        let (context, scratch) = try await matrixContext(w)
        var generator = SplitMix64(seed: 0xC4A05)
        for index in 0..<200 {
            let ext = ["txt", "jpg", "md"][Int(generator.next() % 3)]
            try w.write("Kaynak/k\(index % 7)/d\(index).\(ext)", "kaynak \(index)\n")
        }
        let destinations = (0..<5).map { w.url("Hedef\($0)") }
        for destination in destinations {
            for index in stride(from: 0, to: 200, by: 9) {
                for ext in ["txt", "jpg", "md"] {
                    let url = destination.appendingPathComponent("k\(index % 7)/d\(index).\(ext)")
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("hedef \(index)\n".utf8).write(to: url)
                }
            }
        }
        let rules = RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .isOneOf, value: "txt, jpg")])
        func makeJob(_ destination: URL) -> TransferJob {
            var job = TransferJob(source: w.url("Kaynak"), destination: destination, options: CopyOptions(copyMode: .contents, rules: rules))
            job.conflictResolution = ConflictResolution(decisions: ["k0/d0.txt": .skip, "k1/d36.jpg": .keepBoth], others: .keepBoth)
            return job
        }
        var serial = makeJob(destinations[0])
        #expect(await run(&serial, context).kind == .succeeded)
        let expected = files(destinations[0])

        let jobs = destinations.dropFirst().map(makeJob)
        let results = await withTaskGroup(of: JobResultKind.self) { group in
            for job in jobs {
                group.addTask {
                    var job = job
                    return await run(&job, context).kind
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results == Array(repeating: .succeeded, count: 4))
        for destination in destinations.dropFirst() { #expect(files(destination) == expected, "\(destination.lastPathComponent)") }
        #expect(entries(scratch).isEmpty)
    }
}
