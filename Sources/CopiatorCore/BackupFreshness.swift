// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Yedek tazeliği: bir işin ya da rutinin son başarılı yedeğinden bu yana geçen gün. Yalnızca hatırlatır; hiçbir şeyi
/// kendiliğinden çalıştırmaz (zamanlanmış işler kullanıcı tarafından reddedildi).
public enum BackupFreshness {
    /// Eski bir yedek: iş ya da rutin, adı ve son başarılı yedekten bu yana geçen gün (hiç başarılı yedek yoksa nil).
    public struct Stale: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var days: Int?

        public init(id: UUID, name: String, days: Int?) {
            self.id = id
            self.name = name
            self.days = days
        }
    }

    /// Hatırlatma eşikleri (gün); 0 kapalı.
    public static let choices = [0, 7, 14, 30, 60, 90]

    /// İşlerin en yeni başarılı çalıştırması (geçmişten; geçmişi olmayan bitmiş işte bitiş anı).
    public static func lastSuccess(_ jobs: [TransferJob]) -> Date? {
        jobs.compactMap { job -> Date? in
            job.history.last(where: { $0.result.kind.isSuccess })?.finishedAt ?? (job.status == .finished ? job.finishedAt : nil)
        }.max()
    }

    /// Hedefi `onDestination`a uyan ve `thresholdDays` günden uzun süredir başarılı yedeği olmayan işler (rutine ait
    /// olmayanlar) ve rutinler. Hiç yedeği olmayanlar, kuruluşlarının üzerinden eşik kadar zaman geçtiyse sayılır. "Disk
    /// takılınca başla" seçili olanlar (zaten çalışacaklar) ve şu an bekleyen ya da çalışan işler atlanır.
    public static func stale(
        jobs: [TransferJob], routines: [Routine], onDestination: (URL) -> Bool, now: Date = Date(), thresholdDays: Int,
        calendar: Calendar = .current
    ) -> [Stale] {
        guard thresholdDays > 0 else { return [] }
        func days(since date: Date) -> Int { calendar.dateComponents([.day], from: date, to: now).day ?? 0 }
        func check(id: UUID, name: String, jobs: [TransferJob], created: Date) -> Stale? {
            guard !jobs.contains(where: { $0.status.isActive || $0.status == .waiting }) else { return nil }
            if let last = lastSuccess(jobs) {
                let passed = days(since: last)
                return passed >= thresholdDays ? Stale(id: id, name: name, days: passed) : nil
            }
            return days(since: created) >= thresholdDays ? Stale(id: id, name: name, days: nil) : nil
        }
        var result: [Stale] = []
        for job in jobs where job.routineID == nil && !job.options.runWhenConnected && onDestination(job.destination) {
            if let item = check(id: job.id, name: job.source.lastPathComponent, jobs: [job], created: job.createdAt) { result.append(item) }
        }
        for routine in routines where !routine.options.runWhenConnected && routine.routes.contains(where: { $0.destination.map(onDestination) ?? false }) {
            let own = jobs.filter { $0.routineID == routine.id && $0.routeID != nil }
            if let item = check(id: routine.id, name: routine.name, jobs: own, created: routine.createdAt) { result.append(item) }
        }
        return result.sorted { ($0.days ?? .max) > ($1.days ?? .max) || (($0.days ?? .max) == ($1.days ?? .max) && $0.name < $1.name) }
    }
}
