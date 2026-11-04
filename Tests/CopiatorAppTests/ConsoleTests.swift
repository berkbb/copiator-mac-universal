// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Günlük (konsol): işler başlarken ve biterken kayıt düşer; özet yol ya da dosya adı içermez (iş kısa kimliğiyle anılır),
/// rsync'in ayrıntısı gizli ayrıntıdadır. Pencere yalnızca sorunları gösterebilir ve arayabilir.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct ConsoleTests {
    @Test func jobsAreLoggedWithoutPaths() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        await model.waitUntilIdle()
        let short = AppLog.short(id)
        let mine = AppLog.shared.entries.filter { $0.message.contains(short) }
        #expect(mine.contains { $0.category == .job && $0.message.hasPrefix("Job \(short) started (rsync") })
        let ended = try #require(mine.first { $0.message.hasPrefix("Job \(short) ended: succeeded") })
        #expect(ended.level == .info && ended.category == .job)
        for entry in mine {
            #expect(!entry.message.contains(fixture.workspace.path) && !entry.message.contains("Kaynak"), "\(entry.message)")
        }
        #expect(AppLog.shared.entries.contains { $0.category == .engine && $0.message.hasPrefix("rsync ") && $0.message.contains("ready") })
    }

    @Test func failedJobsAreProblemsWithTheDetailKeptPrivate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        try fixture.write("Okunmaz/gizli ad.txt", "a")
        let file = fixture.url("Okunmaz/gizli ad.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        #expect(model.addJob(source: fixture.url("Okunmaz"), destination: fixture.url("Hedef"), options: CopyOptions()) == nil)
        let id = try #require(model.jobs.last?.id)
        await model.waitUntilIdle()
        let ended = try #require(AppLog.shared.entries.last { $0.message.hasPrefix("Job \(AppLog.short(id)) ended") })
        #expect(ended.level.isProblem)
        #expect(!ended.message.contains("gizli ad"))
        #expect(ended.detail?.contains("gizli ad.txt") == true, "ayrıntı rsync iletisini taşır (Konsol'da gizli)")

        // Pencere verisi: yalnızca sorunlar ve arama.
        let store = LogStore(log: .shared)
        store.scope = .problems
        #expect(store.visibleEntries.allSatisfy { $0.level.isProblem })
        #expect(store.visibleEntries.contains { $0.id == ended.id })
        store.scope = .all
        store.searchText = AppLog.short(id)
        let short = AppLog.short(id)
        let found = store.visibleEntries
        #expect(!found.isEmpty && found.allSatisfy { $0.message.contains(short) || $0.detail?.contains(short) == true })
    }

    @Test func consoleWindowRenders() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let log = AppLog(directory: nil)
        log.info(.app, "Started")
        log.warning(.disk, "Disk could not be ejected", detail: "busy")
        log.error(.job, "Job 1A2B3C4D ended: failed", detail: "rsync: error")
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: NavigationStack { ConsoleView(store: LogStore(log: log)) }.environment(fixture.settings))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(LogStore(log: log).visibleEntries.count == 3)
    }
}
