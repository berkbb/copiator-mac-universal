// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// rsync argümanlarının tek kaynağı. Her argüman burada üretilir ve testlerle denetlenir.
///
/// Kurallar:
/// - Kaynak hiçbir koşulda değiştirilmez: `--remove-source-files` (ve benzeri) hiçbir zaman üretilmez; kum havuzu da
///   kaynağa yazmayı engeller.
/// - Yollar her zaman mutlaktır ve `--`'dan sonra gelir: "-" ile başlayan bir ad seçenek sayılmaz, ":" içeren bir ad
///   ("a:b") uzak sunucu sanılmaz (rsync yalnızca ilk "/"dan önceki ":" işaretine bakar).
/// - `--delete` yalnızca kullanıcı açıkça seçip onayladığında eklenir (`CopyOptions.deleteExtraneous`).
public enum RsyncCommand {
    /// macOS'un birim kökünde tuttuğu, yedeğe girmemesi gereken sistem klasörleri ve dosyaları.
    public static let systemExclusions = [
        ".Spotlight-V100", ".TemporaryItems", ".Trashes", ".fseventsd", ".DocumentRevisions-V100",
        ".PKInstallSandboxManager", ".PKInstallSandboxManager-SystemSoftware", ".MobileBackups",
    ]

    /// Asla üretilmeyen, kaynağı değiştiren ya da silen seçenekler (testler ve `assertSafe` denetler).
    public static let forbiddenArguments = ["--remove-source-files", "--remove-sent-files"]

    /// Hedef birim ve motor yetenekleri: aynı iş farklı birimlerde farklı bayraklarla çalışır.
    public struct Environment: Sendable, Equatable {
        public var engine: EngineInfo
        public var destinationFileSystem: FileSystemKind
        public var sourceIsDirectory: Bool
        /// Kaynağın içinde kalan, kum havuzunun okutmadığı kişisel klasörler (kaynağa göre göreli; bkz.
        /// `SandboxProfile.protectedPaths`). rsync'e dışlama olarak verilir.
        public var protectedPaths: [String]

        public init(engine: EngineInfo, destinationFileSystem: FileSystemKind, sourceIsDirectory: Bool, protectedPaths: [String] = []) {
            self.engine = engine
            self.destinationFileSystem = destinationFileSystem
            self.sourceIsDirectory = sourceIsDirectory
            self.protectedPaths = protectedPaths
        }
    }

    /// Kopyalama. Varsayılan: `-rltDhX --info=progress2 --partial`.
    public static func transfer(_ job: TransferJob, environment: Environment) -> [String] {
        var arguments = baseFlags(job.options, environment)
        if environment.engine.supportsProgress2 { arguments.append("--info=progress2") }
        arguments.append("--partial")
        arguments += metadataFlags(job.options, environment)
        if job.options.deleteExtraneous { arguments.append("--delete") }
        arguments += exclusions(job, environment)
        arguments += ["--", sourceArgument(job, environment), destinationArgument(job)]
        assertSafe(arguments)
        return arguments
    }

    /// Doğrulama: aynı iş kuru çalıştırılır (`-n`), farklar `-i` ile listelenir. Hedefte olup kaynakta olmayanları da
    /// göstermek için `--delete` eklenir; `-n` ile hiçbir şey silinmez (kum havuzu da doğrulamada hiçbir yere yazdırmaz).
    /// - Parameter checksum: İçeriği sağlama toplamıyla karşılaştır (`-c`); boyut ve zaman aynı olsa da farkı bulur, yavaştır.
    public static func verify(_ job: TransferJob, environment: Environment, checksum: Bool) -> [String] {
        var arguments = baseFlags(job.options, environment)
        arguments += ["-n", "-i"]
        if checksum { arguments.append("-c") }
        arguments += metadataFlags(job.options, environment)
        arguments.append("--delete")
        arguments += exclusions(job, environment)
        arguments += ["--", sourceArgument(job, environment), destinationArgument(job)]
        assertSafe(arguments)
        return arguments
    }

    /// `-rltDh` + `X` (öznitelikler). openrsync `-X` kısa bayrağını tanımaz; uzun adı kullanılır.
    static func baseFlags(_ options: CopyOptions, _ environment: Environment) -> [String] {
        let xattrs = options.preserveExtendedAttributes && (environment.engine.supportsXattrs || environment.engine.isOpenrsync)
        if environment.engine.isOpenrsync {
            return ["-rltDh"] + (xattrs ? ["--extended-attributes"] : [])
        }
        return [xattrs ? "-rltDhX" : "-rltDh"]
    }

    /// İzinler (-pogA) ve zaman penceresi. exFAT/FAT/NTFS hedef izin, sahip, grup ve ACL saklayamaz: bayraklar hiç
    /// verilmez (verilseydi her dosyada "chown/chmod failed" uyarısı ve 23 kodu gelirdi). FAT zamanları 2 saniyelik
    /// adımlarla tuttuğu için `--modify-window=1` verilir; yoksa her çalıştırmada her dosya değişmiş sayılırdı.
    static func metadataFlags(_ options: CopyOptions, _ environment: Environment) -> [String] {
        var flags: [String] = []
        if options.preservePermissions && !environment.destinationFileSystem.lacksPosixMetadata {
            flags.append(environment.engine.supportsACLs ? "-pogA" : "-pog")
        }
        if environment.destinationFileSystem.hasCoarseTimestamps { flags.append("--modify-window=1") }
        return flags
    }

    static func exclusions(_ job: TransferJob, _ environment: Environment) -> [String] {
        var patterns: [String] = []
        if job.options.excludeSystemFolders { patterns += systemExclusions }
        // Kum havuzunun okutmadığı kişisel klasörler: aktarım köküne bağlı ("/" ile başlayan) kalıplar.
        for path in environment.protectedPaths {
            let anchored = sourceRootPrefix(job, environment) + escapePattern(path)
            patterns.append(anchored)
        }
        return patterns.map { "--exclude=\($0)" }
    }

    /// Aktarım kökü: "klasörün kendisi" kipinde rsync kaynağın adını da aktarır ("/Ad/…"), "içeriği" kipinde aktarmaz.
    static func sourceRootPrefix(_ job: TransferJob, _ environment: Environment) -> String {
        guard environment.sourceIsDirectory else { return "/" }
        return job.options.copyMode == .contents ? "/" : "/" + escapePattern(job.source.lastPathComponent) + "/"
    }

    /// rsync süzgeç kalıplarında `*`, `?`, `[` ve `\` özel anlamlıdır; adda geçerlerse kaçışlanır.
    public static func escapePattern(_ path: String) -> String {
        var result = ""
        for character in path {
            if "*?[\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// Kaynak: mutlak yol; klasörün içeriği isteniyorsa sonuna "/" eklenir. Dosyada kip yok sayılır.
    static func sourceArgument(_ job: TransferJob, _ environment: Environment) -> String {
        let path = absolutePath(job.source)
        guard environment.sourceIsDirectory else { return path }
        switch job.options.copyMode {
        case .contents: return path == "/" ? path : path + "/"
        case .folder: return path
        }
    }

    /// Hedef her zaman bir klasördür: sonundaki "/" rsync'e bunu söyler.
    static func destinationArgument(_ job: TransferJob) -> String {
        let path = absolutePath(job.destination)
        return path == "/" ? path : path + "/"
    }

    /// Fazladan "/" ve "." bileşenleri olmayan mutlak yol (sonunda "/" yok).
    static func absolutePath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.hasPrefix("/") ? path : "/" + path
    }

    static func assertSafe(_ arguments: [String]) {
        precondition(!arguments.contains { argument in forbiddenArguments.contains { argument.hasPrefix($0) } },
                     "rsync arguments must never modify the source")
    }
}
