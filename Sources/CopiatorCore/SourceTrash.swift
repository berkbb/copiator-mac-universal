// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// "Taşı": kopyalamadan sonra kaynak dosyalar Çöp Sepeti'ne taşınır, ama yalnızca hedefteki karşılığıyla içeriği (SHA-256)
/// birebir aynı olanlar. Atlanan, dışlanan, yarım kalan ya da sonradan değişen dosya hiçbir zaman çöpe gitmez; kalıcı silme
/// yoktur (Çöp Sepeti'ne taşınamayan dosya yerinde kalır). Boşalan alt klasörler de Çöp'e gider; kaynağın kendisi kalır.
/// Bunu rsync değil uygulama yapar: rsync'e hiçbir zaman `--remove-source-files` verilmez.
public enum SourceTrash {
    /// Kaynaktaki bir dosya ve hedefteki karşılığı.
    public struct Pair: Equatable, Sendable {
        public var source: URL
        public var target: URL

        public init(source: URL, target: URL) {
            self.source = source
            self.target = target
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// Çöp Sepeti'ne taşınan dosyalar.
        public var moved = 0
        public var bytes: Int64 = 0
        /// Hedefte birebir aynısı olmadığı için yerinde bırakılan dosyalar.
        public var kept = 0
        /// Taşınamayan dosyalar (Çöp Sepeti yok, izin yok…): kaynağa göre göreli yollar.
        public var failed: [String] = []
        /// Boşalıp Çöp Sepeti'ne taşınan alt klasörler.
        public var folders = 0
        /// Çöp'e taşınan dosya ve klasörlerin eski ve Çöp'teki yerleri (taşıyan çalıştırmayı geri almak için).
        public var located: [RunUndo.MovedSource] = []
        /// Çöp'e taşınan ama Çöp'teki yeri bilinmeyen (ya da kayıt sınırını aşan) öğeler: bu çalıştırma geri alınamaz.
        public var unlocated = 0

        public init() {}

        /// Taşınan öğenin yerini kaydeder; Çöp'teki yerinde bir öğe yoksa yer bilinmiyor sayılır.
        mutating func record(original: URL, location: URL, target: URL?) {
            var info = stat()
            guard lstat(location.path, &info) == 0, located.count < RunUndo.maxRecordedItems else {
                unlocated += 1
                return
            }
            located.append(RunUndo.MovedSource(original: original.path, trashed: location.path, target: target?.path))
        }
    }

    /// İşin kopyaladığı dosyalar ve hedefteki karşılıkları. Kurallı işte seçilen yollar (paketlerin içindeki dosyalarla),
    /// kurulsuz işte kaynağın tamamı (sistem klasörleri ve kum havuzunun okutmadığı kişisel klasörler hariç).
    /// - Parameters:
    ///   - job: İşin çalıştırmadan önceki hâli (asıl kaynak ve hedef).
    ///   - selection: Kural seçimi: asıl kaynak, kaynağa göre yollar ve hedefe göre yollar.
    public static func pairs(
        for job: TransferJob, selection: (source: URL, paths: [String], targets: [String])?, skippedNames: Set<String>,
        skippedPaths: Set<String>, isCancelled: () -> Bool = { false }
    ) -> [Pair] {
        let skipsLeftovers = job.options.excludeWindowsLeftovers
        if let selection {
            var pairs: [Pair] = []
            for (path, target) in zip(selection.paths, selection.targets) {
                let source = selection.source.appendingPathComponent(path)
                let destination = job.destination.appendingPathComponent(target)
                if RsyncEngine.isDirectory(source) {
                    pairs += files(under: source, skippedNames: [], skippedPaths: [], isCancelled: isCancelled)
                        .map { Pair(source: source.appendingPathComponent($0), target: destination.appendingPathComponent($0)) }
                } else {
                    pairs.append(Pair(source: source, target: destination))
                }
            }
            return pairs
        }
        let sourceIsDirectory = RsyncEngine.isDirectory(job.source)
        let target = job.target(sourceIsDirectory: sourceIsDirectory)
        guard sourceIsDirectory else { return [Pair(source: job.source, target: target)] }
        return files(under: job.source, skippedNames: skippedNames, skippedPaths: skippedPaths, skipsWindowsLeftovers: skipsLeftovers,
                     isCancelled: isCancelled)
            .map { Pair(source: job.source.appendingPathComponent($0), target: target.appendingPathComponent($0)) }
    }

    /// Klasörün altındaki düzenli dosyalar (göreli yollar); bağlantılar izlenmez.
    static func files(
        under root: URL, skippedNames: Set<String>, skippedPaths: Set<String>, skipsWindowsLeftovers: Bool = false, isCancelled: () -> Bool
    ) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var paths: [String] = []
        while let relative = enumerator.nextObject() as? String {
            if isCancelled() { break }
            let attributes = enumerator.fileAttributes
            let type = attributes?[.type] as? FileAttributeType
            let name = (relative as NSString).lastPathComponent
            if skippedPaths.contains(relative) || skippedNames.contains(name) || (skipsWindowsLeftovers && RsyncCommand.isWindowsLeftover(name)) {
                if type == .typeDirectory { enumerator.skipDescendants() }
                continue
            }
            if type == .typeRegular { paths.append(relative) }
        }
        return paths
    }

    /// Öğeyi sistemin Çöp Sepeti'ne taşır (öğenin bulunduğu birimin Çöp Sepeti); kalıcı silmez.
    public static func systemTrash(_ url: URL) -> Bool {
        (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
    }

    /// Öğeyi sistemin Çöp Sepeti'ne taşır ve Çöp'teki yerini döndürür (geri koymak için); taşınamazsa nil. macOS yeri
    /// bildirmezse öğenin eski yolu döner: öğe taşınmıştır ama geri konamaz.
    public static func systemTrashLocating(_ url: URL) -> URL? {
        var location: NSURL?
        guard (try? FileManager.default.trashItem(at: url, resultingItemURL: &location)) != nil else { return nil }
        return (location as URL?) ?? url
    }

    /// Hedefteki karşılığıyla birebir aynı olan kaynak dosyaları Çöp Sepeti'ne taşır.
    /// - Parameters:
    ///   - root: Kaynağın kökü: boşalan alt klasörler köke kadar Çöp'e gider, kök kalır.
    ///   - trash: Çöp Sepeti'ne taşıma; öğenin Çöp'teki yerini döndürür, taşınamazsa nil (testler kendi klasörlerini verir).
    public static func moveVerified(
        _ pairs: [Pair], root: URL, trash: (URL) -> URL? = systemTrashLocating, isCancelled: () -> Bool = { false }
    ) -> Outcome {
        var outcome = Outcome()
        var touched = Set<String>()
        for pair in pairs {
            if isCancelled() { break }
            var source = stat(), target = stat()
            guard lstat(pair.source.path, &source) == 0, source.st_mode & S_IFMT == S_IFREG,
                  lstat(pair.target.path, &target) == 0, target.st_mode & S_IFMT == S_IFREG,
                  source.st_size == target.st_size,
                  let left = DestinationIndex.digest(of: pair.source.path), left == DestinationIndex.digest(of: pair.target.path) else {
                outcome.kept += 1
                continue
            }
            // Yollar taşımadan önce çözülür: sonra kaynak artık yoktur.
            let original = SandboxProfile.resolved(pair.source), copy = SandboxProfile.resolved(pair.target)
            if let location = trash(pair.source) {
                outcome.moved += 1
                outcome.bytes = outcome.bytes.saturatingAdding(Int64(source.st_size))
                touched.insert(pair.source.deletingLastPathComponent().standardizedFileURL.path)
                outcome.record(original: original, location: location, target: copy)
            } else {
                outcome.failed.append(relativePath(pair.source, root: root))
            }
        }
        let folders = removeEmptyFolders(touched, root: root, trash: trash)
        outcome.folders = folders.count
        for (original, location) in folders.located { outcome.record(original: original, location: location, target: nil) }
        return outcome
    }

    /// Çok rotalı rutinde bekleyen taşıma: kaynak dosya, bu rotadaki karşılığı ve kaynağın kökü (boşalan klasörler köke
    /// kadar Çöp'e gider); çözülmüş mutlak yollar.
    public struct PendingMove: Codable, Equatable, Sendable {
        public var source: String
        public var target: String
        public var root: String

        public init(source: String, target: String, root: String) {
            self.source = source
            self.target = target
            self.root = root
        }
    }

    /// Bekleyen taşıma kaydı; sınırı aşarsa nil (o zaman hiçbir kaynak taşınmaz: yarım taşıma yanıltıcı olurdu).
    public static func pendingMoves(_ pairs: [Pair], root: URL) -> [PendingMove]? {
        guard pairs.count <= RunUndo.maxRecordedItems else { return nil }
        let base = SandboxProfile.resolved(root).path
        return pairs.map { PendingMove(source: SandboxProfile.resolved($0.source).path, target: SandboxProfile.resolved($0.target).path, root: base) }
    }

    /// Çok rotalı rutinin "Taşı" adımı: her kaynak dosya, onu seçen BÜTÜN rotaların hedefindeki karşılığıyla (boyut ve
    /// SHA-256) birebir aynıysa Çöp'e gider; bir karşılık eksik ya da farklıysa (atlanmış, değişmiş, diski çıkarılmış) kaynak
    /// yerinde kalır. Doğrulama taşıma anında yeniden yapılır. Boşalan alt klasörler köke kadar Çöp'e gider; kök kalır.
    public static func moveAcrossRoutes(_ moves: [PendingMove], trash: (URL) -> URL? = systemTrashLocating,
                                        isCancelled: () -> Bool = { false }) -> Outcome {
        var outcome = Outcome()
        var targets: [String: [String]] = [:]
        var roots: [String: String] = [:]
        var order: [String] = []
        for move in moves {
            if targets[move.source] == nil { order.append(move.source) }
            targets[move.source, default: []].append(move.target)
            // Kaynağı birden çok rota seçtiyse en kısa kök (en dıştaki klasör) kullanılır.
            if roots[move.source].map({ move.root.count < $0.count }) ?? true { roots[move.source] = move.root }
        }
        var touched: [String: Set<String>] = [:]
        for path in order {
            if isCancelled() { break }
            let source = URL(fileURLWithPath: path)
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, let digest = DestinationIndex.digest(of: path),
                  let copies = targets[path], copies.allSatisfy({ target in
                      var copy = stat()
                      return lstat(target, &copy) == 0 && copy.st_mode & S_IFMT == S_IFREG && copy.st_size == info.st_size
                          && DestinationIndex.digest(of: target) == digest
                  }) else {
                outcome.kept += 1
                continue
            }
            if let location = trash(source) {
                outcome.moved += 1
                outcome.bytes = outcome.bytes.saturatingAdding(Int64(info.st_size))
                touched[roots[path] ?? "", default: []].insert(source.deletingLastPathComponent().standardizedFileURL.path)
                outcome.record(original: source, location: location, target: URL(fileURLWithPath: copies[0]))
            } else {
                outcome.failed.append(path)
            }
        }
        for (root, folders) in touched where !root.isEmpty {
            let removed = removeEmptyFolders(folders, root: URL(fileURLWithPath: root, isDirectory: true), trash: trash)
            outcome.folders += removed.count
            for (original, location) in removed.located { outcome.record(original: original, location: location, target: nil) }
        }
        return outcome
    }

    /// Temizleme aracı: kaynakta olup hedefte (herhangi bir yerde, herhangi bir adla) aynı içerikte kopyası bulunan
    /// dosyalar (gizli dosyalar hariç).
    public static func archivedFiles(in source: URL, destination: URL, isCancelled: () -> Bool = { false }) throws -> [URL] {
        let index = try DestinationIndex(root: destination, isCancelled: isCancelled)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var found: [URL] = []
        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            if seen % 256 == 0, isCancelled() || Task.isCancelled { throw CancellationError() }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, let size = values.fileSize,
                  index.contains(url, size: Int64(size)) else { continue }
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }

    /// Verilen dosyaları Çöp Sepeti'ne taşır (temizleme aracı; dosyalar `archivedFiles` ile bulunmuştur).
    public static func move(_ urls: [URL], root: URL, trash: (URL) -> Bool = systemTrash) -> Outcome {
        var outcome = Outcome()
        var touched = Set<String>()
        for url in urls {
            var info = stat()
            let size = lstat(url.path, &info) == 0 ? Int64(info.st_size) : 0
            if trash(url) {
                outcome.moved += 1
                outcome.bytes = outcome.bytes.saturatingAdding(size)
                touched.insert(url.deletingLastPathComponent().standardizedFileURL.path)
            } else {
                outcome.failed.append(relativePath(url, root: root))
            }
        }
        outcome.folders = removeEmptyFolders(touched, root: root, trash: { trash($0) ? $0 : nil }).count
        return outcome
    }

    /// Dosyaları taşınan klasörlerden boşalanlar (en derindekinden başlayarak, köke kadar; kök hariç) Çöp'e gider.
    /// Döner: taşınan klasör sayısı ve her birinin (taşımadan önce çözülmüş) eski yolu ile Çöp'teki yeri.
    private static func removeEmptyFolders(
        _ folders: Set<String>, root: URL, trash: (URL) -> URL?
    ) -> (count: Int, located: [(URL, URL)]) {
        let rootPath = root.standardizedFileURL.path
        var candidates = Set<String>()
        for folder in folders {
            var path = folder
            while path.hasPrefix(rootPath + "/") {
                candidates.insert(path)
                path = (path as NSString).deletingLastPathComponent
            }
        }
        var removed = 0
        var located: [(URL, URL)] = []
        for path in candidates.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            guard (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true else { continue }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let original = SandboxProfile.resolved(folder)
            if let location = trash(folder) {
                removed += 1
                located.append((original, location))
            }
        }
        return (removed, located)
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
    }
}
