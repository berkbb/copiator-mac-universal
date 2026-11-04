// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// Anlık görüntülerde ada göre arama ve iki anlık görüntüyü karşılaştırma. Dosyaların içeriği okunmaz: yalnızca adlar ve
/// dosya bilgisi (boyut ve değiştirilme tarihi) kullanılır; rsync çalıştırılmaz, anlık görüntüler yalnızca
/// okunur. Gizli öğeler ve sembolik bağlantılar, göz atmadaki gibi sayılmaz.
public enum SnapshotSearch {
    public struct Hit: Equatable, Sendable, Identifiable {
        /// İçerik köküne göre göreli yol.
        public var relativePath: String
        public var isDirectory: Bool
        /// Öğeyi içeren anlık görüntüler, en yeni önce.
        public var snapshots: [SnapshotRestore.Snapshot]
        public var id: String { relativePath }
        public var name: String { (relativePath as NSString).lastPathComponent }
    }

    public struct Results: Equatable, Sendable {
        public var hits: [Hit]
        /// Sınıra ulaşıldı: daha fazla eşleşme olabilir.
        public var isTruncated: Bool
    }

    /// İki anlık görüntü arasındaki bir dosya farkı (yeni anlık görüntüdeki boyut ve tarih; silinende eskideki).
    public struct Change: Equatable, Sendable, Identifiable {
        public var relativePath: String
        public var size: Int64
        public var modified: Date?
        public var id: String { relativePath }
    }

    public struct Difference: Equatable, Sendable {
        public var added: [Change] = []
        public var changed: [Change] = []
        public var removed: [Change] = []
        /// Toplam sayılar (listeler `limit` ile kısaltılır).
        public var addedCount = 0
        public var changedCount = 0
        public var removedCount = 0
        public var isEmpty: Bool { addedCount == 0 && changedCount == 0 && removedCount == 0 }
    }

    /// Adında `query` geçen dosya ve klasörler (harf, aksan ve Türkçe I/ı farkı gözetilmez), yola göre sıralı, en çok
    /// `limit` yol. Her yol için onu içeren anlık görüntüler listelenir.
    /// - Parameter snapshots: Aranacak anlık görüntüler, en yeni önce (`SnapshotRestore.snapshots(of:)`).
    public static func search(_ query: String, in snapshots: [SnapshotRestore.Snapshot], job: TransferJob, limit: Int = 500,
                              isCancelled: () -> Bool = { false }) -> Results {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return Results(hits: [], isTruncated: false) }
        var hits: [String: Hit] = [:]
        var truncated = false
        for snapshot in snapshots {
            walk(SnapshotRestore.contentRoot(of: snapshot, job: job), isCancelled: isCancelled) { path, info in
                guard fold((path as NSString).lastPathComponent).contains(needle) else { return }
                if hits[path] != nil {
                    hits[path]?.snapshots.append(snapshot)
                } else if hits.count < limit {
                    hits[path] = Hit(relativePath: path, isDirectory: info.st_mode & S_IFMT == S_IFDIR, snapshots: [snapshot])
                } else {
                    truncated = true
                }
            }
        }
        let sorted = hits.values.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return Results(hits: sorted, isTruncated: truncated)
    }

    /// `older` ile `newer` arasında eklenen, değişen ve silinen dosyalar (klasörler sayılmaz, içlerindeki dosyalar sayılır).
    /// Boyutu ve tarihi (nanosaniyesiyle) aynı olan dosya değişmemiş sayılır; aynı dosyaya bağlı kopyalar (`--link-dest`)
    /// zaten böyledir.
    public static func compare(_ older: SnapshotRestore.Snapshot, _ newer: SnapshotRestore.Snapshot, job: TransferJob,
                               limit: Int = 1000, isCancelled: () -> Bool = { false }) -> Difference {
        var before: [String: stat] = [:]
        walk(SnapshotRestore.contentRoot(of: older, job: job), isCancelled: isCancelled) { path, info in
            if info.st_mode & S_IFMT == S_IFREG { before[path] = info }
        }
        var difference = Difference()
        var added: [Change] = []
        var changed: [Change] = []
        walk(SnapshotRestore.contentRoot(of: newer, job: job), isCancelled: isCancelled) { path, info in
            guard info.st_mode & S_IFMT == S_IFREG else { return }
            guard let old = before.removeValue(forKey: path) else {
                added.append(change(path, info))
                return
            }
            if old.st_size == info.st_size && old.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec
                && old.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec { return }
            changed.append(change(path, info))
        }
        let removed = before.map { change($0.key, $0.value) }
        func ordered(_ list: [Change]) -> [Change] {
            Array(list.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }.prefix(limit))
        }
        difference.addedCount = added.count
        difference.changedCount = changed.count
        difference.removedCount = removed.count
        difference.added = ordered(added)
        difference.changed = ordered(changed)
        difference.removed = ordered(removed)
        return difference
    }

    private static func change(_ path: String, _ info: stat) -> Change {
        Change(relativePath: path, size: Int64(info.st_size),
               modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
    }

    static func fold(_ text: String) -> String { ContentReader.fold(text.precomposedStringWithCanonicalMapping) }

    /// Kökün altındaki klasörler ve sıradan dosyalar (gizliler ve bağlantılar hariç; bağlantılar izlenmez).
    static func walk(_ root: URL, isCancelled: () -> Bool, _ visit: (_ relativePath: String, _ info: stat) -> Void) {
        var pending = [""]
        while let relative = pending.popLast() {
            if isCancelled() { return }
            let folder = relative.isEmpty ? root.path : root.path + "/" + relative
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where !name.hasPrefix(".") {
                let path = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard lstat(root.path + "/" + path, &info) == 0 else { continue }
                let kind = info.st_mode & S_IFMT
                guard kind == S_IFDIR || kind == S_IFREG else { continue }
                visit(path, info)
                if kind == S_IFDIR { pending.append(path) }
            }
        }
    }
}
