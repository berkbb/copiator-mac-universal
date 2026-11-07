// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// Son çalıştırmayı geri alma (güvenli kısım; 2026-11-04 kullanıcı kararı). Anlık görüntülü işte son anlık görüntü
/// Çöp Sepeti'ne taşınır ve "Latest" bir öncekine döner. Anlık görüntüsüz işte yalnızca son çalıştırmanın eklediği
/// öğeler Çöp Sepeti'ne taşınır: üzerine yazılan ya da silinen dosyalar geri gelmez (sayıları söylenir). Hiçbir şey
/// kalıcı olarak silinmez; çalıştırmadan önce var olan (durum değişim zamanı çalıştırmadan eski) ya da sonradan içeriği
/// değiştirilen (değişme zamanı çalıştırmadan yeni) öğelere dokunulmaz.
public enum RunUndo {
    /// Kaydedilen en çok eklenen öğe; fazlası varsa geri alma sunulmaz (yarım geri alma yanıltıcı olurdu).
    public static let maxRecordedItems = 5_000
    /// Dosya tarihlerinde tanınan kayma (dosya sistemleri saniyeyi yuvarlayabilir).
    static let tolerance: TimeInterval = 2

    public struct Record: Codable, Equatable, Sendable {
        /// Eklenen öğeler, hedefe göre göreli (rsync'in değişiklik satırlarındaki adlar; klasörlerin sonunda "/" yok).
        public var created: [String]
        /// Sınır aşıldı: liste eksik.
        public var truncated: Bool
        /// Üzerine yazılan ya da silinen öğe sayısı (geri alınamaz).
        public var otherChanges: Int
        /// "Taşı" ile Çöp Sepeti'ne giden kaynak dosya ve klasörler (geri alma önce bunları yerine koyar).
        public var movedSources: [MovedSource]
        /// Çöp'e taşınan bir kaynağın yeri bilinmiyor ya da sınır aşıldı: çalıştırma geri alınamaz.
        public var movedSourcesIncomplete: Bool
        /// Kayıt Çöp'e taşınan kaynakları tutabiliyor. 1.1.0'ın kayıtlarında (alan yok) bilinmez: "Taşı" seçili işte
        /// böyle bir çalıştırma geri alınmaz, yoksa kopyalar da Çöp'e giderdi.
        public private(set) var knowsMovedSources = true

        public init(created: [String], truncated: Bool, otherChanges: Int, movedSources: [MovedSource] = [],
                    movedSourcesIncomplete: Bool = false) {
            self.created = created
            self.truncated = truncated
            self.otherChanges = otherChanges
            self.movedSources = movedSources
            self.movedSourcesIncomplete = movedSourcesIncomplete
        }

        private enum CodingKeys: String, CodingKey { case created, truncated, otherChanges, movedSources, movedSourcesIncomplete }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            created = (try? c.decodeIfPresent([String].self, forKey: .created)) ?? []
            // Okunamayan liste eksik sayılır: yarım geri alma sunulmaz.
            truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? true
            otherChanges = (try? c.decodeIfPresent(Int.self, forKey: .otherChanges)) ?? 0
            knowsMovedSources = c.contains(.movedSources)
            let moved = try? c.decodeIfPresent([MovedSource].self, forKey: .movedSources)
            movedSources = moved ?? []
            movedSourcesIncomplete = ((try? c.decodeIfPresent(Bool.self, forKey: .movedSourcesIncomplete)) ?? false)
                || (knowsMovedSources && moved == nil)
        }
    }

    /// Çöp Sepeti'ne taşınan bir kaynak öğe: eski yeri, Çöp'teki yeri ve (dosyaysa) hedefteki kopyası; mutlak yollar.
    public struct MovedSource: Codable, Equatable, Sendable {
        public var original: String
        public var trashed: String
        /// Dosyanın hedefteki kopyası; klasörlerde nil.
        public var target: String?

        public init(original: String, trashed: String, target: String?) {
            self.original = original
            self.trashed = trashed
            self.target = target
        }
    }

    public struct Outcome: Equatable, Sendable {
        public var trashed = 0
        /// Dokunulmayan öğeler (artık yok, çalıştırmadan önce vardı, sonradan değişti ya da içinde başka şey var).
        public var kept: [String] = []
        public var failed: [String] = []
    }

    /// Kaynakları geri koymanın sonucu.
    public struct RestoreOutcome: Equatable, Sendable {
        /// Yerine geri konan dosyalar.
        public var restored = 0
        /// Geri konamayan dosyalar (Çöp boşaltılmış, eski yer dolu ya da taşıma başarısız): eski yolları.
        public var notRestored: [String] = []
        /// Kaynağı geri konamayan dosyaların hedefteki kopyaları: bunlar Çöp'e taşınmaz, tek kopya onlar olabilir.
        public var keepTargets: Set<String> = []
    }

    /// Öğeyi Çöp'teki yerinden eski yerine taşır (testler kendi işlevlerini verir).
    public static func putBack(_ trashed: URL, to original: URL) -> Bool {
        (try? FileManager.default.moveItem(at: trashed, to: original)) != nil
    }

    /// Taşıyan çalıştırmayı geri almanın ilk adımı: Çöp Sepeti'ne giden kaynak öğeler eski yerlerine geri konur, önce
    /// klasörler (en sığdan), sonra dosyalar. Yalnızca bir Çöp klasöründeki (".Trash", ".Trashes") öğe ve yalnızca
    /// kaynağın içindeki boş bir yere taşınır; "." ya da ".." içeren ya da kaynağın dışına çıkan kayıt reddedilir. Eski yer
    /// doluysa ya da öğe Çöp'te yoksa dokunulmaz ve dosyanın hedefteki kopyası korunur.
    /// - Parameter source: İşin kaynağı (klasör ya da tek dosya).
    public static func restoreSources(_ moved: [MovedSource], source: URL, putBack: (URL, URL) -> Bool = putBack) -> RestoreOutcome {
        var outcome = RestoreOutcome()
        let root = SandboxProfile.resolved(source).path
        func acceptable(_ item: MovedSource) -> Bool {
            let original = item.original.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            let trashed = item.trashed.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            guard item.original.hasPrefix("/"), item.trashed.hasPrefix("/"),
                  !original.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !trashed.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  trashed.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) else { return false }
            return item.original == root || item.original.hasPrefix(root + "/")
        }
        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0
        }
        func depth(_ item: MovedSource) -> Int { item.original.split(separator: "/").count }
        let folders = moved.filter { $0.target == nil }.sorted { depth($0) < depth($1) }
        for folder in folders where acceptable(folder) && !exists(folder.original) && exists(folder.trashed) {
            let original = URL(fileURLWithPath: folder.original)
            try? FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = putBack(URL(fileURLWithPath: folder.trashed), original)
        }
        for file in moved where file.target != nil {
            let original = URL(fileURLWithPath: file.original)
            if acceptable(file), !exists(file.original), exists(file.trashed) {
                try? FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                if putBack(URL(fileURLWithPath: file.trashed), original) {
                    outcome.restored += 1
                    continue
                }
            }
            // Kaynak zaten yerinde (ör. aynı kaynağı taşıyan çok rotalı rutinin başka bir rotası geri alındı): Çöp'te değil ve
            // eski yerindeki dosya bu kopyayla birebir aynıysa kopya korunmaz; değilse tek kopya o olabilir.
            if acceptable(file), !exists(file.trashed), exists(file.original), let target = file.target,
               let digest = DestinationIndex.digest(of: file.original), digest == DestinationIndex.digest(of: target) {
                continue
            }
            outcome.notRestored.append(file.original)
            if let target = file.target { outcome.keepTargets.insert(Self.key(target)) }
        }
        return outcome
    }

    /// Yolların karşılaştırma biçimi (rsync'in adları ile dosya sisteminin adları Unicode biçimiyle ayrışabilir).
    static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }

    /// Anlık görüntüsüz işin son çalıştırmasının eklediği öğeleri Çöp Sepeti'ne taşır: önce dosyalar, sonra boş kalan
    /// klasörler (en derinden). Yalnızca hedefin içindeki, çalıştırma sırasında oluşmuş ve ondan sonra değişmemiş öğeler.
    /// - Parameter keep: Dokunulmayacak öğeler (mutlak yollar; kaynağı geri konamayan kopyalar).
    public static func undoCreated(_ record: Record, destination: URL, startedAt: Date, finishedAt: Date, keep: Set<String> = [],
                                   trash: (URL) -> Bool) -> Outcome {
        var outcome = Outcome()
        let root = SandboxProfile.resolved(destination)
        let paths = record.created.compactMap { path -> (String, URL)? in
            let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
            // Boş bileşen (mutlak yol ya da "//"), "." ve ".." içeren yol kabul edilmez: rsync böyle ad yazmaz.
            let components = clean.split(separator: "/", omittingEmptySubsequences: false)
            guard !clean.isEmpty, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                outcome.kept.append(path)
                return nil
            }
            return (clean, root.appendingPathComponent(clean))
        }
        var folders: [(String, URL)] = []
        for (path, url) in paths {
            var info = stat()
            guard !keep.contains(Self.key(url.path)), lstat(url.path, &info) == 0 else {
                outcome.kept.append(path)
                continue
            }
            // Oluşma zamanı kanıt olamaz: rsync değişme zamanını kaynaktan alır, macOS da oluşma zamanını ondan eskiye
            // çekilince birlikte geri alır (2026-11-04 denemesi). Durum değişim zamanı (ctime) ise rsync'in yazdığı her
            // öğede çalıştırma sırasına düşer; çalıştırmadan önce var olup dokunulmamış öğede eskidir.
            let touched = Date(timeIntervalSince1970: TimeInterval(info.st_ctimespec.tv_sec))
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            // Çalıştırmadan önce vardı ya da sonra değişti: dokunulmaz. Klasör ancak boşsa taşınır.
            guard touched >= startedAt.addingTimeInterval(-tolerance), SandboxProfile.resolved(url).path.hasPrefix(root.path + "/") else {
                outcome.kept.append(path)
                continue
            }
            if info.st_mode & S_IFMT == S_IFDIR {
                folders.append((path, url))
                continue
            }
            guard modified <= finishedAt.addingTimeInterval(tolerance) else {
                outcome.kept.append(path)
                continue
            }
            if trash(url) { outcome.trashed += 1 } else { outcome.failed.append(path) }
        }
        for (path, url) in folders.sorted(by: { $0.0.split(separator: "/").count > $1.0.split(separator: "/").count }) {
            let contents = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0 != ".DS_Store" }
            guard contents.isEmpty else {
                outcome.kept.append(path)
                continue
            }
            if trash(url) { outcome.trashed += 1 } else { outcome.failed.append(path) }
        }
        return outcome
    }

    /// Anlık görüntülü işin son anlık görüntüsünü Çöp Sepeti'ne taşır ve "Latest"ı bir öncekine çevirir (önceki yoksa
    /// bağlantı kaldırılır). Yalnızca `name` en yeni tamamlanmış anlık görüntüyse.
    public static func undoSnapshot(_ name: String, root: URL, timeZone: TimeZone = .current, trash: (URL) -> Bool) -> Bool {
        let complete = SnapshotStore.completeSnapshots(in: root, timeZone: timeZone)
        guard complete.last == name else { return false }
        guard trash(root.appendingPathComponent(name, isDirectory: true)) else { return false }
        if let previous = complete.dropLast().last {
            SnapshotStore.updateLatestLink(in: root, to: previous)
        } else {
            let link = root.appendingPathComponent(SnapshotStore.latestLinkName)
            var info = stat()
            if lstat(link.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { unlink(link.path) }
        }
        return true
    }
}
