// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Arşiv sağlığı uygulama akışları: anlık görüntüden geri yükleme kuyruğa iş ekler; bütünlük denetimi arka planda biter ve
/// bildirilir; yinelenenler seçilen dosya kalacak şekilde Çöp'e taşınır; rutinler dışa ve içe aktarılır. Sayfalar çizilir.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct ArchiveHealthAppTests {
    private func render(_ view: AnyView, _ size: NSSize, _ name: String) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.layoutIfNeeded()
        window.displayIfNeeded()
        spinRunLoop(0.3)
        if let directory = ProcessInfo.processInfo.environment["COPIATOR_SNAPSHOT_DIR"].map({ URL(fileURLWithPath: $0) }),
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
        window.close()
    }

    @Test func restoreIntegrityDuplicatesAndRoutineTransfer() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let settings = fixture.settings
        settings.language = .tr
        await model.refreshEngine()

        // Anlık görüntülü iş, bir çalıştırma; sonra kaynaktaki dosya silinir ve geri yüklenir.
        #expect(fixture.addJob(options: CopyOptions(snapshots: SnapshotOptions(enabled: true))) != nil)
        let jobID = try #require(model.jobs.last?.id)
        await model.waitUntilIdle()
        let job = try #require(model.job(jobID))
        #expect(job.status == .finished, "\(job.log.suffix(4))")
        let snapshot = try #require(SnapshotRestore.snapshots(of: job).first)
        render(AnyView(SnapshotBrowserSheet(request: SnapshotBrowserRequest(jobID: jobID)).environment(model).environment(settings)),
               NSSize(width: 820, height: 560), "snapshots")
        try FileManager.default.removeItem(at: fixture.url("Kaynak/not.txt"))
        #expect(model.restore("not.txt", from: snapshot, of: jobID) == nil)
        let restoreJob = try #require(model.jobs.last)
        #expect(restoreJob.id != jobID && restoreJob.log.contains { $0.key == LKey.logRestoreFrom.rawValue })
        await model.waitUntilIdle()
        #expect(fixture.read("Kaynak/not.txt") == "merhaba\n")

        // Bütünlük denetimi arka planda biter, sonuç saklanır, bildirilir.
        let destination = fixture.url("Hedef")
        model.startIntegrityCheck(destination)
        for _ in 0..<200 where model.integrityRuns[destination.path] != nil { try await Task.sleep(for: .milliseconds(50)) }
        guard case .report(let report)? = model.integrityResults[destination.path] else {
            Issue.record("bütünlük sonucu yok")
            return
        }
        #expect(report.isFirstCheck && report.added > 0 && !report.hasProblems)
        #expect(fixture.notifications.last?.0 == "Bütünlük denetimi bitti")
        render(AnyView(IntegritySheet(request: IntegrityRequest(destination: destination)).environment(model).environment(settings)),
               NSSize(width: 620, height: 560), "integrity")

        // Yinelenenler: seçilen dosya kalır, fazlası Çöp'e (test klasörüne) gider.
        try fixture.write("Hedef/Arsiv/a.txt", "aynı")
        try fixture.write("Hedef/Arsiv/b.txt", "aynı")
        let trash = fixture.url("Cop")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        model.trashItem = { url in (try? FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))) != nil }
        let groups = try DuplicateFinder.groups(in: destination)
        #expect(groups.map(\.paths) == [["Arsiv/a.txt", "Arsiv/b.txt"]])
        render(AnyView(DuplicatesSheet(request: DuplicatesRequest(destination: destination), groups: groups).environment(model).environment(settings)),
               NSSize(width: 680, height: 580), "duplicates")
        let result = model.trashDuplicates([(group: groups[0], keep: "Arsiv/b.txt")], in: destination)
        #expect(result.moved == 1 && fixture.read("Hedef/Arsiv/b.txt") == "aynı" && fixture.read("Cop/a.txt") == "aynı")

        // Rutinler dışa aktarılır ve içe aktarılır (yeni kimlikle, sıra numaralı adla); bozuk dosya uyarı verir.
        let routine = Routine(name: "Belgeler", routes: [RoutineRoute(source: fixture.url("Kaynak"), destination: destination)])
        #expect(model.saveRoutine(routine) == nil)
        let file = fixture.url("rutinler.json")
        model.exportRoutines(to: file)
        model.beginRoutineImport(from: file)
        let request = try #require(model.routineImport)
        #expect(request.routines.map(\.name) == ["Belgeler (2)"])
        render(AnyView(RoutineImportSheet(request: request).environment(model).environment(settings)), NSSize(width: 640, height: 520), "import")
        #expect(model.importRoutines(request.routines).isEmpty)
        #expect(model.routines.map(\.name) == ["Belgeler", "Belgeler (2)"] && Set(model.routines.map(\.id)).count == 2)
        try Data("bozuk".utf8).write(to: file)
        model.routineImport = nil
        model.beginRoutineImport(from: file)
        #expect(model.routineImport == nil && model.alert?.message == settings.t(.importInvalid))
    }
}
