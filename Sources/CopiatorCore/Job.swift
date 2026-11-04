// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// İşi yürüten motorun türü. Yalnızca yerel rsync vardır; başka bir yerel motor yeni bir tür olarak eklenir ve
/// `TransferEngine` protokolünü uygular. Kayıtlı işler türlerini taşır.
public enum JobKind: String, Codable, CaseIterable, Sendable {
    case rsync
    /// İki yönlü eşitleme (bkz. `SyncEngine`): iki klasör arasında eksikler iki yöne de kopyalanır, hiçbir şey silinmez.
    case sync
}

/// Kaynak klasör nasıl kopyalanır? rsync'te kaynak yolun sonundaki "/" bunu belirler; arayüzde seçenek olarak sunulur.
public enum CopyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// "Kaynak" → hedef/Kaynak/… (Finder'daki kopyalama gibi; varsayılan).
    case folder
    /// "Kaynak/" → hedef/… (klasörün içindekiler doğrudan hedefe).
    case contents

    public var id: String { rawValue }
}

/// Kopyalama bitince hedefin kaynakla yeniden karşılaştırılması.
public enum VerifyAfterCopy: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    /// Boyut ve değişiklik zamanı (`-n`).
    case quick
    /// İçerik sağlama toplamıyla (`-n -c`); yavaş ama kesin.
    case checksum

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
    /// rsync'in kum havuzunda kullanılabilen öteki seçenekleri (süzgeçler, önceki yedek, ilerleme ayrıntısı…).
    public var advanced: AdvancedOptions
    /// Otomatik anlık görüntüler: her çalıştırma hedefte tarihli yeni bir klasöre yazar (bkz. `SnapshotStore`).
    public var snapshots: SnapshotOptions
    /// Kopyalama bitince hedef kaynakla karşılaştırılır; fark varsa iş "doğrulanamadı" olarak biter.
    public var verifyAfterCopy: VerifyAfterCopy
    /// Hedef disk takılınca iş kendiliğinden başlar; disk takılı değilken bekler (hata vermez).
    public var runWhenConnected: Bool
    /// Başarılı bir çalıştırmadan sonra hedef disk, onu kullanan başka iş ya da denetim kalmayınca çıkarılır (bkz. `DiskEject`).
    public var ejectWhenDone: Bool
    /// Hedefte aynı adlı dosya varken ne yapılacağı (varsayılan: sor).
    public var conflictPolicy: ConflictPolicy
    /// Bu ayar gelmeden önce kurulmuş iş ya da rutin: ilk karar sayfasında "hatırla" önceden işaretli gelir; böylece eski
    /// bir yedekleme işi her çalıştırmada aynı dosyaları yeniden sormaz. İlk karardan sonra kalkar.
    public var suggestsRememberingConflictChoice: Bool
    /// Dosya seçme kuralları (rutin rotaları); nil ise kaynağın tamamı kopyalanır. Kurallar her çalıştırmada kaynakta
    /// değerlendirilir (bkz. `RuleSelection`).
    public var rules: RuleGroup?
    /// Seçilen dosyaların hedefte yerleşimi (alt klasör ve ad şablonları; rutin rotaları). nil ise klasör yapısı ve adlar
    /// olduğu gibi kalır (bkz. `RoutePlacement`, `PlacementStaging`).
    public var placement: RoutePlacement?
    /// Yalnızca kaynağın kökündeki bu öğeler (Finder'da seçilip bir rutine gönderilenler); nil ise kaynağın tamamı.
    public var selectedItems: [String]?
    /// "Taşı": kopyalamadan sonra hedefteki karşılığıyla içeriği birebir aynı olan kaynak dosyalar Çöp Sepeti'ne taşınır
    /// (bkz. `SourceTrash`). Yalnızca kullanıcı açıkça seçip onaylarsa; anlık görüntüde kullanılmaz.
    public var trashSourceAfterCopy: Bool

    public init(
        copyMode: CopyMode = .folder, preservePermissions: Bool = false, preserveExtendedAttributes: Bool = true,
        deleteExtraneous: Bool = false, excludeSystemFolders: Bool = true, advanced: AdvancedOptions = AdvancedOptions(),
        snapshots: SnapshotOptions = SnapshotOptions(), verifyAfterCopy: VerifyAfterCopy = .off, runWhenConnected: Bool = false,
        rules: RuleGroup? = nil, conflictPolicy: ConflictPolicy = .ask, suggestsRememberingConflictChoice: Bool = false,
        placement: RoutePlacement? = nil, selectedItems: [String]? = nil, trashSourceAfterCopy: Bool = false, ejectWhenDone: Bool = false
    ) {
        self.copyMode = copyMode
        self.preservePermissions = preservePermissions
        self.preserveExtendedAttributes = preserveExtendedAttributes
        self.deleteExtraneous = deleteExtraneous
        self.excludeSystemFolders = excludeSystemFolders
        self.advanced = advanced
        self.snapshots = snapshots
        self.verifyAfterCopy = verifyAfterCopy
        self.runWhenConnected = runWhenConnected
        self.rules = rules
        self.conflictPolicy = conflictPolicy
        self.suggestsRememberingConflictChoice = suggestsRememberingConflictChoice
        self.placement = placement
        self.selectedItems = selectedItems
        self.trashSourceAfterCopy = trashSourceAfterCopy
        self.ejectWhenDone = ejectWhenDone
    }

    private enum CodingKeys: String, CodingKey {
        case copyMode, preservePermissions, preserveExtendedAttributes, deleteExtraneous, excludeSystemFolders, advanced
        case snapshots, verifyAfterCopy, runWhenConnected, rules, conflictPolicy, suggestsRememberingConflictChoice, placement
        case selectedItems, trashSourceAfterCopy, ejectWhenDone
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
        snapshots = (try? container.decodeIfPresent(SnapshotOptions.self, forKey: .snapshots)) ?? defaults.snapshots
        verifyAfterCopy = (try? container.decodeIfPresent(VerifyAfterCopy.self, forKey: .verifyAfterCopy)) ?? defaults.verifyAfterCopy
        runWhenConnected = (try? container.decodeIfPresent(Bool.self, forKey: .runWhenConnected)) ?? defaults.runWhenConnected
        rules = (try? container.decodeIfPresent(RuleGroup.self, forKey: .rules)) ?? nil
        placement = (try? container.decodeIfPresent(RoutePlacement.self, forKey: .placement)) ?? nil
        selectedItems = (try? container.decodeIfPresent([String].self, forKey: .selectedItems)) ?? nil
        trashSourceAfterCopy = (try? container.decodeIfPresent(Bool.self, forKey: .trashSourceAfterCopy)) ?? false
        ejectWhenDone = (try? container.decodeIfPresent(Bool.self, forKey: .ejectWhenDone)) ?? false
        conflictPolicy = (try? container.decodeIfPresent(ConflictPolicy.self, forKey: .conflictPolicy)) ?? defaults.conflictPolicy
        // Ayarı hiç olmayan (bu sürümden önce kaydedilmiş) seçenekler eski kabul edilir.
        suggestsRememberingConflictChoice = (try? container.decodeIfPresent(Bool.self, forKey: .suggestsRememberingConflictChoice))
            ?? !container.contains(.conflictPolicy)
    }

    /// Seçeneklerdeki sorunlar (gelişmiş seçenekler ve saklama kuralları). Anlık görüntü kipinde "önceki yedek"
    /// ayarı kullanılmadığı için denetlenmez.
    public func problems(source: URL?, now: Date = Date()) -> [AdvancedOptions.Problem] {
        var advanced = advanced
        if snapshots.enabled {
            advanced.referenceMode = .none
            advanced.referenceDirectory = nil
        }
        var problems = advanced.problems(source: source, now: now)
        if snapshots.enabled, !snapshots.isValid { problems.append(.invalidRetention) }
        if let rules { problems += rules.problems().map { .rules($0) } }
        return problems
    }
}

/// İş durumu (Transmission'daki gibi). `scanning`, `copying` ve `verifying` yalnızca çalışan iştedir.
public enum JobStatus: String, Codable, CaseIterable, Sendable {
    case waiting, scanning, copying, verifying, paused, finished, failed

    public var isActive: Bool { self == .scanning || self == .copying || self == .verifying }
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
    /// Hedefte aynı adlı dosyalar var ve ne yapılacağı sorulmalı: iş kopyalamadan duraklar (`noteCount` çakışma sayısı).
    case awaitingDecision
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
    /// Kum havuzu açık ama sandbox-exec bu Mac'te yok: rsync korumasız başlatılmadı.
    case sandboxUnavailable
    /// rsync bu seçeneği ya da işlemi desteklemiyor (rsync 1, 4): motor uyumsuz.
    case unsupported
    /// Dosya G/Ç ya da veri akışı hatası (rsync 11, 12, 30…).
    case ioError
    /// Kopyalandı, ama kopyalama sonrası doğrulama hedefte farklar buldu ya da tamamlanamadı.
    case verificationFailed
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
    /// `.awaitingDecision` sonucunun klasör kararı ("Klasörü sor") beklediğini belirten `detail` değeri.
    public static let placementsDetail = "placements"
    /// Yer yetmediğinde gereken ve boş bayt (`destinationFull`); yazma sürerken durdurulduysa `requiredBytes` nil'dir.
    public var requiredBytes: Int64?
    public var availableBytes: Int64?
    /// Bu çalıştırmanın tamamladığı anlık görüntünün adı ("2026-10-21-143005").
    public var snapshot: String?
    /// Kopyalama sonrası doğrulamanın bulduğu fark sayısı (doğrulama yapılmadıysa nil).
    public var differenceCount: Int?

    public init(
        kind: JobResultKind, exitCode: Int32? = nil, noteCount: Int = 0, detail: String = "",
        requiredBytes: Int64? = nil, availableBytes: Int64? = nil, snapshot: String? = nil, differenceCount: Int? = nil
    ) {
        self.kind = kind
        self.exitCode = exitCode
        self.noteCount = noteCount
        self.detail = detail
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
        self.snapshot = snapshot
        self.differenceCount = differenceCount
    }

    private enum CodingKeys: String, CodingKey {
        case kind, exitCode, noteCount, detail, requiredBytes, availableBytes, snapshot, differenceCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decodeIfPresent(JobResultKind.self, forKey: .kind)) ?? .failed
        exitCode = try? container.decodeIfPresent(Int32.self, forKey: .exitCode)
        noteCount = (try? container.decodeIfPresent(Int.self, forKey: .noteCount)) ?? 0
        detail = (try? container.decodeIfPresent(String.self, forKey: .detail)) ?? ""
        requiredBytes = try? container.decodeIfPresent(Int64.self, forKey: .requiredBytes)
        availableBytes = try? container.decodeIfPresent(Int64.self, forKey: .availableBytes)
        snapshot = (try? container.decodeIfPresent(String.self, forKey: .snapshot)) ?? nil
        differenceCount = (try? container.decodeIfPresent(Int.self, forKey: .differenceCount)) ?? nil
    }
}

/// Bir çalıştırmanın geçmiş kaydı (başlangıç, bitiş, sonuç, aktarılan bayt ve dosya).
public struct JobRun: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date
    public var result: JobResult
    public var bytesTransferred: Int64?
    public var filesTransferred: Int?

    public init(
        id: UUID = UUID(), startedAt: Date, finishedAt: Date, result: JobResult, bytesTransferred: Int64? = nil,
        filesTransferred: Int? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.result = result
        self.bytesTransferred = bytesTransferred
        self.filesTransferred = filesTransferred
    }

    public var duration: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }

    private enum CodingKeys: String, CodingKey { case id, startedAt, finishedAt, result, bytesTransferred, filesTransferred }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = (try? container.decodeIfPresent(Date.self, forKey: .finishedAt)) ?? startedAt
        result = (try? container.decodeIfPresent(JobResult.self, forKey: .result)) ?? JobResult(kind: .failed)
        bytesTransferred = (try? container.decodeIfPresent(Int64.self, forKey: .bytesTransferred)) ?? nil
        filesTransferred = (try? container.decodeIfPresent(Int.self, forKey: .filesTransferred)) ?? nil
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
    /// Kaynağın ya da hedefin diski çıkarıldığı için duraklatıldı: disk yeniden takılınca kendiliğinden sürer.
    public var suspendedForDisk: Bool
    /// Önceki çalıştırmalar, eskiden yeniye.
    public var history: [JobRun]
    /// İşi oluşturan rutin ve rota (rutin silinince nil olur; iş sıradan bir iş olarak kalır).
    public var routineID: UUID?
    public var routeID: UUID?
    public var routineName: String?
    /// Karar bekleyen çakışmalar (iş "karar bekliyor" olarak duraklatıldı).
    public var pendingConflicts: ConflictReport?
    /// Bir sonraki çalıştırmada uygulanacak kararlar; iş bitince silinir.
    public var conflictResolution: ConflictResolution?
    /// "Klasörü sor" rotasında klasörü seçilmemiş dosyalar (iş "karar bekliyor" olarak duraklatıldı).
    public var pendingPlacements: PlacementReport?
    /// Seçilen klasörler; iş bitince silinir.
    public var placementResolution: PlacementResolution?

    /// Günlükte tutulan en çok satır; uzun süreli işlerde kayıt dosyası şişmesin.
    public static let maxLogEntries = 500
    /// Geçmişte tutulan en çok çalıştırma.
    public static let maxHistoryEntries = 100

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
        self.suspendedForDisk = false
        self.history = []
        self.routineID = nil
        self.routeID = nil
        self.routineName = nil
        self.pendingConflicts = nil
        self.conflictResolution = nil
        self.pendingPlacements = nil
        self.placementResolution = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, source, destination, options, status, progress, result, log, createdAt, startedAt, finishedAt, wasInterrupted
        case suspendedForDisk, history, routineID, routeID, routineName, pendingConflicts, conflictResolution, pendingPlacements
        case placementResolution
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
        suspendedForDisk = (try? container.decodeIfPresent(Bool.self, forKey: .suspendedForDisk)) ?? false
        history = (try? container.decodeIfPresent([JobRun].self, forKey: .history)) ?? []
        routineID = (try? container.decodeIfPresent(UUID.self, forKey: .routineID)) ?? nil
        routeID = (try? container.decodeIfPresent(UUID.self, forKey: .routeID)) ?? nil
        routineName = (try? container.decodeIfPresent(String.self, forKey: .routineName)) ?? nil
        pendingConflicts = (try? container.decodeIfPresent(ConflictReport.self, forKey: .pendingConflicts)) ?? nil
        conflictResolution = (try? container.decodeIfPresent(ConflictResolution.self, forKey: .conflictResolution)) ?? nil
        pendingPlacements = (try? container.decodeIfPresent(PlacementReport.self, forKey: .pendingPlacements)) ?? nil
        placementResolution = (try? container.decodeIfPresent(PlacementResolution.self, forKey: .placementResolution)) ?? nil
    }

    /// Kullanıcının kararı bekleniyor: hedefte aynı adlı dosyalar ya da klasörü seçilmemiş dosyalar.
    public var isAwaitingDecision: Bool { (pendingConflicts != nil || pendingPlacements != nil) && status == .paused }

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

    public mutating func appendRun(_ run: JobRun) {
        history.append(run)
        if history.count > Self.maxHistoryEntries { history.removeFirst(history.count - Self.maxHistoryEntries) }
    }

    /// Kaynak ve hedef şu an erişilebilir (diskleri takılı).
    public var pathsAvailable: Bool {
        var info = stat()
        guard lstat(source.path, &info) == 0 else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// İşin kaynağı ya da hedefi bu birimde mi (`/Volumes/Yedek`)? Başlangıç birimi ("/") hiçbir işle eşleşmez:
    /// takılıp çıkarılan diskler her zaman kendi bağlama noktalarındadır.
    public func uses(volume: URL) -> Bool {
        usesAsDestination(volume: volume) || Self.path(source, isOn: volume)
    }

    public func usesAsDestination(volume: URL) -> Bool { Self.path(destination, isOn: volume) }

    static func path(_ url: URL, isOn volume: URL) -> Bool {
        let base = RsyncCommand.absolutePath(volume)
        guard base != "/" else { return false }
        let path = RsyncCommand.absolutePath(url)
        return path == base || path.hasPrefix(base + "/")
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
