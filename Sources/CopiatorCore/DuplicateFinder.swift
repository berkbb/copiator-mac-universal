// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Arşivde yinelenen dosyalar: boyutu eşit dosyaların SHA-256'sı karşılaştırılır. Aynı dosyaya bağlı kopyalar (sabit
/// bağlantılar) yineleme sayılmaz; anlık görüntü klasörleri ("yyyy-MM-dd-HHmmss", "….partial") taranmaz, çünkü oradaki
/// kopyalar bilerek tutulur; boş dosyalar ve gizli dosyalar sayılmaz. Fazlalar yalnızca onayla ve yalnızca Çöp Sepeti'ne
/// taşınır; taşımadan hemen önce her dosyanın hâlâ kalan dosyayla aynı olduğu yeniden denetlenir.
public enum DuplicateFinder {
    public struct Group: Equatable, Sendable, Identifiable {
        public var size: Int64
        /// Göreli yollar: en sığ (sonra ada göre) önce; ilki varsayılan olarak kalır.
        public var paths: [String]
        public var digest: String
        public var id: String { digest }
        /// Fazlaların kapladığı yer.
        public var wasted: Int64 { size * Int64(max(paths.count - 1, 0)) }
    }

    /// Aynı içerikli dosya grupları, en çok yer kaplayan önce.
    public static func groups(in root: URL, isCancelled: () -> Bool = { false }) throws -> [Group] {
        var bySize: [Int64: [String]] = [:]
        var seenInodes: Set<String> = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles, .producesRelativePathURLs])
        else { return [] }
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited % 256 == 0, isCancelled() || Task.isCancelled { throw CancellationError() }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR {
                if enumerator.level == 1, isSnapshotFolder(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard kind == S_IFREG, info.st_size > 0 else { continue }
            // Aynı dosyaya bağlı ikinci yol yineleme değildir.
            guard seenInodes.insert("\(info.st_dev):\(info.st_ino)").inserted else { continue }
            bySize[Int64(info.st_size), default: []].append(url.relativePath.precomposedStringWithCanonicalMapping)
        }
        var groups: [Group] = []
        for (size, paths) in bySize where paths.count > 1 {
            var byDigest: [String: [String]] = [:]
            for path in paths {
                if isCancelled() || Task.isCancelled { throw CancellationError() }
                guard let digest = try? ArchiveIntegrity.hash(root.appendingPathComponent(path).path, isCancelled: isCancelled) else { continue }
                byDigest[digest, default: []].append(path)
            }
            for (digest, same) in byDigest where same.count > 1 {
                groups.append(Group(size: size, paths: same.sorted(by: shallowFirst), digest: digest))
            }
        }
        return groups.sorted { $0.wasted != $1.wasted ? $0.wasted > $1.wasted : $0.paths[0] < $1.paths[0] }
    }

    /// Fazlaları Çöp'e taşır: her grupta `keep` kalır; taşınacak her dosya taşınmadan önce kalan dosyayla aynı boyut ve
    /// içerikte olmalıdır (tarandıktan sonra değişen dosyaya dokunulmaz).
    /// - Returns: Taşınan dosya sayısı ve taşınmayanlar.
    public static func trashExtras(
        _ groups: [(group: Group, keep: String)], in root: URL, trash: (URL) -> Bool
    ) -> (moved: Int, skipped: [String]) {
        var moved = 0
        var skipped: [String] = []
        for (group, keep) in groups where group.paths.contains(keep) {
            let kept = root.appendingPathComponent(keep)
            guard let keptDigest = try? ArchiveIntegrity.hash(kept.path, isCancelled: { false }), keptDigest == group.digest else {
                skipped += group.paths.filter { $0 != keep }
                continue
            }
            for path in group.paths where path != keep {
                let url = root.appendingPathComponent(path)
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) == group.size,
                      (try? ArchiveIntegrity.hash(url.path, isCancelled: { false })) == keptDigest, trash(url)
                else {
                    skipped.append(path)
                    continue
                }
                moved += 1
            }
        }
        return (moved, skipped)
    }

    static func isSnapshotFolder(_ name: String) -> Bool {
        SnapshotStore.isSnapshotName(name)
            || (name.hasSuffix(SnapshotStore.partialSuffix) && SnapshotStore.isSnapshotName(String(name.dropLast(SnapshotStore.partialSuffix.count))))
    }

    private static func shallowFirst(_ a: String, _ b: String) -> Bool {
        let depthA = a.split(separator: "/").count, depthB = b.split(separator: "/").count
        return depthA != depthB ? depthA < depthB : a.localizedStandardCompare(b) == .orderedAscending
    }
}
