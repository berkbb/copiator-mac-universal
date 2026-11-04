// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// macOS Tam Disk Erişimi (Full Disk Access, TCC): izin var mı ve bir iş için gerekli mi. Yoklama düzeni (korumalı
/// yerleri açmayı denemek) ve Sistem Ayarları bağlantısı Curatare'den uyarlandı (bkz. THIRD_PARTY_NOTICES.md).
public enum FullDiskAccess {
    /// Sistem Ayarları › Gizlilik ve Güvenlik › Tam Disk Erişimi.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Ev klasöründe yalnızca Tam Disk Erişimiyle açılabilen yerler. 2026-11-04'te izinsiz bir süreçten her biri
    /// "Operation not permitted" verdi (Calendars, Reminders ve iCloud Drive vermedi: listede değiller).
    public static let protectedLocations = [
        ".Trash", "Library/Mail", "Library/Messages", "Library/Safari", "Library/Cookies", "Library/Suggestions",
        "Library/HomeKit", "Library/Metadata/CoreSpotlight", "Library/IdentityServices", "Library/PersonalizationPortrait",
        "Library/Biome", "Library/Sharing", "Library/Trial", "Library/DoNotDisturb", "Library/Autosave Information",
        "Library/Containers", "Library/Application Support/com.apple.TCC", "Library/Application Support/AddressBook",
        "Library/Application Support/CallHistoryDB", "Library/Application Support/Knowledge",
        "Library/Application Support/FaceTime", "Library/Application Support/com.apple.sharedfilelist",
        "Pictures/Photos Library.photoslibrary",
    ]

    /// Yoklanan yerler: biri açılabiliyorsa izin vardır. Yalnızca açmayı dener, içeriği okumaz.
    static let probes = [
        "Library/Application Support/com.apple.TCC/TCC.db", "Library/Safari", "Library/Suggestions", "Library/Metadata/CoreSpotlight",
    ]

    /// true: izin var; false: yoklanan yerler var ama açılamıyor; nil: hiçbiri yok, karar verilemez. İzin yokken
    /// macOS TCC.db'yi "yok" (ENOENT) gösterir, öteki klasörler "Operation not permitted" (EPERM) verir.
    public static func isGranted(home: URL) -> Bool? {
        var denied = false
        for relative in probes {
            let descriptor = open(home.appendingPathComponent(relative).path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }
            if errno == EPERM || errno == EACCES { denied = true }
        }
        return denied ? false : nil
    }

    /// Yollardan biri Tam Disk Erişimi gerektiren bir yere değiyor mu? Korumalı bir yerin içindeyse (ya da kendisiyse)
    /// her zaman; korumalı yeri kapsıyorsa (ör. ev klasörünün tamamı) kum havuzunun zaten atladığı klasörler (`skipped`)
    /// dışında.
    public static func isNeeded(for paths: [URL], home: URL, skipped: [URL] = []) -> Bool {
        let skipped = skipped.map { SandboxProfile.resolved($0).path }
        let locations = protectedLocations.map { SandboxProfile.resolved(home.appendingPathComponent($0)).path }
        return paths.contains { path in
            let target = SandboxProfile.resolved(path).path
            return locations.contains { location in
                if target == location || target.hasPrefix(location + "/") { return true }
                guard location.hasPrefix(target == "/" ? "/" : target + "/") else { return false }
                return !skipped.contains { location == $0 || location.hasPrefix($0 + "/") }
            }
        }
    }

    /// rsync kaynağı okuyamadı mı ("[sender] … Operation not permitted (1)")? Kum havuzunun yasakladığı klasörler
    /// baştan dışlandığından kaynakta bu hata macOS'un korumasından gelir.
    public static func blockedRead(in detail: String) -> Bool {
        detail.split(whereSeparator: \.isNewline).contains { line in
            line.contains("[sender]") && RsyncOutcome.endsWithErrno(line, ["Operation not permitted (1)"])
        }
    }
}
