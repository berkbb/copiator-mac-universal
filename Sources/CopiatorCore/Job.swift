// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// İşi yürüten motorun türü. 1.0'da yalnızca yerel rsync vardır; uzak (SSH) rsync ya da başka bir motor (aria2) yeni bir
/// tür olarak eklenir ve `TransferEngine` protokolünü uygular. Kayıtlı işler türlerini taşır.
public enum JobKind: String, Codable, CaseIterable, Sendable {
    case rsync
}

/// Kaynak klasör nasıl kopyalanır? rsync'te kaynak yolun sonundaki "/" bunu belirler; arayüzde seçenek olarak sunulur.
public enum CopyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// "Kaynak" → hedef/Kaynak/… (Finder'daki kopyalama gibi; varsayılan).
    case folder
    /// "Kaynak/" → hedef/… (klasörün içindekiler doğrudan hedefe).
    case contents

    public var id: String { rawValue }
}

/// Bir işin kopyalama seçenekleri. Yeni alanlar varsayılanla eklenir; eski kayıtlar okunmaya devam eder.
public struct CopyOptions: Codable, Equatable, Sendable {
    public var copyMode: CopyMode
    /// İzinleri, sahibi, grubu ve ACL'leri koru (-pogA). exFAT/FAT hedefte her durumda kapalıdır.
    public var preservePermissions: Bool
    /// Genişletilmiş öznitelikleri (Finder etiketleri, karantina…) koru (-X). Kapalıyken de karantina işareti aktarılır.
    public var preserveExtendedAttributes: Bool
    /// Kaynakta olmayan dosyaları hedeften sil (--delete). Yalnızca kullanıcı açıkça seçip onaylarsa.
    public var deleteExtraneous: Bool
    /// .Spotlight-V100, .Trashes, .fseventsd gibi macOS sistem klasörlerini dışarıda bırak.
    public var excludeSystemFolders: Bool
    /// rsync'in kum havuzunda kullanılabilen öteki seçenekleri (süzgeçler, anlık görüntüler, ilerleme ayrıntısı…).
    public var advanced: AdvancedOptions

    public init(
        copyMode: CopyMode = .folder, preservePermissions: Bool = false, preserveExtendedAttributes: Bool = true,
        deleteExtraneous: Bool = false, excludeSystemFolders: Bool = true, advanced: AdvancedOptions = AdvancedOptions()
    ) {
        self.copyMode = copyMode
        self.preservePermissions = preservePermissions
        self.preserveExtendedAttributes = preserveExtendedAttributes
        self.deleteExtraneous = deleteExtraneous
        self.excludeSystemFolders = excludeSystemFolders
        self.advanced = advanced
    }

    private enum CodingKeys: String, CodingKey {
        case copyMode, preservePermissions, preserveExtendedAttributes, deleteExtraneous, excludeSystemFolders, advanced
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CopyOptions()
        copyMode = (try? container.decodeIfPresent(CopyMode.self, forKey: .copyMode)) ?? defaults.copyMode
        preservePermissions = (try? container.decodeIfPresent(Bool.self, forKey: .preservePermissions)) ?? defaults.preservePermissions
        preserveExtendedAttributes = (try? container.decodeIfPresent(Bool.self, forKey: .preserveExtendedAttributes))
            ?? defaults.preserveExtendedAttributes
        deleteExtraneous = (try? container.decodeIfPresent(Bool.self, forKey: .deleteExtraneous)) ?? defaults.deleteExtraneous
        excludeSystemFolders = (try? container.decodeIfPresent(Bool.self, forKey: .excludeSystemFolders)) ?? defaults.excludeSystemFolders
        advanced = (try? container.decodeIfPresent(AdvancedOptions.self, forKey: .advanced)) ?? defaults.advanced
    }
}

/// İş durumu (Transmission'daki gibi). `scanning` ve `copying` yalnızca çalışan iştedir.
public enum JobStatus: String, Codable, CaseIterable, Sendable {
    case waiting, scanning, copying, paused, finished, failed

    public var isActive: Bool { self == .scanning || self == .copying }
}

/// Bir çalıştırmanın sonucu (motordan bağımsız sınıflar; rsync çıkış kodları `RsyncOutcome` ile buraya çevrilir).
public enum JobResultKind: String, Codable, Sendable, CaseIterable {
    /// Her şey kopyalandı.
    case succeeded
    /// Kopyalandı; exFAT/FAT hedefin saklayamadığı izin, sahip ya da zaman bilgisi uyarıları yok sayıldı.
    case succeededWithNotes
    /// Kopyalama sırasında kaynaktaki bazı dosyalar silindi ya da taşındı (rsync 24).
    case sourceFilesVanished
    /// Bazı dosyalar ya da öznitelikler aktarılamadı (rsync 23).
    case partial
    /// Kullanıcı durdurdu (rsync 20).
    case cancelled
    /// `--stop-at` / `--stop-after` sınırına ulaşıldı (rsync 30, "stopping at requested limit"); iş sürdürülebilir.
    case stoppedAtLimit
    case destinationFull
    case destinationReadOnly
    case permissionDenied
    case sourceMissing
    /// Hedef klasör yok (ör. harici disk takılı değil).
    case destinationMissing
    /// Kaynak ile hedefteki karşılığı çakışıyor (bkz. `JobValidation`).
    case overlapping
    /// Kullanılabilir bir rsync bulunamadı.
    case engineMissing
    /// rsync bu seçeneği ya da işlemi desteklemiyor (rsync 1, 4): motor uyumsuz.
    case unsupported
    /// Dosya G/Ç ya da veri akışı hatası (rsync 11, 12, 30…).
    case ioError
    case failed

    /// İş "bitti" sayılır mı (yoksa "hatalı")?
    public var isSuccess: Bool { self == .succeeded || self == .succeededWithNotes || self == .sourceFilesVanished }
}

public struct JobResult: Codable, Equatable, Sendable {
    public var kind: JobResultKind
    public var exitCode: Int32?
    /// Zararsız sayılan uyarıların sayısı (`succeededWithNotes`).
    public var noteCount: Int
    /// rsync'in kısa tanı satırları (ham, İngilizce).
    public var detail: String
    /// Yer yetmediğinde gereken ve boş bayt (`destinationFull`); yazma sürerken durdurulduysa `requiredBytes` nil'dir.
    public var requiredBytes: Int64?
    public var availableBytes: Int64?

    public init(
        kind: JobResultKind, exitCode: Int32? = nil, noteCount: Int = 0, detail: String = "",
        requiredBytes: Int64? = nil, availableBytes: Int64? = nil
    ) {
        self.kind = kind
        self.exitCode = exitCode
        self.noteCount = noteCount
        self.detail = detail
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
    }

    private enum CodingKeys: String, CodingKey { case kind, exitCode, noteCount, detail, requiredBytes, availableBytes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decodeIfPresent(JobResultKind.self, forKey: .kind)) ?? .failed
        exitCode = try? container.decodeIfPresent(Int32.self, forKey: .exitCode)
        noteCount = (try? container.decodeIfPresent(Int.self, forKey: .noteCount)) ?? 0
        detail = (try? container.decodeIfPresent(String.self, forKey: .detail)) ?? ""
        requiredBytes = try? container.decodeIfPresent(Int64.self, forKey: .requiredBytes)
        availableBytes = try? container.decodeIfPresent(Int64.self, forKey: .availableBytes)
    }
}

/// İş günlüğünün bir satırı. Metin ya bir yerelleştirme anahtarı (arayüz çevirir) ya da motorun ham çıktısıdır.
public struct JobLogEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Level: String, Codable, Sendable { case info, warning, error }

    public var id: UUID
    public var date: Date
    public var level: Level
    /// `LKey` ham değeri; doluysa `arguments` ile biçimlenip gösterilir.
    public var key: String?
    public var arguments: [String]
    /// Motorun ham çıktısı (çevrilmez).
    public var raw: String?

    public init(id: UUID = UUID(), date: Date = Date(), level: Level, key: LKey? = nil, arguments: [String] = [], raw: String? = nil) {
        self.id = id
        self.date = date
        self.level = level
        self.key = key?.rawValue
        self.arguments = arguments
        self.raw = raw
    }
}

/// Kuyruktaki bir kopyalama işi.
public struct TransferJob: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: JobKind
    public var source: URL
    public var destination: URL
    public var options: CopyOptions
    public var status: JobStatus
    public var progress: TransferProgress?
    public var result: JobResult?
    public var log: [JobLogEntry]
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Uygulama iş çalışırken kapandıysa (ya da çöktüyse) true: iş duraklatılmış olarak geri gelir.
    public var wasInterrupted: Bool

    /// Günlükte tutulan en çok satır; uzun süreli işlerde kayıt dosyası şişmesin.
    public static let maxLogEntries = 500

    public init(
        id: UUID = UUID(), kind: JobKind = .rsync, source: URL, destination: URL, options: CopyOptions = CopyOptions(),
        status: JobStatus = .waiting, createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.destination = destination
        self.options = options
        self.status = status
        self.progress = nil
        self.result = nil
        self.log = []
        self.createdAt = createdAt
        self.startedAt = nil
        self.finishedAt = nil
        self.wasInterrupted = false
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, source, destination, options, status, progress, result, log, createdAt, startedAt, finishedAt, wasInterrupted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        source = try container.decode(URL.self, forKey: .source)
        destination = try container.decode(URL.self, forKey: .destination)
        // Bilinmeyen (daha yeni bir sürümün eklediği) motor türü ya da durum işi silmez; varsayılana düşer.
        kind = (try? container.decodeIfPresent(JobKind.self, forKey: .kind)) ?? .rsync
        options = (try? container.decodeIfPresent(CopyOptions.self, forKey: .options)) ?? CopyOptions()
        status = (try? container.decodeIfPresent(JobStatus.self, forKey: .status)) ?? .waiting
        progress = try? container.decodeIfPresent(TransferProgress.self, forKey: .progress)
        result = try? container.decodeIfPresent(JobResult.self, forKey: .result)
        log = (try? container.decodeIfPresent([JobLogEntry].self, forKey: .log)) ?? []
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        startedAt = try? container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try? container.decodeIfPresent(Date.self, forKey: .finishedAt)
        wasInterrupted = (try? container.decodeIfPresent(Bool.self, forKey: .wasInterrupted)) ?? false
    }

    /// Kaynağın hedefteki karşılığı: "klasörün kendisi" kipinde hedef/Ad, "içeriği" kipinde hedefin kendisi.
    /// Kaynak bir dosyaysa her zaman hedef/Ad.
    public func target(sourceIsDirectory: Bool) -> URL {
        if sourceIsDirectory && options.copyMode == .contents { return destination }
        return destination.appendingPathComponent(source.lastPathComponent)
    }

    public mutating func appendLog(_ entry: JobLogEntry) {
        log.append(entry)
        if log.count > Self.maxLogEntries { log.removeFirst(log.count - Self.maxLogEntries) }
    }
}

/// İş oluşturulmadan önceki denetimler.
public enum JobValidation {
    public enum Problem: Error, Equatable, Sendable {
        case sourceMissing
        case destinationMissing
        case destinationNotDirectory
        /// Kaynak ve hedef aynı yer ya da biri ötekinin içinde: kopya kendi içine büyür ya da `--delete` kaynağa ulaşır.
        case overlapping
    }

    /// Kaynağın hedefteki karşılığı (`TransferJob.target`) kaynakla çakışmamalı: karşılık kaynağın içindeyse kopya kendi
    /// içine büyür; kaynak karşılığın içindeyse (ör. "içeriği" kipinde hedef = ev klasörü) `--delete` kaynağın
    /// kardeşlerini, hatta kaynağın kendisini silmeye kalkar. "Klasörün kendisi" kipinde kaynağın kendi üst klasörüne
    /// kopyalamak karşılığı kaynağın kendisi yapar. Kum havuzu kaynağa yazmayı zaten engeller; bu denetim işi baştan reddeder.
    public static func check(
        source: URL, destination: URL, copyMode: CopyMode, fileManager: FileManager = .default
    ) -> Problem? {
        var info = stat()
        guard lstat(source.path, &info) == 0 else { return .sourceMissing }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) else { return .destinationMissing }
        guard isDirectory.boolValue else { return .destinationNotDirectory }
        let sourceIsDirectory = info.st_mode & S_IFMT == S_IFDIR
        let job = TransferJob(source: source, destination: destination, options: CopyOptions(copyMode: copyMode))
        let resolvedSource = SandboxProfile.resolved(source).path
        let target = SandboxProfile.resolved(job.target(sourceIsDirectory: sourceIsDirectory)).path
        func inside(_ path: String, _ base: String) -> Bool { path == base || base == "/" || path.hasPrefix(base + "/") }
        return inside(target, resolvedSource) || inside(resolvedSource, target) ? .overlapping : nil
    }
}
