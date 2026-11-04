// SPDX-License-Identifier: GPL-3.0-only
import CopiatorCore
import Foundation

/// Güç önerilerinin arayüzdeki karşılığı: metin, simge, önem.
extension PowerAdvice {
    var titleKey: LKey {
        switch self {
        case .onBattery: .adviceOnBattery
        case .batteryLow: .adviceBatteryLow
        case .batteryCritical: .adviceBatteryCritical
        case .lowPowerMode: .adviceLowPowerMode
        case .displayMaySleep: .adviceDisplaySleep
        case .lidClosesSleep: .adviceLid
        }
    }

    /// Kullanıcının bir şey yapması önerilen durum (yoksa bilgi).
    var isWarning: Bool {
        switch self {
        case .onBattery, .batteryLow, .batteryCritical, .lowPowerMode: true
        case .displayMaySleep, .lidClosesSleep: false
        }
    }

    var systemImage: String {
        switch self {
        case .onBattery: "battery.50percent"
        case .batteryLow: "battery.25percent"
        case .batteryCritical: "battery.0percent"
        case .lowPowerMode: "leaf.fill"
        case .displayMaySleep: "display"
        case .lidClosesSleep: "laptopcomputer"
        }
    }

    /// Metindeki biçim değişkenleri (pil yüzdesi).
    func arguments(_ snapshot: PowerSnapshot, _ settings: AppSettings) -> [String] {
        switch self {
        case .onBattery, .batteryLow, .batteryCritical:
            [settings.percent(Double(snapshot.batteryPercent ?? 0) / 100)]
        default:
            []
        }
    }
}
