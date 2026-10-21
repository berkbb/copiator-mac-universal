// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Bilgisayarın güç durumu: güç kaynağı, pil, Düşük Güç Modu.
public struct PowerSnapshot: Equatable, Sendable {
    public enum Source: String, Sendable { case ac, battery, ups, unknown }

    public var source: Source
    /// Dahili pil var mı (dizüstü)?
    public var hasBattery: Bool
    /// Pil yüzdesi (0...100); pil yoksa nil.
    public var batteryPercent: Int?
    public var isCharging: Bool
    public var lowPowerMode: Bool

    public init(source: Source, hasBattery: Bool, batteryPercent: Int? = nil, isCharging: Bool = false, lowPowerMode: Bool = false) {
        self.source = source
        self.hasBattery = hasBattery
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.lowPowerMode = lowPowerMode
    }

    /// Şu anki durum (IOKit güç kaynakları ve `ProcessInfo.isLowPowerModeEnabled`).
    public static func current() -> PowerSnapshot {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerSnapshot(source: .unknown, hasBattery: false, lowPowerMode: lowPower)
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let source: Source = switch providing {
        case kIOPMACPowerKey: .ac
        case kIOPMBatteryPowerKey: .battery
        case kIOPMUPSPowerKey: .ups
        default: .unknown
        }
        var snapshot = PowerSnapshot(source: source, hasBattery: false, lowPowerMode: lowPower)
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            snapshot.hasBattery = true
            if let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
               let maxCapacity = description[kIOPSMaxCapacityKey] as? Int, maxCapacity > 0 {
                snapshot.batteryPercent = min(100, max(0, currentCapacity * 100 / maxCapacity))
            }
            snapshot.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
        }
        return snapshot
    }
}

/// Uzun bir kopya için güç, pil ve ekran önerileri.
public enum PowerAdvice: String, CaseIterable, Sendable, Equatable {
    /// Pille çalışıyor (pil yeterli).
    case onBattery
    /// Pil %20'nin altında.
    case batteryLow
    /// Pil %10'un altında: Mac kapanabilir.
    case batteryCritical
    /// Düşük Güç Modu açık: kopyalama yavaşlayabilir.
    case lowPowerMode
    /// Ekran kararabilir (yalnızca sistem uykusu engellenir); bu kopyalamayı etkilemez.
    case displayMaySleep
    /// Dizüstünde kapak kapanınca Mac yine uyur.
    case lidClosesSleep
}

public enum PowerAdvisor {
    public static let lowBatteryPercent = 20
    public static let criticalBatteryPercent = 10

    /// Öneriler, önem sırasıyla (en önemlisi önce).
    /// - Parameter keepDisplayAwake: Ekran da açık tutuluyor mu (`caffeinate -d` karşılığı).
    public static func advice(for snapshot: PowerSnapshot, keepDisplayAwake: Bool) -> [PowerAdvice] {
        var advice: [PowerAdvice] = []
        if snapshot.source == .battery {
            let percent = snapshot.batteryPercent ?? 100
            if percent < criticalBatteryPercent {
                advice.append(.batteryCritical)
            } else if percent < lowBatteryPercent {
                advice.append(.batteryLow)
            } else {
                advice.append(.onBattery)
            }
        }
        if snapshot.lowPowerMode { advice.append(.lowPowerMode) }
        if snapshot.hasBattery { advice.append(.lidClosesSleep) }
        if !keepDisplayAwake { advice.append(.displayMaySleep) }
        return advice
    }

    /// Bir önceki duruma göre yeni çıkan uyarılar (iş sürerken her denetimde yalnızca bunlar bildirilir).
    public static func newWarnings(previous: [PowerAdvice], current: [PowerAdvice]) -> [PowerAdvice] {
        let warnings: Set<PowerAdvice> = [.onBattery, .batteryLow, .batteryCritical, .lowPowerMode]
        return current.filter { warnings.contains($0) && !previous.contains($0) }
    }
}

/// İş sürerken Mac'in uyumasını engelleyen ve bunu sistemin kendi kayıtlarında doğrulayan bekçi.
///
/// `caffeinate -i` ile aynı türde (`PreventUserIdleSystemSleep`) bir engel alır; istenirse ekran için de
/// (`PreventUserIdleDisplaySleep`, `caffeinate -d`). Doğrulama, sistemin süreç başına tuttuğu engel listesinde
/// (`pmset -g assertions` çıktısının kaynağı) bu engellerin gerçekten göründüğüne bakar.
public final class SleepGuard: @unchecked Sendable {
    public struct Status: Equatable, Sendable {
        /// Sistem uykusu engeli alındı ve sistem listesinde görülüyor.
        public var systemSleepPrevented: Bool
        /// Ekran engeli istendi ve sistem listesinde görülüyor.
        public var displaySleepPrevented: Bool
        /// Engel istendi ama sistem listesinde görülmedi.
        public var unverified: Bool

        public init(systemSleepPrevented: Bool = false, displaySleepPrevented: Bool = false, unverified: Bool = false) {
            self.systemSleepPrevented = systemSleepPrevented
            self.displaySleepPrevented = displaySleepPrevented
            self.unverified = unverified
        }
    }

    private let system: SleepAssertion
    private let display: SleepAssertion
    private let systemReason: String
    private let displayReason: String

    public init(reason: String) {
        systemReason = reason
        displayReason = reason + " (display)"
        system = SleepAssertion(reason: systemReason, type: kIOPMAssertionTypePreventUserIdleSystemSleep)
        display = SleepAssertion(reason: displayReason, type: kIOPMAssertionTypePreventUserIdleDisplaySleep)
    }

    /// Engeli alır ve doğrular.
    @discardableResult
    public func begin(keepDisplayAwake: Bool) -> Status {
        system.acquire()
        if keepDisplayAwake { display.acquire() } else { display.release() }
        return status(expectDisplay: keepDisplayAwake)
    }

    /// Engelleri bırakır. - Returns: Bıraktıktan sonra sistem listesinde hâlâ görünen engel var mı?
    @discardableResult
    public func end() -> Bool {
        system.release()
        display.release()
        let names = SleepAssertion.activeAssertionNames()
        return names.contains(systemReason) || names.contains(displayReason)
    }

    public var isHeld: Bool { system.isHeld }

    public func status(expectDisplay: Bool) -> Status {
        let names = SleepAssertion.activeAssertionNames()
        let systemVerified = system.isHeld && names.contains(systemReason)
        let displayVerified = display.isHeld && names.contains(displayReason)
        return Status(
            systemSleepPrevented: systemVerified,
            displaySleepPrevented: displayVerified,
            unverified: !systemVerified || (expectDisplay && !displayVerified)
        )
    }
}
