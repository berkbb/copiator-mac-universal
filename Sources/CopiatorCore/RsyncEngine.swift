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
        let sourceIsDirectory = Self.isDirectory(job.source)
        let fileSystem = FileSystemKind.of(job.destination)

        // Ön denetim: kaynağın boyutu, hedefte zaten bulunan kopya kadar azaltılarak boş alanla karşılaştırılır.
        let sourceBytes = DiskSpace.totalSize(of: [job.source], isCancelled: { Task.isCancelled })
        let existing = DiskSpace.totalSize(of: Self.existingCounterparts(of: job, sourceIsDirectory: sourceIsDirectory),
                                           isCancelled: { Task.isCancelled })
        if Task.isCancelled { return JobResult(kind: .cancelled) }
        let required = DiskSpace.requiredForCopy(sourceBytes: sourceBytes, existingDestinationBytes: existing)
        do {
            try InsufficientSpaceError.check(required: required, at: job.destination)
        } catch let space as InsufficientSpaceError {
            return JobResult(kind: .destinationFull, requiredBytes: space.required, availableBytes: space.available)
        } catch {
            return JobResult(kind: .failed, detail: error.localizedDescription)
        }

        let profile = context.sandboxed
            ? SandboxProfile.forTransfer(sources: [job.source], destination: job.destination, home: context.home)
            : nil
        let protectedPaths = sourceIsDirectory ? (profile?.protectedPaths(inside: job.source) ?? []) : []
        if !protectedPaths.isEmpty {
            onEvent(.log(JobLogEntry(level: .info, key: .logProtectedSkipped, arguments: [protectedPaths.joined(separator: ", ")])))
        }
        let environment = RsyncCommand.Environment(
            engine: context.info, destinationFileSystem: fileSystem, sourceIsDirectory: sourceIsDirectory,
            protectedPaths: protectedPaths
        )
        let arguments = RsyncCommand.transfer(job, environment: environment)
        if fileSystem.lacksPosixMetadata {
            onEvent(.log(JobLogEntry(level: .info, key: .logLimitedFileSystem, arguments: [fileSystem.rawValue])))
        }
        if !context.info.supportsProgress2 {
            onEvent(.log(JobLogEntry(level: .warning, key: .logLimitedProgress, arguments: [context.info.version])))
        }

        let runner = CommandRunner(executableURL: context.executable).sandboxed(profile)
        let throttle = ProgressThrottle(interval: Self.progressInterval, onEvent: onEvent)
        let started = Date()
        onEvent(.phase(.copying))
        let processResult: ProcessResult
        do {
            let floor = DiskSpaceGuard.floor(forVolumeCapacity: DiskSpace.totalCapacity(at: job.destination))
            processResult = try await DiskSpaceGuard.run(watching: job.destination, floor: floor) {
                try await runner.run(arguments, retainStdout: false) { record in
                    if let progress = RsyncProgressParser.parse(record) { throttle.offer(progress) }
                }
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
        if Task.isCancelled { return JobResult(kind: .cancelled, exitCode: processResult.exitCode) }

        let result = RsyncOutcome.classify(exitCode: processResult.exitCode, stderr: processResult.stderr, destinationFileSystem: fileSystem)
        for line in RsyncOutcome.errorLines(in: processResult.stderr, destinationFileSystem: fileSystem) {
            onEvent(.log(JobLogEntry(level: result.kind.isSuccess ? .warning : .error, raw: line)))
        }
        if result.kind == .succeededWithNotes {
            onEvent(.log(JobLogEntry(level: .info, key: .logHarmlessNotes, arguments: [String(result.noteCount), fileSystem.rawValue])))
        }

        // Öznitelikler taşınmadıysa karantina işareti ayrıca aktarılır (Gatekeeper koruması kaybolmasın).
        let xattrsCopied = job.options.preserveExtendedAttributes && (context.info.supportsXattrs || context.info.isOpenrsync)
        if !xattrsCopied, result.kind != .cancelled {
            let target = job.target(sourceIsDirectory: sourceIsDirectory)
            let marked = Quarantine.propagate(from: job.source, to: target, since: started, isCancelled: { Task.isCancelled })
            if marked > 0 { onEvent(.log(JobLogEntry(level: .info, key: .logQuarantineApplied, arguments: [String(marked)]))) }
        }
        return result
    }

    public func verify(_ job: TransferJob, context: EngineContext, checksum: Bool) async -> VerifyReport {
        func report(_ kind: JobResultKind) -> VerifyReport { VerifyReport(entries: [], result: JobResult(kind: kind), checksum: checksum) }
        if let problem = JobValidation.check(source: job.source, destination: job.destination, copyMode: job.options.copyMode) {
            return report(Self.resultKind(for: problem))
        }
        let sourceIsDirectory = Self.isDirectory(job.source)
        let fileSystem = FileSystemKind.of(job.destination)
        // Doğrulama hiçbir yere yazmaz: kum havuzunda hedef de salt okunurdur (yalnızca /dev yazılabilir).
        var profile = context.sandboxed
            ? SandboxProfile.forTransfer(sources: [job.source], destination: job.destination, home: context.home)
            : nil
        let protectedPaths = sourceIsDirectory ? (profile?.protectedPaths(inside: job.source) ?? []) : []
        profile?.writableDirectories = []
        let environment = RsyncCommand.Environment(
            engine: context.info, destinationFileSystem: fileSystem, sourceIsDirectory: sourceIsDirectory,
            protectedPaths: protectedPaths
        )
        let arguments = RsyncCommand.verify(job, environment: environment, checksum: checksum)
        let runner = CommandRunner(executableURL: context.executable).sandboxed(profile)
        do {
            let processResult = try await runner.run(arguments)
            if Task.isCancelled { return report(.cancelled) }
            let result = RsyncOutcome.classify(exitCode: processResult.exitCode, stderr: processResult.stderr, destinationFileSystem: fileSystem)
            return VerifyReport(entries: ItemizeParser.parse(processResult.stdout), result: result, checksum: checksum)
        } catch EngineError.cancelled, is CancellationError {
            return report(.cancelled)
        } catch EngineError.engineNotFound {
            return report(.engineMissing)
        } catch {
            return VerifyReport(entries: [], result: JobResult(kind: .failed, detail: String(describing: error)), checksum: checksum)
        }
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
