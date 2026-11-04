// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Çalışan rsync'in stdout kayıtlarını sınıflandırır: ilerleme, dosya adı, liste sayacı, değişiklik satırı, istatistik.
///
/// Gerçek rsync 3.5.1 çıktısı (`--info=progress2,name1,flist2,stats2`, `-i`):
///
///     sending incremental file list            ← gürültü
///     src/a/f1                                 ← ad (name1), "\n" ile biter
///                   3  12%    0.00kB/s    0:00:00 (xfr#1, to-chk=4/8)   ← ilerleme, "\r" ile biter
///     >f+++++++++ src/a/f2                     ← değişiklik (-i)
///      1000 files...                           ← liste sayacı (flist2, yalnızca --no-inc-recursive)
///     Number of files: 8 (reg: 4, dir: 2, link: 2)   ← istatistik (stats2)
///
/// Dosya başı ilerlemede (`progress1`) satır biçimi aynıdır ama bayt ve yüzde o dosyanındır: toplam bayt, biten
/// dosyaların (ardında `xfr#` grubu olan satırların) boyutları toplanarak, genel oran denetlenen öğelerden bulunur.
public final class RsyncOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let perFile: Bool
    private let trackNames: Bool
    private let logChanges: Bool
    private let itemizeFormat: ItemizeParser.Format
    private let onProgress: @Sendable (TransferProgress) -> Void
    private let onChanges: @Sendable ([String]) -> Void

    private var current = TransferProgress()
    private var hasRealProgress = false
    private var completedBytes: Int64 = 0
    private var pendingChanges: [String] = []
    private var lastChangeFlush = Date.distantPast
    private var stats: [String] = []
    private var created: [String] = []
    private var createdTruncated = false
    private var otherChanges = 0

    /// Değişiklik satırları en çok bu aralıkla toplu bildirilir; tamponda en çok `maxBufferedChanges` satır tutulur
    /// (iş günlüğü zaten son `TransferJob.maxLogEntries` satırı saklar).
    public static let changeFlushInterval: TimeInterval = 1
    public static let maxBufferedChanges = TransferJob.maxLogEntries

    static let statsPrefixes = [
        "Number of ", "Total file size", "Total transferred file size", "Literal data", "Matched data", "File list ",
        "Total bytes ", "sent ", "total size is ",
    ]
    static let noise = ["sending incremental file list", "receiving incremental file list", "building file list", "done", "delta-transmission"]

    public init(
        advanced: AdvancedOptions,
        itemizeFormat: ItemizeParser.Format = .rsync3,
        onProgress: @escaping @Sendable (TransferProgress) -> Void,
        onChanges: @escaping @Sendable ([String]) -> Void
    ) {
        perFile = advanced.progressDetail == .perFile
        trackNames = advanced.showFileNames
        logChanges = advanced.logChanges
        self.itemizeFormat = itemizeFormat
        self.onProgress = onProgress
        self.onChanges = onChanges
    }

    public func consume(_ record: String) {
        var progressToSend: TransferProgress?
        var changesToSend: [String]?
        lock.withLock {
            if let parsed = RsyncProgressParser.parse(record) {
                progressToSend = merge(parsed)
                return
            }
            let line = record.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }
            if let listed = Self.listedCount(line) {
                guard !hasRealProgress else { return }
                current.filesListed = listed
                progressToSend = current
                return
            }
            if Self.statsPrefixes.contains(where: line.hasPrefix) {
                stats.append(line)
                return
            }
            if Self.noise.contains(where: { line.hasPrefix($0) }) || line.hasPrefix("created directory ") || line.hasSuffix(" files to consider") {
                return
            }
            if let change = ItemizeParser.parseLine(line, format: itemizeFormat) ?? (line.hasPrefix("*") ? DiffEntry(kind: .extra, path: line, isDirectory: false, code: "") : nil) {
                // Geri alma kaydı: eklenen öğeler (en çok `RunUndo.maxRecordedItems`), üzerine yazılan ya da silinenlerin sayısı.
                switch change.kind {
                case .missing:
                    if created.count < RunUndo.maxRecordedItems { created.append(change.path) } else { createdTruncated = true }
                case .changed, .extra:
                    otherChanges += 1
                case .attributes:
                    break
                }
                if logChanges {
                    pendingChanges.append(OpenSafety.visibleName(line))
                    if pendingChanges.count > Self.maxBufferedChanges { pendingChanges.removeFirst(pendingChanges.count - Self.maxBufferedChanges) }
                    if Date().timeIntervalSince(lastChangeFlush) >= Self.changeFlushInterval {
                        lastChangeFlush = Date()
                        changesToSend = pendingChanges
                        pendingChanges = []
                    }
                }
                if trackNames || logChanges {
                    current.currentItem = change.path
                    if hasRealProgress { progressToSend = current }
                }
                return
            }
            if trackNames {
                // "ad -> hedef" (bağlantı) gösterimden atılır.
                let name = line.components(separatedBy: " -> ").first ?? line
                current.currentItem = ItemizeParser.unescape(name)
                if hasRealProgress { progressToSend = current }
            }
        }
        if let changesToSend, !changesToSend.isEmpty { onChanges(changesToSend) }
        if let progressToSend { onProgress(progressToSend) }
    }

    /// Kalan değişiklik satırlarını bildirir; iş sonunda çağrılır.
    public func flush() {
        let changes: [String] = lock.withLock {
            defer { pendingChanges = [] }
            return pendingChanges
        }
        if !changes.isEmpty { onChanges(changes) }
    }

    /// Çalıştırmanın geri alma kaydı (değişiklik satırlarından).
    public var undoRecord: RunUndo.Record {
        lock.withLock { RunUndo.Record(created: created, truncated: createdTruncated, otherChanges: otherChanges) }
    }

    /// İş sonu istatistikleri (`--info=stats2`), rsync'in yazdığı sırayla.
    public var statistics: [String] { lock.withLock { stats } }

    private func merge(_ parsed: TransferProgress) -> TransferProgress {
        hasRealProgress = true
        let item = current.currentItem
        if perFile {
            let finishedFile = parsed.itemsTotal != nil
            if finishedFile { completedBytes = completedBytes.saturatingAdding(parsed.bytesTransferred) }
            var next = parsed
            next.fileFraction = parsed.fraction
            next.bytesTransferred = finishedFile ? completedBytes : completedBytes.saturatingAdding(parsed.bytesTransferred)
            if let checked = parsed.itemsChecked, let total = parsed.itemsTotal, total > 0 {
                next.fraction = Double(checked) / Double(total)
            } else {
                next.fraction = current.fraction
                next.itemsRemaining = current.itemsRemaining
                next.itemsTotal = current.itemsTotal
                next.isEstimating = current.isEstimating
            }
            // Dosya başı kalan süre yalnızca o dosyanındır; genel kalan süre bilinmez.
            next.remainingSeconds = nil
            next.filesTransferred = max(parsed.filesTransferred, current.filesTransferred)
            next.currentItem = item
            current = next
        } else {
            var next = parsed
            next.currentItem = item
            current = next
        }
        return current
    }

    /// " 1000 files..." → 1000 (flist2 sayacı).
    static func listedCount(_ line: String) -> Int? {
        guard line.hasSuffix(" files...") else { return nil }
        let number = line.dropLast(" files...".count).trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }), number.count <= 12 else { return nil }
        return Int(number)
    }
}
