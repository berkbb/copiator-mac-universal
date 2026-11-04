// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Sembolik bağlantıların nasıl kopyalanacağı.
public enum SymlinkMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Bağlantı bağlantı olarak kopyalanır (`-l`, varsayılan).
    case preserve
    /// Bağlantının gösterdiği dosya kopyalanır (`-L`).
    case copyTargets
    /// Yalnızca ağacın dışını gösteren bağlantıların hedefi kopyalanır (`--copy-unsafe-links`).
    case copyUnsafeTargets
    /// Ağacın dışını gösteren bağlantılar atlanır (`--safe-links`).
    case skipUnsafe

    public var id: String { rawValue }
}

/// `--delete` seçiliyken silmenin ne zaman yapılacağı.
public enum DeleteTiming: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Aktarım sırasında (rsync'in varsayılanı).
    case during
    case before
    case after
    /// Silinecekler aktarım sırasında bulunur, sonunda toplu silinir.
    case delay

    public var id: String { rawValue }
}

/// Yalnızca dosyanın sonuna eklenen kısmı aktarma.
public enum AppendMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    /// `--append`: var olan kısım denetlenmez.
    case append
    /// `--append-verify`: var olan kısım sağlama toplamıyla denetlenir.
    case appendVerify

    public var id: String { rawValue }
}

/// Önceki bir yedeğe göre kopyalama (anlık görüntü yedekleri).
public enum ReferenceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    /// `--link-dest`: değişmeyen dosyalar önceki yedekle sabit bağlantıyla paylaşılır.
    case linkDest
    /// `--compare-dest`: önceki yedekte aynısı olan dosyalar hedefe yazılmaz.
    case compareDest
    /// `--copy-dest`: değişmeyen dosyalar önceki yedekten yerel olarak kopyalanır.
    case copyDest

    public var id: String { rawValue }
}

/// rsync toplu iş dosyası (batch) yazma.
public enum BatchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    /// `--write-batch`: hedef güncellenir ve değişiklikler dosyaya da yazılır.
    case write
    /// `--only-write-batch`: hedef güncellenmez, yalnızca dosya yazılır.
    case onlyWrite

    public var id: String { rawValue }
}

/// İlerlemenin ayrıntısı.
public enum ProgressDetail: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `--info=progress2`: tüm aktarımın toplam ilerlemesi.
    case total
    /// `--info=progress1`: her dosyanın ayrı ilerlemesi.
    case perFile

    public var id: String { rawValue }
}

/// Hazır dışlama listeleri: yedekte yer kaplayan, yeniden üretilebilen klasörler ve dosyalar. Kalıplar rsync'e
/// `--exclude` olarak verilir; "/" ile bitenler yalnızca klasörlerle, ötekiler hem dosya hem klasörle eşleşir.
/// "/" içeren kalıplar (ör. "Library/Caches/") yolun sonuyla, ötekiler yalnızca adla karşılaştırılır.
public enum ExcludePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Paket ve derleme klasörleri (node_modules, DerivedData, .build, Pods, Python ve JavaScript önbellekleri…).
    case developer
    /// Sürüm denetimi klasörleri (.git, .svn, .hg): depo geçmişi yedeğe girmez.
    case versionControl
    /// Uygulama ve araç önbellekleri (~/Library/Caches, ~/.cache…).
    case caches
    /// macOS'un yardımcı dosyaları (.DS_Store, "._" dosyaları, Çöp Sepeti).
    case macOSJunk

    public var id: String { rawValue }

    public var patterns: [String] {
        switch self {
        case .developer:
            ["node_modules/", "DerivedData/", ".build/", "Pods/", ".gradle/", "__pycache__/", ".venv/", ".tox/",
             ".mypy_cache/", ".pytest_cache/", ".next/", ".nuxt/", ".dart_tool/", ".parcel-cache/", ".turbo/"]
        case .versionControl:
            [".git", ".svn", ".hg"]
        case .caches:
            ["Library/Caches/", ".cache/", ".npm/_cacache/", "Library/Developer/CoreSimulator/Caches/"]
        case .macOSJunk:
            [".DS_Store", "._*", ".AppleDouble/", ".Trash/", ".apdisk"]
        }
    }
}

/// rsync'in kum havuzunda kullanılabilen, varsayılan kopyalamanın ötesindeki seçenekleri. Her alanın varsayılanı
/// "rsync'in kendi davranışı"dır: varsayılan değerlerle hiçbir ek argüman üretilmez.
///
/// Kum havuzunda yapılamayanlar (uzak aktarım, kaynağı değiştirme, başka program çalıştırma) burada yoktur; `--preallocate`
/// macOS derlemesinde desteklenmediği, `--read-batch` ise bir seçenek değil ayrı bir işlem olduğu için yoktur.
public struct AdvancedOptions: Codable, Equatable, Sendable {
    // MARK: Dosya seçimi
    /// `--filter` kuralları ("- *.tmp", "+ belgeler/", "P korunan/"…), sırasıyla.
    public var filterRules: [String] = []
    /// `--include` kalıpları.
    public var includePatterns: [String] = []
    /// `--exclude` kalıpları.
    public var excludePatterns: [String] = []
    /// Hazır dışlama listeleri (bkz. `ExcludePreset`).
    public var excludePresets: [ExcludePreset] = []
    /// `-F`: klasörlerdeki `.rsync-filter` dosyalarını kullan.
    public var useFilterFiles = false
    /// `--include-from`, `--exclude-from`, `--files-from` dosyaları (mutlak yollar).
    public var includeFromFile: String?
    public var excludeFromFile: String?
    public var filesFromFile: String?
    /// `--from0`: liste dosyaları NUL ile ayrılmış (rutin kurallarının ve çakışma kararlarının ürettiği listelerde;
    /// adında satır sonu olabilir).
    public var filesFromZeroTerminated = false
    /// Çakışma kararlarının ürettiği dışlama listesi (atlanan ve numaralı kopyalanan dosyalar); yalnızca çalıştırma
    /// sırasında vardır, kaydedilmez.
    public var conflictExcludeFile: String?
    /// `--max-size`, `--min-size` (bayt).
    public var maxSizeBytes: Int64?
    public var minSizeBytes: Int64?
    /// `--ignore-existing`, `--existing`, `-u`, `-m`.
    public var ignoreExisting = false
    public var existingOnly = false
    public var updateOnly = false
    public var pruneEmptyDirectories = false

    // MARK: Öznitelikler
    /// `-H`, `-N` (`--crtimes`), `-U` (`--atimes`), `--numeric-ids`, `-x`.
    public var hardLinks = false
    public var creationTimes = false
    public var accessTimes = false
    public var numericIDs = false
    public var oneFileSystem = false
    /// `--chmod` (ör. "D755,F644", "u+rwX,go-w").
    public var chmod: String?

    // MARK: Bağlantılar ve yazma biçimi
    public var symlinks: SymlinkMode = .preserve
    /// `--sparse`, `--inplace`, `-W`.
    public var sparse = false
    public var inplace = false
    public var wholeFile = false
    public var appendMode: AppendMode = .off

    // MARK: Silme ayrıntıları (yalnızca `CopyOptions.deleteExtraneous` açıkken)
    public var deleteTiming: DeleteTiming = .during
    public var deleteExcluded = false
    public var maxDelete: Int?
    public var ignoreErrors = false

    // MARK: Karşılaştırma ve hız
    public var sizeOnly = false
    /// `--modify-window` (saniye). Boşsa FAT hedefte 1, ötekilerde verilmez.
    public var modifyWindowSeconds: Int?
    /// `--bwlimit` (KiB/sn).
    public var bandwidthLimitKiB: Int?
    /// `--stop-after` (dakika) ve `--stop-at` (yerel saat).
    public var stopAfterMinutes: Int?
    public var stopAt: Date?
    /// `--iconv` (ör. "utf-8-mac,utf-8").
    public var iconv: String?

    // MARK: Anlık görüntü ve eski sürümler
    public var referenceMode: ReferenceMode = .none
    public var referenceDirectory: String?
    /// `-b`, `--backup-dir`, `--suffix`.
    public var keepBackups = false
    public var backupDirectory: String?
    public var backupSuffix: String?

    // MARK: İlerleme ve çıktı
    public var progressDetail: ProgressDetail = .total
    /// `--info=name1`: şu an kopyalanan dosyanın adı.
    public var showFileNames = false
    /// `--info=flist2`: dosya listesi çıkarılırken sayaç (yalnızca `preciseProgress` ile).
    public var fileListProgress = false
    /// `--info=stats2`: iş sonunda istatistikler günlüğe yazılır.
    public var showStats = false
    /// `-i`: her değişiklik günlüğe yazılır.
    public var logChanges = false
    /// `--no-inc-recursive`: kopyalamadan önce tüm liste çıkarılır; yüzde ve kalan süre baştan kesindir.
    public var preciseProgress = false
    /// `--log-file`.
    public var logFile: String?
    public var batchMode: BatchMode = .off
    public var batchFile: String?

    public init() {}

    /// Hiçbir ek seçenek yok (varsayılan kopyalama).
    public var isDefault: Bool { self == AdvancedOptions() }

    // MARK: Kodlama (geriye ve ileriye uyumlu)

    private enum CodingKeys: String, CodingKey {
        case filterRules, includePatterns, excludePatterns, excludePresets, useFilterFiles, includeFromFile, excludeFromFile, filesFromFile
        case filesFromZeroTerminated
        case maxSizeBytes, minSizeBytes, ignoreExisting, existingOnly, updateOnly, pruneEmptyDirectories
        case hardLinks, creationTimes, accessTimes, numericIDs, oneFileSystem, chmod
        case symlinks, sparse, inplace, wholeFile, appendMode
        case deleteTiming, deleteExcluded, maxDelete, ignoreErrors
        case sizeOnly, modifyWindowSeconds, bandwidthLimitKiB, stopAfterMinutes, stopAt, iconv
        case referenceMode, referenceDirectory, keepBackups, backupDirectory, backupSuffix
        case progressDetail, showFileNames, fileListProgress, showStats, logChanges, preciseProgress, logFile, batchMode, batchFile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        func optional<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        let d = AdvancedOptions()
        filterRules = value(.filterRules, d.filterRules)
        includePatterns = value(.includePatterns, d.includePatterns)
        excludePatterns = value(.excludePatterns, d.excludePatterns)
        // Daha yeni bir sürümün eklediği bilinmeyen liste öteki listeleri silmez; yalnızca o atlanır.
        excludePresets = ((try? c.decodeIfPresent([String].self, forKey: .excludePresets)) ?? nil)?
            .compactMap(ExcludePreset.init(rawValue:)) ?? d.excludePresets
        useFilterFiles = value(.useFilterFiles, d.useFilterFiles)
        includeFromFile = optional(.includeFromFile)
        excludeFromFile = optional(.excludeFromFile)
        filesFromFile = optional(.filesFromFile)
        filesFromZeroTerminated = value(.filesFromZeroTerminated, d.filesFromZeroTerminated)
        maxSizeBytes = optional(.maxSizeBytes)
        minSizeBytes = optional(.minSizeBytes)
        ignoreExisting = value(.ignoreExisting, d.ignoreExisting)
        existingOnly = value(.existingOnly, d.existingOnly)
        updateOnly = value(.updateOnly, d.updateOnly)
        pruneEmptyDirectories = value(.pruneEmptyDirectories, d.pruneEmptyDirectories)
        hardLinks = value(.hardLinks, d.hardLinks)
        creationTimes = value(.creationTimes, d.creationTimes)
        accessTimes = value(.accessTimes, d.accessTimes)
        numericIDs = value(.numericIDs, d.numericIDs)
        oneFileSystem = value(.oneFileSystem, d.oneFileSystem)
        chmod = optional(.chmod)
        symlinks = value(.symlinks, d.symlinks)
        sparse = value(.sparse, d.sparse)
        inplace = value(.inplace, d.inplace)
        wholeFile = value(.wholeFile, d.wholeFile)
        appendMode = value(.appendMode, d.appendMode)
        deleteTiming = value(.deleteTiming, d.deleteTiming)
        deleteExcluded = value(.deleteExcluded, d.deleteExcluded)
        maxDelete = optional(.maxDelete)
        ignoreErrors = value(.ignoreErrors, d.ignoreErrors)
        sizeOnly = value(.sizeOnly, d.sizeOnly)
        modifyWindowSeconds = optional(.modifyWindowSeconds)
        bandwidthLimitKiB = optional(.bandwidthLimitKiB)
        stopAfterMinutes = optional(.stopAfterMinutes)
        stopAt = optional(.stopAt)
        iconv = optional(.iconv)
        referenceMode = value(.referenceMode, d.referenceMode)
        referenceDirectory = optional(.referenceDirectory)
        keepBackups = value(.keepBackups, d.keepBackups)
        backupDirectory = optional(.backupDirectory)
        backupSuffix = optional(.backupSuffix)
        progressDetail = value(.progressDetail, d.progressDetail)
        showFileNames = value(.showFileNames, d.showFileNames)
        fileListProgress = value(.fileListProgress, d.fileListProgress)
        showStats = value(.showStats, d.showStats)
        logChanges = value(.logChanges, d.logChanges)
        preciseProgress = value(.preciseProgress, d.preciseProgress)
        logFile = optional(.logFile)
        batchMode = value(.batchMode, d.batchMode)
        batchFile = optional(.batchFile)
    }

    // MARK: Doğrulama

    /// Seçeneklerdeki sorunlar. Sorunlu seçeneklerle iş kuyruğa eklenmez.
    public enum Problem: Equatable, Sendable {
        case invalidPattern(String)
        case invalidChmod
        case invalidIconv
        case invalidSuffix
        case invalidNumber
        /// Yol mutlak değil ya da boş.
        case pathNotAbsolute(String)
        /// rsync'in yazacağı bir yol kaynağın içinde: kaynak salt okunurdur.
        case writesInsideSource(String)
        case missingReferenceDirectory
        case missingBatchFile
        case stopAtInPast
        /// Anlık görüntü saklama sayısı 1'den küçük.
        case invalidRetention
        /// Rutin kurallarında bir sorun (boş değer, geçersiz düzenli ifade…).
        case rules(RuleGroup.Problem)
    }

    /// - Parameters:
    ///   - source: İşin kaynağı (yazılacak yolların kaynağın içine düşmemesi için).
    ///   - now: Şimdiki zaman (`--stop-at` geçmişte olmasın).
    public func problems(source: URL?, now: Date = Date()) -> [Problem] {
        var problems: [Problem] = []
        for pattern in filterRules + includePatterns + excludePatterns where !Self.isValidPattern(pattern) {
            problems.append(.invalidPattern(pattern))
        }
        if let chmod, !Self.isValidChmod(chmod) { problems.append(.invalidChmod) }
        if let iconv, !Self.isValidIconv(iconv) { problems.append(.invalidIconv) }
        if let backupSuffix, !Self.isValidSuffix(backupSuffix) { problems.append(.invalidSuffix) }
        let numbers: [Int64?] = [maxSizeBytes, minSizeBytes, maxDelete.map(Int64.init), modifyWindowSeconds.map(Int64.init),
                                 bandwidthLimitKiB.map(Int64.init), stopAfterMinutes.map(Int64.init)]
        if numbers.contains(where: { ($0 ?? 0) < 0 }) || stopAfterMinutes == 0 { problems.append(.invalidNumber) }
        if let stopAt, stopAt <= now { problems.append(.stopAtInPast) }
        if referenceMode != .none, (referenceDirectory ?? "").isEmpty { problems.append(.missingReferenceDirectory) }
        if batchMode != .off, (batchFile ?? "").isEmpty { problems.append(.missingBatchFile) }

        let paths: [(String, String?)] = [
            ("includeFromFile", includeFromFile), ("excludeFromFile", excludeFromFile), ("filesFromFile", filesFromFile),
            ("referenceDirectory", referenceMode == .none ? nil : referenceDirectory),
            ("backupDirectory", keepBackups ? backupDirectory : nil), ("logFile", logFile),
            ("batchFile", batchMode == .off ? nil : batchFile),
        ]
        for (name, path) in paths {
            guard let path, !path.isEmpty else { continue }
            if !path.hasPrefix("/") { problems.append(.pathNotAbsolute(name)) }
        }
        if let source {
            let root = SandboxProfile.resolved(source).path
            let written: [(String, String?)] = [
                ("backupDirectory", keepBackups ? backupDirectory : nil), ("logFile", logFile),
                ("batchFile", batchMode == .off ? nil : batchFile),
                ("referenceDirectory", referenceMode == .linkDest ? referenceDirectory : nil),
            ]
            for (name, path) in written {
                guard let path, path.hasPrefix("/") else { continue }
                let resolved = SandboxProfile.resolved(URL(fileURLWithPath: path)).path
                if resolved == root || resolved.hasPrefix(root + "/") { problems.append(.writesInsideSource(name)) }
            }
        }
        return problems
    }

    /// Süzgeç kalıbı: boş olmayan, satır sonu ya da NUL içermeyen metin. Kalıplar rsync'e olduğu gibi verilir
    /// (`*`, `**`, `?`, `[…]` joker karakterleri anlamlıdır).
    static func isValidPattern(_ pattern: String) -> Bool {
        !pattern.trimmingCharacters(in: .whitespaces).isEmpty && !pattern.contains { $0.isNewline || $0 == "\u{0}" }
    }

    /// `--chmod` biçimi: "D755,F644", "u+rwX,go-w", "a=r".
    static func isValidChmod(_ value: String) -> Bool {
        let allowed = Set("ugoaDF0123456789+=-rwxXst,")
        guard !value.isEmpty, value.allSatisfy(allowed.contains) else { return false }
        return !value.split(separator: ",", omittingEmptySubsequences: false).contains { $0.isEmpty }
    }

    /// `--iconv` biçimi: "YEREL" ya da "YEREL,UZAK" (ör. "utf-8-mac,utf-8"); "." yerel kodlamadır.
    static func isValidIconv(_ value: String) -> Bool {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 64 && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) }
        }
    }

    /// Yedek soneki (ör. "~", ".eski"): "/" ve kontrol karakteri içermez.
    static func isValidSuffix(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && !value.contains("/") && !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// rsync'in `--stop-at` biçimi: "yyyy-mm-ddThh:mm" (yerel saat).
    public static func stopAtArgument(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// Kum havuzunun ek olarak okuyabilmesi gereken yollar (liste dosyaları, önceki yedek).
    public var readablePaths: [URL] {
        [includeFromFile, excludeFromFile, filesFromFile, referenceMode == .none ? nil : referenceDirectory]
            .compactMap { $0 }.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
    }

    /// Kum havuzunun ek olarak yazabilmesi gereken tek dosyalar (günlük, toplu iş dosyası ve betiği).
    public var writableFiles: [URL] {
        var files: [String] = []
        if let logFile, logFile.hasPrefix("/") { files.append(logFile) }
        if batchMode != .off, let batchFile, batchFile.hasPrefix("/") { files += [batchFile, batchFile + ".sh"] }
        return files.map { URL(fileURLWithPath: $0) }
    }

    /// Kum havuzunun ek olarak yazabilmesi gereken klasörler: hedefin dışındaki yedek klasörü ve `--link-dest` için
    /// önceki yedek. macOS kum havuzu sabit bağlantı oluşturmayı var olan dosyaya yazma sayar; önceki yedeğe yazma
    /// izni olmadan rsync bağlantı yerine sessizce kopyalar (yer kazanılmaz). `--compare-dest`/`--copy-dest` yalnızca okur.
    public var writableDirectories: [URL] {
        var directories: [String] = []
        if keepBackups, let backupDirectory, backupDirectory.hasPrefix("/") { directories.append(backupDirectory) }
        if referenceMode == .linkDest, let referenceDirectory, referenceDirectory.hasPrefix("/") { directories.append(referenceDirectory) }
        return directories.map { URL(fileURLWithPath: $0) }
    }

    /// rsync'in kendisinin okuduğu liste dosyaları (`--include-from`, `--exclude-from`, `--files-from`).
    var listFiles: [WritableKeyPath<AdvancedOptions, String?>] { [\.includeFromFile, \.excludeFromFile, \.filesFromFile] }
}
