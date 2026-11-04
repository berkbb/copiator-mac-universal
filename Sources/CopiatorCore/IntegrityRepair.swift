// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// Bozuk dosyaların onarımı: bütünlük listesinde her dosyanın olması gereken boyutu ve SHA-256 özeti kayıtlıdır. Hedefin
/// kendisinde (ör. dosyanın ayrı kopyası olan eski bir anlık görüntü) ve işin kaynak klasörlerinde bu özetle birebir aynı
/// bir dosya aranır; bulunursa bozuk dosyanın içeriği yerinde onunla değiştirilir. Yerinde yazıldığı için aynı dosyaya
/// bağlı anlık görüntü kopyaları da birlikte düzelir; değiştirilme tarihi listedeki tarihe geri alınır ve yazılan içerik
/// yeniden okunup özetle karşılaştırılır. Kaynak yalnızca okunur; denetimden sonra değişen dosyaya dokunulmaz.
extension ArchiveIntegrity {
    public struct RepairReport: Equatable, Sendable {
        /// Onarılan dosyalar: göreli yol → sağlam kopyanın bulunduğu yer.
        public var repaired: [String: URL] = [:]
        /// Sağlam kopyası bulunamayan dosyalar.
        public var noCopy: [String] = []
        /// Denetimden sonra değişen (artık bozuk sayılmayan) ya da listede olmayan dosyalar; dokunulmadı.
        public var changed: [String] = []
        /// Yazılamayan ya da yazıldıktan sonra özeti tutmayan dosyalar.
        public var failed: [String] = []

        public init() {}
    }

    /// Bozuk dosyaları sağlam kopyalarından onarır.
    /// - Parameters:
    ///   - corrupted: Bütünlük denetiminin bozuk bulduğu göreli yollar.
    ///   - root: Denetlenen hedef (listenin bulunduğu klasör).
    ///   - sources: Sağlam kopyanın da aranacağı klasörler (işlerin kaynakları); yalnızca okunur.
    /// - Throws: İptalde `CancellationError` (o ana kadar onarılanlar onarılmış kalır).
    public static func repair(
        _ corrupted: [String], in root: URL, searching sources: [URL], isCancelled: () -> Bool = { false }
    ) throws -> RepairReport {
        var report = RepairReport()
        let files = manifest(in: root)?.files ?? [:]
        let realRoot = realPath(root.path) ?? root.path
        // Hâlâ bozuk olan hedefler: boyutu ve tarihi listedekiyle aynı, içeriği farklı.
        var targets: [(relative: String, url: URL, entry: Entry, inode: String)] = []
        for relative in Array(Set(corrupted)).sorted() {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            let url = root.appendingPathComponent(relative)
            var info = stat()
            guard let entry = files[relative], isInside(relative, url: url, realRoot: realRoot), lstat(url.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) == entry.size, abs(modifiedTime(info) - entry.modified) < 0.001
            else {
                report.changed.append(relative)
                continue
            }
            guard let digest = try? hash(url.path, isCancelled: isCancelled), digest != entry.sha256 else {
                report.changed.append(relative)
                continue
            }
            targets.append((relative, url, entry, "\(info.st_dev):\(info.st_ino)"))
        }
        guard !targets.isEmpty else { return report }

        // Aranan boyutlardaki aday dosyalar (bozuk dosyaların kendisi ve onlara bağlı yollar hariç); özet aday başına bir kez.
        let sizes = Set(targets.map(\.entry.size))
        let corruptedInodes = Set(targets.map(\.inode))
        var candidates: [Int64: [(url: URL, inode: String)]] = [:]
        for folder in [root] + sources {
            for (url, info) in candidateFiles(in: folder, sizes: sizes, isCancelled: isCancelled) {
                let inode = "\(info.st_dev):\(info.st_ino)"
                guard !corruptedInodes.contains(inode) else { continue }
                candidates[Int64(info.st_size), default: []].append((url, inode))
            }
        }
        var digests: [String: String] = [:]
        func digest(of candidate: (url: URL, inode: String)) throws -> String? {
            if let known = digests[candidate.inode] { return known }
            do {
                let value = try hash(candidate.url.path, isCancelled: isCancelled)
                digests[candidate.inode] = value
                return value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
        }

        var repairedInodes: [String: URL] = [:]
        for target in targets {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            // Aynı dosyaya bağlı başka bir yol az önce onarıldıysa bu yol da onarılmıştır.
            if let source = repairedInodes[target.inode] {
                if (try? hash(target.url.path, isCancelled: isCancelled)) == target.entry.sha256 {
                    report.repaired[target.relative] = source
                } else {
                    report.failed.append(target.relative)
                }
                continue
            }
            var source: URL?
            for candidate in candidates[target.entry.size] ?? [] where try digest(of: candidate) == target.entry.sha256 {
                source = candidate.url
                break
            }
            guard let source else {
                report.noCopy.append(target.relative)
                continue
            }
            if write(from: source, to: target.url, entry: target.entry),
               (try? hash(target.url.path, isCancelled: isCancelled)) == target.entry.sha256 {
                report.repaired[target.relative] = source
                repairedInodes[target.inode] = source
            } else {
                report.failed.append(target.relative)
            }
        }
        return report
    }

    /// Sağlam kopyanın da aranacağı kaynaklar: hedefi bu klasör olan işlerin ve rutin rotalarının var olan kaynakları
    /// (her biri bir kez).
    public static func repairSources(for destination: URL, jobs: [TransferJob], routines: [Routine]) -> [URL] {
        let path = RsyncCommand.absolutePath(destination)
        var sources = jobs.filter { RsyncCommand.absolutePath($0.destination) == path }.map(\.source)
        for routine in routines {
            for route in routine.routes where route.destination.map({ RsyncCommand.absolutePath($0) == path }) ?? false {
                if let source = route.source { sources.append(source) }
            }
        }
        var seen = Set<String>()
        return sources.filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert(RsyncCommand.absolutePath($0)).inserted }
    }

    /// Göreli yol hedefin içinde mi ("." ya da ".." bileşeni yok; üst klasör bağlantılarla dışarı çıkmıyor).
    static func isInside(_ relative: String, url: URL, realRoot: String) -> Bool {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        guard let parent = realPath(url.deletingLastPathComponent().path) else { return false }
        return parent == realRoot || parent.hasPrefix(realRoot.hasSuffix("/") ? realRoot : realRoot + "/")
    }

    /// Bir klasördeki (ya da tek dosyalık kaynaktaki), boyutu aranan boyutlardan biri olan düzenli dosyalar (bağlantılar
    /// izlenmez; atlanan sistem klasörlerinin içine girilmez).
    static func candidateFiles(in folder: URL, sizes: Set<Int64>, isCancelled: () -> Bool) -> [(URL, stat)] {
        var result: [(URL, stat)] = []
        var top = stat()
        guard lstat(folder.path, &top) == 0 else { return [] }
        // Tek dosyalık bir kaynak.
        if top.st_mode & S_IFMT == S_IFREG { return sizes.contains(Int64(top.st_size)) ? [(folder, top)] : [] }
        guard top.st_mode & S_IFMT == S_IFDIR, let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited % 256 == 0, isCancelled() || Task.isCancelled { break }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            if skippedNames.contains(url.lastPathComponent) {
                if info.st_mode & S_IFMT == S_IFDIR { enumerator.skipDescendants() }
                continue
            }
            guard info.st_mode & S_IFMT == S_IFREG, sizes.contains(Int64(info.st_size)) else { continue }
            result.append((url, info))
        }
        return result
    }

    /// Sağlam kopyanın içeriğini bozuk dosyanın üzerine yerinde yazar (aynı dosyaya bağlı yollar birlikte düzelir), boyutu
    /// listedekine keser ve değiştirilme tarihini listedekine geri alır. Salt okunur dosyaya yazmak için sahibin yazma izni
    /// geçici olarak eklenir ve sonra geri alınır. Bağlantı izlenmez.
    static func write(from source: URL, to target: URL, entry: Entry) -> Bool {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { return false }
        defer { close(input) }
        var info = stat()
        guard lstat(target.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        var output = open(target.path, O_WRONLY | O_NOFOLLOW)
        var restoreMode: mode_t?
        if output < 0, errno == EACCES, info.st_uid == getuid(), info.st_mode & S_IWUSR == 0,
           chmod(target.path, (info.st_mode & 0o7777) | S_IWUSR) == 0 {
            restoreMode = info.st_mode & 0o7777
            output = open(target.path, O_WRONLY | O_NOFOLLOW)
        }
        defer { if let restoreMode { chmod(target.path, restoreMode) } }
        guard output >= 0 else { return false }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var written: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count < 0 { return false }
            if count == 0 { break }
            var offset = 0
            while offset < count {
                let done = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress! + offset, count - offset) }
                if done <= 0 { return false }
                offset += done
            }
            written += Int64(count)
        }
        guard written == entry.size, ftruncate(output, off_t(entry.size)) == 0, fsync(output) == 0 else { return false }
        let seconds = entry.modified.rounded(.down)
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: Int(seconds), tv_nsec: Int(((entry.modified - seconds) * 1e9).rounded()))]
        if times[1].tv_nsec >= 1_000_000_000 { times[1].tv_nsec = 999_999_999 }
        return futimens(output, &times) == 0
    }

    /// Bağlantıları çözülmüş tam yol (yoksa nil).
    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func modifiedTime(_ info: stat) -> TimeInterval {
        TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
    }
}
