// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Hedefte aynı adlı dosyalar: iş karar için duraklar, sıradaki iş sürer; karar ve "hatırla" uygulanır.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct ConflictAppTests {
    private func prepare(_ fixture: Fixture) throws {
        try fixture.write("Hedef/Kaynak/not.txt", "hedefteki eski not\n")
        try fixture.write("Hedef/Kaynak/alt/b.txt", "alt\n")
    }

    @Test func askPausesNotifiesAndContinuesAfterDecision() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try prepare(fixture)
        try fixture.write("Diger/x.txt", "x\n")
        let model = fixture.model
        await model.refreshEngine()
        model.toggleQueueHold()
        let id = try #require(fixture.addJob())
        let other = try #require(model.addJob(source: fixture.url("Diger"), destination: fixture.url("Hedef"), options: CopyOptions()) == nil
                                 ? model.jobs.last?.id : nil)
        model.toggleQueueHold()
        await model.waitUntilIdle()

        let job = try #require(model.job(id))
        #expect(job.isAwaitingDecision && job.result?.kind == .awaitingDecision)
        #expect(job.pendingConflicts?.total == 2)
        #expect(model.conflictPrompt?.id == id)
        #expect(fixture.notifications.contains { $0.0 == fixture.settings.t(.notifyDecisionTitle) })
        // Karar beklenirken sıradaki iş çalıştı; karar bekleyen işte hiçbir şey kopyalanmadı.
        #expect(model.job(other)?.status == .finished)
        #expect(fixture.read("Hedef/Kaynak/not.txt") == "hedefteki eski not\n")
        // Kararsız sürdürme yeniden çalıştırmaz, sayfayı açar.
        model.conflictPrompt = nil
        model.resume([id])
        #expect(model.conflictPrompt?.id == id && model.job(id)?.status == .paused)

        model.resolveConflicts(id, resolution: ConflictResolution(decisions: ["Kaynak/not.txt": .keepBoth, "Kaynak/alt/b.txt": .skip]), remember: nil)
        #expect(model.conflictPrompt == nil)
        await model.waitUntilIdle()
        let done = try #require(model.job(id))
        #expect(done.status == .finished, "\(String(describing: done.result))")
        #expect(fixture.read("Hedef/Kaynak/not.txt") == "hedefteki eski not\n")
        #expect(fixture.read("Hedef/Kaynak/not 2.txt") == "merhaba\n")
        #expect(done.conflictResolution == nil && done.pendingConflicts == nil)
        #expect(done.options.conflictPolicy == .ask)

        // Yeniden çalıştırınca yine sorulur (artık "not 2.txt" de aynı adlı dosyalardan biri değil, çünkü kaynakta yok).
        model.resume([id])
        await model.waitUntilIdle()
        #expect(model.job(id)?.isAwaitingDecision == true)
    }

    /// "Hatırla": karar işin (rutin işinde rutinin) ayarı olur, bir daha sorulmaz.
    @Test func rememberedDecisionBecomesThePolicy() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try prepare(fixture)
        let model = fixture.model
        await model.refreshEngine()
        let routine = Routine(name: "Metinler", routes: [RoutineRoute(source: fixture.url("Kaynak"), destination: fixture.url("Hedef/Kaynak"),
            rules: RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "txt")]))])
        #expect(model.saveRoutine(routine) == nil)
        model.runRoutine(routine.id)
        await model.waitUntilIdle()
        let job = try #require(model.jobs(for: routine.id).first)
        #expect(job.isAwaitingDecision)
        model.resolveConflicts(job.id, resolution: ConflictResolution(decisions: ["not.txt": .replace, "alt/b.txt": .replace], others: .replace),
                               remember: .replace)
        await model.waitUntilIdle()
        #expect(model.job(job.id)?.status == .finished)
        #expect(fixture.read("Hedef/Kaynak/not.txt") == "merhaba\n")
        #expect(model.routine(routine.id)?.options.conflictPolicy == .replace)
        model.runRoutine(routine.id)
        await model.waitUntilIdle()
        #expect(model.job(job.id)?.status == .finished && model.job(job.id)?.isAwaitingDecision == false)
    }

    /// "Disk takılınca başla" seçili rutin hiç çalıştırılmamış olsa da hedef diski takılınca çalışır.
    @Test func diskTriggeredRoutineRunsWithoutAPriorRun() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        var routine = Routine(name: "Disk", routes: [RoutineRoute(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"),
            rules: RuleGroup(conditions: [RuleCondition(attribute: .name, op: .equals, value: "not.txt")]))])
        routine.options.runWhenConnected = true
        #expect(model.saveRoutine(routine) == nil)
        #expect(model.jobs.isEmpty)
        model.volumeDidMount(fixture.url("BaskaDisk"))
        #expect(model.jobs.isEmpty)
        model.volumeDidMount(fixture.url("Hedef"))
        await model.waitUntilIdle()
        #expect(model.jobs(for: routine.id).first?.status == .finished)
        #expect(fixture.read("Hedef/not.txt") == "merhaba\n")
    }

    @Test func conflictSheetRenders() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try prepare(fixture)
        let model = fixture.model
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        await model.waitUntilIdle()
        #expect(model.job(id)?.isAwaitingDecision == true)
        _ = NSApplication.shared
        for view in [AnyView(ConflictSheet(prompt: ConflictPrompt(id: id))), AnyView(ConflictSheet(prompt: ConflictPrompt(id: UUID()))),
                     AnyView(ContentView()), AnyView(MenuBarContent())] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: view.environment(model).environment(fixture.settings)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = host
            window.layoutIfNeeded()
            window.displayIfNeeded()
            spinRunLoop(0.3)
            if let directory = ProcessInfo.processInfo.environment["COPIATOR_SNAPSHOT_DIR"].map({ URL(fileURLWithPath: $0) }),
               let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("conflict-\(Int.random(in: 0...999)).png"))
            }
            window.close()
        }
    }
}
