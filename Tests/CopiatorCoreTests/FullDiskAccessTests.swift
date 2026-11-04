// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// Tam Disk Erişimi yoklaması sahte bir ev klasöründe: yoklanan yer yoksa karar yok, açılamıyorsa izin yok, biri
/// açılabiliyorsa izin var. Gerçek ev klasörüne dokunulmaz.
@Test func probeReadsTheProtectedPlacesOfTheGivenHome() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("FDA-\(UUID().uuidString)", isDirectory: true)
    let safari = home.appendingPathComponent("Library/Safari")
    let suggestions = home.appendingPathComponent("Library/Suggestions")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safari.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: suggestions.path)
        try? FileManager.default.removeItem(at: home)
    }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    #expect(FullDiskAccess.isGranted(home: home) == nil)

    try FileManager.default.createDirectory(at: safari, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: safari.path)
    #expect(FullDiskAccess.isGranted(home: home) == false)

    // Bir yer açılamasa da ötekisi açılıyorsa izin vardır.
    try FileManager.default.createDirectory(at: suggestions, withIntermediateDirectories: true)
    #expect(FullDiskAccess.isGranted(home: home) == true)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: suggestions.path)
    #expect(FullDiskAccess.isGranted(home: home) == false)

    let database = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
    try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: database)
    #expect(FullDiskAccess.isGranted(home: home) == true)
}

/// Gereklilik: korumalı bir yerin içi ya da kendisi her zaman; onu kapsayan bir klasör (ev, kök) kum havuzunun atladığı
/// yerler dışında; adı yalnızca benzeyen klasör ve korumasız klasörler hiçbir zaman.
@Test func needDependsOnProtectedPlacesAndWhatTheSandboxSkips() {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    let personal = SandboxProfile.personalDataDirectories(home: home)
    func needed(_ path: String, skipped: [URL] = personal) -> Bool {
        FullDiskAccess.isNeeded(for: [URL(fileURLWithPath: path)], home: home, skipped: skipped)
    }
    #expect(needed("/Users/test/Library/Mail"))
    #expect(needed("/Users/test/Library/Mail/V10/Gelen"))
    #expect(needed("/Users/test/.Trash"))
    #expect(needed("/Users/test/Pictures/Photos Library.photoslibrary"))
    // Ev klasörünün tamamı: Mail ve Safari kum havuzunca atlanır, ama Çöp Sepeti ve Fotoğraflar atlanmaz.
    #expect(needed("/Users/test"))
    #expect(needed("/Users/test/Library"))
    #expect(needed("/"))
    // Her şeyi atlayan kum havuzunda kapsayan klasör izin istemez; korumalı yerin içi yine ister.
    #expect(!needed("/Users/test", skipped: [home]))
    #expect(needed("/Users/test/Library/Mail/V10", skipped: [home]))
    // Library atlanınca onu kapsayan ev klasörü yine izin ister: Çöp Sepeti ve Fotoğraflar Library dışında.
    let library = home.appendingPathComponent("Library")
    #expect(!needed("/Users/test/Library", skipped: [library]))
    #expect(needed("/Users/test", skipped: [library]))
    #expect(!needed("/Users/test/Library/MailArchive"))
    #expect(!needed("/Users/test/Documents"))
    // Resimler klasörünün tamamı Fotoğraflar arşivini kapsar; içindeki başka bir klasör kapsamaz.
    #expect(needed("/Users/test/Pictures"))
    #expect(!needed("/Users/test/Pictures/Tatil"))
    #expect(!needed("/Volumes/Yedek/Arsiv"))
    #expect(!FullDiskAccess.isNeeded(for: [], home: home))
    #expect(FullDiskAccess.isNeeded(for: [URL(fileURLWithPath: "/Users/test/Documents"), URL(fileURLWithPath: "/Users/test/.Trash/a")], home: home))
}

/// Yollar sembolik bağlantılar çözülerek karşılaştırılır (/var → /private/var).
@Test func needComparesResolvedPaths() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("FDA-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let mail = home.appendingPathComponent("Library/Mail")
    try FileManager.default.createDirectory(at: mail, withIntermediateDirectories: true)
    let resolvedHome = SandboxProfile.resolved(home)
    #expect(resolvedHome.path != home.path, "geçici klasör sembolik bağlantı üzerinden gelir")
    #expect(FullDiskAccess.isNeeded(for: [mail], home: resolvedHome))
    #expect(FullDiskAccess.isNeeded(for: [resolvedHome.appendingPathComponent("Library/Mail/a")], home: home))
}

/// Kaynak okunamadı (gönderen tarafta "Operation not permitted") ise izin gerekir; hedefe yazılamaması ya da sıradan
/// "Permission denied" değil.
@Test func blockedReadIsASenderSideOperationNotPermitted() {
    #expect(FullDiskAccess.blockedRead(in: "rsync: [sender] opendir \"/Users/test/Library/Suggestions\" failed: Operation not permitted (1)"))
    #expect(FullDiskAccess.blockedRead(in: """
        rsync: [receiver] mkstemp "/Volumes/Yedek/a" failed: Permission denied (13)
        rsync: [sender] send_files failed to open "/Users/test/.Trash/b": Operation not permitted (1)
        """))
    #expect(!FullDiskAccess.blockedRead(in: "rsync: [receiver] mkstemp \"/Volumes/Yedek/a\" failed: Operation not permitted (1)"))
    #expect(!FullDiskAccess.blockedRead(in: "rsync: [sender] send_files failed to open \"/Users/test/a\": Permission denied (13)"))
    #expect(!FullDiskAccess.blockedRead(in: "rsync: [sender] opendir \"/Users/test/Operation not permitted (1)\" failed: No such file or directory (2)"))
    #expect(!FullDiskAccess.blockedRead(in: ""))
}
