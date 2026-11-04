// SPDX-License-Identifier: GPL-3.0-only
import CopiatorCore
import Foundation
import ServiceManagement
import SwiftUI

/// Girişte açılma kaydı (`SMAppService.mainApp`); testler sahte bir kayıt verir.
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// "Girişte aç" ayarının durumu. Kaynağı sistemdir (ayar olarak saklanmaz): kullanıcı Sistem Ayarları'ndan da kapatabilir.
enum LoginItemState: Equatable {
    case off
    case on
    /// Kayıt yapıldı, macOS kullanıcının Sistem Ayarları › Genel › Giriş Öğeleri'nde onaylamasını bekliyor.
    case needsApproval
    /// macOS bu kopyayı giriş öğesi olarak bulamıyor.
    case unavailable

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .on
        case .requiresApproval: self = .needsApproval
        case .notRegistered: self = .off
        case .notFound: self = .unavailable
        @unknown default: self = .unavailable
        }
    }

    /// Anahtar açık görünür mü (onay bekleyen kayıt da kullanıcının açtığı bir ayardır).
    var isRequested: Bool { self == .on || self == .needsApproval }
}

extension AppModel {
    /// Kaydın durumu yeniden okunur (açılışta, uygulama öne gelince, Ayarlar açılınca ve değiştirince).
    func refreshLoginItem() {
        let state = LoginItemState(loginItem.status)
        if state != loginItemState { loginItemState = state }
    }

    /// "Girişte aç" açılır ya da kapatılır; olmazsa neden söylenir. Hiçbir iş zamanlanmaz: uygulama yalnızca açılır.
    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try loginItem.register() } else { try loginItem.unregister() }
        } catch {
            alert = AlertItem(title: settings.t(.errorTitle), message: settings.t(.loginItemFailed, error.localizedDescription))
        }
        refreshLoginItem()
    }

    /// Sistem Ayarları › Genel › Giriş Öğeleri.
    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Ayarlar › Genel: "Girişte aç" anahtarı; macOS onay bekliyorsa ya da kopyayı bulamıyorsa nedeni ve Sistem Ayarları
/// düğmesi. Durum her gösterimde sistemden yeniden okunur.
struct OpenAtLoginRow: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(settings.t(.settingsOpenAtLogin), isOn: Binding(
                get: { model.loginItemState.isRequested },
                set: { model.setOpenAtLogin($0) }
            ))
            .accessibilityIdentifier("copiator.settings.openAtLogin")
            Text(settings.t(.settingsOpenAtLoginNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                HStack(spacing: 8) {
                    Label(settings.t(problem), systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.loginItemState == .needsApproval {
                        Button(settings.t(.permissionOpenSettings)) { model.openLoginItemSettings() }
                    }
                }
            }
        }
        .task { model.refreshLoginItem() }
    }

    private var problem: LKey? {
        switch model.loginItemState {
        case .needsApproval: .loginItemNeedsApproval
        case .unavailable: .loginItemUnavailable
        case .on, .off: nil
        }
    }
}
