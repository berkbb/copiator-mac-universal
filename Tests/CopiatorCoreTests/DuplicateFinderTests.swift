// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

/// Yinelenen dosyalar: aynı içerikli dosyalar gruplanır (en sığ yol önce); aynı boyutlu farklı içerik, sabit bağlantı, boş
/// dosya, anlık görüntü klasörü ve gizli dosya sayılmaz. Fazlalar Çöp'e taşınır, seçilen dosya kalır; taramadan sonra
/// değişen dosyaya dokunulmaz.
@Test func duplicatesAreFoundAndOnlyVerifiedExtrasAreTrashed() throws {
    let w = try Workspace()
    for path in ["Arsiv/a/foto.jpg", "Arsiv/b/foto-kopya.jpg", "Arsiv/c/derin/foto2.jpg", "Arsiv/2026-10-22-101500/foto.jpg", "Arsiv/.gizli.jpg"] {
        try w.write(path, "aynı fotoğraf")
    }
    try w.write("Arsiv/notlar.txt", "not 1")
    try w.write("Arsiv/notlar2.txt", "not 2")
    try FileManager.default.linkItem(at: w.url("Arsiv/notlar.txt"), to: w.url("Arsiv/notlar-baglanti.txt"))
    try w.write("Arsiv/bos1.txt", "")
    try w.write("Arsiv/bos2.txt", "")
    let root = w.url("Arsiv")

    let groups = try DuplicateFinder.groups(in: root)
    #expect(groups.count == 1)
    let group = try #require(groups.first)
    #expect(group.paths == ["a/foto.jpg", "b/foto-kopya.jpg", "c/derin/foto2.jpg"])
    #expect(group.wasted == 2 * Int64("aynı fotoğraf".utf8.count))
    #expect(throws: CancellationError.self) { try DuplicateFinder.groups(in: root, isCancelled: { true }) }

    // Taramadan sonra değişen dosya (boyutu aynı, içeriği farklı) taşınmaz; seçilen dosya kalır.
    try w.write("Arsiv/c/derin/foto2.jpg", "aynı fotoğraF")
    let trash = try w.mkdir("Cop")
    let result = DuplicateFinder.trashExtras([(group: group, keep: "b/foto-kopya.jpg")], in: root) { url in
        (try? FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))) != nil
    }
    #expect(result.moved == 1 && result.skipped == ["c/derin/foto2.jpg"])
    #expect(!w.exists("Arsiv/a/foto.jpg") && w.read("Arsiv/b/foto-kopya.jpg") == "aynı fotoğraf" && w.exists("Arsiv/c/derin/foto2.jpg"))
    #expect(w.read("Cop/foto.jpg") == "aynı fotoğraf" && w.exists("Arsiv/2026-10-22-101500/foto.jpg"))
    #expect(try DuplicateFinder.groups(in: root).isEmpty)
}
