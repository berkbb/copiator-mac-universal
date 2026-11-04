// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Dolma tahmini uygulamada: başarılı çalıştırma hedef diskteki boş alanı kaydeder; günler içinde dolacak disk bir kez
/// bildirilir (haftada en çok bir kez); aralık her dilde gün, ay ya da yıl olarak ve her zaman iki uçla yazılır.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct FillForecastAppTests {
    @Test func runsRecordFreeSpaceAndWarnOnceWhenTheDiskFillsSoon() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let gb: Int64 = 1 << 30
        var day = 0
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        model.clock = { start.addingTimeInterval(Double(day) * 86_400) }
        model.freeSpace = { _ in (100 - Int64(day) * 10) * gb }
        let title = fixture.settings.t(.notifyFillTitle)
        func warnings() -> Int { fixture.notifications.filter { $0.0 == title }.count }
        await model.refreshEngine()
        #expect(model.addJob(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"),
                             options: CopyOptions(conflictPolicy: .replace)) == nil)
        let id = try #require(model.jobs.last?.id)
        await model.waitUntilIdle()
        for _ in 1...4 {
            day += 1
            model.resume([id])
            await model.waitUntilIdle()
        }
        let job = try #require(model.job(id))
        #expect(job.history.compactMap(\.destinationFreeBytes) == [100, 90, 80, 70, 60].map { $0 * gb })
        #expect(job.history.last?.finishedAt == start.addingTimeInterval(4 * 86_400))
        // Son boş alan 60 GB, günde 10 GB: 6 gün, ±%20.
        #expect(model.fillForecast(for: job, now: start.addingTimeInterval(4 * 86_400)) == .range(lowerDays: 4, upperDays: 8))
        #expect(warnings() == 1, "dördüncü çalıştırmada uyarıldı, beşincide hafta dolmadı")
        let body = try #require(fixture.notifications.first { $0.0 == title }?.1)
        #expect(body.contains(fixture.settings.fillRange(lower: 5, upper: 9)), "\(body)")
        // Bir hafta sonra yeniden uyarılır.
        day = 12
        model.freeSpace = { _ in 10 * gb }
        model.resume([id])
        await model.waitUntilIdle()
        #expect(warnings() == 2)
    }

    @Test func failedRunsRecordNoFreeSpace() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.freeSpace = { _ in 42 }
        await model.refreshEngine()
        try fixture.write("Okunmaz/a.txt", "a")
        let file = fixture.url("Okunmaz/a.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        #expect(model.addJob(source: fixture.url("Okunmaz"), destination: fixture.url("Hedef"), options: CopyOptions()) == nil)
        await model.waitUntilIdle()
        let job = try #require(model.jobs.last)
        #expect(job.result?.kind.isSuccess == false)
        #expect(job.history.last?.destinationFreeBytes == nil)
        #expect(model.fillForecast(for: job) == .notEnoughData)
    }

    @Test func rangesAreWrittenWithTwoEndsInEachLanguage() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings
        // Biçimlendirici bazı dillerde sayı ile birim arasına (dar) bölünmez boşluk koyar.
        func range(_ lower: Int, _ upper: Int?) -> String {
            settings.fillRange(lower: lower, upper: upper).replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        }
        settings.language = .en
        #expect(range(4, 8) == "4–8 days")
        #expect(range(100, 200) == "3–7 months")
        #expect(range(800, 1500) == "2–5 years")
        #expect(range(45, nil) == "at least 45 days")
        #expect(range(3, 3) == "3–4 days", "iki uç eşitse üst uç artar")
        settings.language = .tr
        #expect(range(4, 8) == "4–8 gün")
        #expect(range(100, 200) == "3–7 ay")
        #expect(range(45, nil) == "en az 45 gün")
        settings.language = .ro
        let ro = range(100, 200)
        #expect(ro.hasPrefix("3–7 ") && ro != "3–7 months")
    }
}
