// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Çıkarma çağrıları (sahte disk).
@MainActor
private final class EjectLog {
    var volumes: [URL] = []
    var failure: String?
}

/// Bitince diski çıkarma, bildirim düğmeleri ve bozuk dosya onarımı: disk yalnızca başarılı bir çalıştırmadan sonra ve onu
/// kullanan başka iş kalmayınca bir kez çıkarılır; düğmeler doğru öğeyle gelir, bildirimin kendisi yalnızca gösterir;
/// onarım işin kaynağındaki sağlam kopyayı kullanır.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct NoticeAndEjectAppTests {
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func ejectsTheDiskOnceNothingUsesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        fixture.settings.language = .tr
        await model.refreshEngine()
        let disk = fixture.url("Hedef")
        let log = EjectLog()
        model.ejectTarget = { url in url.path.hasPrefix(disk.path) ? (disk, [disk]) : nil }
        model.ejectVolume = { volume, done in
            log.volumes.append(volume)
            done(log.failure)
        }
        try fixture.write("Kaynak2/b.txt", "b\n")
        try fixture.write("Kaynak3/c.txt", "c\n")
        try fixture.write("Kaynak4/d.txt", "d\n")
        let options = CopyOptions(conflictPolicy: .replace, ejectWhenDone: true)

        // İki iş aynı diske: ilki bitince ikincisi sırada beklediği için disk tutulur; ikincisi bitince bir kez çıkarılır.
        model.toggleQueueHold()
        let first = try #require(fixture.addJob(options: options))
        let second = try #require(fixture.addJob("Kaynak2", options: options))
        model.toggleQueueHold()
        await model.waitUntilIdle()
        try await waitFor { model.job(second)?.log.contains { $0.key == LKey.logEjected.rawValue } == true }
        #expect(model.job(first)?.status == .finished && model.job(second)?.status == .finished)
        #expect(log.volumes == [disk])
        #expect(model.job(first)?.log.contains { $0.key == LKey.logEjected.rawValue } == false)
        #expect(fixture.notifications.last?.0 == "Disk çıkarıldı" && fixture.notifications.last?.1 == "“Hedef” güvenle sökülebilir.")

        // Seçenek kapalıysa çıkarılmaz.
        let plain = try #require(fixture.addJob("Kaynak3"))
        await model.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.job(plain)?.status == .finished && log.volumes == [disk])

        // Çıkarılamayınca günlüğe uyarı yazılır ve bildirilir.
        log.failure = "Disk kullanımda"
        model.resume([second])
        await model.waitUntilIdle()
        try await waitFor { model.job(second)?.log.contains { $0.key == LKey.logEjectFailed.rawValue } == true }
        let warning = try #require(model.job(second)?.log.last { $0.key == LKey.logEjectFailed.rawValue })
        #expect(warning.level == .warning && warning.arguments == ["Hedef", "Disk kullanımda"])
        #expect(fixture.notifications.last?.0 == "Disk çıkarılamadı" && log.volumes == [disk, disk])

        // Başarısız çalıştırmadan sonra çıkarılmaz.
        model.toggleQueueHold()
        let failing = try #require(fixture.addJob("Kaynak4", options: options))
        try FileManager.default.removeItem(at: fixture.url("Kaynak4"))
        model.toggleQueueHold()
        await model.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.job(failing)?.status == .failed && log.volumes.count == 2)
    }

    @Test func noticeButtonsCarryTheirItems() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.settings.language = .tr
        let now = Date()
        var job = TransferJob(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"), status: .finished)
        job.history = [JobRun(startedAt: now.addingTimeInterval(-40 * 86_400 - 60), finishedAt: now.addingTimeInterval(-40 * 86_400),
                              result: JobResult(kind: .succeeded))]
        let id = job.id
        try fixture.store.save([job])
        let model = fixture.relaunch()
        await model.refreshEngine()

        // Eski yedek: "Şimdi Yedekle" işi yeniden çalıştırır; bildirimin kendisine tıklamak çalıştırmaz.
        model.remindStaleBackups(on: nil, now: now)
        let stale = try #require(fixture.noticeActions.last ?? nil)
        #expect(stale == .backUpNow([id]))
        model.handleNotice(stale, button: false)
        #expect(model.job(id)?.status == .finished && model.job(id)?.history.count == 1)
        model.handleNotice(.backUpNow([id, UUID()]), button: true)
        #expect(model.toast?.message == "1 yedek kuyruğa alındı")
        await model.waitUntilIdle()
        #expect(model.job(id)?.status == .finished && model.job(id)?.history.count == 2)

        // Karar bekleyen iş: "Karar Ver" karar sayfasını açar; bilinmeyen ya da karar beklemeyen iş açmaz.
        try fixture.write("Hedef/Kaynak/not.txt", "hedefteki eski not\n")
        try fixture.write("Kaynak/not.txt", "yeni not içeriği\n")
        model.resume([id])
        await model.waitUntilIdle()
        #expect(model.job(id)?.isAwaitingDecision == true)
        #expect(fixture.noticeActions.last == .decide(id))
        model.conflictPrompt = nil
        model.handleNotice(.decide(UUID()), button: true)
        #expect(model.conflictPrompt == nil)
        model.handleNotice(.decide(id), button: true)
        #expect(model.conflictPrompt?.id == id)

        // Kimlik ve yol bildirimin içinde taşınır; bozuk ya da göreli değerler reddedilir.
        for action in [NoticeAction.backUpNow([id, UUID()]), .showIntegrity("/Volumes/Yedek/Arsiv"), .decide(id)] {
            #expect(NoticeAction(category: action.category, userInfo: action.userInfo) == action)
        }
        #expect(NoticeAction(category: NoticeAction.integrityCategory, userInfo: ["path": "Arsiv/../x"]) == nil)
        #expect(NoticeAction(category: NoticeAction.staleCategory, userInfo: ["ids": "yok"]) == nil)
        #expect(NoticeAction(category: NoticeAction.decisionCategory, userInfo: [:]) == nil)
        #expect(NoticeAction(category: "baska", userInfo: ["job": id.uuidString]) == nil)
        #expect(NoticeAction.categories { fixture.settings.t($0) }.flatMap(\.actions).map(\.title).sorted() == ["Göster", "Karar Ver", "Şimdi Yedekle"])
    }

    @Test func integrityNoticeOpensTheSheetAndRepairUsesTheSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let settings = fixture.settings
        settings.language = .tr
        await model.refreshEngine()
        #expect(fixture.addJob() != nil)
        await model.waitUntilIdle()
        let destination = fixture.url("Hedef")
        model.startIntegrityCheck(destination)
        try await waitFor { model.integrityRuns[destination.path] == nil }
        #expect(fixture.noticeActions.last == .some(nil))

        // Sessiz bozulma: aynı uzunlukta farklı içerik, eski tarih.
        let damaged = fixture.url("Hedef/Kaynak/not.txt")
        let date = try #require(try FileManager.default.attributesOfItem(atPath: damaged.path)[.modificationDate] as? Date)
        try Data("merhabA\n".utf8).write(to: damaged)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: damaged.path)
        model.startIntegrityCheck(destination)
        try await waitFor { model.integrityRuns[destination.path] == nil }
        guard case .report(let report)? = model.integrityResults[destination.path] else {
            Issue.record("bütünlük sonucu yok")
            return
        }
        #expect(report.corrupted == ["Kaynak/not.txt"])
        #expect(fixture.noticeActions.last == .showIntegrity(destination.path))

        // "Göster" bütünlük sayfasını açar; listesi olmayan bir yol açmaz.
        model.handleNotice(.showIntegrity(fixture.url("Kaynak").path), button: true)
        #expect(model.integrityRequest == nil)
        model.handleNotice(.showIntegrity(destination.path), button: true)
        #expect(model.integrityRequest?.destination.path == destination.path)

        // Onarım: işin kaynağındaki sağlam kopya kullanılır; sonuç sayfada gösterilir, bozuk listesi boşalır.
        model.repairCorrupted(destination)
        #expect(model.integrityRepairing.contains(destination.path))
        try await waitFor { !model.integrityRepairing.contains(destination.path) }
        let repair = try #require(model.integrityRepairResults[destination.path])
        #expect(repair.repaired["Kaynak/not.txt"]?.path == fixture.url("Kaynak/not.txt").path)
        #expect(fixture.read("Hedef/Kaynak/not.txt") == "merhaba\n" && fixture.read("Kaynak/not.txt") == "merhaba\n")
        guard case .report(let after)? = model.integrityResults[destination.path] else {
            Issue.record("bütünlük sonucu yok")
            return
        }
        #expect(after.corrupted.isEmpty && model.toast?.message == "1 dosya onarıldı.")
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: IntegritySheet(request: IntegrityRequest(destination: destination))
            .environment(model).environment(settings))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        spinRunLoop(0.2)
        window.close()
        #expect(try ArchiveIntegrity.check(destination).corrupted.isEmpty)
    }
}
