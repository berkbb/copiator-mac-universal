// SPDX-License-Identifier: GPL-3.0-only
import CopiatorCore
import Foundation
import SwiftUI

extension AppModel {
    /// Bir klasörün diskini tanıtan anahtar: takılı diskin bağlama noktası; disk takılı değilse "/Volumes/Ad".
    nonisolated static func volumeKey(of url: URL) -> String? {
        if let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume { return volume.standardizedFileURL.path }
        let parts = url.standardizedFileURL.pathComponents
        return parts.count >= 3 && parts[1] == "Volumes" ? "/Volumes/" + parts[2] : nil
    }

    /// İşin hedef diskinin dolma tahmini: aynı diske yazan bütün işlerin ölçümleriyle.
    func fillForecast(for job: TransferJob, now: Date = Date()) -> FillForecast.Outcome {
        guard let key = Self.volumeKey(of: job.destination) else { return .notEnoughData }
        let sameDisk = jobs.filter { Self.volumeKey(of: $0.destination) == key }
        return FillForecast.estimate(FillForecast.samples(for: sameDisk), now: now)
    }

    /// Başarılı bir çalıştırmadan sonra: disk bu hızla `FillForecast.warningDays` gün içinde dolabilecekse bildirilir; aynı
    /// disk için haftada en çok bir kez.
    func warnIfFillingSoon(_ job: TransferJob, now: Date = Date()) {
        guard case .range(let lower, let upper) = fillForecast(for: job, now: now), lower <= FillForecast.warningDays,
              let key = Self.volumeKey(of: job.destination) else { return }
        if let last = settings.fillWarnedAt[key], now.timeIntervalSince(last) < 7 * 86_400 { return }
        settings.fillWarnedAt[key] = now
        let disk = URL(fileURLWithPath: key).lastPathComponent
        notifier(settings.t(.notifyFillTitle), settings.t(.notifyFillBody, disk, settings.fillRange(lower: lower, upper: upper)), nil)
    }
}

/// Ayrıntılar panelinde hedef doluluğu: boş alan, dolma tahmini (aralık), yakında dolacaksa uyarı ve saklama kuralı
/// olmayan anlık görüntü işine kural önerisi. Tahmin çalıştırma geçmişi değişince yeniden hesaplanır.
struct FillForecastView: View {
    let job: TransferJob
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var outcome: FillForecast.Outcome?
    @State private var free: Int64?
    @State private var encrypted: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(settings.t(.fillForecastTitle)).font(.headline)
            if let free {
                Text(settings.t(.fillForecastFree, settings.bytes(free))).font(.callout)
            }
            if encrypted == false { UnencryptedDiskNote() }
            switch outcome {
            case .range(let lower, let upper)?:
                let soon = lower <= FillForecast.warningDays
                Label(settings.t(.fillForecastRange, settings.fillRange(lower: lower, upper: upper)),
                      systemImage: soon ? "exclamationmark.triangle.fill" : "chart.line.downtrend.xyaxis")
                    .font(.callout)
                    .foregroundStyle(soon ? Color.orange : Color.primary)
                if job.options.snapshots.enabled, !job.options.snapshots.hasRetention {
                    Text(settings.t(.fillForecastRetention)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .notFilling?:
                Text(settings.t(.fillForecastNotFilling)).font(.callout).foregroundStyle(.secondary)
            case .notEnoughData?, nil:
                Text(settings.t(.fillForecastNotEnough, FillForecast.minimumSamples)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(settings.t(.fillForecastNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("copiator.fillForecast")
        .task(id: "\(job.id)-\(job.history.count)") {
            outcome = model.fillForecast(for: job)
            free = model.freeSpace(job.destination)
            encrypted = model.volumeEncryption(job.destination)
        }
    }
}

/// Hedef disk şifreli değil: disk kaybolursa ya da çalınırsa yedekler okunabilir. Copiator şifrelemez; kullanıcı Disk
/// İzlencesi'nde şifreli bir APFS birimi kullanabilir.
struct UnencryptedDiskNote: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(settings.t(.destinationNotEncrypted), systemImage: "lock.open")
                .font(.callout)
                .foregroundStyle(.orange)
            Text(settings.t(.destinationNotEncryptedNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("copiator.destination.notEncrypted")
    }
}

