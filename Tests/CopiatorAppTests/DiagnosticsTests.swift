// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Tanılama raporu: sürümler, izinler, ayarlar, işler, rsync komutu ve günlük yer alır; ev klasörü, kullanıcı adı ve
/// klasör adları (rsync'in hata ayrıntısındaki boşluklu yol dahil) görünmez. Rapor yalnızca önizlenir.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct DiagnosticsTests {
    @Test func reportListsJobsAndMasksPersonalNames() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.homeDirectory = fixture.workspace
        await model.refreshEngine()
        try FileManager.default.createDirectory(at: fixture.url("Gizli Hedef"), withIntermediateDirectories: true)
        try fixture.write("Kayıp Fotoğraflar/özel not.jpg", "a")
        // Okunamayan dosya: rsync'in hata ayrıntısı boşluklu yolu içerir.
        let unreadable = fixture.url("Kayıp Fotoğraflar/özel not.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        #expect(model.addJob(source: fixture.url("Kayıp Fotoğraflar"), destination: fixture.url("Gizli Hedef"), options: CopyOptions()) == nil)
        await model.waitUntilIdle()
        let job = try #require(model.jobs.last)
        #expect(job.result?.detail.contains("Kayıp Fotoğraflar/özel not.jpg") == true, "rsync ayrıntısı yolu içerir")
        model.notificationPermission = .denied
        model.fullDiskAccessGranted = false

        let masker = DiagnosticMasker(home: fixture.workspace.path, userNames: ["kullanici"], salt: Data([7]))
        let report = model.diagnosticReport(masker: masker)
        for expected in ["Copiator diagnostic report", "rsync: 3.5.1", "Permissions: notifications=denied · full disk access=off",
                         "sandbox=on", "Jobs: 1", "[1] ~/‹name-", "command: rsync ", "log (last", "detail:"] {
            #expect(report.contains(expected), "\(expected)")
        }
        for hidden in ["Kayıp", "Fotoğraflar", "Gizli", "özel", fixture.workspace.path, fixture.workspace.lastPathComponent] {
            #expect(!report.contains(hidden), "\(hidden)")
        }
        model.showDiagnostics()
        #expect(model.diagnostics?.text.hasPrefix("Copiator diagnostic report") == true)
    }

    /// Çok sayıda işte rapor son işlerle ve her işin son günlük satırlarıyla sınırlıdır.
    @Test func reportIsLimited() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.toggleQueueHold()
        await model.refreshEngine()
        for index in 0..<(AppModel.diagnosticJobLimit + 3) {
            let destination = fixture.url("Hedef/\(index)")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            #expect(model.addJob(source: fixture.url("Kaynak"), destination: destination, options: CopyOptions()) == nil)
        }
        let report = model.diagnosticReport(masker: DiagnosticMasker(home: fixture.workspace.path, userNames: []))
        #expect(report.contains("Jobs: \(AppModel.diagnosticJobLimit + 3) (showing the last \(AppModel.diagnosticJobLimit))"))
        #expect(report.contains("[\(AppModel.diagnosticJobLimit)] ") && !report.contains("[\(AppModel.diagnosticJobLimit + 1)] "))
    }
}
