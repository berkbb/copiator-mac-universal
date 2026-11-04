// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// Dolma tahmini: yeterli ölçüm yoksa tahmin yok; boş alan azalmıyorsa dolma yok; azalıyorsa günlük tüketimin alt ve
/// üst çeyreğinden bir aralık (hızlar aynıysa ±%20 genişletilir; yavaş çeyrek tüketmiyorsa üst sınır yok). Bir saatten
/// yakın ölçümler birleşir, 180 günden eskiler sayılmaz. Sonuç hiçbir zaman tek bir tarih değildir.
struct FillForecastTests {
    private let gb: Int64 = 1 << 30
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func samples(_ free: [Int64], every days: Double = 1) -> [FillForecast.Sample] {
        free.enumerated().map { FillForecast.Sample(date: start.addingTimeInterval(Double($0.offset) * days * 86_400), freeBytes: $0.element) }
    }
    private var end: Date { start.addingTimeInterval(30 * 86_400) }

    @Test func needsEnoughSamplesOverMoreThanADay() {
        #expect(FillForecast.estimate([], now: end) == .notEnoughData)
        #expect(FillForecast.estimate(samples([100, 90, 80].map { $0 * gb }), now: end) == .notEnoughData)
        #expect(FillForecast.estimate(samples([100, 90, 80, 70].map { $0 * gb }, every: 0.1), now: end) == .notEnoughData, "toplam süre bir günden kısa")
        // Bir saatten yakın ölçümler tek ölçümdür: dört ölçüm üçe iner.
        var close = samples([100, 90, 80].map { $0 * gb })
        close.append(FillForecast.Sample(date: close[2].date.addingTimeInterval(600), freeBytes: 79 * gb))
        #expect(FillForecast.estimate(close, now: end) == .notEnoughData)
    }

    @Test func steadyConsumptionGivesAWidenedRange() {
        // Günde 10 GB; son ölçümde 960 GB boş → 96 gün; aralık ±%20.
        let outcome = FillForecast.estimate(samples([1000, 990, 980, 970, 960].map { $0 * gb }), now: end)
        #expect(outcome == .range(lowerDays: 76, upperDays: 116))
    }

    @Test func varyingConsumptionUsesTheQuartiles() {
        // Tüketim: 5, 10, 15, 20 GB/gün → çeyrekler 8,75 ve 16,25; son boş alan 950 GB.
        let outcome = FillForecast.estimate(samples([1000, 995, 985, 970, 950].map { $0 * gb }), now: end)
        #expect(outcome == .range(lowerDays: Int((950 / 16.25).rounded(.down)), upperDays: Int((950 / 8.75).rounded(.up))))
        // Yavaş çeyrek tüketmiyorsa (alan açılan günler) üst sınır yoktur.
        let open = FillForecast.estimate(samples([1000, 1005, 1005, 995, 975].map { $0 * gb }), now: end)
        #expect(open == .range(lowerDays: Int((975 / 12.5).rounded(.down)), upperDays: nil))
    }

    @Test func stableOrGrowingSpaceIsNotFilling() {
        #expect(FillForecast.estimate(samples([500, 500, 500, 500].map { $0 * gb }), now: end) == .notFilling)
        #expect(FillForecast.estimate(samples([500, 510, 520, 530].map { $0 * gb }), now: end) == .notFilling)
    }

    @Test func oldAndFutureSamplesAreIgnored() {
        let old = samples([1000, 900, 800, 700].map { $0 * gb })
        #expect(FillForecast.estimate(old, now: start.addingTimeInterval(200 * 86_400)) == .notEnoughData)
        #expect(FillForecast.estimate(old, now: start.addingTimeInterval(86_400)) == .notEnoughData, "gelecekteki ölçümler sayılmaz")
    }

    @Test func samplesComeFromSuccessfulRunsWithFreeSpace() throws {
        var job = TransferJob(source: URL(fileURLWithPath: "/tmp/a"), destination: URL(fileURLWithPath: "/tmp/b"))
        job.appendRun(JobRun(startedAt: start, finishedAt: start, result: JobResult(kind: .succeeded), destinationFreeBytes: 5))
        job.appendRun(JobRun(startedAt: start, finishedAt: start, result: JobResult(kind: .failed), destinationFreeBytes: 6))
        job.appendRun(JobRun(startedAt: start, finishedAt: start, result: JobResult(kind: .succeeded)))
        #expect(FillForecast.samples(for: [job]) == [FillForecast.Sample(date: start, freeBytes: 5)])
        // Eski kayıtlarda alan yoktur; yenisi saklanıp okunur.
        let old = try JSONDecoder().decode(JobRun.self, from: Data(#"{"startedAt":0,"finishedAt":0,"result":{"kind":"succeeded","noteCount":0,"detail":""}}"#.utf8))
        #expect(old.destinationFreeBytes == nil)
        let saved = try JSONDecoder().decode(JobRun.self, from: JSONEncoder().encode(job.history[0]))
        #expect(saved.destinationFreeBytes == 5)
    }
}
