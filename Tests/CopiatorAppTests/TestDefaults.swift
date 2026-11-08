// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Bir testin ayar alanı (`UserDefaults`): kullanıcının `~/Library/Preferences` klasörüne hiçbir şey yazmaz.
///
/// Düz bir adla `UserDefaults(suiteName:)` alanı `~/Library/Preferences/<ad>.plist` olarak saklar ve
/// `removePersistentDomain(forName:)` dosyayı silmez, boşaltır: her test 42 baytlık boş bir plist bırakıyordu; 2026-11-08'e
/// dek ~4 900 `CopiatorAppTests-<UUID>.plist` ve `CopiatorSettings-<UUID>.plist` birikmişti. Dosya alan kaldırıldıktan
/// sonra silinse de cfprefsd'nin zaman uyumsuz yazması onu yeniden yaratır (Descarcator'da ölçüldü, Darwin 27).
///
/// Burada alanın adı geçici bir klasörde mutlak bir yoldur: cfprefsd dosyayı `<yol>.plist` olarak o klasöre yazar,
/// `~/Library/Preferences`'a hiçbir şey yazılmaz. Ayarlar yine gerçek `UserDefaults` ve cfprefsd üzerinden okunup yazılır.
/// `remove()` alanı boşaltır, cfprefsd'nin yazmasını eşzamanlar ve klasörü siler. Testler alanlarını yalnızca bu türle açar
/// (`TestDefaultsTests.everyTestOpensItsSettingsThroughTestDefaults`), `package.sh` de yeni bir dosya kalırsa durur.
final class TestDefaults: @unchecked Sendable {
    /// `<önek>-<UUID>`: ayar dosyasının adı; testler aynı adı çalışma klasörleri için de kullanır.
    let name: String
    /// Alanın adı: `folder` içindeki mutlak yol (`<folder>/<name>`; dosya `<folder>/<name>.plist`).
    let suite: String
    /// Alanın klasörü (`CopiatorDefaults-<UUID>`, geçici klasörde); `remove()` siler.
    let folder: URL
    let defaults: UserDefaults

    /// Yeni, boş bir alan. - Parameter prefix: Dosya adının öneki (ör. `CopiatorSettings`); kalan bir dosyanın hangi
    /// testten geldiği adından okunur.
    convenience init(_ prefix: String) throws {
        let id = UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CopiatorDefaults-\(id)", isDirectory: true)
        try self.init(suite: folder.appendingPathComponent("\(prefix)-\(id)").path)
    }

    /// Daha önce açılmış bir alanı yeniden açar (uygulamanın yeniden açılışını sınayan testler; `suite` bu türün verdiği
    /// bir addır).
    convenience init(reopening suite: String) throws {
        try self.init(suite: suite)
    }

    private init(suite: String) throws {
        // Düz bir ad `~/Library/Preferences`'a yazardı: yalnızca mutlak yollar kabul edilir.
        guard suite.hasPrefix("/") else { throw CocoaError(.fileWriteInvalidFileName) }
        self.suite = suite
        let url = URL(fileURLWithPath: suite)
        name = url.lastPathComponent
        folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileWriteUnknown) }
        self.defaults = defaults
    }

    /// Alanı boşaltır, cfprefsd'nin yazmasını eşzamanlar (yoksa sonradan gelen yazma silinen klasörü yeniden açar) ve
    /// klasörü siler. Birden çok kez çağrılabilir.
    func remove() {
        defaults.removePersistentDomain(forName: suite)
        CFPreferencesAppSynchronize(suite as CFString)
        try? FileManager.default.removeItem(at: folder)
    }
}
