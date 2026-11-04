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

    /// Pencere kapalıyken (iş arka planda eklendi) izin gerektiği bir kez bildirilir; pencere açıkken bant yeter.
    @Test func fullDiskNeedIsAnnouncedOnceWhenTheWindowIsHidden() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let title = fixture.settings.t(.permissionFullDiskTitle)
        func announcements() -> Int { fixture.notifications.filter { $0.0 == title }.count }
        model.homeDirectory = fixture.url("Kaynak")
        var visible = true
        model.isMainWindowVisible = { visible }
        model.fullDiskAccessGranted = false
        await model.refreshEngine()
        fixture.addJob()
        await model.waitUntilIdle()
        #expect(model.permissionBanners == [.fullDiskAccess])
        #expect(announcements() == 0, "pencere açık: bant görünüyor")

        // Gereklilik kalkıp yeniden doğunca, pencere kapalıysa bir kez bildirilir.
        model.remove(Set(model.jobs.map(\.id)))
        #expect(model.permissionBanners.isEmpty)
        visible = false
        fixture.addJob()
        await model.waitUntilIdle()
        #expect(announcements() == 1)
        #expect(fixture.notifications.first { $0.0 == title }?.1 == fixture.settings.t(.permissionFullDiskNotice))
        model.remove(Set(model.jobs.map(\.id)))
        fixture.addJob()
        await model.waitUntilIdle()
        #expect(announcements() == 1, "oturumda bir kez")
    }

    @Test func settingsShowEachPermissionsStatusAndButton() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        #expect(NotificationPermission.allowed.statusKey == .permissionStatusOn)
        #expect(NotificationPermission.denied.statusKey == .permissionStatusOff)
        #expect(NotificationPermission.notDetermined.statusKey == .permissionStatusNotAsked)
        #expect(NotificationPermission.unavailable.statusKey == .permissionStatusUnavailable)
        #expect(NotificationPermission.unknown.statusKey == .permissionStatusUnknown)
        for (granted, key) in [(true, LKey.permissionStatusOn), (false, .permissionStatusOff)] {
            model.fullDiskAccessGranted = granted
            #expect(model.fullDiskAccessStatusKey == key)
        }
        model.fullDiskAccessGranted = nil
        #expect(model.fullDiskAccessStatusKey == .permissionStatusUnknown)
        // Bildirimler Uygulamalar dışından açıldığı için sunulmuyorsa düğme uygulamayı Finder'da gösterir.
        model.notificationPermission = .unavailable
        model.isInApplicationsFolder = false
        #expect(model.permissionButtonKey(.notifications) == .buttonShowInFinder)
        #expect(model.permissionButtonKey(.fullDiskAccess) == .permissionOpenSettings)
        model.isInApplicationsFolder = true
        #expect(model.permissionButtonKey(.notifications) == .permissionOpenSettings)
        model.isInApplicationsFolder = false
        model.notificationPermission = .denied
        #expect(model.permissionButtonKey(.notifications) == .permissionOpenSettings)
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
