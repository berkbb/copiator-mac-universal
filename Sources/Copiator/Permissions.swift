// SPDX-License-Identifier: GPL-3.0-only
import CopiatorCore
import SwiftUI
@preconcurrency import UserNotifications

/// Bildirim izninin durumu.
enum NotificationPermission: Equatable {
    /// Okunmadı (testler, uygulama paketi dışı).
    case unknown
    case allowed
    /// Kullanıcı henüz yanıtlamadı.
    case notDetermined
    case denied
    /// macOS izin sormayı reddetti (UNErrorDomain 1). 2026-11-04 denemesi: aynı ad-hoc imzalı uygulama /tmp'den ya da
    /// derleme klasöründen açılınca bu hatayı alır, /Applications'tan açılınca izin sorusu çıkar; sorun imza değil konum.
    case unavailable

    init(status: UNAuthorizationStatus, requestFailed: Bool) {
        switch status {
        case .authorized, .provisional, .ephemeral: self = .allowed
        case _ where requestFailed: self = .unavailable
        case .denied: self = .denied
        case .notDetermined: self = .notDetermined
        @unknown default: self = .unknown
        }
    }

    /// Bildirim gönderilemiyor ve kullanıcının yapabileceği bir şey var.
    var isBlocked: Bool { self == .denied || self == .unavailable }
}

/// Pencerenin üstündeki izin uyarısı.
enum PermissionBanner: Hashable, Identifiable {
    case notifications
    case fullDiskAccess

    var id: Self { self }
}

/// İzin uyarıları (Curatare'nin Tam Disk Erişimi bandından uyarlandı): neden gerektiği, Sistem Ayarları düğmesi ve
/// "Sonra". Bant iş listesinin üstündeyken (`safeAreaInset`) yüksekliği genişliğe bağlı olmamalı (bkz.
/// `PowerStatusBanner`): başlık tek satır, açıklama her zaman iki satırlık yer kaplar; tamamı ipucunda görünür.
struct PermissionBanners: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.permissionBanners) { banner in
                row(banner)
                Divider()
            }
        }
    }

    private func row(_ banner: PermissionBanner) -> some View {
        let text = content(banner)
        return HStack(spacing: 12) {
            Image(systemName: text.symbol)
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.t(text.title))
                    .font(.headline)
                    .lineLimit(1)
                Text(settings.t(text.detail))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .help(settings.t(text.detail))
            Spacer(minLength: 8)
            Button(settings.t(text.button)) { model.openPermissionSettings(banner) }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("copiator.permission.\(banner).open")
            Button(settings.t(.permissionLater)) { model.dismissedPermissionBanners.insert(banner) }
                .buttonStyle(.glass)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("copiator.permission.\(banner)")
    }

    private func content(_ banner: PermissionBanner) -> (symbol: String, title: LKey, detail: LKey, button: LKey) {
        switch banner {
        case .fullDiskAccess:
            return ("lock.shield", .permissionFullDiskTitle, .permissionFullDisk, .permissionOpenSettings)
        case .notifications where model.permissionButtonKey(.notifications) == .buttonShowInFinder:
            return ("bell.slash", .permissionNotificationsTitle, .permissionNotificationsMoveApp, .buttonShowInFinder)
        case .notifications:
            let detail: LKey = model.notificationPermission == .unavailable ? .permissionNotificationsUnavailable : .permissionNotificationsDenied
            return ("bell.slash", .permissionNotificationsTitle, detail, .permissionOpenSettings)
        }
    }
}

extension NotificationPermission {
    /// Ayarlar'daki durum metni.
    var statusKey: LKey {
        switch self {
        case .allowed: .permissionStatusOn
        case .denied: .permissionStatusOff
        case .notDetermined: .permissionStatusNotAsked
        case .unavailable: .permissionStatusUnavailable
        case .unknown: .permissionStatusUnknown
        }
    }
}

extension AppModel {
    /// Ayarlar'daki Tam Disk Erişimi durum metni.
    var fullDiskAccessStatusKey: LKey {
        switch fullDiskAccessGranted {
        case true?: .permissionStatusOn
        case false?: .permissionStatusOff
        case nil: .permissionStatusUnknown
        }
    }

    /// İzin düğmesinin adı: bildirimler Uygulamalar klasörü dışından açıldığı için sunulmuyorsa "Finder'da Göster".
    func permissionButtonKey(_ banner: PermissionBanner) -> LKey {
        banner == .notifications && notificationPermission == .unavailable && !isInApplicationsFolder
            ? .buttonShowInFinder : .permissionOpenSettings
    }
}

/// Ayarlar › Genel › İzinler: bildirim ve Tam Disk Erişimi durumu, her biri için Sistem Ayarları düğmesi. Bir iş
/// gerektirmeden de izin görülüp verilebilir; açılınca durum yeniden okunur.
struct PermissionStatusSection: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            row(.settingsPermissionNotifications, status: model.notificationPermission.statusKey,
                isOn: model.notificationPermission == .allowed, banner: .notifications)
            row(.settingsPermissionFullDisk, status: model.fullDiskAccessStatusKey,
                isOn: model.fullDiskAccessGranted == true, banner: .fullDiskAccess)
        } header: {
            Text(settings.t(.settingsPermissionsSection))
        } footer: {
            Text(settings.t(.settingsPermissionsNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await model.refreshPermissions(ask: false) }
    }

    private func row(_ title: LKey, status: LKey, isOn: Bool, banner: PermissionBanner) -> some View {
        LabeledContent(settings.t(title)) {
            HStack(spacing: 8) {
                Label(settings.t(status), systemImage: isOn ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isOn ? .green : .orange)
                Button(settings.t(model.permissionButtonKey(banner))) { model.openPermissionSettings(banner) }
                    .accessibilityIdentifier("copiator.settings.permission.\(banner)")
            }
        }
    }
}
