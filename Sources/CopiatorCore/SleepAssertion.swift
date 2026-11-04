// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import IOKit.pwr_mgt

/// Bir iş çalışırken Mac'in boşta kalınca uyumasını engeller (`caffeinate -i` karşılığı); ekran türüyle
/// (`kIOPMAssertionTypePreventUserIdleDisplaySleep`) ekranın kararmasını da (`caffeinate -d`).
///
/// Varsayılan türde ekran kararabilir; yalnızca sistem uykusu ertelenir. Kapak kapatma ve elle uyutma engellenmez. İş bitince,
/// duraklatılınca ya da hata verince bırakılır; nesne yok edilirken de bırakılır (sızıntı olmaz).
public final class SleepAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private let reason: String
    private let type: String

    /// - Parameters:
    ///   - reason: Etkinlik Monitörü ve `pmset -g assertions` çıktısında görünen açıklama.
    ///   - type: IOPM engel türü (varsayılan: boşta sistem uykusu).
    public init(reason: String, type: String = kIOPMAssertionTypePreventUserIdleSystemSleep) {
        self.reason = reason
        self.type = type
    }

    deinit { release() }

    public var isHeld: Bool { lock.withLock { assertionID != IOPMAssertionID(kIOPMNullAssertionID) } }

    /// Engeli alır (zaten alınmışsa bir şey yapmaz). - Returns: Engel tutuluyor mu?
    @discardableResult
    public func acquire() -> Bool {
        lock.withLock {
            if assertionID != IOPMAssertionID(kIOPMNullAssertionID) { return true }
            var id = IOPMAssertionID(kIOPMNullAssertionID)
            let status = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            guard status == kIOReturnSuccess else { return false }
            assertionID = id
            return true
        }
    }

    public func release() {
        lock.withLock {
            guard assertionID != IOPMAssertionID(kIOPMNullAssertionID) else { return }
            IOPMAssertionRelease(assertionID)
            assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        }
    }

    /// Bu süreçteki etkin uyku engellerinin adları (testler ve tanı için).
    public static func activeAssertionNames() -> [String] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dictionary = unmanaged?.takeRetainedValue() as? [AnyHashable: Any] else { return [] }
        let pid = ProcessInfo.processInfo.processIdentifier
        let own = dictionary.first { (key, _) in (key as? NSNumber)?.int32Value == pid }?.value as? [[String: Any]] ?? []
        return own.compactMap { $0[kIOPMAssertionNameKey] as? String }
    }
}
