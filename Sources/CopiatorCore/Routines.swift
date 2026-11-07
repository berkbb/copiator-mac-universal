// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Kopyalama rutini: adı olan, tekrar tekrar çalıştırılan bir kural kümesi. Her rota "şu kaynaktaki, şu kurallara uyan
/// dosyaları şu hedefe" der; klasör yapısı korunur (A/2026/rapor.xlsx → B/2026/rapor.xlsx). Tek rotalı rutin bir
/// klasörün seçili dosyalarını kopyalar; çok rotalı rutinde her dosya grubunun nereden nereye gideceği ayrı seçilir.
/// Çalıştırılınca her rota kuyruğa bir iş olarak girer (rota başına tek iş; sonraki çalıştırmalar aynı işi yeniden sıraya
/// alır, geçmişi birikir).
public struct Routine: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Kopyalama (kaynaktan hedefe) ya da iki yönlü eşitleme (her rota A ↔ B).
    public var kind: RoutineKind = .copy
    public var routes: [RoutineRoute]
    /// Tüm rotaların kopyalama seçenekleri. Kip her zaman "içeriği" kopyalamaktır ve `--delete` kullanılmaz: kurallar
    /// dosya seçer, hedefteki öteki dosyalara dokunulmaz.
    public var options: CopyOptions
    public var createdAt: Date
    public var updatedAt: Date
    public var lastRunAt: Date?

    public init(
        id: UUID = UUID(), name: String = "", kind: RoutineKind = .copy, routes: [RoutineRoute] = [RoutineRoute()],
        options: CopyOptions = CopyOptions(), createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.routes = routes
        self.options = options
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.lastRunAt = nil
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, routes, options, createdAt, updatedAt, lastRunAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        kind = (try? c.decodeIfPresent(RoutineKind.self, forKey: .kind)) ?? .copy
        routes = ((try? c.decodeIfPresent([Lossy<RoutineRoute>].self, forKey: .routes)) ?? nil)?.compactMap(\.value) ?? []
        options = (try? c.decodeIfPresent(CopyOptions.self, forKey: .options)) ?? CopyOptions()
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? createdAt
        lastRunAt = (try? c.decodeIfPresent(Date.self, forKey: .lastRunAt)) ?? nil
    }

    /// Bir rotanın işi için seçenekler: rotanın kuralları, "içeriği" kipi, `--delete` kapalı. Eşitlemede yerleşim,
    /// anlık görüntü ve "taşı" kullanılmaz (iki yan da kaynak ve hedeftir).
    public func jobOptions(for route: RoutineRoute) -> CopyOptions {
        var options = options
        options.copyMode = .contents
        options.deleteExtraneous = false
        options.rules = route.rules
        options.placement = route.placement.isActive && kind == .copy ? route.placement : nil
        if kind == .sync {
            options.snapshots.enabled = false
            options.trashSourceAfterCopy = false
            if options.conflictPolicy == .keepBoth { options.conflictPolicy = .ask }
        } else if options.conflictPolicy == .reverse || options.conflictPolicy == .newer {
            options.conflictPolicy = .ask
        }
        return options
    }

    /// Rotanın işinin türü.
    public var jobKind: JobKind { kind == .sync ? .sync : .rsync }

    /// Rutin sorunları; sorunlu rutin kaydedilmez ve çalıştırılmaz.
    public enum Problem: Equatable, Sendable {
        case emptyName
        case noRoutes
        case missingSource(route: Int)
        case missingDestination(route: Int)
        /// Kaynak bir klasör değil (kurallar bir klasörün içinde uygulanır).
        case sourceNotFolder(route: Int)
        /// Kaynak ya da hedef yok (diski takılı değil olabilir).
        case path(route: Int, JobValidation.Problem)
        case rules(route: Int, RuleGroup.Problem)
        case placement(route: Int, RoutePlacement.Problem)
        case options(AdvancedOptions.Problem)
    }

    /// - Parameter checkPaths: Kaynak ve hedefin diskte olup olmadığı da denetlensin mi (kayıtta evet; diski takılı değilken
    ///   "disk takılınca başla" seçili rutin yine kaydedilebilir).
    public func problems(checkPaths: Bool = true) -> [Problem] {
        var problems: [Problem] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append(.emptyName) }
        if routes.isEmpty { problems.append(.noRoutes) }
        for (index, route) in routes.enumerated() {
            guard let source = route.source else {
                problems.append(.missingSource(route: index))
                continue
            }
            guard let destination = route.destination else {
                problems.append(.missingDestination(route: index))
                continue
            }
            problems += route.rules.problems().map { .rules(route: index, $0) }
            problems += route.placement.problems().map { .placement(route: index, $0) }
            guard checkPaths else { continue }
            if let problem = JobValidation.check(source: source, destination: destination, copyMode: .contents) {
                problems.append(.path(route: index, problem))
            } else if !RsyncEngine.isDirectory(source) {
                problems.append(.sourceNotFolder(route: index))
            }
        }
        problems += jobOptions(for: routes.first ?? RoutineRoute()).problems(source: routes.first?.source).map { .options($0) }
        return problems
    }
}

/// Rutinin türü.
public enum RoutineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Kaynaktan hedefe kopyalama (klasör yapısı ya da yerleşim şablonlarıyla).
    case copy
    /// İki yönlü eşitleme: her rotada A ile B karşılaştırılır, eksikler iki yöne kopyalanır, hiçbir şey silinmez.
    case sync

    public var id: String { rawValue }
}

/// Rutinin bir rotası: kaynak klasör, kurallar, hedef klasör ve hedefte yerleşim (alt klasör ve ad şablonları).
public struct RoutineRoute: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var source: URL?
    public var destination: URL?
    public var rules: RuleGroup
    public var placement: RoutePlacement

    public init(id: UUID = UUID(), source: URL? = nil, destination: URL? = nil, rules: RuleGroup = RuleGroup(),
                placement: RoutePlacement = RoutePlacement()) {
        self.id = id
        self.source = source
        self.destination = destination
        self.rules = rules
        self.placement = placement
    }

    private enum CodingKeys: String, CodingKey { case id, source, destination, rules, placement }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        source = (try? c.decodeIfPresent(URL.self, forKey: .source)) ?? nil
        destination = (try? c.decodeIfPresent(URL.self, forKey: .destination)) ?? nil
        rules = (try? c.decodeIfPresent(RuleGroup.self, forKey: .rules)) ?? RuleGroup()
        placement = (try? c.decodeIfPresent(RoutePlacement.self, forKey: .placement)) ?? RoutePlacement()
    }
}

/// Rutinleri diske kaydeder (`~/Library/Application Support/Copiator/routines.json`); `JobStore` gibi atomik ve sürümlü.
public struct RoutineStore: Sendable {
    public static let formatVersion = 1

    public let url: URL

    public init(url: URL = RoutineStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Copiator/routines.json")
    }

    private struct Envelope: Codable {
        var version: Int
        var routines: [Lossy<Routine>]

        init(version: Int, routines: [Routine]) {
            self.version = version
            self.routines = routines.map { Lossy(value: $0) }
        }
    }

    public func load() throws -> [Routine] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Envelope.self, from: Data(contentsOf: url)).routines.compactMap(\.value)
    }

    public func save(_ routines: [Routine]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: Self.formatVersion, routines: routines))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Okunamayan dosyayı "routines.corrupt-<zaman>.json" adıyla kenara alır.
    @discardableResult
    public func quarantineCorruptFile(now: Date = Date()) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let backup = url.deletingLastPathComponent().appendingPathComponent("routines.corrupt-\(Int(now.timeIntervalSince1970)).json")
        return (try? FileManager.default.moveItem(at: url, to: backup)) == nil ? nil : backup
    }
}

extension Lossy: Encodable where T: Encodable {
    init(value: T) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

// MARK: - Çalıştırma sırasında kural seçimi

/// Kurallı bir işin dosya listesini hazırlar: kaynak taranır, uyan yollar kullanıcıya özel (0700) geçici bir klasördeki
/// listeye yazılır ve rsync'e `--files-from` ile verilir. Klasör iş bitince silinir.
public enum RuleSelection {
    public struct Prepared: Sendable {
        public var folder: URL
        /// Asıl kaynak (yerleştirmede işin kaynağı hazırlık ağacına döner).
        public var source: URL
        /// Seçilen göreli yollar (kaynağa göre).
        public var paths: [String]
        /// Her seçilen yolun hedefe göre göreli yolu (yerleştirme yoksa `paths` ile aynı).
        public var targets: [String]
        public var matched: Int
        public var scanned: Int
        /// Adında satır sonu olduğu için listeye yazılamayan yollar (yalnızca `--from0` desteklemeyen motorda).
        public var skippedNewlines: Int
        /// Yerleştirmede kopyalanmayan sembolik bağlantılar (bkz. `PlacementStaging`).
        public var skippedLinks: Int = 0
        /// İş hazırlık ağacından kopyalanıyor (asıl kaynak kum havuzunda ayrıca okunabilir olmalı).
        public var staged: Bool = false
    }

    /// - Parameters:
    ///   - zeroTerminated: Liste NUL ile ayrılsın (`--from0`); motor desteklemiyorsa satır sonuyla, adında satır sonu
    ///     olanlar atlanarak yazılır.
    ///   - skippedPaths: Taranmayacak göreli yollar (kum havuzunun okutmadığı kişisel klasörler).
    ///   - scratch: Listenin özel (0700) klasörünün açılacağı yer.
    ///   - askFolders: "Klasörü sor"da klasörü bilinmeyen dosya için `PlacementQuestions.DecisionNeeded` atılsın; false ise
    ///     (önizleme) ilk öneri kullanılır.
    public static func prepare(
        _ job: inout TransferJob, zeroTerminated: Bool, skippedPaths: Set<String>,
        scratch: URL = FileManager.default.temporaryDirectory, askFolders: Bool = true, isCancelled: () -> Bool
    ) async throws -> Prepared? {
        guard let rules = job.options.rules else { return nil }
        let skippedNames = job.options.excludeSystemFolders ? Set(RsyncCommand.systemExclusions) : []
        let selected = job.options.selectedItems.map(Set.init)
        let result = try await RuleScanner.scan(job.source, rules: rules, skippedPaths: skippedPaths, skippedNames: skippedNames,
                                                skipsWindowsLeftovers: job.options.excludeWindowsLeftovers,
                                                destination: job.destination, onlyItems: selected, isCancelled: isCancelled)
        let source = job.source
        let folder = scratch.appendingPathComponent("Copiator-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        job.options.copyMode = .contents
        job.options.deleteExtraneous = false
        // Yerleştirme: hedefteki düzen hazırlık ağacında kurulur, iş onu kopyalar (liste gerekmez).
        if let placement = job.options.placement, placement.isActive {
            // "Klasörü sor": klasörü bilinmeyen dosya varsa iş karar bekler (önizlemede ilk öneri kullanılır). Ad şablonu
            // içerikten bir değer istiyorsa dosyaların metni okunur; değeri bulunamayan dosya için ad sorulur.
            var paths = result.paths
            var folders: [String: String]?
            var names: [String: String] = [:]
            var contents: [String: [String: String]] = [:]
            if placement.usesContent {
                let fields = placement.contentFields, required = placement.referencedFields
                for path in paths {
                    if isCancelled() || Task.isCancelled {
                        try? FileManager.default.removeItem(at: folder)
                        throw CancellationError()
                    }
                    contents[path] = ContentField.values(of: source.appendingPathComponent(path), fields: fields, only: required)
                }
            }
            if placement.askFolder || placement.usesContent {
                let plan: PlacementQuestions.Plan
                do {
                    plan = try PlacementQuestions.plan(paths: paths, source: source, destination: job.destination, placement: placement,
                                                       resolution: job.placementResolution, contents: contents, decide: askFolders,
                                                       isCancelled: isCancelled)
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    throw error
                }
                if let report = plan.report {
                    try? FileManager.default.removeItem(at: folder)
                    throw PlacementQuestions.DecisionNeeded(report: report)
                }
                paths = plan.paths
                folders = placement.askFolder ? plan.folders : nil
                names = plan.names
            }
            let staged = try await PlacementStaging.build(paths: paths, source: source, placement: placement,
                                                          in: folder.appendingPathComponent("yerlesim", isDirectory: true),
                                                          destination: job.destination, folders: folders, names: names, contents: contents,
                                                          isCancelled: isCancelled)
            job.source = staged.root
            job.options.placement = nil
            job.options.advanced.filesFromFile = nil
            job.options.advanced.filesFromZeroTerminated = false
            if job.options.advanced.symlinks != .copyTargets { job.options.advanced.symlinks = .copyUnsafeTargets }
            return Prepared(folder: folder, source: source, paths: staged.paths, targets: staged.targets, matched: staged.paths.count,
                            scanned: result.scanned, skippedNewlines: 0, skippedLinks: staged.skippedLinks, staged: true)
        }
        var paths = result.paths
        var skipped = 0
        if !zeroTerminated {
            paths = paths.filter { path in
                let bad = path.contains { $0 == "\n" || $0 == "\r" }
                if bad { skipped += 1 }
                return !bad
            }
        }
        let list = folder.appendingPathComponent("secilenler.txt")
        let separator = zeroTerminated ? "\u{0}" : "\n"
        try Data(paths.map { $0 + separator }.joined().utf8).write(to: list)
        job.options.advanced.filesFromFile = SandboxProfile.resolved(list).path
        job.options.advanced.filesFromZeroTerminated = zeroTerminated
        return Prepared(folder: folder, source: source, paths: paths, targets: paths, matched: paths.count, scanned: result.scanned,
                        skippedNewlines: skipped)
    }
}
