// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Çalıştırma raporu uygulamada: son çalıştırmadan sonra kaydedilebilir, seçilen dile çevrilmiş başlıkları ve eklenen
/// dosyaları içerir; hiç çalışmamış işte sunulmaz.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct RunReportAppTests {
    @Test func savedReportListsTheRun() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.settings.queueHeld = true
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        #expect(!model.canSaveRunReport(try #require(model.job(id))), "hiç çalışmadı")
        model.settings.queueHeld = false
        model.scheduleNext()
        await model.waitUntilIdle()
        let job = try #require(model.job(id))
        #expect(model.canSaveRunReport(job))
        let file = fixture.url("rapor.txt")
        #expect(model.saveRunReport(id, to: file))
        let text = try #require(fixture.read("rapor.txt"))
        let settings = fixture.settings
        #expect(text.hasPrefix(settings.t(.reportTitle, "Kaynak") + "\n"))
        #expect(text.contains(settings.t(.reportAdded, "2")) && text.contains("  Kaynak/not.txt\n") && text.contains("  Kaynak/alt/b.txt\n"))
        #expect(text.contains(settings.t(.reportResult, settings.result(job.result ?? JobResult(kind: .failed)))))
    }
}
