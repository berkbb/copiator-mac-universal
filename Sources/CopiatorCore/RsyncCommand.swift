// SPDX-License-Identifier: GPL-3.0-only
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
        /// Motorun gerçek (bağlantıları çözülmüş) mutlak yolu. openrsync yerel kopyada da karşı tarafı ayrı bir süreç
        /// olarak başlatır; yol verilmezse "rsync" adını PATH'te arar (bkz. `rsyncPathFlags`).
        public var enginePath: String?

        public init(
            engine: EngineInfo, destinationFileSystem: FileSystemKind, sourceIsDirectory: Bool, protectedPaths: [String] = [],
            enginePath: String? = nil
        ) {
            self.engine = engine
            self.destinationFileSystem = destinationFileSystem
            self.sourceIsDirectory = sourceIsDirectory
            self.protectedPaths = protectedPaths
            self.enginePath = enginePath
        }
    }

    /// Kopyalama. Varsayılan: `-rltDhX --info=progress2 --partial`.
    public static func transfer(_ job: TransferJob, environment: Environment) -> [String] {
        let advanced = job.options.advanced
        var arguments = baseFlags(job.options, environment)
        arguments += infoFlags(advanced, environment)
        arguments.append("--partial")
        arguments += rsyncPathFlags(environment)
        arguments += metadataFlags(job.options, environment)
        arguments += advancedFlags(job.options, environment, forVerify: false)
        // Kurallı işte kurallar dosya seçer; hedefteki öteki dosyalar silinmez.
        if job.options.deleteExtraneous, job.options.rules == nil { arguments += deleteFlags(advanced, forVerify: false) }
        arguments += exclusions(job, environment)
        arguments += ["--", sourceArgument(job, environment), destinationArgument(job)]
        assertSafe(arguments)
        return arguments
    }

    /// Doğrulama: aynı iş kuru çalıştırılır (`-n`), farklar `-i` ile listelenir. Hedefte olup kaynakta olmayanları da
    /// göstermek için `--delete` eklenir; `-n` ile hiçbir şey silinmez (kum havuzu da doğrulamada hiçbir yere yazdırmaz).
    /// Karşılaştırmayı etkileyen gelişmiş seçenekler (süzgeçler, -H, öznitelikler, önceki yedek…) aynen verilir; yalnızca
    /// yazmayı ya da çıktıyı etkileyenler (günlük dosyası, toplu iş, hız sınırı, durma zamanı, yedekler) verilmez.
    /// - Parameter checksum: İçeriği sağlama toplamıyla karşılaştır (`-c`); boyut ve zaman aynı olsa da farkı bulur, yavaştır.
    public static func verify(_ job: TransferJob, environment: Environment, checksum: Bool) -> [String] {
        var arguments = baseFlags(job.options, environment)
        arguments += ["-n", "-i"]
        arguments += rsyncPathFlags(environment)
        if checksum { arguments.append("-c") }
        arguments += metadataFlags(job.options, environment)
        arguments += advancedFlags(job.options, environment, forVerify: true)
        arguments.append("--delete")
        if job.options.deleteExtraneous { arguments += deleteFlags(job.options.advanced, forVerify: true) }
        arguments += exclusions(job, environment)
        arguments += ["--", sourceArgument(job, environment), destinationArgument(job)]
        assertSafe(arguments)
        return arguments
    }

    /// openrsync (macOS'un /usr/bin/rsync'i) yerel kopyada da alıcı tarafı `rsync --server …` olarak yeniden çalıştırır ve
    /// "rsync" adını PATH'te arar. PATH'te önce başka bir rsync (ör. Homebrew'unki) varsa o çalışırdı; kum havuzu bunu
    /// engellediği için iş "exec on 'rsync': Operation not permitted" hatasıyla biterdi. Motorun kendi yolu verilir: karşı
    /// taraf da aynı program olur, kum havuzunun çalıştırmaya izin verdiği tek program odur. rsync 3.x yerel kopyada
    /// yalnızca çatallanır (fork); ona verilmez.
    static func rsyncPathFlags(_ environment: Environment) -> [String] {
        guard environment.engine.isOpenrsync, let path = environment.enginePath, path.hasPrefix("/") else { return [] }
        return ["--rsync-path=\(path)"]
    }

    /// Çakışma denetimi: iş kuru çalıştırılır (`-n`) ve `-ii` ile değişmeyenler dahil her dosya listelenir; hedefte
    /// bulunan dosyalar çakışmadır (bkz. `ConflictDetector`). Hiçbir şey silinmez ya da yazılmaz.
    /// Önceki yedek seçenekleri (`--link-dest` vb.) verilmez: oradaki dosyalar hedefte olmadığı hâlde "değişmemiş" görünürdü.
    public static func conflictCheck(_ job: TransferJob, environment: Environment) -> [String] {
        var options = job.options
        options.advanced.referenceMode = .none
        var arguments = baseFlags(options, environment)
        arguments += ["-n", "-ii"]
        arguments += rsyncPathFlags(environment)
        arguments += metadataFlags(options, environment)
        arguments += advancedFlags(options, environment, forVerify: true)
        arguments += exclusions(job, environment)
        arguments += ["--", sourceArgument(job, environment), destinationArgument(job)]
        assertSafe(arguments)
        return arguments
    }

    /// "İkisini de sakla": tek bir dosyayı hedefte verilen (numaralı) ada kopyalar. Bağlantı ayarı ana kopyadakiyle
    /// aynıdır (yerleştirmede kaynak hazırlık ağacındaki bir bağlantıdır).
    public static func singleFile(_ job: TransferJob, environment: Environment, source: String, destination: String) -> [String] {
        var arguments = baseFlags(job.options, environment)
        arguments += rsyncPathFlags(environment)
        arguments += metadataFlags(job.options, environment)
        arguments += symlinkFlags(job.options.advanced)
        arguments += ["--", source, destination]
        assertSafe(arguments)
        return arguments
    }

    /// macOS'un openrsync'inin desteklemediği seçenekler. Bu motorla bunlar verilmez ve iş günlüğünde bildirilir.
    static let unsupportedByOpenrsync: Set<String> = [
        "-N", "-U", "--iconv", "--stop-after", "--stop-at", "--log-file", "--append-verify", "--no-inc-recursive",
    ]

    /// Seçilmiş ama bu motorun desteklemediği için verilmeyen seçenekler (yalnızca openrsync'te boş değildir).
    public static func droppedOptions(_ job: TransferJob, environment: Environment) -> [String] {
        guard environment.engine.isOpenrsync else { return [] }
        var full = environment
        full.engine = EngineInfo(version: "3.5.1", isOpenrsync: false, supportsACLs: true, supportsXattrs: true)
        let wanted = advancedFlags(job.options, full, forVerify: false) + infoFlags(job.options.advanced, full)
        let dropped = wanted.filter { flag in unsupportedByOpenrsync.contains { flag == $0 || flag.hasPrefix($0 + "=") } || flag.hasPrefix("--info=") }
            .map { $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? $0 }
        return (job.options.preserveExtendedAttributes ? ["-X"] : []) + dropped
    }

    /// `--info=…`: ilerleme ayrıntısı, dosya adları, liste sayacı ve istatistikler; değişiklik günlüğü (`-i`) ve kesin
    /// ilerleme (`--no-inc-recursive`). openrsync `--info` tanımaz.
    static func infoFlags(_ advanced: AdvancedOptions, _ environment: Environment) -> [String] {
        var flags: [String] = []
        if environment.engine.supportsProgress2 {
            var info = [advanced.progressDetail == .perFile ? "progress1" : "progress2"]
            if advanced.showFileNames { info.append("name1") }
            if advanced.fileListProgress && advanced.preciseProgress { info.append("flist2") }
            if advanced.showStats { info.append("stats2") }
            flags.append("--info=" + info.joined(separator: ","))
            if advanced.preciseProgress { flags.append("--no-inc-recursive") }
        } else if advanced.showStats {
            flags.append("--stats")
        }
        if advanced.logChanges { flags.append("-i") }
        return flags
    }

    /// Gelişmiş seçeneklerin argümanları (silme ayrıntıları ve süzgeçler hariç; onlar ayrı üretilir).
    static func advancedFlags(_ options: CopyOptions, _ environment: Environment, forVerify: Bool) -> [String] {
        let a = options.advanced
        let open = environment.engine.isOpenrsync
        var flags: [String] = []
        // Dosya seçimi
        if a.ignoreExisting { flags.append("--ignore-existing") }
        if a.existingOnly { flags.append("--existing") }
        if a.updateOnly { flags.append("-u") }
        if a.pruneEmptyDirectories { flags.append("-m") }
        if let max = a.maxSizeBytes { flags.append("--max-size=\(max)") }
        if let min = a.minSizeBytes { flags.append("--min-size=\(min)") }
        // Öznitelikler
        if a.hardLinks { flags.append("-H") }
        if a.creationTimes && !open { flags.append("-N") }
        if a.accessTimes && !open { flags.append("-U") }
        if a.numericIDs { flags.append("--numeric-ids") }
        if a.oneFileSystem { flags.append("-x") }
        if let chmod = a.chmod { flags.append("--chmod=\(chmod)") }
        flags += symlinkFlags(a)
        // Karşılaştırma
        if a.sizeOnly { flags.append("--size-only") }
        if let window = a.modifyWindowSeconds, !environment.destinationFileSystem.hasCoarseTimestamps {
            flags.append("--modify-window=\(window)")
        }
        if let iconv = a.iconv, !open { flags.append("--iconv=\(iconv)") }
        // Önceki yedek
        if let reference = a.referenceDirectory, !reference.isEmpty {
            switch a.referenceMode {
            case .none: break
            case .linkDest: flags.append("--link-dest=\(reference)")
            case .compareDest: flags.append("--compare-dest=\(reference)")
            case .copyDest: flags.append("--copy-dest=\(reference)")
            }
        }
        guard !forVerify else { return flags }
        // Yazma biçimi
        if a.sparse { flags.append("--sparse") }
        if a.inplace { flags.append("--inplace") }
        if a.wholeFile { flags.append("-W") }
        switch a.appendMode {
        case .off: break
        case .append: flags.append("--append")
        case .appendVerify: flags.append(open ? "--append" : "--append-verify")
        }
        // Hız ve zaman sınırları
        if let limit = a.bandwidthLimitKiB { flags.append("--bwlimit=\(limit)") }
        if !open {
            if let minutes = a.stopAfterMinutes { flags.append("--stop-after=\(minutes)") }
            if let stopAt = a.stopAt { flags.append("--stop-at=" + AdvancedOptions.stopAtArgument(stopAt)) }
        }
        // Eski sürümler
        if a.keepBackups {
            flags.append("-b")
            if let directory = a.backupDirectory, !directory.isEmpty { flags.append("--backup-dir=\(directory)") }
            if let suffix = a.backupSuffix, !suffix.isEmpty { flags.append("--suffix=\(suffix)") }
        }
        // Çıktı dosyaları
        if let logFile = a.logFile, !logFile.isEmpty, !open { flags.append("--log-file=\(logFile)") }
        if let batch = a.batchFile, !batch.isEmpty {
            switch a.batchMode {
            case .off: break
            case .write: flags.append("--write-batch=\(batch)")
            case .onlyWrite: flags.append("--only-write-batch=\(batch)")
            }
        }
        return flags
    }

    /// `--delete` ve ayrıntıları. Doğrulamada yalnızca listeyi etkileyenler (`--delete-excluded`) verilir.
    static func deleteFlags(_ advanced: AdvancedOptions, forVerify: Bool) -> [String] {
        var flags = forVerify ? [] : ["--delete"]
        if advanced.deleteExcluded { flags.append("--delete-excluded") }
        guard !forVerify else { return flags }
        switch advanced.deleteTiming {
        case .during: break
        case .before: flags.append("--delete-before")
        case .after: flags.append("--delete-after")
        case .delay: flags.append("--delete-delay")
        }
        if let max = advanced.maxDelete { flags.append("--max-delete=\(max)") }
        if advanced.ignoreErrors { flags.append("--ignore-errors") }
        return flags
    }

    /// `-rltDh` + `X` (öznitelikler). openrsync'e öznitelik seçeneği hiç verilmez: `--extended-attributes` ile
    /// öznitelikleri paylaşılan /private/tmp'de tahmin edilebilir adlı geçici AppleDouble dosyalarıyla ("/tmp/.<pid>._ad")
    /// taşır. Kum havuzu bu yazmayı (doğru olarak) engeller ve kuru çalıştırma (doğrulama, önizleme) olmayan "._" dosyalarını
    /// açmaya çalışıp hata verir. Bu kipte karantina işareti `Quarantine.propagate` ile ayrıca aktarılır; seçenek
    /// `droppedOptions` ile günlüğe yazılır.
    /// Bağlantıların kopyalanışı.
    static func symlinkFlags(_ a: AdvancedOptions) -> [String] {
        switch a.symlinks {
        case .preserve: []
        case .copyTargets: ["-L"]
        case .copyUnsafeTargets: ["--copy-unsafe-links"]
        case .skipUnsafe: ["--safe-links"]
        }
    }

    static func baseFlags(_ options: CopyOptions, _ environment: Environment) -> [String] {
        let xattrs = options.preserveExtendedAttributes && environment.engine.supportsXattrs && !environment.engine.isOpenrsync
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
        // FAT'te en az 1 saniye; kullanıcı daha büyük bir pencere seçtiyse o (bkz. `advancedFlags`).
        if environment.destinationFileSystem.hasCoarseTimestamps {
            flags.append("--modify-window=\(max(1, options.advanced.modifyWindowSeconds ?? 1))")
        }
        return flags
    }

    /// Süzgeçler. rsync kuralları sırayla dener ve ilk eşleşen kazanır: kum havuzunun okutmadığı kişisel klasörler önce
    /// gelir (kullanıcının bir `--include` kuralı onları geri alamaz), ardından sistem klasörleri, sonra kullanıcının
    /// `--filter`, `--include`, `--exclude` kuralları, hazır dışlama listeleri (kullanıcının `--include` kuralı onlardan
    /// önce gelir ve bir öğeyi geri alabilir), `.rsync-filter` dosyaları ve liste dosyaları.
    static func exclusions(_ job: TransferJob, _ environment: Environment) -> [String] {
        var patterns: [String] = []
        // Kum havuzunun okutmadığı kişisel klasörler: aktarım köküne bağlı ("/" ile başlayan) kalıplar.
        for path in environment.protectedPaths {
            patterns.append(escapePattern(sourceRootPrefix(job, environment) + path))
        }
        if job.options.excludeSystemFolders { patterns += systemExclusions }
        // Arşiv bütünlüğü listesi hedefin kökünde durur: kaynakta yoktur, ama `--delete` onu silmemeli ve doğrulama fazla
        // saymamalı (dışlanan dosya silinmeye karşı korunur; köke bağlı kalıp başka yerdeki aynı adlı dosyaya dokunmaz).
        patterns.append("/" + ArchiveIntegrity.manifestName)
        let a = job.options.advanced
        // `--from0` liste seçeneklerinden önce gelmeli: rsync `--exclude-from` dosyasını seçeneği okuduğu anda işler; sonra
        // gelen `--from0` o listeye uygulanmaz (NUL ile ayrılmış listede yalnızca ilk kalıp geçerli olurdu).
        let generatedLists = !(a.filesFromFile ?? "").isEmpty || !(a.conflictExcludeFile ?? "").isEmpty
        var arguments = generatedLists && a.filesFromZeroTerminated && !environment.engine.isOpenrsync ? ["--from0"] : []
        arguments += patterns.map { "--exclude=\($0)" }
        // Çakışma kararları: atlanan ve numaralı kopyalanan dosyalar ana kopyadan dışlanır; kullanıcının ekleme kuralları
        // onları geri alamaz.
        if let file = a.conflictExcludeFile, !file.isEmpty { arguments.append("--exclude-from=\(file)") }
        arguments += a.filterRules.map { "--filter=\($0)" }
        arguments += a.includePatterns.map { "--include=\($0)" }
        arguments += a.excludePatterns.map { "--exclude=\($0)" }
        for preset in ExcludePreset.allCases where a.excludePresets.contains(preset) {
            arguments += preset.patterns.map { "--exclude=\($0)" }
        }
        if a.useFilterFiles { arguments.append("-F") }
        if let file = a.includeFromFile, !file.isEmpty { arguments.append("--include-from=\(file)") }
        if let file = a.excludeFromFile, !file.isEmpty { arguments.append("--exclude-from=\(file)") }
        if let file = a.filesFromFile, !file.isEmpty { arguments.append("--files-from=\(file)") }
        return arguments
    }

    /// Aktarım kökü: "klasörün kendisi" kipinde rsync kaynağın adını da aktarır ("/Ad/…"), "içeriği" kipinde aktarmaz.
    /// Kaçışlanmamıştır: kalıbın tamamı birlikte kaçışlanır (bkz. `escapePattern`).
    static func sourceRootPrefix(_ job: TransferJob, _ environment: Environment) -> String {
        guard environment.sourceIsDirectory else { return "/" }
        return job.options.copyMode == .contents ? "/" : "/" + job.source.lastPathComponent + "/"
    }

    /// Bir yolu harfi harfine eşleşen rsync kalıbına çevirir; kalıbın tamamına (kök öneki dahil) bir kez uygulanır.
    /// rsync bir kalıbı yalnızca `*`, `?` ya da `[` içeriyorsa joker kalıp sayar ve ancak o zaman `\` kaçış karakteridir:
    /// böyle bir kalıpta dördü de kaçışlanır. Joker karakter yoksa kalıp olduğu gibi karşılaştırılır; ters bölüyü kaçışlamak
    /// eşleşmeyi bozardı ("ters\bölü.txt" dışlanmazdı).
    public static func escapePattern(_ path: String) -> String {
        guard path.contains(where: { "*?[".contains($0) }) else { return path }
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

extension RsyncCommand {
    /// Argümanları bir kabukta aynen çalıştırılabilecek biçimde gösterir: `rsync -rltDhX … -- '/Kaynak' '/Hedef/'`.
    /// Yalnızca güvenli karakterlerden oluşan argümanlar tırnaksız kalır; ötekiler tek tırnağa alınır ("'" → '\'').
    public static func displayString(executable: String = "rsync", arguments: [String]) -> String {
        ([executable] + arguments).map(shellQuoted).joined(separator: " ")
    }

    static func shellQuoted(_ argument: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_=./,:+@%")
        if !argument.isEmpty, argument.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
