// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// İki klasörün eşitleme planı: yalnızca A'da olanlar B'ye, yalnızca B'de olanlar A'ya kopyalanır; iki yanda farklı
/// olanlar karara kalır. Hiçbir şey silinmez: bir yanda silinen dosya öbür yandan geri gelir.
public struct SyncPlan: Equatable, Sendable {
    /// İki yanda aynı adla bulunan ama içeriği farklı dosya (yollar her yanın kendi yazımıyla).
    public struct Difference: Equatable, Sendable {
        public var pathA: String
        public var pathB: String
        public var modifiedA: Date
        public var modifiedB: Date
    }

    /// A'dan B'ye kopyalanacaklar (A'ya göre yollar).
    public var toB: [String] = []
    /// B'den A'ya kopyalanacaklar (B'ye göre yollar).
    public var toA: [String] = []
    public var differences: [Difference] = []
    /// İki yanda aynı olanlar.
    public var same = 0
}

public enum SyncPlanner {
    /// Bir yandaki öğe: dosya (ya da paket) boyutu ve değişiklik zamanı.
    struct Item {
        var path: String
        var size: Int64
        var modified: Date
        var isDirectory: Bool
    }

    /// İki klasörü tarar ve karşılaştırır. Rutinin kuralları her iki yana uygulanır; adlar Unicode NFC ve büyük/küçük harf
    /// duyarsız eşlenir (macOS birimlerinin çoğu harf duyarsızdır: "Rapor.txt" ile "rapor.txt" aynı dosyadır).
    public static func plan(_ job: TransferJob, context: EngineContext, isCancelled: () -> Bool = { false }) async throws -> SyncPlan {
        let a = try await scan(job.source, other: job.destination, job: job, context: context, isCancelled: isCancelled)
        let b = try await scan(job.destination, other: job.source, job: job, context: context, isCancelled: isCancelled)
        let window = FileSystemKind.of(job.source).hasCoarseTimestamps || FileSystemKind.of(job.destination).hasCoarseTimestamps ? 2.0 : 1.0
        var plan = SyncPlan()
        for (key, itemA) in a {
            if isCancelled() { throw CancellationError() }
            guard let itemB = b[key] else {
                plan.toB.append(itemA.path)
                continue
            }
            if same(itemA, itemB, rootA: job.source, rootB: job.destination, window: window) {
                plan.same += 1
            } else {
                plan.differences.append(SyncPlan.Difference(pathA: itemA.path, pathB: itemB.path, modifiedA: itemA.modified, modifiedB: itemB.modified))
            }
        }
        for (key, itemB) in b where a[key] == nil { plan.toA.append(itemB.path) }
        plan.toB.sort()
        plan.toA.sort()
        plan.differences.sort { $0.pathA < $1.pathA }
        return plan
    }

    static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    private static func scan(_ root: URL, other: URL, job: TransferJob, context: EngineContext, isCancelled: () -> Bool) async throws -> [String: Item] {
        let skippedNames: Set<String> = job.options.excludeSystemFolders ? Set(RsyncCommand.systemExclusions) : []
        let skippedPaths: Set<String> = context.sandboxed
            ? Set(SandboxProfile.forTransfer(sources: [root], destination: other, home: context.home).protectedPaths(inside: root))
            : []
        let paths = try await RuleScanner.scan(root, rules: job.options.rules ?? RuleGroup(), skippedPaths: skippedPaths,
                                               skippedNames: skippedNames, skipsWindowsLeftovers: job.options.excludeWindowsLeftovers,
                                               isCancelled: isCancelled).paths
        var items: [String: Item] = [:]
        for path in paths {
            let url = root.appendingPathComponent(path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
            let size = kind == S_IFDIR ? DiskSpace.totalSize(of: [url]) : Int64(info.st_size)
            items[key(path)] = Item(path: path, size: size, modified: modified, isDirectory: kind == S_IFDIR)
        }
        return items
    }

    /// Aynı mı: tür ve boyut aynı, zaman farkı pencere içinde; boyut aynı ama zaman farklı dosyada içerik (SHA-256). Paket
    /// klasörleri (.app…) içlerindeki dosyalarla karşılaştırılır: toplam boyutun tutması içeriğin aynı olduğunu göstermez.
    static func same(_ a: Item, _ b: Item, rootA: URL, rootB: URL, window: TimeInterval) -> Bool {
        guard a.isDirectory == b.isDirectory, a.size == b.size else { return false }
        let left = rootA.appendingPathComponent(a.path), right = rootB.appendingPathComponent(b.path)
        if a.isDirectory { return sameTree(left, right, window: window) }
        return sameFile(left.path, right.path, modifiedA: a.modified, modifiedB: b.modified, window: window)
    }

    static func sameFile(_ a: String, _ b: String, modifiedA: Date, modifiedB: Date, window: TimeInterval) -> Bool {
        if abs(modifiedA.timeIntervalSince(modifiedB)) <= window { return true }
        guard let left = DestinationIndex.digest(of: a) else { return false }
        return left == DestinationIndex.digest(of: b)
    }

    /// İki klasör ağacında aynı adlı dosyalar var ve her biri aynı (boyut, zaman ya da içerik).
    static func sameTree(_ a: URL, _ b: URL, window: TimeInterval) -> Bool {
        func files(_ root: URL) -> [String: (Int64, Date)] {
            var result: [String: (Int64, Date)] = [:]
            guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return result }
            while let relative = enumerator.nextObject() as? String {
                var info = stat()
                guard lstat(root.appendingPathComponent(relative).path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR else { continue }
                let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
                result[relative] = (Int64(info.st_size), modified)
            }
            return result
        }
        let left = files(a), right = files(b)
        guard Set(left.keys) == Set(right.keys) else { return false }
        return left.allSatisfy { path, item in
            guard let other = right[path], other.0 == item.0 else { return false }
            return sameFile(a.appendingPathComponent(path).path, b.appendingPathComponent(path).path,
                            modifiedA: item.1, modifiedB: other.1, window: window)
        }
    }
}

/// İki yönlü eşitleme motoru. İşin kaynağı A, hedefi B'dir. Plan çıkarılır, iki yanda farklı dosyalar için karar
/// beklenir (kural: `ConflictPolicy`; "değiştir" A kazanır, "ters" B kazanır, "yenisi" yeni olan kazanır), ardından eksikler
/// ve kararlar iki ayrı rsync çalıştırmasıyla (A → B, B → A) kopyalanır. Her çalıştırma kendi kum havuzundadır (kaynağı
/// salt okunur, hedefi yazılabilir); `--delete` hiçbir zaman verilmez.
public struct SyncEngine: TransferEngine {
    public var kind: JobKind { .sync }

    public init() {}

    public func run(_ job: TransferJob, context: EngineContext, onEvent: @escaping @Sendable (TransferEvent) -> Void) async -> JobResult {
        onEvent(.phase(.scanning))
        if let problem = Self.validate(job) { return JobResult(kind: RsyncEngine.resultKind(for: problem)) }
        let plan: SyncPlan
        do {
            plan = try await SyncPlanner.plan(job, context: context, isCancelled: { Task.isCancelled })
        } catch is CancellationError {
            return JobResult(kind: .cancelled)
        } catch let runaway as RuleEvaluator.RunawayRegex {
            onEvent(.log(JobLogEntry(level: .error, key: .logRuleRegexTooComplex, arguments: [runaway.pattern])))
            return JobResult(kind: .failed, detail: runaway.pattern)
        } catch {
            return JobResult(kind: .failed, detail: error.localizedDescription)
        }
        onEvent(.log(JobLogEntry(level: .info, key: .logSyncPlanned,
                                 arguments: [String(plan.toB.count), String(plan.toA.count), String(plan.differences.count)])))

        var toB = plan.toB, toA = plan.toA, skipped = 0
        var undecided: [FileConflict] = []
        let resolution = job.conflictResolution ?? ConflictResolution()
        for difference in plan.differences {
            switch resolution.decision(for: difference.pathA) ?? Self.decision(job.options.conflictPolicy, difference) {
            case .replace?: toB.append(difference.pathA)
            case .reverse?: toA.append(difference.pathB)
            case .skip?, .keepBoth?: skipped += 1
            case nil: undecided.append(FileConflict(path: difference.pathA, identical: false))
            }
        }
        if !undecided.isEmpty {
            let report = ConflictReport(items: Array(undecided.prefix(ConflictDetector.maxListed)), total: undecided.count)
            onEvent(.conflicts(report))
            onEvent(.log(JobLogEntry(level: .warning, key: .logAwaitingDecision, arguments: [String(report.total)])))
            return JobResult(kind: .awaitingDecision, noteCount: report.total)
        }

        var result = JobResult(kind: .succeeded)
        for (from, to, paths) in [(job.source, job.destination, toB), (job.destination, job.source, toA)] where !paths.isEmpty {
            if Task.isCancelled { return JobResult(kind: .cancelled) }
            onEvent(.log(JobLogEntry(level: .info, key: .logSyncDirection, arguments: [from.lastPathComponent, to.lastPathComponent, String(paths.count)])))
            let part = await copy(paths, from: from, to: to, job: job, context: context, onEvent: onEvent)
            if part.kind == .cancelled { return part }
            // En kötü sonuç kalır: başarıdan notlu başarıya, ondan başarısızlığa.
            if part.kind != .succeeded, result.kind == .succeeded || (result.kind.isSuccess && !part.kind.isSuccess) { result = part }
        }
        onEvent(.log(JobLogEntry(level: .info, key: .logSyncDone, arguments: [String(toB.count), String(toA.count), String(skipped)])))
        return result
    }

    /// Kuralın bir farklı dosyaya kararı ("yenisi": zaman farkı 1 saniyeden büyükse yeni olan, değilse atla).
    static func decision(_ policy: ConflictPolicy, _ difference: SyncPlan.Difference) -> ConflictDecision? {
        guard policy == .newer else { return policy == .keepBoth ? .skip : policy.decision }
        let delta = difference.modifiedA.timeIntervalSince(difference.modifiedB)
        if delta > 1 { return .replace }
        if delta < -1 { return .reverse }
        return .skip
    }

    static func validate(_ job: TransferJob) -> JobValidation.Problem? {
        if let problem = JobValidation.check(source: job.source, destination: job.destination, copyMode: .contents) { return problem }
        return RsyncEngine.isDirectory(job.source) && RsyncEngine.isDirectory(job.destination) ? nil : .destinationNotDirectory
    }

    /// Bir yöndeki dosyaları ayrı bir rsync işiyle kopyalar: seçilen yollar `--files-from` listesiyle, aynı adlı dosya
    /// denetimi olmadan (kararlar plan aşamasında verildi).
    func copy(
        _ paths: [String], from: URL, to: URL, job: TransferJob, context: EngineContext, onEvent: @escaping @Sendable (TransferEvent) -> Void
    ) async -> JobResult {
        let zeroTerminated = !context.info.isOpenrsync
        let usable = zeroTerminated ? paths : paths.filter { !$0.contains { $0 == "\n" || $0 == "\r" } }
        if usable.count < paths.count {
            onEvent(.log(JobLogEntry(level: .warning, key: .logRulesNewlineSkipped, arguments: [String(paths.count - usable.count)])))
        }
        let folder = context.scratchDirectory.appendingPathComponent("Copiator-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let list = folder.appendingPathComponent("liste.txt")
            try Data(usable.map { $0 + (zeroTerminated ? "\u{0}" : "\n") }.joined().utf8).write(to: list)
            let options = Self.partOptions(job.options, list: SandboxProfile.resolved(list).path, zeroTerminated: zeroTerminated)
            let part = TransferJob(kind: .rsync, source: from, destination: to, options: options)
            return await RsyncEngine().run(part, context: context) { event in
                switch event {
                case .conflicts, .conflictsSettled, .placements: break
                default: onEvent(event)
                }
            }
        } catch {
            return JobResult(kind: .failed, detail: error.localizedDescription)
        }
    }

    /// Bir yönün rsync işinin seçenekleri: liste dosyasındaki yollar, "içeriği" kipi, aynı adlı dosya denetimi yok (kararlar
    /// verildi), `--delete` yok (paket klasörleri listede olsa bile içlerinden hiçbir şey silinmez), anlık görüntü ve "taşı" yok.
    static func partOptions(_ base: CopyOptions, list: String, zeroTerminated: Bool) -> CopyOptions {
        var options = base
        options.copyMode = .contents
        options.rules = nil
        options.placement = nil
        options.selectedItems = nil
        options.deleteExtraneous = false
        options.snapshots.enabled = false
        options.trashSourceAfterCopy = false
        options.conflictPolicy = .replace
        options.advanced.filesFromFile = list
        options.advanced.filesFromZeroTerminated = zeroTerminated
        return options
    }

    /// Önizleme: planın gösterimi. A → B "eksik", B → A "fazla", iki yanda farklı "değişmiş" olarak listelenir; hiçbir şey
    /// yazılmaz.
    public func verify(_ job: TransferJob, context: EngineContext, checksum: Bool) async -> VerifyReport {
        if let problem = Self.validate(job) {
            return VerifyReport(entries: [], result: JobResult(kind: RsyncEngine.resultKind(for: problem)), checksum: checksum)
        }
        do {
            let plan = try await SyncPlanner.plan(job, context: context, isCancelled: { Task.isCancelled })
            let entries = plan.toB.map { DiffEntry(kind: .missing, path: $0, isDirectory: false, code: "A>B") }
                + plan.toA.map { DiffEntry(kind: .extra, path: $0, isDirectory: false, code: "B>A") }
                + plan.differences.map { DiffEntry(kind: .changed, path: $0.pathA, isDirectory: false, code: "A<>B") }
            return VerifyReport(entries: entries, result: JobResult(kind: .succeeded), checksum: checksum)
        } catch is CancellationError {
            return VerifyReport(entries: [], result: JobResult(kind: .cancelled), checksum: checksum)
        } catch {
            return VerifyReport(entries: [], result: JobResult(kind: .failed, detail: error.localizedDescription), checksum: checksum)
        }
    }
}
