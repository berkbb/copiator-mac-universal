// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

private func job(_ source: String = "/Users/x/Fotoğraflar", _ destination: String = "/Volumes/Yedek", options: CopyOptions = CopyOptions()) -> TransferJob {
    TransferJob(source: URL(fileURLWithPath: source), destination: URL(fileURLWithPath: destination), options: options)
}

private func env(_ fs: FileSystemKind = .apfs, engine: EngineInfo = fullEngine, directory: Bool = true, protected: [String] = []) -> RsyncCommand.Environment {
    RsyncCommand.Environment(engine: engine, destinationFileSystem: fs, sourceIsDirectory: directory, protectedPaths: protected)
}

private let systemExcludes = RsyncCommand.systemExclusions.map { "--exclude=\($0)" }

/// Varsayılan yerel kopya: -rltDhX --info=progress2 --partial, sistem klasörleri dışarıda, "--"dan sonra yollar.
@Test func defaultTransferArguments() {
    let arguments = RsyncCommand.transfer(job(), environment: env())
    #expect(arguments == ["-rltDhX", "--info=progress2", "--partial"] + systemExcludes
        + ["--", "/Users/x/Fotoğraflar", "/Volumes/Yedek/"])
}

/// "İçeriğini kopyala" kaynağın sonuna "/" ekler; "klasörün kendisi" eklemez.
@Test func copyModeControlsTrailingSlash() {
    let contents = RsyncCommand.transfer(job(options: CopyOptions(copyMode: .contents)), environment: env())
    #expect(contents.suffix(2) == ["/Users/x/Fotoğraflar/", "/Volumes/Yedek/"])
    let folder = RsyncCommand.transfer(job("/Users/x/Fotoğraflar/", "/Volumes/Yedek//"), environment: env())
    #expect(folder.suffix(2) == ["/Users/x/Fotoğraflar", "/Volumes/Yedek/"])
    // Dosya kaynağında kip yok sayılır.
    let file = RsyncCommand.transfer(job("/Users/x/a.txt", options: CopyOptions(copyMode: .contents)), environment: env(directory: false))
    #expect(file.suffix(2) == ["/Users/x/a.txt", "/Volumes/Yedek/"])
    // Kök klasörün içeriği "//" olmaz.
    #expect(RsyncCommand.transfer(job("/", options: CopyOptions(copyMode: .contents)), environment: env()).suffix(2) == ["/", "/Volumes/Yedek/"])
}

@Test func permissionsAddPogA() {
    let options = CopyOptions(preservePermissions: true)
    #expect(RsyncCommand.transfer(job(options: options), environment: env()).contains("-pogA"))
    // ACL desteği olmayan rsync'te yalnızca -pog.
    let noACL = EngineInfo(version: "3.2.7", isOpenrsync: false, supportsACLs: false, supportsXattrs: true)
    let arguments = RsyncCommand.transfer(job(options: options), environment: env(engine: noACL))
    #expect(arguments.contains("-pog") && !arguments.contains("-pogA"))
}

/// exFAT/FAT hedefte -p/-o/-g (ve -A) hiç verilmez; FAT'te zaman penceresi 1 saniyedir.
@Test(arguments: [FileSystemKind.exfat, .fat, .ntfs])
func fatLikeDestinationsDropPermissionFlags(fs: FileSystemKind) {
    let arguments = RsyncCommand.transfer(job(options: CopyOptions(preservePermissions: true)), environment: env(fs))
    #expect(!arguments.contains { $0.hasPrefix("-pog") })
    #expect(arguments.contains("--modify-window=1") == (fs == .fat))
    #expect(arguments.first == "-rltDhX")
}

@Test func extendedAttributesCanBeTurnedOff() {
    let arguments = RsyncCommand.transfer(job(options: CopyOptions(preserveExtendedAttributes: false)), environment: env())
    #expect(arguments.first == "-rltDh")
}

/// --delete yalnızca açıkça seçilince; kaynağı değiştiren bir seçenek hiçbir koşulda üretilmez.
@Test func deleteOnlyWhenChosenAndSourceNeverModified() {
    #expect(!RsyncCommand.transfer(job(), environment: env()).contains("--delete"))
    #expect(RsyncCommand.transfer(job(options: CopyOptions(deleteExtraneous: true)), environment: env()).contains("--delete"))
    for options in [CopyOptions(), CopyOptions(preservePermissions: true, deleteExtraneous: true), CopyOptions(copyMode: .contents, deleteExtraneous: true)] {
        for fs in [FileSystemKind.apfs, .exfat, .fat] {
            for engine in [fullEngine, openrsyncEngine] {
                let all = RsyncCommand.transfer(job(options: options), environment: env(fs, engine: engine))
                    + RsyncCommand.verify(job(options: options), environment: env(fs, engine: engine), checksum: true)
                #expect(!all.contains { $0.contains("remove-source") || $0.contains("remove-sent") })
            }
        }
    }
}

@Test func systemFolderExclusionCanBeTurnedOff() {
    let arguments = RsyncCommand.transfer(job(options: CopyOptions(excludeSystemFolders: false)), environment: env())
    #expect(!arguments.contains { $0.hasPrefix("--exclude=") })
    #expect(RsyncCommand.systemExclusions.contains(".Spotlight-V100"))
    #expect(RsyncCommand.systemExclusions.contains(".fseventsd"))
    #expect(RsyncCommand.systemExclusions.contains(".Trashes"))
    #expect(RsyncCommand.systemExclusions.contains(".TemporaryItems"))
}

/// Kum havuzunun okutmadığı kişisel klasörler aktarım köküne bağlı dışlamalar olur; özel karakterler kaçışlanır.
@Test func protectedPathsBecomeAnchoredExclusions() {
    let options = CopyOptions(excludeSystemFolders: false)
    let folder = RsyncCommand.transfer(job("/Users/x", "/Volumes/Y", options: options), environment: env(protected: [".ssh", "Library/Keychains"]))
    #expect(folder.contains("--exclude=/x/.ssh"))
    #expect(folder.contains("--exclude=/x/Library/Keychains"))
    let contents = RsyncCommand.transfer(job("/Users/x", "/Volumes/Y", options: CopyOptions(copyMode: .contents, excludeSystemFolders: false)),
                                         environment: env(protected: [".ssh"]))
    #expect(contents.contains("--exclude=/.ssh"))
    #expect(RsyncCommand.escapePattern("a*b?[c]\\d") == "a\\*b\\?\\[c]\\\\d")
    // Joker karakter yoksa rsync kalıbı harfi harfine karşılaştırır: ters bölü kaçışlanmaz.
    #expect(RsyncCommand.escapePattern("/ters\\bölü.txt") == "/ters\\bölü.txt")
    let odd = RsyncCommand.transfer(job("/Users/x*y", "/Volumes/Y", options: options), environment: env(protected: [".ssh"]))
    #expect(odd.contains("--exclude=/x\\*y/.ssh"))
    let slashed = RsyncCommand.transfer(job("/Users/x*y", "/Volumes/Y", options: options), environment: env(protected: ["a\\b"]))
    #expect(slashed.contains("--exclude=/x\\*y/a\\\\b"))
}

/// Yollar "--"dan sonra gelir ve mutlaktır: "-" ile başlayan ya da ":" içeren adlar seçenek ya da uzak sunucu sayılmaz.
@Test func pathsComeAfterSeparatorAndAreAbsolute() {
    let arguments = RsyncCommand.transfer(job("/Users/x/-rf", "/Volumes/host:share"), environment: env())
    let separator = arguments.firstIndex(of: "--")
    #expect(separator == arguments.count - 3)
    #expect(arguments.suffix(2).allSatisfy { $0.hasPrefix("/") })
    #expect(arguments.last == "/Volumes/host:share/")
}

/// macOS'un openrsync'i: --info=progress2, öznitelikler ve ACL yok; öznitelik seçeneği "düşürülen" olarak bildirilir.
@Test func openrsyncRestrictedMode() {
    let arguments = RsyncCommand.transfer(job(options: CopyOptions(preservePermissions: true)), environment: env(engine: openrsyncEngine))
    #expect(arguments.prefix(3) == ["-rltDh", "--partial", "-pog"])
    #expect(!arguments.contains("--info=progress2"))
    #expect(!arguments.contains { $0 == "--extended-attributes" || $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("X") })
    #expect(RsyncCommand.droppedOptions(job(), environment: env(engine: openrsyncEngine)).first == "-X")
    let noXattr = job(options: CopyOptions(preserveExtendedAttributes: false))
    #expect(!RsyncCommand.droppedOptions(noXattr, environment: env(engine: openrsyncEngine)).contains("-X"))
    #expect(!RsyncCommand.verify(job(), environment: env(engine: openrsyncEngine), checksum: false).contains("--extended-attributes"))
}

@Test func verifyIsADryRunWithItemizeAndDeleteListing() {
    let quick = RsyncCommand.verify(job(), environment: env(), checksum: false)
    #expect(quick.prefix(3) == ["-rltDhX", "-n", "-i"])
    #expect(quick.contains("--delete"))
    #expect(!quick.contains("-c"))
    #expect(!quick.contains("--info=progress2"))
    #expect(!quick.contains("--partial"))
    #expect(RsyncCommand.verify(job(), environment: env(), checksum: true).contains("-c"))
    #expect(quick.suffix(2) == RsyncCommand.transfer(job(), environment: env()).suffix(2))
}
