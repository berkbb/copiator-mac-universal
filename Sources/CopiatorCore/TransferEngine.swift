// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Çalışan bir işin bildirdiği olaylar. Olaylar arka plandan gelir; çağıran ana iş parçacığına taşır.
public enum TransferEvent: Sendable, Equatable {
    /// Kaynak taranıyor (boyut, boş alan ön denetimi) ya da kopyalama başladı.
    case phase(JobStatus)
    case progress(TransferProgress)
    case log(JobLogEntry)
    /// Birden çok günlük satırı (değişiklik listesi, istatistikler): kayıt dosyası satır başına değil bir kez yazılır.
    case logBatch([JobLogEntry])
    /// Hedefte aynı adlı dosyalar var ve karar bekleniyor (iş ardından `.awaitingDecision` ile biter).
    case conflicts(ConflictReport)
    /// Çakışmalar bu geçiş için karara bağlandı (ya da hiç yoktu); kopyalama başlıyor. İş duraklatılıp sürdürülürse bu
    /// geçişin hedefe yazdığı dosyalar yeniden sorulmaz.
    case conflictsSettled
    /// "Klasörü sor" rotasında klasörü seçilmemiş dosyalar var (iş ardından `.awaitingDecision` ile biter).
    case placements(PlacementReport)
}

/// Motoru çalıştırmak için gereken ortam: hangi ikili, hangi yetenekler, kum havuzu.
public struct EngineContext: Sendable {
    public var executable: URL
    public var info: EngineInfo
    /// Motor sandbox-exec altında çalışsın mı (Ayarlar › Gelişmiş).
    public var sandboxed: Bool
    public var home: URL
    /// Motorun geçici listelerini (seçilen dosyalar, dışlananlar, liste kopyaları) yazdığı klasör. Her çalıştırma burada
    /// kendine özel (0700) bir alt klasör açar ve bitince siler. Testler kendi klasörlerini verir.
    public var scratchDirectory: URL
    /// "Taşı" adımında öğeyi Çöp Sepeti'ne taşır (testler kendi klasörlerini verir).
    public var trashItem: @Sendable (URL) -> Bool = { SourceTrash.systemTrash($0) }

    public init(
        executable: URL, info: EngineInfo, sandboxed: Bool = true, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        scratchDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.executable = executable
        self.info = info
        self.sandboxed = sandboxed
        self.home = home
        self.scratchDirectory = scratchDirectory
    }
}

/// Doğrulamanın sonucu: farklar ve motorun çıkış durumu.
public struct VerifyReport: Sendable, Equatable {
    public var entries: [DiffEntry]
    public var result: JobResult
    public var checksum: Bool

    public init(entries: [DiffEntry], result: JobResult, checksum: Bool) {
        self.entries = entries
        self.result = result
        self.checksum = checksum
    }

    public func count(_ kind: DiffEntry.Kind) -> Int { entries.lazy.filter { $0.kind == kind }.count }

    /// İçerik farkı (eksik, değişmiş ya da fazla öğe) yok: hedef kaynağın tam kopyası.
    public var isIdentical: Bool { !entries.contains { $0.kind != .attributes } }
}

/// Bir iş türünü (`JobKind`) yürüten motor. İkinci bir motor (uzak rsync, aria2) bu protokolü uygulayıp
/// `TransferEngines.engine(for:)` kaydına eklenir; kuyruk, kayıt ve arayüz değişmez.
public protocol TransferEngine: Sendable {
    var kind: JobKind { get }

    /// İşi çalıştırır. İptal (Task.cancel) `.cancelled` sonucuyla döner; kesilen iş aynı çağrıyla sürdürülür.
    func run(_ job: TransferJob, context: EngineContext, onEvent: @escaping @Sendable (TransferEvent) -> Void) async -> JobResult

    /// İşi değişiklik yapmadan çalıştırıp hedefle kaynak arasındaki farkları listeler.
    func verify(_ job: TransferJob, context: EngineContext, checksum: Bool) async -> VerifyReport
}

public enum TransferEngines {
    public static func engine(for kind: JobKind) -> any TransferEngine {
        switch kind {
        case .rsync: RsyncEngine()
        case .sync: SyncEngine()
        }
    }
}
