// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

/// Bitince diski çıkarma: disk, üzerinde sırada bekleyen, çalışan ya da karar bekleyen bir iş ya da süren bir denetim varken
/// tutulur; biten, hata veren ve kullanıcının duraklattığı işler ve başka diskler tutmaz. Başlangıç diski ve dahili disk
/// çıkarılabilir sayılmaz; seçenek eski kayıtlarda kapalı gelir.
@Test func diskStaysWhileSomethingUsesIt() throws {
    let disk = URL(fileURLWithPath: "/Volumes/Yedek", isDirectory: true)
    let other = URL(fileURLWithPath: "/Volumes/Baska", isDirectory: true)
    func job(_ status: JobStatus, destination: URL = URL(fileURLWithPath: "/Volumes/Yedek/Arsiv"),
             source: URL = URL(fileURLWithPath: "/Users/x/Belgeler")) -> TransferJob {
        TransferJob(source: source, destination: destination, status: status)
    }
    #expect(!DiskEject.isBusy([disk], jobs: [job(.finished), job(.failed), job(.paused), job(.waiting, destination: other.appendingPathComponent("A"))]))
    for status in [JobStatus.waiting, .scanning, .copying, .verifying] {
        #expect(DiskEject.isBusy([disk], jobs: [job(.finished), job(status)]), "\(status)")
    }
    // Kaynağı bu diskte olan iş de diski tutar; aynı diskteki öteki birim de sayılır.
    #expect(DiskEject.isBusy([disk], jobs: [job(.waiting, destination: other, source: disk.appendingPathComponent("Fotograflar"))]))
    #expect(DiskEject.isBusy([other, disk], jobs: [job(.copying)]))
    var awaiting = job(.paused)
    awaiting.pendingConflicts = ConflictReport(items: [], total: 1)
    #expect(awaiting.isAwaitingDecision && DiskEject.isBusy([disk], jobs: [awaiting]))
    #expect(DiskEject.isBusy([disk], jobs: [], checking: ["/Volumes/Yedek/Arsiv"]))
    #expect(!DiskEject.isBusy([disk], jobs: [], checking: ["/Volumes/Baska/Arsiv", "/Volumes/YedekX/Arsiv"]))

    // Başlangıç diski ve dahili diskteki geçici klasör çıkarılmaz.
    #expect(!DiskEject.isEjectable(URL(fileURLWithPath: "/")))
    #expect(DiskEject.volume(of: FileManager.default.temporaryDirectory) == nil)
    #expect(DiskEject.volume(of: URL(fileURLWithPath: "/Users")) == nil)
    // Dahili sistem birimleri (VM, Preboot) kök dosya sistemi değildir ama çıkarılmaz.
    let systemVolumes = ["/System/Volumes/VM", "/System/Volumes/Preboot"].filter { FileManager.default.fileExists(atPath: $0) }
    #expect(!systemVolumes.isEmpty)
    for path in systemVolumes { #expect(!DiskEject.isEjectable(URL(fileURLWithPath: path, isDirectory: true)), "\(path)") }

    let old = try JSONDecoder().decode(CopyOptions.self, from: Data(#"{"runWhenConnected": true}"#.utf8))
    #expect(old.runWhenConnected && !old.ejectWhenDone)
    let saved = try JSONDecoder().decode(CopyOptions.self, from: JSONEncoder().encode(CopyOptions(ejectWhenDone: true)))
    #expect(saved.ejectWhenDone)
}

/// Gerçek bir disk görüntüsüyle: bağlı görüntü çıkarılabilir bir birimdir, aynı diskteki birimler arasında kendisi vardır
/// ve çıkarılınca bağlantısı kalkar. Yavaş olduğu için COPIATOR_VOLUME_TESTS=1 ile çalışır.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["COPIATOR_VOLUME_TESTS"] == "1"), .serialized)
struct LiveDiskEjectTests {
    @Test func ejectsAnAttachedDiskImage() async throws {
        let w = try Workspace()
        let image = w.url("yedek.dmg")
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "16m", "-fs", "APFS", "-volname", "CPEJECT", image.path])
        let mountPoint = try w.mkdir("mnt")
        try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path, image.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path]) }
        try Data("yedek".utf8).write(to: mountPoint.appendingPathComponent("a.txt"))

        let volume = try #require(DiskEject.volume(of: mountPoint.appendingPathComponent("a.txt")))
        #expect(volume.standardizedFileURL.path == mountPoint.standardizedFileURL.path)
        #expect(DiskEject.siblingVolumes(of: volume).contains { $0.standardizedFileURL.path == mountPoint.standardizedFileURL.path })
        // Bildirimde ve günlükte görünen ad diskin adıdır (bağlama noktasının klasör adı değil).
        #expect(FileManager.default.displayName(atPath: volume.path) == "CPEJECT")
        let error: String? = await withCheckedContinuation { continuation in
            DiskEject.eject(volume) { continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        #expect(!mounted.contains { $0.standardizedFileURL.path == mountPoint.standardizedFileURL.path })
    }

    private func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw EngineError.failed(code: process.terminationStatus, message: path) }
    }
}
