// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@preconcurrency import UserNotifications
@testable import Copiator
@testable import CopiatorCore

/// İzin uyarıları: bildirim bandı yalnızca izin yokken ve bildirim kullanan bir ayar açıkken; Tam Disk Erişimi bandı
/// yalnızca izin yokken ve bir iş ya da rutin korumalı bir yere değerken. "Sonra" bandı bu oturum için kaldırır.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct PermissionTests {
    @Test func notificationBannerNeedsABlockedPermissionAndANotifyingSetting() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let settings = fixture.settings
        settings.notifyOnFinish = true
        #expect(model.permissionBanners.isEmpty, "durum okunmadı")
        for permission in [NotificationPermission.allowed, .notDetermined, .unknown] {
            model.notificationPermission = permission
            #expect(model.permissionBanners.isEmpty, "\(permission)")
        }
        for permission in [NotificationPermission.denied, .unavailable] {
            model.notificationPermission = permission
            #expect(model.permissionBanners == [.notifications], "\(permission)")
        }
        // Bildirim kullanan hiçbir ayar açık değilse uyarı yok; biri açılınca gelir.
        settings.notifyOnFinish = false
        settings.backupReminderDays = 0
        settings.integrityOnConnect = []
        #expect(model.permissionBanners.isEmpty)
        settings.backupReminderDays = 30
        #expect(model.permissionBanners == [.notifications])
        settings.backupReminderDays = 0
        settings.integrityOnConnect = [fixture.url("Hedef").path]
        #expect(model.permissionBanners == [.notifications])
        model.dismissedPermissionBanners.insert(.notifications)
        #expect(model.permissionBanners.isEmpty)
    }

    @Test func fullDiskBannerNeedsAMissingPermissionAndAProtectedPath() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.homeDirectory = fixture.url("Ev")
        let mail = fixture.url("Ev/Library/Mail")
        try FileManager.default.createDirectory(at: mail, withIntermediateDirectories: true)
        model.fullDiskAccessGranted = false
        #expect(model.permissionBanners.isEmpty, "korumalı yere değen iş yok")

        // Açılıştaki sıra: rutin izin bilinmezken kayıtlı, yoklama sonra "yok" der; karar o anda hesaplanır.
        model.fullDiskAccessGranted = nil
        let routine = Routine(name: "Posta", routes: [RoutineRoute(source: mail, destination: fixture.url("Hedef"))])
        #expect(model.saveRoutine(routine) == nil)
        #expect(model.permissionBanners.isEmpty, "izin bilinmiyor")
        model.fullDiskAccessGranted = false
        #expect(model.permissionBanners == [.fullDiskAccess])
        model.fullDiskAccessGranted = true
        #expect(model.permissionBanners.isEmpty)
        model.fullDiskAccessGranted = nil
        #expect(model.permissionBanners.isEmpty, "bilinmiyorsa uyarı yok")
        model.fullDiskAccessGranted = false
        #expect(model.permissionBanners == [.fullDiskAccess])
        model.dismissedPermissionBanners.insert(.fullDiskAccess)
        #expect(model.permissionBanners.isEmpty)
    }

    /// Ev klasörünün tamamını yedekleyen iş: kum havuzunun atlamadığı korumalı yerler (Çöp Sepeti) için izin gerekir.
    @Test func homeBackupJobNeedsFullDiskAccess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.homeDirectory = fixture.url("Kaynak")
        model.fullDiskAccessGranted = false
        #expect(model.permissionBanners.isEmpty)
        await model.refreshEngine()
        fixture.addJob()
        await model.waitUntilIdle()
        #expect(model.permissionBanners == [.fullDiskAccess])
    }

    @Test func permissionFollowsTheSystemStatusAndTheFailedRequest() {
        #expect(NotificationPermission(status: .authorized, requestFailed: false) == .allowed)
        #expect(NotificationPermission(status: .provisional, requestFailed: true) == .allowed)
        #expect(NotificationPermission(status: .denied, requestFailed: false) == .denied)
        #expect(NotificationPermission(status: .notDetermined, requestFailed: false) == .notDetermined)
        #expect(NotificationPermission(status: .notDetermined, requestFailed: true) == .unavailable)
        #expect(NotificationPermission(status: .denied, requestFailed: true) == .unavailable)
        #expect(NotificationPermission.denied.isBlocked && NotificationPermission.unavailable.isBlocked)
        #expect(!NotificationPermission.notDetermined.isBlocked && !NotificationPermission.allowed.isBlocked)
    }

    @Test func applicationsFolderIsRecognized() {
        #expect(AppModel.isInApplicationsFolder(URL(fileURLWithPath: "/Applications/Copiator.app")))
        #expect(AppModel.isInApplicationsFolder(URL(fileURLWithPath: "/Applications/Yedek/Copiator.app")))
        #expect(!AppModel.isInApplicationsFolder(URL(fileURLWithPath: "/ApplicationsX/Copiator.app")))
        #expect(!AppModel.isInApplicationsFolder(URL(fileURLWithPath: "/private/tmp/Copiator.app")))
        #expect(!AppModel.isInApplicationsFolder(URL(fileURLWithPath: "/Users/test/Applications/Copiator.app")))
    }

    @Test func settingsLinksPointAtTheRightPanes() {
        #expect(AppLinks.notificationSettings.absoluteString.hasSuffix("Notifications-Settings.extension?id=com.babadogantech.copiator"))
        #expect(FullDiskAccess.settingsURL.absoluteString.hasSuffix("?Privacy_AllFiles"))
    }
}
