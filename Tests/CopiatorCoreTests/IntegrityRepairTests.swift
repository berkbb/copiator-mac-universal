// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import Testing
@testable import CopiatorCore

/// Sessiz bozulma taklidi: aynı uzunlukta farklı içerik yazılır ve eski değiştirilme tarihi geri konur.
private func corrupt(_ url: URL, with text: String) throws {
    let date = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

private func inode(_ url: URL) -> UInt64 {
    var info = stat()
    return lstat(url.path, &info) == 0 ? UInt64(info.st_ino) : 0
}

/// Onarım: bozuk dosya, listedeki özetle birebir aynı ayrı bir kopyadan (eski anlık görüntü ya da kaynak) yerinde onarılır;
/// aynı dosyaya bağlı yollar birlikte düzelir ve bağlantı korunur; değiştirilme tarihi geri alınır; sonraki denetim sağlam
/// bulur. Sağlam kopyası olmayan, denetimden sonra değişen ve hedefin dışını gösteren yollara dokunulmaz; kaynak değişmez.
@Test func corruptedFilesAreRepairedFromIntactCopies() throws {
    let w = try Workspace()
    // Eski anlık görüntüde ayrı bir kopya; yenisinde iki anlık görüntü arasında aynı dosyaya bağlı bir kopya.
    try w.write("Arsiv/2026-10-20-090000/Belgeler/rapor.txt", "rapor içeriği")
    try w.write("Arsiv/2026-10-21-090000/Belgeler/rapor.txt", "rapor içeriği")
    try w.write("Arsiv/2026-10-21-090000/Belgeler/foto.jpg", "fotoğraf verisi")
    try FileManager.default.createDirectory(at: w.url("Arsiv/2026-10-22-090000/Belgeler"), withIntermediateDirectories: true)
    try FileManager.default.linkItem(at: w.url("Arsiv/2026-10-21-090000/Belgeler/foto.jpg"),
                                     to: w.url("Arsiv/2026-10-22-090000/Belgeler/foto.jpg"))
    try w.write("Arsiv/2026-10-22-090000/Belgeler/tek.txt", "tek kopya")
    try w.write("Arsiv/2026-10-22-090000/Belgeler/kilitli.txt", "salt okunur")
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: w.url("Arsiv/2026-10-22-090000/Belgeler/kilitli.txt").path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: w.url("Arsiv/2026-10-22-090000/Belgeler/kilitli.txt").path) }
    // Kaynakta fotoğrafın ve salt okunur dosyanın sağlam kopyası (başka adla).
    try w.write("Kaynak/Belgeler/foto-asil.jpg", "fotoğraf verisi")
    try w.write("Kaynak/kilitli-asil.txt", "salt okunur")
    // Aynı boyutta ama içeriği farklı bir dosya sağlam kopya sayılmaz.
    try w.write("Kaynak/tek-benzer.txt", "tek kopyZ")
    let root = w.url("Arsiv"), source = w.url("Kaynak")
    _ = try ArchiveIntegrity.check(root)
    let sourceDate = try FileManager.default.attributesOfItem(atPath: w.url("Kaynak/Belgeler/foto-asil.jpg").path)[.modificationDate] as? Date

    let rapor = w.url("Arsiv/2026-10-21-090000/Belgeler/rapor.txt")
    let foto = w.url("Arsiv/2026-10-21-090000/Belgeler/foto.jpg")
    let kilitli = w.url("Arsiv/2026-10-22-090000/Belgeler/kilitli.txt")
    try corrupt(rapor, with: "rapor içeriğX")
    try corrupt(foto, with: "fotoğraf verisX")
    try corrupt(w.url("Arsiv/2026-10-22-090000/Belgeler/tek.txt"), with: "tek kopyX")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: kilitli.path)
    try corrupt(kilitli, with: "salt okunuX")
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: kilitli.path)
    let report = try ArchiveIntegrity.check(root)
    #expect(report.corrupted == ["2026-10-21-090000/Belgeler/foto.jpg", "2026-10-21-090000/Belgeler/rapor.txt",
                                 "2026-10-22-090000/Belgeler/foto.jpg", "2026-10-22-090000/Belgeler/kilitli.txt",
                                 "2026-10-22-090000/Belgeler/tek.txt"])
    let fotoInode = inode(foto)
    let manifest = try #require(ArchiveIntegrity.manifest(in: root))

    let repair = try ArchiveIntegrity.repair(report.corrupted + ["../disari.txt", "2026-10-20-090000/yok.txt"], in: root, searching: [source])
    #expect(repair.repaired.keys.sorted() == ["2026-10-21-090000/Belgeler/foto.jpg", "2026-10-21-090000/Belgeler/rapor.txt",
                                              "2026-10-22-090000/Belgeler/foto.jpg", "2026-10-22-090000/Belgeler/kilitli.txt"])
    #expect(repair.repaired["2026-10-21-090000/Belgeler/rapor.txt"]?.lastPathComponent == "rapor.txt")
    #expect(repair.repaired["2026-10-21-090000/Belgeler/foto.jpg"]?.lastPathComponent == "foto-asil.jpg")
    #expect(repair.noCopy == ["2026-10-22-090000/Belgeler/tek.txt"])
    #expect(repair.changed == ["../disari.txt", "2026-10-20-090000/yok.txt"] && repair.failed.isEmpty)

    // İçerik, bağlantı, tarih ve izin; kaynak değişmedi; sonraki denetim yalnızca sağlam kopyası olmayanı bildirir.
    #expect(w.read("Arsiv/2026-10-21-090000/Belgeler/rapor.txt") == "rapor içeriği")
    #expect(w.read("Arsiv/2026-10-22-090000/Belgeler/foto.jpg") == "fotoğraf verisi" && inode(foto) == fotoInode)
    #expect(inode(w.url("Arsiv/2026-10-22-090000/Belgeler/foto.jpg")) == fotoInode)
    #expect(w.read("Arsiv/2026-10-22-090000/Belgeler/kilitli.txt") == "salt okunur")
    #expect((try FileManager.default.attributesOfItem(atPath: kilitli.path)[.posixPermissions] as? Int) == 0o444)
    var info = stat()
    #expect(lstat(rapor.path, &info) == 0)
    let expected = try #require(manifest.files["2026-10-21-090000/Belgeler/rapor.txt"]?.modified)
    #expect(abs(ArchiveIntegrity.modifiedTime(info) - expected) < 0.001)
    #expect(w.read("Kaynak/Belgeler/foto-asil.jpg") == "fotoğraf verisi")
    #expect(try FileManager.default.attributesOfItem(atPath: w.url("Kaynak/Belgeler/foto-asil.jpg").path)[.modificationDate] as? Date == sourceDate)
    let after = try ArchiveIntegrity.check(root)
    #expect(after.corrupted == ["2026-10-22-090000/Belgeler/tek.txt"] && after.updated == 0)

    // Denetimden sonra meşru olarak değişen dosyaya dokunulmaz.
    try w.write("Arsiv/2026-10-22-090000/Belgeler/tek.txt", "yeni ve daha uzun içerik")
    let late = try ArchiveIntegrity.repair(["2026-10-22-090000/Belgeler/tek.txt"], in: root, searching: [source])
    #expect(late.changed == ["2026-10-22-090000/Belgeler/tek.txt"] && late.repaired.isEmpty)
    #expect(w.read("Arsiv/2026-10-22-090000/Belgeler/tek.txt") == "yeni ve daha uzun içerik")
    #expect(throws: CancellationError.self) { try ArchiveIntegrity.repair(after.corrupted, in: root, searching: [source], isCancelled: { true }) }
}

/// Hedefin içinde mi: "." ve ".." bileşenleri, mutlak yollar ve dışarıyı gösteren bağlantılı üst klasörler reddedilir.
@Test func repairStaysInsideTheDestination() throws {
    let w = try Workspace()
    try w.write("Arsiv/alt/a.txt", "a")
    try w.write("Disari/b.txt", "b")
    try FileManager.default.createSymbolicLink(at: w.url("Arsiv/kacis"), withDestinationURL: w.url("Disari"))
    let root = w.url("Arsiv")
    let real = try #require(ArchiveIntegrity.realPath(root.path))
    #expect(ArchiveIntegrity.isInside("alt/a.txt", url: root.appendingPathComponent("alt/a.txt"), realRoot: real))
    for path in ["../Disari/b.txt", "alt/../alt/a.txt", "./alt/a.txt", "/alt/a.txt", "alt//a.txt", "kacis/b.txt", ""] {
        #expect(!ArchiveIntegrity.isInside(path, url: root.appendingPathComponent(path), realRoot: real), "\(path)")
    }
}

/// Sağlam kopya, hedefi bu klasör olan işlerin ve rutin rotalarının var olan kaynaklarında aranır (her biri bir kez); tek
/// dosyalık bir kaynak da aday olur.
@Test func repairSearchesTheSourcesOfThatDestination() throws {
    let w = try Workspace()
    let destination = try w.mkdir("Hedef"), other = try w.mkdir("Baska")
    let folder = try w.mkdir("Klasor"), file = try w.write("Tek/rapor.txt", "rapor içeriği"), routeSource = try w.mkdir("Rota")
    _ = try w.mkdir("Baska-kaynak")
    _ = try w.mkdir("Baska-rota")
    let jobs = [TransferJob(source: folder, destination: destination),
                TransferJob(source: folder, destination: URL(fileURLWithPath: destination.path + "/")),
                TransferJob(source: file, destination: destination),
                TransferJob(source: w.url("Baska-kaynak"), destination: other),
                TransferJob(source: w.url("Yok"), destination: destination)]
    let routines = [Routine(name: "Rutin", routes: [RoutineRoute(source: routeSource, destination: destination),
                                                     RoutineRoute(source: w.url("Baska-rota"), destination: other)])]
    let sources = ArchiveIntegrity.repairSources(for: destination, jobs: jobs, routines: routines)
    #expect(sources.map(\.lastPathComponent) == ["Klasor", "rapor.txt", "Rota"])

    let size = Int64("rapor içeriği".utf8.count)
    #expect(ArchiveIntegrity.candidateFiles(in: file, sizes: [size], isCancelled: { false }).map(\.0) == [file])
    #expect(ArchiveIntegrity.candidateFiles(in: file, sizes: [size + 1], isCancelled: { false }).isEmpty)
}

/// Değiştirilmiş bir liste hedefin dışını gösterse de (bağlantılı bir üst klasörle) onarım oraya yazmaz.
@Test func repairNeverWritesThroughALinkedFolder() throws {
    let w = try Workspace()
    try w.write("Arsiv/a.txt", "a")
    try w.write("Disari/b.txt", "b")
    try w.write("Kaynak/c.txt", "c")
    try FileManager.default.createSymbolicLink(at: w.url("Arsiv/kacis"), withDestinationURL: w.url("Disari"))
    let root = w.url("Arsiv")
    _ = try ArchiveIntegrity.check(root)
    var info = stat()
    #expect(lstat(w.url("Disari/b.txt").path, &info) == 0)
    // Listeye dışarıdaki dosya, "c" içeriğinin özetiyle eklenir: dosya bozukmuş gibi görünür ve kaynakta "c" vardır.
    var manifest = try #require(ArchiveIntegrity.manifest(in: root))
    let digest = try ArchiveIntegrity.hash(w.url("Kaynak/c.txt").path, isCancelled: { false })
    manifest.files["kacis/b.txt"] = ArchiveIntegrity.Entry(size: 1, modified: ArchiveIntegrity.modifiedTime(info), sha256: digest)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: root.appendingPathComponent(ArchiveIntegrity.manifestName))

    let report = try ArchiveIntegrity.repair(["kacis/b.txt"], in: root, searching: [w.url("Kaynak")])
    #expect(report.changed == ["kacis/b.txt"] && report.repaired.isEmpty)
    #expect(w.read("Disari/b.txt") == "b")
}
