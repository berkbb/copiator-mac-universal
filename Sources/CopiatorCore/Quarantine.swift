// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// İnternetten inmiş dosyaların karantina işaretini (com.apple.quarantine) kopyalara aktarır.
///
/// rsync `-X` ile genişletilmiş öznitelikleri zaten taşır. Kullanıcı öznitelik kopyalamayı kapattıysa (ör. ._ dosyası
/// üretmesin diye exFAT bir diske) ya da `-X` desteklemeyen sistem rsync'i kullanılıyorsa işaret kaybolur ve kopyalanan
/// .app, .command ve betikler Gatekeeper denetimi olmadan açılır. Finder ve ditto bu işareti her zaman taşır;
/// Copiator da öznitelikler taşınmasa bile yalnızca bu işareti aktarır.
public enum Quarantine {
    static let attributeName = "com.apple.quarantine"

    /// Öğenin karantina değeri (yoksa nil). Sembolik bağlantıda bağlantının kendisininki okunur.
    public static func value(of url: URL) -> String? {
        if let value = read(url.path) { return value }
        // Okuma izni olmayan (0111, 0000) dosyalarda getxattr EACCES verir; izin kısa süre açılır.
        guard errno == EACCES || errno == EPERM else { return nil }
        return OwnerAccess.granting(S_IRUSR, on: url.path) { read(url.path) }
    }

    private static func read(_ path: String) -> String? {
        let size = getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, attributeName, &buffer, size, 0, XATTR_NOFOLLOW)
        guard read > 0 else { return nil }
        return String(decoding: buffer.prefix(read), as: UTF8.self)
    }

    /// Karantina değerini yazar. Sahibin yazma izni olmayan öğelerde (0555 .app ikilileri ve .command betikleri,
    /// 0444) setxattr EACCES verir; işaret yazılmazsa öğe Gatekeeper denetimi olmadan açılırdı. Bu yüzden izin kısa
    /// süre açılıp eski kip geri yüklenir.
    @discardableResult
    static func set(_ value: String, on url: URL) -> Bool {
        let bytes = Array(value.utf8)
        func write() -> Bool { setxattr(url.path, attributeName, bytes, bytes.count, 0, XATTR_NOFOLLOW) == 0 }
        if write() { return true }
        guard errno == EACCES || errno == EPERM else { return false }
        return OwnerAccess.granting(S_IWUSR, on: url.path, write)
    }

    /// Kaynak ağaçtaki karantinalı öğelerin işaretini, hedefteki karşılıklarına (ve yalnızca `since` anından sonra
    /// yazılmışlarsa) aktarır. Hedefte zaten aynı işaret varsa dokunulmaz.
    ///
    /// - Parameters:
    ///   - source: Kopyalanan öğe (dosya ya da klasör).
    ///   - target: Kaynağın hedefteki karşılığı ("klasörün kendisi" kipinde hedef/Ad, "içeriği" kipinde hedef).
    ///   - since: Kopyalamanın başladığı an; değişim zamanı (ctime) bundan yeni olanlar bu kopyada yazılmıştır.
    ///   - isCancelled: Büyük ağaçlarda yürüyüşü durdurmak için.
    /// - Returns: İşaretlenen öğe sayısı.
    @discardableResult
    public static func propagate(from source: URL, to target: URL, since start: Date, isCancelled: () -> Bool = { false }) -> Int {
        // Dosya sistemi zaman çözünürlüğü (FAT: 2 sn) için pay.
        let threshold = start.addingTimeInterval(-2)
        var count = 0

        func isFresh(_ path: String) -> Bool {
            var info = stat()
            guard lstat(path, &info) == 0 else { return false }
            let changed = Date(timeIntervalSince1970: TimeInterval(info.st_ctimespec.tv_sec) + TimeInterval(info.st_ctimespec.tv_nsec) / 1e9)
            return changed >= threshold
        }

        // Kaynakta sembolik bağlantıların gösterdiği klasörlere inilmez; rsync de bağlantıyı bağlantı olarak kopyalar.
        func visit(_ sourcePath: String, _ targetPath: String) {
            guard !isCancelled() else { return }
            if let value = value(of: URL(fileURLWithPath: sourcePath)), isFresh(targetPath),
               read(targetPath) != value, set(value, on: URL(fileURLWithPath: targetPath)) {
                count += 1
            }
            var info = stat()
            guard lstat(sourcePath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
            for name in (try? DiskSpace.entries(ofDirectory: sourcePath)) ?? [] {
                visit((sourcePath as NSString).appendingPathComponent(name), (targetPath as NSString).appendingPathComponent(name))
            }
        }
        visit(source.path, target.path)
        return count
    }
}
