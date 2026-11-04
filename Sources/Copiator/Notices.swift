// SPDX-License-Identifier: GPL-3.0-only
import CopiatorCore
import Foundation
import UserNotifications

/// Bildirimdeki düğme: eski yedekleri şimdi yedekle, bütünlük sonucunu göster, karar sayfasını aç. Bildirimin içinde
/// kategori ve kimlik/yol olarak taşınır; uygulama tıklamayı alınca yeniden çözer ve var olan öğelerle doğrular.
nonisolated enum NoticeAction: Equatable, Sendable {
    case backUpNow([UUID])
    case showIntegrity(String)
    case decide(TransferJob.ID)

    static let staleCategory = "copiator.stale"
    static let integrityCategory = "copiator.integrity"
    static let decisionCategory = "copiator.decision"
    static let backUpNowButton = "copiator.backUpNow"
    static let showButton = "copiator.show"
    static let decideButton = "copiator.decide"

    var category: String {
        switch self {
        case .backUpNow: Self.staleCategory
        case .showIntegrity: Self.integrityCategory
        case .decide: Self.decisionCategory
        }
    }

    var userInfo: [String: String] {
        switch self {
        case .backUpNow(let ids): ["ids": ids.map(\.uuidString).joined(separator: ",")]
        case .showIntegrity(let path): ["path": path]
        case .decide(let id): ["job": id.uuidString]
        }
    }

    init?(category: String, userInfo: [AnyHashable: Any]) {
        switch category {
        case Self.staleCategory:
            guard let text = userInfo["ids"] as? String else { return nil }
            let ids = text.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            guard !ids.isEmpty else { return nil }
            self = .backUpNow(ids)
        case Self.integrityCategory:
            guard let path = userInfo["path"] as? String, path.hasPrefix("/") else { return nil }
            self = .showIntegrity(path)
        case Self.decisionCategory:
            guard let text = userInfo["job"] as? String, let id = UUID(uuidString: text) else { return nil }
            self = .decide(id)
        default:
            return nil
        }
    }

    /// Bildirim kategorileri ve düğmeleri, uygulamanın dilinde. "Şimdi Yedekle" uygulamayı öne getirmez; ötekiler bir
    /// sayfa açtığı için getirir.
    static func categories(_ title: (LKey) -> String) -> Set<UNNotificationCategory> {
        [
            UNNotificationCategory(identifier: staleCategory,
                                   actions: [UNNotificationAction(identifier: backUpNowButton, title: title(.notifyActionBackUpNow), options: [])],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: integrityCategory,
                                   actions: [UNNotificationAction(identifier: showButton, title: title(.notifyActionShow), options: [.foreground])],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: decisionCategory,
                                   actions: [UNNotificationAction(identifier: decideButton, title: title(.notifyActionDecide), options: [.foreground])],
                                   intentIdentifiers: []),
        ]
    }
}

/// Bildirime ya da düğmesine tıklamayı modele iletir. Bildirimin kendisine tıklamak yalnızca gösterir (yedek başlatmaz).
nonisolated final class NoticeHandler: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let action = NoticeAction(category: content.categoryIdentifier, userInfo: content.userInfo)
        let identifier = response.actionIdentifier
        completionHandler()
        guard let action, identifier != UNNotificationDismissActionIdentifier else { return }
        let button = identifier != UNNotificationDefaultActionIdentifier
        Task { @MainActor in AppModel.shared.handleNotice(action, button: button) }
    }
}
