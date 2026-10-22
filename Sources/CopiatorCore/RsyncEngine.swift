// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Yerel disk → yerel disk kopyalama motoru (rsync, ayrı süreç olarak; hiçbir zaman bağlanmaz).
public struct RsyncEngine: TransferEngine {
    public var kind: JobKind { .rsync }

    /// Arayüze en sık bu aralıkla ilerleme gönderilir: rsync saniyede onlarca satır yazar.
    public static let progressInterval: TimeInterval = 0.25

    public init() {}

    public func run(_ job: TransferJob, context: EngineContext, onEvent: @escaping @Sendable (TransferEvent) -> Void) async -> JobResult {
        onEvent(.phase(.scanning))
        if let problem = JobValidation.check(source: job.source, destination: job.destination, copyMode: job.options.copyMode) {
            return JobResult(kind: Self.resultKind(for: problem))
        }
        // Sürdürülen bir işin geçmişte kalmış "şu saatte dur" sınırı yok sayılır (rsync geçmiş bir zamanı reddeder).
        var job = job
        if let stopAt = job.options.advanced.stopAt, stopAt <= Date() { job.options.advanced.stopAt = nil }
        let problems = job.options.problems(source: job.source)
        guard problems.isEmpty else { return JobResult(kind: .failed, detail: "\(problems)") }

        // Anlık görüntü: hedef kökte tarihli bir "….partial" klasörü (yarım kalan varsa o sürdürülür), önceki anlık
        // görüntü `--link-dest` olur. Klasör ancak başarıyla bitince tarihli adına taşınır.
        let snapshotRoot = job.destination
        var preparation: SnapshotStore.Preparation?
        if job.options.snapshots.enabled {
            do {
                let prepared = try SnapshotStore.prepare(in: snapshotRoot)
                preparation = prepared
                job = SnapshotStore.apply(prepared, to: job)
                let name = prepared.partial.lastPathComponent
                if prepared.resumed {
                    onEvent(.log(JobLogEntry(level: .info, key: .logSnapshotResumed, arguments: [name])))
                } else if let previous = prepared.previous {
                    onEvent(.log(JobLogEntry(level: .info, key: .logSnapshotStarted, arguments: [name, previous.lastPathComponent])))
                } else {
                    onEvent(.log(JobLogEntry(level: .info, key: .logSnapshotFirst, arguments: [name])))
                }
            } catch {
                return JobResult(kind: .failed, detail: error.localizedDescription)
            }
        }
        // Rutin kuralları: kaynak taranır, uyan dosyalar listeye yazılır (`--files-from`). Sonraki doğrulama aynı listeyi
        // kullanır; kaynak yeniden taranmaz.
        let selection: RuleSelection.Prepared?
        do {
            selection = try await Self.prepareRules(&job, context: context)
        } catch is CancellationError {
            return JobResult(kind: .cancelled)
        } catch {
            return JobResult(kind: .failed, detail: error.localizedDescription)
        }
        defer { if let selection { try? FileManager.default.removeItem(at: selection.folder) } }
        if let selection {
            onEvent(.log(JobLogEntry(level: .info, key: .logRulesMatched, arguments: [String(selection.matched), String(selection.scanned)])))
            if selection.skippedNewlines > 0 {
                onEvent(.log(JobLogEntry(level: .warning, key: .logRulesNewlineSkipped, arguments: [String(selection.skippedNewlines)])))
            }
            job.options.rules = nil
        }

        // Liste dosyaları (--files-from vb.) kum havuzunda özel bir kopyadan okunur: rsync bu dosyaları yol bileşenlerini
        // tek tek açarak okur; kişisel bir klasördeki listeye (ör. ~/.ssh) yalnızca dosyanın kendisine izin vermek
        // yetmez, klasörü açmak da kişisel klasörün içeriğini listeletirdi. Kopyalar iş bitince silinir.
        var staged: URL?
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        if context.sandboxed {
            do {
                staged = try Self.stageListFiles(&job.options.advanced)
            } catch {
                return JobResult(kind: .failed, detail: error.localizedDescription)
            }
        }
        let sourceIsDirectory = Self.isDirectory(job.source)
        let fileSystem = FileSystemKind.of(job.destination)

        // Ön denetim: kaynağın boyutu, hedefte zaten bulunan kopya kadar azaltılarak boş alanla karşılaştırılır. Anlık
        // görüntüde değişmeyen dosyalar önceki anlık görüntüyle paylaşıldığı için o da "zaten var" sayılır.
        // Kurallı işte yalnızca seçilen dosyalar sayılır.
        let sourceBytes = DiskSpace.totalSize(of: selection.map { $0.paths.map { job.source.appendingPathComponent($0) } } ?? [job.source],
                                              isCancelled: { Task.isCancelled })
        let counterparts = selection.map { $0.paths.map { job.destination.appendingPathComponent($0) } }
            ?? Self.existingCounterparts(of: job, sourceIsDirectory: sourceIsDirectory)
        var existing = DiskSpace.totalSize(of: counterparts, isCancelled: { Task.isCancelled })
        if let previous = preparation?.previous {
            var previousJob = job
            previousJob.destination = previous
            let previousCounterparts = selection.map { $0.paths.map { previous.appendingPathComponent($0) } }
                ?? Self.existingCounterparts(of: previousJob, sourceIsDirectory: sourceIsDirectory)
            existing = max(existing, DiskSpace.totalSize(of: previousCounterparts, isCancelled: { Task.isCancelled }))
        }
        if Task.isCancelled { return JobResult(kind: .cancelled) }
        let required = DiskSpace.requiredForCopy(sourceBytes: sourceBytes, existingDestinationBytes: existing)
        do {
            try InsufficientSpaceError.check(required: required, at: job.destination)
        } catch let space as InsufficientSpaceError {
            return JobResult(kind: .destinationFull, requiredBytes: space.required, availableBytes: space.available)
        } catch {
            return JobResult(kind: .failed, detail: error.localizedDescription)
        }

        let advanced = job.options.advanced
        let profile = context.sandboxed
            ? SandboxProfile.forTransfer(
                sources: [job.source], destination: job.destination, home: context.home,
                extraReadable: advanced.readablePaths, extraWritableFiles: advanced.writableFiles,
                extraWritableDirectories: advanced.writableDirectories
            )
            : nil
        let protectedPaths = sourceIsDirectory ? (profile?.protectedPaths(inside: job.source) ?? []) : []
        if !protectedPaths.isEmpty {
            onEvent(.log(JobLogEntry(level: .info, key: .logProtectedSkipped, arguments: [protectedPaths.joined(separator: ", ")])))
        }
        let environment = RsyncCommand.Environment(
            engine: context.info, destinationFileSystem: fileSystem, sourceIsDirectory: sourceIsDirectory,
            protectedPaths: protectedPaths, enginePath: SandboxProfile.resolved(context.executable).path
        )
        let arguments = RsyncCommand.transfer(job, environment: environment)
        let dropped = RsyncCommand.droppedOptions(job, environment: environment)
        if !dropped.isEmpty {
            onEvent(.log(JobLogEntry(level: .warning, key: .logDroppedOptions, arguments: [dropped.joined(separator: " ")])))
        }
        if fileSystem.lacksPosixMetadata {
            onEvent(.log(JobLogEntry(level: .info, key: .logLimitedFileSystem, arguments: [fileSystem.rawValue])))
        }
        if !context.info.supportsProgress2 {
            onEvent(.log(JobLogEntry(level: .warning, key: .logLimitedProgress, arguments: [context.info.version])))
        }

        let runner = CommandRunner(executableURL: context.executable).sandboxed(profile)
        let throttle = ProgressThrottle(interval: Self.progressInterval, onEvent: onEvent)
        let collector = RsyncOutputCollector(advanced: advanced, itemizeFormat: ItemizeParser.Format(engine: context.info),
                                             onProgress: { throttle.offer($0) }) { lines in
            onEvent(.logBatch(lines.map { JobLogEntry(level: .info, raw: $0) }))
        }
        let started = Date()
        onEvent(.phase(.copying))
        let processResult: ProcessResult
        do {
            let floor = DiskSpaceGuard.floor(forVolumeCapacity: DiskSpace.totalCapacity(at: job.destination))
            processResult = try await DiskSpaceGuard.run(watching: job.destination, floor: floor) {
                try await runner.run(arguments, retainStdout: false) { collector.consume($0) }
            }
        } catch let space as InsufficientSpaceError {
            throttle.flush()
            return JobResult(kind: .destinationFull, availableBytes: space.available)
        } catch EngineError.cancelled, is CancellationError {
            throttle.flush()
            return JobResult(kind: .cancelled)
        } catch EngineError.engineNotFound {
            return JobResult(kind: .engineMissing)
        } catch {
            throttle.flush()
            return JobResult(kind: .failed, detail: (error as? EngineError).map(String.init(describing:)) ?? error.localizedDescription)
        }
        throttle.flush()
        collector.flush()
        let statistics = collector.statistics
        if !statistics.isEmpty {
            onEvent(.logBatch([JobLogEntry(level: .info, key: .logStatsHeader)] + statistics.map { JobLogEntry(level: .info, raw: $0) }))
        }
        if Task.isCancelled { return JobResult(kind: .cancelled, exitCode: processResult.exitCode) }

        var result = RsyncOutcome.classify(exitCode: processResult.exitCode, stderr: processResult.stderr, destinationFileSystem: fileSystem)
        for line in RsyncOutcome.errorLines(in: processResult.stderr, destinationFileSystem: fileSystem) {
            onEvent(.log(JobLogEntry(level: result.kind.isSuccess ? .warning : .error, raw: line)))
        }
        if result.kind == .succeededWithNotes {
            onEvent(.log(JobLogEntry(level: .info, key: .logHarmlessNotes, arguments: [String(result.noteCount), fileSystem.rawValue])))
        }

        // Öznitelikler taşınmadıysa karantina işareti ayrıca aktarılır (Gatekeeper koruması kaybolmasın).
        let xattrsCopied = job.options.preserveExtendedAttributes && context.info.supportsXattrs && !context.info.isOpenrsync
        if !xattrsCopied, result.kind != .cancelled, advanced.batchMode != .onlyWrite {
            let target = job.target(sourceIsDirectory: sourceIsDirectory)
            let marked = Quarantine.propagate(from: job.source, to: target, since: started, isCancelled: { Task.isCancelled })
            if marked > 0 { onEvent(.log(JobLogEntry(level: .info, key: .logQuarantineApplied, arguments: [String(marked)]))) }
        }

        // Kopyalama sonrası doğrulama: hedef kaynakla yeniden karşılaştırılır (yalnızca toplu iş dosyası yazıldıysa hedef
        // değişmediği için yapılmaz).
        if result.kind.isSuccess, job.options.verifyAfterCopy != .off, advanced.batchMode != .onlyWrite, !Task.isCancelled {
            onEvent(.phase(.verifying))
            result = await verifyAfterCopy(job, context: context, copyResult: result, onEvent: onEvent)
            if result.kind == .cancelled { return result }
        }

        if let preparation { finishSnapshot(preparation, root: snapshotRoot, options: job.options, result: &result, onEvent: onEvent) }
        return result
    }

    /// Kopyalanan hedefi kaynakla karşılaştırır. Eksik ya da değişmiş öğeler (ve `--delete` seçiliyse hedefteki fazlalar)
    /// fark sayılır; yalnızca öznitelik farkları ve `--delete` seçili değilken hedefte kalan eski dosyalar sayılmaz.
    func verifyAfterCopy(
        _ job: TransferJob, context: EngineContext, copyResult: JobResult, onEvent: @escaping @Sendable (TransferEvent) -> Void
    ) async -> JobResult {
        let checksum = job.options.verifyAfterCopy == .checksum
        onEvent(.log(JobLogEntry(level: .info, key: checksum ? .logVerifyAfterCopyChecksum : .logVerifyAfterCopyQuick)))
        // Anlık görüntü kendi başına tam bir kopyadır: önceki anlık görüntüyle değil, yalnızca kaynakla karşılaştırılır.
        var target = job
        if job.options.snapshots.enabled {
            target.options.snapshots.enabled = false
            target.options.advanced.referenceMode = .none
            target.options.advanced.referenceDirectory = nil
        }
        let report = await compare(target, context: context, checksum: checksum)
        if report.result.kind == .cancelled { return JobResult(kind: .cancelled) }
        var result = copyResult
        guard report.result.kind.isSuccess else {
            onEvent(.log(JobLogEntry(level: .error, key: .logVerifyAfterCopyIncomplete)))
            if !report.result.detail.isEmpty { onEvent(.log(JobLogEntry(level: .error, raw: report.result.detail))) }
            result.kind = .verificationFailed
            result.differenceCount = nil
            return result
        }
        let differences = report.entries.filter { entry in
            switch entry.kind {
            case .missing, .changed: true
            case .extra: job.options.deleteExtraneous
            case .attributes: false
            }
        }
        result.differenceCount = differences.count
        if differences.isEmpty {
            onEvent(.log(JobLogEntry(level: .info, key: .logVerifyAfterCopyPassed)))
        } else {
            result.kind = .verificationFailed
            onEvent(.log(JobLogEntry(level: .error, key: .logVerifyAfterCopyDifferences, arguments: [String(differences.count)])))
            onEvent(.logBatch(differences.prefix(Self.maxLoggedDifferences).map { JobLogEntry(level: .error, raw: "\($0.code) \($0.path)") }))
        }
        return result
    }

    /// Doğrulamanın günlüğe yazdığı en çok fark satırı.
    static let maxLoggedDifferences = 100

    /// Anlık görüntüyü tamamlar: başarılı (ya da kısmen başarılı) çalıştırmada "….partial" tarihli adına taşınır,
    /// "Latest" ona çevrilir; yalnızca tam başarıda saklama kuralları uygulanır (eksik bir anlık görüntüye güvenip eski
    /// anlık görüntüler silinmez). Duraklatılan ya da hatalı çalıştırmada klasör sonraki çalıştırma için bekler.
    func finishSnapshot(
        _ preparation: SnapshotStore.Preparation, root: URL, options: CopyOptions, result: inout JobResult,
        onEvent: @escaping @Sendable (TransferEvent) -> Void
    ) {
        guard result.kind.isSuccess || result.kind == .partial || result.kind == .verificationFailed else {
            onEvent(.log(JobLogEntry(level: .info, key: .logSnapshotPartialKept, arguments: [preparation.partial.lastPathComponent])))
            return
        }
        let final: URL
        do {
            final = try SnapshotStore.finalize(partial: preparation.partial, in: root)
        } catch {
            onEvent(.log(JobLogEntry(level: .warning, key: .logSnapshotFinalizeFailed, arguments: [error.localizedDescription])))
            return
        }
        result.snapshot = final.lastPathComponent
        onEvent(.log(JobLogEntry(level: .info, key: .logSnapshotCreated, arguments: [final.lastPathComponent])))
        guard result.kind.isSuccess, options.snapshots.hasRetention else { return }
        let pruned = SnapshotStore.prune(in: root, options: options.snapshots, protecting: final.lastPathComponent)
        if !pruned.removed.isEmpty {
            onEvent(.log(JobLogEntry(level: .info, key: .logSnapshotPruned,
                                     arguments: [String(pruned.removed.count), pruned.removed.joined(separator: ", ")])))
        }
        if !pruned.failed.isEmpty {
            onEvent(.log(JobLogEntry(level: .warning, key: .logSnapshotPruneFailed, arguments: [pruned.failed.joined(separator: ", ")])))
        }
    }

    /// Anlık görüntü işinde kaynak en yeni anlık görüntüyle karşılaştırılır; henüz anlık görüntü yoksa boş bir klasörle
    /// (her şey "eksik" görünür: ilk çalıştırma her şeyi kopyalar).
    public func verify(_ job: TransferJob, context: EngineContext, checksum: Bool) async -> VerifyReport {
        guard job.options.snapshots.enabled else { return await compare(job, context: context, checksum: checksum) }
        if let problem = JobValidation.check(source: job.source, destination: job.destination, copyMode: job.options.copyMode) {
            return VerifyReport(entries: [], result: JobResult(kind: Self.resultKind(for: problem)), checksum: checksum)
        }
        var target = job
        target.options.snapshots.enabled = false
        target.options.advanced.referenceMode = .none
        target.options.advanced.referenceDirectory = nil
        var empty: URL?
        defer { if let empty { try? FileManager.default.removeItem(at: empty) } }
        if let latest = SnapshotStore.latest(in: job.destination) {
            target.destination = latest
        } else {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Copiator-empty-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                return VerifyReport(entries: [], result: JobResult(kind: .failed, detail: error.localizedDescription), checksum: checksum)
            }
            empty = folder
            target.destination = SandboxProfile.resolved(folder)
        }
        return await compare(target, context: context, checksum: checksum)
    }

    /// İşi kuru çalıştırıp (`-n -i`) hedefle kaynak arasındaki farkları listeler; hiçbir yere yazmaz.
    func compare(_ job: TransferJob, context: EngineContext, checksum: Bool) async -> VerifyReport {
        func report(_ kind: JobResultKind) -> VerifyReport { VerifyReport(entries: [], result: JobResult(kind: kind), checksum: checksum) }
        if let problem = JobValidation.check(source: job.source, destination: job.destination, copyMode: job.options.copyMode) {
            return report(Self.resultKind(for: problem))
        }
        var job = job
        let selection: RuleSelection.Prepared?
        do {
            selection = try await Self.prepareRules(&job, context: context)
        } catch is CancellationError {
            return report(.cancelled)
        } catch {
            return VerifyReport(entries: [], result: JobResult(kind: .failed, detail: error.localizedDescription), checksum: checksum)
        }
        defer { if let selection { try? FileManager.default.removeItem(at: selection.folder) } }
        var staged: URL?
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        if context.sandboxed {
            do {
                staged = try Self.stageListFiles(&job.options.advanced)
            } catch {
                return VerifyReport(entries: [], result: JobResult(kind: .failed, detail: error.localizedDescription), checksum: checksum)
            }
        }
        let sourceIsDirectory = Self.isDirectory(job.source)
        let fileSystem = FileSystemKind.of(job.destination)
        // Doğrulama hiçbir yere yazmaz: kum havuzunda hedef de salt okunurdur (yalnızca /dev yazılabilir). Liste dosyaları
        // ve önceki yedek okunabilir kalır; karşılaştırmayı etkilerler.
        var profile = context.sandboxed
            ? SandboxProfile.forTransfer(
                sources: [job.source], destination: job.destination, home: context.home,
                extraReadable: job.options.advanced.readablePaths
            )
            : nil
        let protectedPaths = sourceIsDirectory ? (profile?.protectedPaths(inside: job.source) ?? []) : []
        profile?.writableDirectories = []
        profile?.writableFiles = []
        let environment = RsyncCommand.Environment(
            engine: context.info, destinationFileSystem: fileSystem, sourceIsDirectory: sourceIsDirectory,
            protectedPaths: protectedPaths, enginePath: SandboxProfile.resolved(context.executable).path
        )
        let arguments = RsyncCommand.verify(job, environment: environment, checksum: checksum)
        let runner = CommandRunner(executableURL: context.executable).sandboxed(profile)
        do {
            let processResult = try await runner.run(arguments)
            if Task.isCancelled { return report(.cancelled) }
            let result = RsyncOutcome.classify(exitCode: processResult.exitCode, stderr: processResult.stderr, destinationFileSystem: fileSystem)
            let entries = ItemizeParser.parse(processResult.stdout, format: ItemizeParser.Format(engine: context.info))
            return VerifyReport(entries: entries, result: result, checksum: checksum)
        } catch EngineError.cancelled, is CancellationError {
            return report(.cancelled)
        } catch EngineError.engineNotFound {
            return report(.engineMissing)
        } catch {
            return VerifyReport(entries: [], result: JobResult(kind: .failed, detail: String(describing: error)), checksum: checksum)
        }
    }

    /// Kurallı işin dosya listesini hazırlar (kural yoksa nil). Kum havuzunda okunamayan kişisel klasörler taranmaz.
    /// Liste NUL ile ayrılır (`--from0`); motor desteklemiyorsa ya da işin başka bir liste dosyası varsa (`--from0` onları da
    /// etkilerdi) satır sonuyla.
    static func prepareRules(_ job: inout TransferJob, context: EngineContext) async throws -> RuleSelection.Prepared? {
        guard job.options.rules != nil else { return nil }
        let skipped = context.sandboxed
            ? Set(SandboxProfile.forTransfer(sources: [job.source], destination: job.destination, home: context.home)
                .protectedPaths(inside: job.source))
            : []
        let a = job.options.advanced
        let zeroTerminated = !context.info.isOpenrsync && (a.includeFromFile ?? "").isEmpty && (a.excludeFromFile ?? "").isEmpty
        return try await RuleSelection.prepare(&job, zeroTerminated: zeroTerminated, skippedPaths: skipped, isCancelled: { Task.isCancelled })
    }

    /// Liste dosyalarını kullanıcıya özel (0700) geçici bir klasöre kopyalar ve seçenekleri kopyalara çevirir.
    /// - Returns: Geçici klasör (liste yoksa nil); çağıran işi bitince siler.
    static func stageListFiles(_ options: inout AdvancedOptions) throws -> URL? {
        let paths = options.listFiles.filter { options[keyPath: $0]?.isEmpty == false }
        guard !paths.isEmpty else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Copiator-lists-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (index, keyPath) in paths.enumerated() {
            guard let original = options[keyPath: keyPath] else { continue }
            let copy = folder.appendingPathComponent("liste-\(index).txt")
            try Data(contentsOf: URL(fileURLWithPath: original)).write(to: copy)
            options[keyPath: keyPath] = SandboxProfile.resolved(copy).path
        }
        return folder
    }

    public static func resultKind(for problem: JobValidation.Problem) -> JobResultKind {
        switch problem {
        case .sourceMissing: .sourceMissing
        case .destinationMissing, .destinationNotDirectory: .destinationMissing
        case .overlapping: .overlapping
        }
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Hedefte zaten bulunan kopya: "klasörün kendisi" kipinde hedef/Ad; "içeriği" kipinde hedefteki, kaynağın üst
    /// düzey öğeleriyle aynı adlı öğeler (hedefteki ilgisiz dosyalar sayılmaz).
    static func existingCounterparts(of job: TransferJob, sourceIsDirectory: Bool) -> [URL] {
        let target = job.target(sourceIsDirectory: sourceIsDirectory)
        guard sourceIsDirectory, job.options.copyMode == .contents else { return [target] }
        let names = (try? DiskSpace.entries(ofDirectory: job.source.path)) ?? []
        return names.map { target.appendingPathComponent($0) }
    }
}

/// İlerleme olaylarını seyreltir: en çok `interval` saniyede bir, ama tarama/kopyalama geçişi ve son değer hemen.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private let onEvent: @Sendable (TransferEvent) -> Void
    private var lastSent = Date.distantPast
    private var pending: TransferProgress?
    private var lastEstimating: Bool?

    init(interval: TimeInterval, onEvent: @escaping @Sendable (TransferEvent) -> Void) {
        self.interval = interval
        self.onEvent = onEvent
    }

    func offer(_ progress: TransferProgress) {
        let send: TransferProgress? = lock.withLock {
            let now = Date()
            let changedPhase = lastEstimating != progress.isEstimating
            if changedPhase || now.timeIntervalSince(lastSent) >= interval {
                lastSent = now
                lastEstimating = progress.isEstimating
                pending = nil
                return progress
            }
            pending = progress
            return nil
        }
        if let send { onEvent(.progress(send)) }
    }

    func flush() {
        let send: TransferProgress? = lock.withLock {
            defer { pending = nil }
            return pending
        }
        if let send { onEvent(.progress(send)) }
    }
}
