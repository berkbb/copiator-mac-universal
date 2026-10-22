// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// İş kuyruğunu diske kaydeder ve geri okur (`~/Library/Application Support/Copiator/jobs.json`).
///
/// Dosya atomik yazılır (önce geçici ad, sonra yerine taşıma): yazma sırasında çökme eski kuyruğu bozmaz.
/// Biçim sürümlüdür; bilinmeyen alanlar yok sayılır, eksik alanlar varsayılanla doldurulur.
public struct JobStore: Sendable {
    public static let formatVersion = 1

    public let url: URL

    public init(url: URL = JobStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Copiator/jobs.json")
    }

    private struct Envelope: Codable {
        var version: Int
        var jobs: [TransferJob]
    }

    /// Kayıtlı işler. Dosya yoksa boş liste; bozuksa hata (çağıran dosyayı yedekleyip boş kuyrukla başlar).
    public func load() throws -> [TransferJob] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Envelope.self, from: data).jobs
    }

    public func save(_ jobs: [TransferJob]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: Self.formatVersion, jobs: jobs))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Okunamayan kayıt dosyasını "jobs.json.bozuk-<zaman>" adıyla kenara alır; kullanıcının işleri sessizce silinmez.
    @discardableResult
    public func quarantineCorruptFile(now: Date = Date()) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("jobs.corrupt-\(Int(now.timeIntervalSince1970)).json")
        return (try? FileManager.default.moveItem(at: url, to: backup)) == nil ? nil : backup
    }
}

/// Kuyruğun saf kuralları (arayüz ve süreçten bağımsız, test edilebilir). İşler sırayla, birer birer çalışır.
public enum JobQueue {
    /// Sıradaki çalıştırılacak iş: listede ilk "bekliyor" durumundaki. Diski takılı olmadığı için bekleyen iş
    /// (`isWaitingForDisk`) atlanır; sıradaki iş başlar.
    public static func next(in jobs: [TransferJob], pathsAvailable: (TransferJob) -> Bool = { $0.pathsAvailable }) -> TransferJob.ID? {
        jobs.first { $0.status == .waiting && !isWaitingForDisk($0, pathsAvailable: pathsAvailable) }?.id
    }

    /// "Disk takılınca başla" seçili iş, kaynağının ya da hedefinin diski takılı değilken hata vermez, bekler.
    public static func isWaitingForDisk(_ job: TransferJob, pathsAvailable: (TransferJob) -> Bool = { $0.pathsAvailable }) -> Bool {
        job.status == .waiting && job.options.runWhenConnected && !pathsAvailable(job)
    }

    /// Uygulama açılırken: kapanış ya da çökme sırasında çalışan iş duraklatılmış ve "kesildi" olarak işaretlenir;
    /// kullanıcı sürdürünce rsync aynı komutla kaldığı yerden devam eder (`--partial`).
    public static func restoredAfterLaunch(_ jobs: [TransferJob]) -> [TransferJob] {
        jobs.map { job in
            var job = job
            if job.status.isActive {
                job.status = .paused
                job.wasInterrupted = true
            }
            return job
        }
    }

    public static func canPause(_ job: TransferJob) -> Bool { job.status == .waiting || job.status.isActive }
    public static func canResume(_ job: TransferJob) -> Bool { job.status == .paused || job.status == .failed }
    /// Bitmiş bir iş yeniden çalıştırılabilir (güncel yedek: yalnızca değişenler kopyalanır).
    public static func canRunAgain(_ job: TransferJob) -> Bool { job.status == .finished }
    public static func canRemove(_ job: TransferJob) -> Bool { !job.status.isActive }
    public static func canVerify(_ job: TransferJob) -> Bool { !job.status.isActive }
    /// Çalışmayan bir işin kaynağı, hedefi ve seçenekleri değiştirilebilir (geçmişi ve günlüğü korunur).
    public static func canEdit(_ job: TransferJob) -> Bool { !job.status.isActive }

    /// İşi sıraya alır (sürdürme, yeniden çalıştırma).
    public static func requeue(_ job: inout TransferJob) {
        job.status = .waiting
        job.result = nil
        job.suspendedForDisk = false
    }

    /// Bir olayı işe uygular.
    public static func apply(_ event: TransferEvent, to job: inout TransferJob) {
        switch event {
        case .phase(let status):
            job.status = status
            if status == .scanning { job.progress = nil }
        case .progress(let progress):
            job.progress = progress
            // Liste sayacı (flist2) gelirken iş hâlâ taranıyordur.
            if job.status == .scanning, !progress.isListing { job.status = .copying }
        case .log(let entry):
            job.appendLog(entry)
        case .logBatch(let entries):
            entries.forEach { job.appendLog($0) }
        case .conflicts(let report):
            job.pendingConflicts = report
        case .conflictsSettled:
            // Sürdürmede yeni görünen aynı adlı dosyalar bu geçişin yazdıklarıdır: olağan güncelleme (değiştir).
            var resolution = job.conflictResolution ?? ConflictResolution()
            resolution.others = resolution.others ?? .replace
            job.conflictResolution = resolution
            job.pendingConflicts = nil
        }
    }

    /// Çalıştırma bitince işin son durumu. Kullanıcının iptali ve süre sınırı (`--stop-at`/`--stop-after`) işi
    /// "duraklatıldı" yapar: iş aynı komutla sürdürülebilir.
    public static func finish(_ job: inout TransferJob, with result: JobResult, at date: Date = Date()) {
        job.appendRun(JobRun(
            startedAt: job.startedAt ?? date, finishedAt: date, result: result,
            bytesTransferred: job.progress?.bytesTransferred, filesTransferred: job.progress?.filesTransferred
        ))
        job.result = result
        job.wasInterrupted = false
        switch result.kind {
        case .awaitingDecision:
            // Çakışma listesi olaydan gelir (`.conflicts`); karar verilince iş yeniden sıraya girer.
            job.status = .paused
        case .cancelled, .stoppedAtLimit:
            // Verilen kararlar, iş sürdürülünce de geçerlidir.
            job.status = .paused
            job.pendingConflicts = nil
        case let kind where kind.isSuccess:
            job.pendingConflicts = nil
            job.conflictResolution = nil
            job.status = .finished
            job.finishedAt = date
            if var progress = job.progress {
                progress.fraction = 1
                progress.isEstimating = false
                progress.itemsRemaining = 0
                progress.remainingSeconds = nil
                job.progress = progress
            }
        default:
            job.status = .failed
            job.finishedAt = date
            job.pendingConflicts = nil
            job.conflictResolution = nil
        }
    }

    /// Bir işi listede başka bir konuma taşır (sürükle-bırak sıralama).
    /// `destination`, taşımadan ÖNCEKİ listeye göre ekleme konumudur (SwiftUI `onMove` ile aynı anlam).
    public static func move(_ jobs: inout [TransferJob], from source: IndexSet, to destination: Int) {
        let valid = source.filter { jobs.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.map { jobs[$0] }
        let insertion = min(max(0, destination), jobs.count) - valid.filter { $0 < destination }.count
        for index in valid.sorted(by: >) { jobs.remove(at: index) }
        jobs.insert(contentsOf: moving, at: min(max(0, insertion), jobs.count))
    }
}
