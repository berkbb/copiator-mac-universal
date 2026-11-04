// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

// MARK: - İlerleme (--info=progress2)

/// Gerçek rsync 3.5.1 çıktısından alınmış satırlar.
@Test func parsesProgress2LineWithToCheck() throws {
    let progress = try #require(RsyncProgressParser.parse("         29.70K  81%    0.61kB/s    0:00:47 (xfr#4801, to-chk=1199/6041)"))
    #expect(progress.bytesTransferred == 29_700)
    #expect(progress.fraction == 0.81)
    #expect(progress.bytesPerSecond == 0.61 * 1024)
    #expect(progress.remainingSeconds == 47)
    #expect(progress.filesTransferred == 4801)
    #expect(progress.itemsRemaining == 1199)
    #expect(progress.itemsTotal == 6041)
    #expect(progress.itemsChecked == 4842)
    #expect(!progress.isEstimating)
}

/// `ir-chk`: dosya listesi hâlâ taranıyor; toplam kesin değil.
@Test func incrementalRecursionMarksEstimate() throws {
    let progress = try #require(RsyncProgressParser.parse("              0   0%    0.00kB/s    0:00:00 (xfr#0, ir-chk=1050/1091)"))
    #expect(progress.isEstimating)
    #expect(progress.bytesTransferred == 0)
    #expect(progress.itemsTotal == 1091)
}

@Test func parsesProgressWithoutTransferGroup() throws {
    let progress = try #require(RsyncProgressParser.parse("              8   0%    0.00kB/s    0:00:00  "))
    #expect(progress.bytesTransferred == 8)
    #expect(progress.itemsTotal == nil)
    #expect(progress.filesTransferred == 0)
}

@Test(arguments: [
    ("209.72M", Int64(209_720_000)), ("1.02G", Int64(1_020_000_000)), ("3.10T", Int64(3_100_000_000_000)),
    ("1,234,567", Int64(1_234_567)), ("1.234.567", Int64(1_234_567)), ("0", Int64(0)), ("999", Int64(999)),
])
func parsesByteCounts(token: String, expected: Int64) {
    #expect(RsyncProgressParser.parseBytes(token) == expected)
}

@Test func parsesRatesInBinaryUnits() {
    #expect(RsyncProgressParser.parseRate("624.90MB/s") == 624.90 * 1024 * 1024)
    #expect(RsyncProgressParser.parseRate("1.50GB/s") == 1.5 * 1024 * 1024 * 1024)
    #expect(RsyncProgressParser.parseRate("12.0") == nil)
}

@Test func parsesDurationsAndUnknownTime() {
    #expect(RsyncProgressParser.parseDuration("0:00:47") == 47)
    #expect(RsyncProgressParser.parseDuration("123:04:05") == 123 * 3600 + 4 * 60 + 5)
    #expect(RsyncProgressParser.parseDuration("??:??:??") == nil)
    #expect(RsyncProgressParser.parseDuration("1:61:00") == nil)
}

@Test(arguments: [
    "sending incremental file list", "src/d1/f1", ">f+++++++++ src/a", "", "   ", "50% done",
    "rsync error: some files/attrs were not transferred", "abc 10% 1.0kB/s 0:00:01",
])
func ignoresNonProgressLines(line: String) {
    #expect(RsyncProgressParser.parse(line) == nil)
}

// MARK: - Fark listesi (-i)

@Test func parsesItemizeOutputFromRealDryRun() {
    let output = """
    *deleting   src/extradir/
    *deleting   src/extra.txt
    .d..t...... src/
    >f.st...... src/d1/f1
    .d..t...... src/d2/
    >f+++++++++ src/d2/f2
    cd+++++++++ src/new/
    cL+++++++++ src/link -> target
    >fcs....... src/sum.bin
    .f....og... src/owned
    """
    let entries = ItemizeParser.parse(output)
    #expect(entries.map(\.kind) == [.extra, .extra, .attributes, .changed, .attributes, .missing, .missing, .missing, .changed, .attributes])
    #expect(entries[0].path == "src/extradir" && entries[0].isDirectory)
    #expect(entries[5].path == "src/d2/f2" && !entries[5].isDirectory)
    #expect(entries[7].path == "src/link")
    #expect(entries[6].isDirectory)
}

@Test func unchangedItemizeLinesAreSkipped() {
    #expect(ItemizeParser.parseLine(".f          src/same") == nil)
    #expect(ItemizeParser.parseLine("sending incremental file list") == nil)
    #expect(ItemizeParser.parseLine(".d          ./") == nil)
}

/// rsync yazdırılamayan baytları "\#ooo" olarak kaçışlar; satır sonu içeren bir ad tek giriş olarak okunur.
@Test func unescapesOctalNames() {
    #expect(ItemizeParser.unescape("a\\#012b") == "a\nb")
    #expect(ItemizeParser.unescape("\\#303\\#274") == "ü")
    #expect(ItemizeParser.unescape("yarım\\#01") == "yarım\\#01")
    #expect(ItemizeParser.unescape("\\#999") == "\\#999")
    let entry = ItemizeParser.parseLine(">f+++++++++ satır\\#012sonu.txt")
    #expect(entry?.path == "satır\nsonu.txt")
}

// MARK: - Çıkış kodları

@Test func classifiesSuccessCancelAndVanished() {
    #expect(RsyncOutcome.classify(exitCode: 0, stderr: "", destinationFileSystem: .apfs).kind == .succeeded)
    #expect(RsyncOutcome.classify(exitCode: 20, stderr: "rsync error: received SIGINT, SIGTERM, or SIGHUP (code 20)", destinationFileSystem: .apfs).kind == .cancelled)
    let vanished = RsyncOutcome.classify(
        exitCode: 24, stderr: "file has vanished: \"/a/tmp.log\"\nrsync warning: some files vanished before they could be transferred (code 24)",
        destinationFileSystem: .apfs
    )
    #expect(vanished.kind == .sourceFilesVanished)
    #expect(vanished.kind.isSuccess)
}

/// Gerçek rsync çıktısı: salt okunur bir hedef klasöre yazma.
@Test func classifiesPermissionDenied() {
    let stderr = """
    rsync: [generator] recv_generator: mkdir "/x/ro/src" failed: Permission denied (13)
    *** Skipping any contents from this failed directory ***
    rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1412) [sender=3.5.1]
    """
    let result = RsyncOutcome.classify(exitCode: 23, stderr: stderr, destinationFileSystem: .apfs)
    #expect(result.kind == .permissionDenied)
    #expect(!result.kind.isSuccess)
}

@Test func classifiesMissingSource() {
    let stderr = """
    rsync: [sender] link_stat "/x/nope" failed: No such file or directory (2)
    rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1412) [sender=3.5.1]
    """
    #expect(RsyncOutcome.classify(exitCode: 23, stderr: stderr, destinationFileSystem: .apfs).kind == .sourceMissing)
}

@Test func classifiesFullAndReadOnlyDestinations() {
    let full = "rsync: [receiver] write failed on \"/Volumes/USB/big.iso\": No space left on device (28)\nrsync error: error in file IO (code 11)"
    #expect(RsyncOutcome.classify(exitCode: 11, stderr: full, destinationFileSystem: .exfat).kind == .destinationFull)
    let readOnly = "rsync: [receiver] mkstemp \"/Volumes/RO/.a.X\" failed: Read-only file system (30)\nrsync error: some files/attrs were not transferred (code 23)"
    #expect(RsyncOutcome.classify(exitCode: 23, stderr: readOnly, destinationFileSystem: .apfs).kind == .destinationReadOnly)
}

/// Adında hata metni geçen dosya yanlış sınıflandırılmaz: yalnızca satır sonundaki errno metnine bakılır.
@Test func fileNamesDoNotFakeErrorClasses() {
    let stderr = "rsync: [receiver] open \"/x/No space left on device (28).txt\" failed: Permission denied (13)\nrsync error: (code 23)"
    #expect(RsyncOutcome.classify(exitCode: 23, stderr: stderr, destinationFileSystem: .apfs).kind == .permissionDenied)
    // FAT hedefte "chown " ile başlayan bir dosya adının yazılamaması zararsız SAYILMAZ.
    let fat = "rsync: [receiver] mkstemp \"/Volumes/USB/chown notlar.txt\" failed: Input/output error (5)\nrsync error: (code 23)"
    #expect(RsyncOutcome.classify(exitCode: 23, stderr: fat, destinationFileSystem: .fat).kind == .partial)
}

/// exFAT/FAT hedefin saklayamadığı öznitelik uyarıları zararsızdır ve tek bir bilgi satırına indirgenir.
@Test func attributeWarningsAreHarmlessOnlyOnFatLikeVolumes() {
    let stderr = """
    rsync: [generator] failed to set times on "/Volumes/USB/a": Operation not permitted (1)
    rsync: [receiver] failed to set permissions on "/Volumes/USB/b": Operation not permitted (1)
    rsync: [receiver] chown "/Volumes/USB/c" failed: Operation not permitted (1)
    rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1412) [sender=3.5.1]
    """
    let fat = RsyncOutcome.classify(exitCode: 23, stderr: stderr, destinationFileSystem: .exfat)
    #expect(fat.kind == .succeededWithNotes)
    #expect(fat.noteCount == 3)
    #expect(RsyncOutcome.errorLines(in: stderr, destinationFileSystem: .exfat).isEmpty)
    // APFS'te aynı uyarılar gerçek bir sorundur.
    #expect(RsyncOutcome.classify(exitCode: 23, stderr: stderr, destinationFileSystem: .apfs).kind == .permissionDenied)
    // Zararsızların yanında gerçek bir hata varsa iş başarılı sayılmaz.
    let mixed = stderr + "\nrsync: [receiver] write failed on \"/Volumes/USB/d\": Input/output error (5)"
    #expect(RsyncOutcome.classify(exitCode: 23, stderr: mixed, destinationFileSystem: .exfat).kind == .partial)
    #expect(RsyncOutcome.errorLines(in: mixed, destinationFileSystem: .exfat).count == 1)
}

@Test(arguments: [(Int32(1), JobResultKind.unsupported), (2, .unsupported), (4, .unsupported), (3, .sourceMissing),
                  (11, .ioError), (12, .ioError), (30, .ioError), (35, .ioError), (25, .failed), (127, .failed)])
func classifiesOtherExitCodes(code: Int32, kind: JobResultKind) {
    #expect(RsyncOutcome.classify(exitCode: code, stderr: "rsync error: x", destinationFileSystem: .apfs).kind == kind)
}

// MARK: - Motor sürümü ve seçimi

@Test func parsesRsyncAndOpenrsyncVersions() throws {
    let rsync = try #require(EngineLocator.parse("""
    rsync  version 3.5.1  protocol version 33
    Capabilities:
        64-bit files, 64-bit inums, 64-bit timestamps, 64-bit long ints,
        socketpairs, symlinks, symtimes, hardlinks, hardlink-specials,
        hardlink-symlinks, IPv6, atimes, batchfiles, inplace, append, ACLs,
        xattrs, optional secluded-args, iconv, no prealloc, stop-at, crtimes,
        no IDN
    Optimizations:
        no SIMD-roll
    """))
    #expect(rsync == EngineInfo(version: "3.5.1", isOpenrsync: false, supportsACLs: true, supportsXattrs: true))
    #expect(rsync.supportsProgress2)

    let open = try #require(EngineLocator.parse("openrsync: protocol version 29\nrsync version 2.6.9 compatible"))
    #expect(open.isOpenrsync)
    #expect(open.version == "2.6.9")
    #expect(!open.supportsProgress2)
    #expect(!open.supportsACLs)

    let old = try #require(EngineLocator.parse("rsync  version 3.0.9  protocol version 30\nCapabilities:\n    no ACLs, no xattrs\nOptimizations:"))
    #expect(!old.supportsProgress2)
    #expect(!old.supportsACLs && !old.supportsXattrs)
    #expect(EngineLocator.parse("tar (bsdtar) 3.7.4") == nil)
    #expect(EngineLocator.parse("") == nil)
}

/// Kullanıcının seçtiği her zaman kazanır; yoksa tam özellikli en yeni sürüm; sistem rsync'i yalnızca son çare.
@Test func choosesNewestFullFeaturedEngine() {
    let bundled = URL(fileURLWithPath: "/App/rsync"), brew = URL(fileURLWithPath: "/opt/homebrew/bin/rsync")
    let system = URL(fileURLWithPath: "/usr/bin/rsync"), custom = URL(fileURLWithPath: "/custom/rsync")
    func info(_ version: String, open: Bool = false) -> EngineInfo {
        EngineInfo(version: version, isOpenrsync: open, supportsACLs: !open, supportsXattrs: !open)
    }
    let probed: [(url: URL, info: EngineInfo?)] = [(bundled, info("3.5.1")), (brew, info("3.6.0")), (system, info("2.6.9", open: true))]
    #expect(EngineLocator.choose(probed)?.url == brew)
    #expect(EngineLocator.choose([(bundled, info("3.5.1")), (brew, info("3.5.1"))])?.url == bundled)
    #expect(EngineLocator.choose([(system, info("2.6.9", open: true)), (bundled, nil)])?.url == system)
    // openrsync'in sürüm numarası yüksek olsa bile tam rsync tercih edilir.
    #expect(EngineLocator.choose([(system, info("9.9.9", open: true)), (bundled, info("3.0.0"))])?.url == bundled)
    #expect(EngineLocator.choose([(custom, info("3.0.9")), (brew, info("3.6.0"))], customPath: custom.path)?.url == custom)
    // Seçilen özel rsync çalışmıyorsa en iyisine düşülür.
    #expect(EngineLocator.choose([(custom, nil), (brew, info("3.6.0"))], customPath: custom.path)?.url == brew)
    #expect(EngineLocator.choose([]) == nil)
}

@Test func candidateOrderEndsWithSystemRsync() {
    let managed = URL(fileURLWithPath: "/tmp/managed")
    let candidates = EngineLocator.candidates(customPath: "/custom/rsync", managedDirectory: managed, bundle: .main)
    #expect(candidates.first?.path == "/custom/rsync")
    #expect(candidates.last?.path == "/usr/bin/rsync")
    #expect(candidates.contains { $0.path == "/tmp/managed/rsync" })
    #expect(candidates.contains { $0.path == "/opt/homebrew/bin/rsync" })
    #expect(Set(candidates.map(\.path)).count == candidates.count)
}

@Test func comparesEngineVersions() {
    #expect(EngineLocator.isNewer("3.10.0", than: "3.9.9"))
    #expect(EngineLocator.isNewer("3.5.1", than: "3.5"))
    #expect(!EngineLocator.isNewer("3.5", than: "3.5.0"))
    #expect(EngineLocator.isNewer("3.0.0", than: nil))
}

@Test func parsesUpdaterOutput() {
    let parsed = EngineUpdateResult.parse("LATEST=3.6.0\nCURRENT=3.5.1\nSOURCE=https://github.com/RsyncProject/rsync/releases/tag/v3.6.0\nSTATUS=update-available\n")
    #expect(parsed?.status == .updateAvailable)
    #expect(parsed?.latestVersion == "3.6.0")
    #expect(parsed?.currentVersion == "3.5.1")
    #expect(EngineUpdateResult.parse("CURRENT=none\nSTATUS=up-to-date")?.currentVersion == nil)
    #expect(EngineUpdateResult.parse("STATUS=error\nERROR=command-line-tools-missing")?.errorMessage == "command-line-tools-missing")
    #expect(EngineUpdateResult.parse("garbage") == nil)
    let updater = EngineUpdater(scriptURL: URL(fileURLWithPath: "/a/update-rsync.sh"), currentVersion: "3.5.1")
    #expect(updater.arguments(command: "check") == ["/a/update-rsync.sh", "check", "--current", "3.5.1"])
}

/// macOS'un openrsync'i 9 karakterlik kod yazar ve "*deleting" satırını doldurmaz (gerçek çıktı).
@Test func parsesOpenrsyncItemizeOutput() {
    let output = """
    *deleting eski/
    *deleting fazla.txt
    .f..t.... a.txt
    cL+++++++ bag -> a.txt
    >f+++++++ yeni.txt
    >fcs..... alt/b.txt
    .f        ayni.txt
    """
    let entries = ItemizeParser.parse(output, format: .openrsync)
    #expect(entries.map(\.kind) == [.extra, .extra, .attributes, .missing, .missing, .changed])
    #expect(entries.map(\.path) == ["eski", "fazla.txt", "a.txt", "bag", "yeni.txt", "alt/b.txt"])
    #expect(entries[0].isDirectory)
    #expect(entries[5].code == ">fcs.....")
    // Aynı satırlar rsync 3.x biçimiyle okunursa yanlış ayrılırdı: biçim motora göre seçilir.
    #expect(ItemizeParser.Format(engine: openrsyncEngine) == .openrsync && ItemizeParser.Format(engine: fullEngine) == .rsync3)
    #expect(ItemizeParser.parse(">f+++++++ yeni.txt", format: .rsync3).isEmpty)
}
