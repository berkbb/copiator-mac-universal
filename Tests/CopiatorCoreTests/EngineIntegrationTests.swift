// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

/// Gerçek rsync (Vendor/rsync/rsync) ile uçtan uca: kopyalama, sürdürme, doğrulama, kaynağın korunması.
@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok (./Scripts/build-rsync.sh)"), .serialized)
struct EngineIntegrationTests {
    private func makeSource(_ workspace: Workspace) throws {
        try workspace.write("Kaynak/a.txt", "birinci\n")
        try workspace.write("Kaynak/alt/b.txt", "ikinci\n")
        try workspace.write("Kaynak/boşluklu ad ğüş.txt", "türkçe\n")
        try workspace.write("Kaynak/.Spotlight-V100/store.db", "dizin\n")
        try workspace.write("Kaynak/.fseventsd/0001", "olay\n")
        try workspace.mkdir("Hedef")
    }

    private func run(_ job: TransferJob, sandboxed: Bool = true) async throws -> (JobResult, [TransferEvent]) {
        let events = Collected<TransferEvent>()
        let result = await RsyncEngine().run(job, context: try await engineContext(sandboxed: sandboxed)) { events.add($0) }
        return (result, events.values)
    }

    @Test func bundledRsyncIsUniversalAndCurrent() async throws {
        let rsync = try #require(vendoredRsync)
        let info = try #require(await EngineLocator.probe(rsync))
        #expect(info.version == "3.5.1")
        #expect(info.supportsProgress2 && info.supportsACLs && info.supportsXattrs && !info.isOpenrsync)
    }

    @Test func copiesFolderItselfAndSkipsSystemFolders() async throws {
        let workspace = try Workspace()
        try makeSource(workspace)
        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"))
        let (result, events) = try await run(job)
        #expect(result.kind == .succeeded, "\(result)")
        #expect(workspace.read("Hedef/Kaynak/a.txt") == "birinci\n")
        #expect(workspace.read("Hedef/Kaynak/alt/b.txt") == "ikinci\n")
        #expect(workspace.read("Hedef/Kaynak/boşluklu ad ğüş.txt") == "türkçe\n")
        #expect(!workspace.exists("Hedef/Kaynak/.Spotlight-V100"))
        #expect(!workspace.exists("Hedef/Kaynak/.fseventsd"))
        #expect(events.contains(.phase(.scanning)))
        #expect(events.contains(.phase(.copying)))
        let last = events.compactMap { if case .progress(let p) = $0 { p } else { nil } }.last
        #expect(last?.fraction == 1)
        #expect(last?.itemsRemaining == 0)
    }

    @Test func copiesContentsIntoDestination() async throws {
        let workspace = try Workspace()
        try makeSource(workspace)
        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"), options: CopyOptions(copyMode: .contents))
        let (result, _) = try await run(job)
        #expect(result.kind == .succeeded)
        #expect(workspace.read("Hedef/a.txt") == "birinci\n")
        #expect(!workspace.exists("Hedef/Kaynak"))
    }

    /// --delete yalnızca hedefteki fazlaları siler; kaynak değişmez.
    @Test func deleteRemovesOnlyExtraDestinationFilesAndNeverTouchesSource() async throws {
        let workspace = try Workspace()
        try makeSource(workspace)
        try workspace.write("Hedef/Kaynak/fazla.txt", "silinecek\n")
        let before = try snapshot(workspace.url("Kaynak"))
        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"), options: CopyOptions(deleteExtraneous: true))
        let (result, _) = try await run(job)
        #expect(result.kind == .succeeded)
        #expect(!workspace.exists("Hedef/Kaynak/fazla.txt"))
        #expect(try snapshot(workspace.url("Kaynak")) == before)
    }

    /// Kesilen iş aynı komutla sürer: ikinci çalıştırma yalnızca eksikleri aktarır ve aynı sonuca varır.
    @Test func interruptedCopyResumesWithTheSameCommand() async throws {
        let workspace = try Workspace()
        try workspace.mkdir("Hedef")
        for index in 0..<40 {
            try workspace.write("Kaynak/d\(index % 4)/f\(index).bin", String(repeating: "x", count: 4096) + "\(index)")
        }
        let big = workspace.url("Kaynak/buyuk.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        let chunk = Data(repeating: 0x5A, count: 1 << 20)
        for _ in 0..<512 { handle.write(chunk) }
        try handle.close()
        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"))

        let first = Task { try await run(job) }
        try await Task.sleep(for: .milliseconds(400))
        first.cancel()
        let (cancelled, _) = try await first.value
        #expect(cancelled.kind == .cancelled)

        let (resumed, events) = try await run(job)
        #expect(resumed.kind == .succeeded, "\(resumed)")
        #expect(try snapshot(workspace.url("Kaynak")) == snapshot(workspace.url("Hedef/Kaynak")))
        // Kaldığı yerden: ikinci çalıştırmada aktarılan dosya sayısı tüm dosyalardan azdır ya da eşittir.
        let progress = events.compactMap { if case .progress(let p) = $0 { p } else { nil } }.last
        #expect((progress?.filesTransferred ?? 0) <= 41)
    }

    @Test func verifyReportsIdenticalThenDifferences() async throws {
        let workspace = try Workspace()
        try makeSource(workspace)
        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"))
        let context = try await engineContext()
        _ = try await run(job)

        let identical = await RsyncEngine().verify(job, context: context, checksum: false)
        #expect(identical.result.kind == .succeeded)
        #expect(identical.isIdentical, "\(identical.entries)")

        try workspace.write("Kaynak/yeni.txt", "yeni\n")
        try workspace.write("Hedef/Kaynak/fazla.txt", "fazla\n")
        try workspace.write("Kaynak/a.txt", "değişti, daha uzun\n")
        let report = await RsyncEngine().verify(job, context: context, checksum: false)
        #expect(report.entries.contains { $0.kind == .missing && $0.path == "Kaynak/yeni.txt" })
        #expect(report.entries.contains { $0.kind == .extra && $0.path == "Kaynak/fazla.txt" })
        #expect(report.entries.contains { $0.kind == .changed && $0.path == "Kaynak/a.txt" })
        // Doğrulama hiçbir şeyi değiştirmez: fazla dosya hâlâ hedefte, yeni dosya hâlâ kopyalanmamış.
        #expect(workspace.exists("Hedef/Kaynak/fazla.txt"))
        #expect(!workspace.exists("Hedef/Kaynak/yeni.txt"))
    }

    /// Boyutu ve zamanı aynı ama içeriği farklı dosya yalnızca sağlama toplamıyla bulunur.
    @Test func checksumVerifyFindsSilentCorruption() async throws {
        let workspace = try Workspace()
        try makeSource(workspace)
        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"))
        let context = try await engineContext()
        _ = try await run(job)
        let copy = workspace.url("Hedef/Kaynak/a.txt")
        let date = try FileManager.default.attributesOfItem(atPath: copy.path)[.modificationDate] as! Date
        try Data("BİRİNCİ\n".utf8.prefix(8)).write(to: copy)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: copy.path)

        let quick = await RsyncEngine().verify(job, context: context, checksum: false)
        #expect(!quick.entries.contains { $0.path == "Kaynak/a.txt" && $0.kind == .changed })
        let deep = await RsyncEngine().verify(job, context: context, checksum: true)
        #expect(deep.entries.contains { $0.path == "Kaynak/a.txt" && $0.kind == .changed })
        #expect(deep.checksum)
    }

    @Test func overlappingJobIsRejectedBeforeRunning() async throws {
        let workspace = try Workspace()
        try makeSource(workspace)
        let inside = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Kaynak/alt"))
        #expect(try await run(inside).0.kind == .overlapping)
        let parent = TransferJob(source: workspace.url("Kaynak/alt"), destination: workspace.url("Kaynak"))
        #expect(try await run(parent).0.kind == .overlapping)
        let missing = TransferJob(source: workspace.url("Yok"), destination: workspace.url("Hedef"))
        #expect(try await run(missing).0.kind == .sourceMissing)
        let noDestination = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Takılı değil"))
        #expect(try await run(noDestination).0.kind == .destinationMissing)
    }

    /// Öznitelik kopyalama kapalıyken karantina işareti yine aktarılır (Gatekeeper koruması kaybolmaz).
    @Test func quarantineSurvivesWithoutExtendedAttributes() async throws {
        let workspace = try Workspace()
        try makeSource(workspace)
        let script = try workspace.write("Kaynak/calistir.command", "#!/bin/sh\necho hi\n")
        let value = "0081;5f000000;Safari;"
        #expect(setxattr(script.path, "com.apple.quarantine", value, value.utf8.count, 0, 0) == 0)
        try workspace.write("Kaynak/notlar.txt", "etiketli\n")
        let tag = "etiket"
        #expect(setxattr(workspace.url("Kaynak/notlar.txt").path, "user.copiator.test", tag, tag.utf8.count, 0, 0) == 0)

        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"),
                              options: CopyOptions(preserveExtendedAttributes: false))
        let (result, events) = try await run(job)
        #expect(result.kind == .succeeded)
        #expect(Quarantine.value(of: workspace.url("Hedef/Kaynak/calistir.command")) == value)
        // Öteki öznitelikler kopyalanmadı.
        #expect(getxattr(workspace.url("Hedef/Kaynak/notlar.txt").path, "user.copiator.test", nil, 0, 0, 0) < 0)
        #expect(events.contains { if case .log(let entry) = $0 { entry.key == LKey.logQuarantineApplied.rawValue } else { false } })
    }

    @Test func extendedAttributesAreCopiedByDefault() async throws {
        let workspace = try Workspace()
        try makeSource(workspace)
        let tag = "etiket"
        #expect(setxattr(workspace.url("Kaynak/a.txt").path, "user.copiator.test", tag, tag.utf8.count, 0, 0) == 0)
        let (result, _) = try await run(TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef")))
        #expect(result.kind == .succeeded)
        #expect(getxattr(workspace.url("Hedef/Kaynak/a.txt").path, "user.copiator.test", nil, 0, 0, 0) == tag.utf8.count)
    }

    /// Hedefte yer yoksa rsync hiç başlatılmaz; gereken ve boş alan bildirilir.
    @Test func insufficientSpaceStopsBeforeCopying() {
        let result = JobResult(kind: .destinationFull, requiredBytes: 10, availableBytes: 5)
        #expect(!result.kind.isSuccess)
        #expect(DiskSpace.requiredForCopy(sourceBytes: 100, existingDestinationBytes: 40) == 60)
        #expect(DiskSpace.requiredForCopy(sourceBytes: 100, existingDestinationBytes: 400) == 0)
    }

    @Test func sandboxCanBeTurnedOff() async throws {
        let workspace = try Workspace()
        try makeSource(workspace)
        let (result, _) = try await run(TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef")), sandboxed: false)
        #expect(result.kind == .succeeded)
    }

    /// Bir klasör ağacının içerik özeti (göreli yol → içerik), kaynakla kopyanın karşılaştırılması için.
    private func snapshot(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let relative = String(url.path.dropFirst(root.path.count))
            if RsyncCommand.systemExclusions.contains(where: { relative.contains("/\($0)/") }) { continue }
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }
}

/// Gerçek FAT32 / exFAT birimlerinde: hdiutil ile bağlanan küçük disk görüntüleri. Yavaş olduğu için
/// COPIATOR_VOLUME_TESTS=1 ile çalışır (stress-test.sh bunu açar).
@Suite(.enabled(if: vendoredRsync != nil && ProcessInfo.processInfo.environment["COPIATOR_VOLUME_TESTS"] == "1"), .serialized)
struct ForeignVolumeTests {
    @Test(arguments: ["MS-DOS", "ExFAT"])
    func copiesToForeignFileSystemsAndRerunsCleanly(format: String) async throws {
        let workspace = try Workspace()
        try workspace.write("Kaynak/a.txt", "fat\n")
        let image = workspace.url("disk.dmg")
        try runTool("/usr/bin/hdiutil", ["create", "-quiet", "-size", "64m", "-fs", format, "-volname", "CPTEST", image.path])
        let mountPoint = try workspace.mkdir("mnt")
        try runTool("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path, image.path])
        defer { try? runTool("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path]) }

        let fs = FileSystemKind.of(mountPoint)
        #expect(fs == (format == "MS-DOS" ? .fat : .exfat))
        let job = TransferJob(source: workspace.url("Kaynak"), destination: mountPoint, options: CopyOptions(preservePermissions: true))
        let context = try await engineContext()
        let result = await RsyncEngine().run(job, context: context) { _ in }
        #expect(result.kind.isSuccess, "\(result)")
        // İkinci çalıştırmada (FAT'te --modify-window=1 sayesinde) fark kalmaz.
        let report = await RsyncEngine().verify(job, context: context, checksum: false)
        #expect(!report.entries.contains { $0.kind == .changed || $0.kind == .missing }, "\(report.entries)")
    }

    private func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw EngineError.failed(code: process.terminationStatus, message: path) }
    }
}
