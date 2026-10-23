// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Anlık görüntülerden geri yükleme: bir işin anlık görüntülerine göz atılır, bir dosyanın zaman içindeki sürümleri
/// görülür ve seçilen öğe sıradan bir kopyalama işiyle asıl yerine ya da başka bir klasöre geri kopyalanır. Böylece kum
/// havuzu, aynı adlı dosya sorusu (değiştir, ikisini de sakla, atla) ve doğrulama olduğu gibi kullanılır; hiçbir şey
/// silinmez, anlık görüntü yalnızca okunur.
public enum SnapshotRestore {
    public struct Snapshot: Equatable, Hashable, Sendable, Identifiable {
        public var name: String
        public var date: Date
        public var url: URL
        public var id: String { name }
    }

    public struct Item: Equatable, Sendable, Identifiable {
        public var name: String
        /// İçerik köküne (kaynağın anlık görüntüdeki karşılığına) göre göreli yol.
        public var relativePath: String
        public var isDirectory: Bool
        public var size: Int64
        public var modified: Date?
        public var id: String { relativePath }
    }

    /// Bir dosyanın bir sürümü: içinde bulunduğu en eski anlık görüntü (sonrakilerde değişmeden kaldıysa onlarda aynı dosyaya
    /// bağlıdır), boyutu ve değiştirilme tarihi.
    public struct Version: Equatable, Sendable, Identifiable {
        public var snapshot: Snapshot
        public var size: Int64
        public var modified: Date?
        public var id: String { snapshot.name }
    }

    /// İşin tamamlanmış anlık görüntüleri, en yeni önce (yarım kalanlar ve "Latest" bağlantısı hariç).
    public static func snapshots(of job: TransferJob, timeZone: TimeZone = .current) -> [Snapshot] {
        SnapshotStore.completeSnapshots(in: job.destination, timeZone: timeZone).reversed().compactMap { name in
            SnapshotStore.date(fromName: name, timeZone: timeZone).map {
                Snapshot(name: name, date: $0, url: job.destination.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    /// Kaynağın anlık görüntüdeki karşılığı: "klasörün kendisi" kipinde anlık görüntü/Ad, "içeriği" kipinde anlık görüntünün
    /// kendisi.
    public static func contentRoot(of snapshot: Snapshot, job: TransferJob) -> URL {
        var copy = job
        copy.destination = snapshot.url
        // Kaynak artık yoksa (silinmişse) klasör sayılır: geri yüklemenin en sık nedeni budur.
        return copy.target(sourceIsDirectory: isDirectory(job.source) || !exists(job.source))
    }

    /// Bir klasörün öğeleri (gizliler hariç): klasörler önce, sonra adına göre. Bağlantılar izlenmez.
    public static func items(in root: URL, at relativePath: String) -> [Item] {
        let folder = relativePath.isEmpty ? root : root.appendingPathComponent(relativePath)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
        return names.compactMap { name -> Item? in
            var info = stat()
            let url = folder.appendingPathComponent(name)
            guard lstat(url.path, &info) == 0 else { return nil }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { return nil }
            let path = relativePath.isEmpty ? name : relativePath + "/" + name
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            return Item(name: name, relativePath: path, isDirectory: kind == S_IFDIR, size: kind == S_IFREG ? Int64(info.st_size) : 0,
                        modified: modified)
        }.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Bir dosyanın farklı sürümleri, en yeni önce: anlık görüntüler arasında aynı dosyaya bağlı (değişmemiş) kopyalar tek
    /// sürümdür ve en eski anlık görüntüyle gösterilir.
    public static func versions(of relativePath: String, job: TransferJob, timeZone: TimeZone = .current) -> [Version] {
        var seen: [String: Version] = [:]
        var order: [String] = []
        for snapshot in snapshots(of: job, timeZone: timeZone).reversed() {
            let url = contentRoot(of: snapshot, job: job).appendingPathComponent(relativePath)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            let key = "\(info.st_dev):\(info.st_ino)"
            guard seen[key] == nil else { continue }
            seen[key] = Version(snapshot: snapshot, size: Int64(info.st_size),
                                modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
            order.append(key)
        }
        return order.reversed().compactMap { seen[$0] }
    }

    /// Öğenin asıl yeri: kaynakta içinde bulunduğu klasör ("klasörün kendisi" kipinde kaynağın tamamı için kaynağın üst
    /// klasörü).
    public static func originalFolder(of relativePath: String, job: TransferJob) -> URL {
        if relativePath.isEmpty { return job.options.copyMode == .contents ? job.source : job.source.deletingLastPathComponent() }
        let base = job.options.copyMode == .contents ? job.source : job.source.deletingLastPathComponent()
        let parent = (relativePath as NSString).deletingLastPathComponent
        let inside = job.options.copyMode == .contents ? parent : ([job.source.lastPathComponent] + [parent]).filter { !$0.isEmpty }.joined(separator: "/")
        return inside.isEmpty ? base : base.appendingPathComponent(inside, isDirectory: true)
    }

    /// Geri yükleme işi: anlık görüntüdeki öğe `folder` klasörüne kopyalanır. Kaynak öğenin anlık görüntüdeki klasörüdür ve
    /// yalnızca o öğe seçilir; aynı adlı dosya varsa sorulur, hiçbir şey silinmez.
    /// - Parameter relativePath: İçerik köküne göre öğe ("" kaynağın tamamı).
    public static func restoreJob(_ relativePath: String, from snapshot: Snapshot, of job: TransferJob, to folder: URL) -> TransferJob {
        let root = contentRoot(of: snapshot, job: job)
        var options = CopyOptions(copyMode: .contents, preservePermissions: job.options.preservePermissions,
                                  preserveExtendedAttributes: job.options.preserveExtendedAttributes, rules: RuleGroup(),
                                  conflictPolicy: .ask)
        if relativePath.isEmpty {
            // Kaynağın tamamı: "klasörün kendisi" kipinde klasör adıyla, "içeriği" kipinde içeriğiyle geri gelir.
            if job.options.copyMode == .folder {
                options.selectedItems = [root.lastPathComponent]
                return TransferJob(source: root.deletingLastPathComponent(), destination: folder, options: options)
            }
            return TransferJob(source: root, destination: folder, options: options)
        }
        let parent = (relativePath as NSString).deletingLastPathComponent
        options.selectedItems = [(relativePath as NSString).lastPathComponent]
        return TransferJob(source: parent.isEmpty ? root : root.appendingPathComponent(parent, isDirectory: true), destination: folder,
                           options: options)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
