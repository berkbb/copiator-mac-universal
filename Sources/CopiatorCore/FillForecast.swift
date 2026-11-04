// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Hedef diskin ne zaman dolacağının tahmini. Kaynak, aynı diske yazan işlerin başarılı çalıştırmalarından sonra ölçülen
/// boş alandır (`JobRun.destinationFreeBytes`): ardışık ölçümler arasındaki günlük tüketim hızlarının alt ve üst çeyreği
/// bir aralık verir. Sonuç her zaman bir aralıktır, hiçbir zaman tek bir tarih değildir; diske başka şeyler yazılırsa ya da
/// alan açılırsa değişir.
public enum FillForecast {
    public struct Sample: Equatable, Sendable {
        public var date: Date
        public var freeBytes: Int64

        public init(date: Date, freeBytes: Int64) {
            self.date = date
            self.freeBytes = freeBytes
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Yeterli ölçüm yok (en az `minimumSamples` ölçüm ve bir günden uzun bir süre gerekir).
        case notEnoughData
        /// Boş alan azalmıyor.
        case notFilling
        /// Bu hızla en erken ve en geç kaç gün içinde dolacağı; `upperDays` nil ise üst sınır yok ("en az").
        case range(lowerDays: Int, upperDays: Int?)
    }

    public static let minimumSamples = 4
    /// Bu süreden eski ölçümler sayılmaz: tahmin son kullanımı yansıtsın.
    public static let window: TimeInterval = 180 * 86_400
    /// Bir saatten yakın ölçümler aynı oturum sayılır (son ölçüm kalır): kısa aralıklar hızı abartmasın.
    static let mergeInterval: TimeInterval = 3_600
    /// Tüketim hızları birbirine çok yakınsa aralık en az bu oran kadar genişletilir (doğrusal tahmin kesin değildir).
    static let minimumSpread = 0.2

    /// Uyarı eşiği: en erken dolma bu kadar gün içindeyse kullanıcı uyarılır.
    public static let warningDays = 30

    public static func estimate(_ samples: [Sample], now: Date) -> Outcome {
        let recent = samples.filter { $0.date <= now && now.timeIntervalSince($0.date) <= window }.sorted { $0.date < $1.date }
        var merged: [Sample] = []
        for sample in recent {
            if let last = merged.last, sample.date.timeIntervalSince(last.date) < mergeInterval {
                merged[merged.count - 1] = sample
            } else {
                merged.append(sample)
            }
        }
        guard merged.count >= minimumSamples, let first = merged.first, let latest = merged.last,
              latest.date.timeIntervalSince(first.date) >= 86_400 else { return .notEnoughData }
        let rates = zip(merged, merged.dropFirst()).map { older, newer in
            Double(older.freeBytes - newer.freeBytes) / (newer.date.timeIntervalSince(older.date) / 86_400)
        }.sorted()
        let fast = quantile(rates, 0.75)
        let slow = quantile(rates, 0.25)
        guard fast > 0 else { return .notFilling }
        let free = Double(max(latest.freeBytes, 0))
        var lower = free / fast
        var upper: Double? = slow > 0 ? free / slow : nil
        if let high = upper, high < lower * (1 + minimumSpread) {
            let middle = (lower + high) / 2
            lower = middle * (1 - minimumSpread)
            upper = middle * (1 + minimumSpread)
        }
        return .range(lowerDays: Int(lower.rounded(.down)), upperDays: upper.map { Int($0.rounded(.up)) })
    }

    /// Sıralı değerlerde doğrusal aradeğerli çeyrek.
    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = q * Double(sorted.count - 1)
        let low = Int(position.rounded(.down))
        let high = min(low + 1, sorted.count - 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }

    /// Aynı diske yazan işlerin ölçümleri (başarılı çalıştırmalar, boş alanı kayıtlı olanlar).
    public static func samples(for jobs: [TransferJob]) -> [Sample] {
        jobs.flatMap { job in
            job.history.compactMap { run in
                guard run.result.kind.isSuccess, let free = run.destinationFreeBytes else { return nil }
                return Sample(date: run.finishedAt, freeBytes: free)
            }
        }
    }
}
