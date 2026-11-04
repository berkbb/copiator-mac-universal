// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// Son çalıştırmayı geri alma (güvenli kısım; 2026-11-04 kullanıcı kararı). Anlık görüntülü işte son anlık görüntü
/// Çöp Sepeti'ne taşınır ve "Latest" bir öncekine döner. Anlık görüntüsüz işte yalnızca son çalıştırmanın eklediği
/// öğeler Çöp Sepeti'ne taşınır: üzerine yazılan ya da silinen dosyalar geri gelmez (sayıları söylenir). Hiçbir şey
/// kalıcı olarak silinmez; çalıştırmadan önce var olan ya da sonradan değiştirilen öğelere dokunulmaz.
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

        public init(created: [String], truncated: Bool, otherChanges: Int) {
            self.created = created
            self.truncated = truncated
            self.otherChanges = otherChanges
        }
    }

    public struct Outcome: Equatable, Sendable {
        public var trashed = 0
        /// Dokunulmayan öğeler (artık yok, çalıştırmadan önce vardı, sonradan değişti ya da içinde başka şey var).
        public var kept: [String] = []
        public var failed: [String] = []
    }

    /// Anlık görüntüsüz işin son çalıştırmasının eklediği öğeleri Çöp Sepeti'ne taşır: önce dosyalar, sonra boş kalan
    /// klasörler (en derinden). Yalnızca hedefin içindeki, çalıştırma sırasında oluşmuş ve ondan sonra değişmemiş öğeler.
    public static func undoCreated(_ record: Record, destination: URL, startedAt: Date, finishedAt: Date,
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
            guard lstat(url.path, &info) == 0 else {
                outcome.kept.append(path)
                continue
            }
            let born = Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec))
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            // Çalıştırmadan önce vardı ya da sonra değişti: dokunulmaz. Klasörün zamanı içine dosya eklenince değişir;
            // klasör ancak boşsa taşınır.
            guard born >= startedAt.addingTimeInterval(-tolerance), SandboxProfile.resolved(url).path.hasPrefix(root.path + "/") else {
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
