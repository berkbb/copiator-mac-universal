// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import ServiceManagement
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Sahte giriş öğesi kaydı: gerçek SMAppService'e (bu Mac'in giriş öğelerine) dokunulmaz.
private final class FakeLoginItem: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    /// Kayıttan sonraki durum (macOS onay isteyebilir).
    var statusAfterRegister: SMAppService.Status = .enabled
    var failure: Error?
    func register() throws {
        if let failure { throw failure }
        status = statusAfterRegister
    }
    func unregister() throws {
        if let failure { throw failure }
        status = .notRegistered
    }
}

/// "Girişte aç": durum sistemden okunur, anahtar kaydı yapar ya da kaldırır; onay bekleyen kayıt açık görünür ve
/// nedeni söylenir; hata bir uyarıyla açıklanır ve durum değişmez.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct LoginItemTests {
    @Test func toggleRegistersAndUnregisters() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let item = FakeLoginItem()
        model.loginItem = item
        model.refreshLoginItem()
        #expect(model.loginItemState == .off && !model.loginItemState.isRequested)
        model.setOpenAtLogin(true)
        #expect(item.status == .enabled && model.loginItemState == .on)
        model.setOpenAtLogin(false)
        #expect(item.status == .notRegistered && model.loginItemState == .off)
        #expect(model.alert == nil)
    }

    @Test func approvalAndOutsideChangesAreShown() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let item = FakeLoginItem()
        item.statusAfterRegister = .requiresApproval
        model.loginItem = item
        model.setOpenAtLogin(true)
        #expect(model.loginItemState == .needsApproval && model.loginItemState.isRequested)
        // Kullanıcı Sistem Ayarları'ndan onayladı ya da kapattı: yeniden okununca görünür.
        item.status = .enabled
        model.refreshLoginItem()
        #expect(model.loginItemState == .on)
        item.status = .notRegistered
        model.refreshLoginItem()
        #expect(model.loginItemState == .off)
        // Hiç kaydedilmemiş uygulama için macOS "bulunamadı" da der: bu da kapalıdır, anahtar kullanılabilir.
        item.status = .notFound
        model.refreshLoginItem()
        #expect(model.loginItemState == .off && !model.loginItemState.isRequested)
        model.setOpenAtLogin(true)
        #expect(model.loginItemState == .needsApproval)
    }

    @Test func failureIsExplainedAndStateStays() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let item = FakeLoginItem()
        item.failure = NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "izin yok"])
        model.loginItem = item
        model.setOpenAtLogin(true)
        #expect(model.loginItemState == .off)
        let alert = try #require(model.alert)
        #expect(alert.message == fixture.settings.t(.loginItemFailed, "izin yok"))
    }
}
