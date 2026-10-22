// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Rutin kütüphanesi: oluşturma, düzenleme, çoğaltma, silme, çalıştırma (rota başına tek iş), Kestirmeler, görünümler.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct RoutineAppTests {
    private func makeFixture() throws -> Fixture {
        let fixture = try Fixture()
        for path in ["Ofis/2026/Ocak/satis_raporu_2026-01-31_v1.xlsx", "Ofis/2026/Ocak/fatura.pdf", "Ofis/Tatil/IMG_1.HEIC",
                     "Ofis/Tatil/IMG_1 kopya.HEIC", "Ofis/notlar.txt"] {
            try fixture.write(path, path)
        }
        try FileManager.default.createDirectory(at: fixture.url("Raporlar"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.url("Fotograflar"), withIntermediateDirectories: true)
        return fixture
    }

    private func officeRoutine(_ fixture: Fixture) -> Routine {
        let reports = RuleGroup(conditions: [RuleCondition(attribute: .name, op: .matchesRegex, value: #"^[a-z_]+_\d{4}-\d{2}-\d{2}_v\d+\.xlsx?$"#)])
        let photos = RuleGroup(conditions: [RuleCondition(attribute: .folderName, op: .equals, value: "tatil"),
                                            RuleCondition(attribute: .kind, op: .equals, value: "image")],
                               groups: [RuleGroup(match: .none, conditions: [RuleCondition(attribute: .name, op: .contains, value: "kopya")])])
        return Routine(name: "Ofis yedeği", routes: [
            RoutineRoute(source: fixture.url("Ofis"), destination: fixture.url("Raporlar"), rules: reports),
            RoutineRoute(source: fixture.url("Ofis"), destination: fixture.url("Fotograflar"), rules: photos),
        ], options: CopyOptions(verifyAfterCopy: .quick))
    }

    @Test func createRunRerunEditAndDelete() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()

        // Sorunlu rutin kaydedilmez.
        #expect(model.saveRoutine(Routine(name: " ", routes: [])) != nil)
        #expect(model.routines.isEmpty)

        let routine = officeRoutine(fixture)
        #expect(model.saveRoutine(routine) == nil)
        #expect(model.selectedRoutineID == routine.id)
        #expect(model.sidebarSelection == .routine(routine.id))

        #expect(model.runRoutine(routine.id) == nil)
        await model.waitUntilIdle()
        let jobs = model.jobs(for: routine.id)
        #expect(jobs.count == 2)
        #expect(jobs.allSatisfy { $0.status == .finished && $0.routineName == "Ofis yedeği" })
        #expect(jobs.map(\.routeID) == routine.routes.map(\.id))
        #expect(fixture.read("Raporlar/2026/Ocak/satis_raporu_2026-01-31_v1.xlsx") != nil)
        #expect(fixture.read("Raporlar/2026/Ocak/fatura.pdf") == nil)
        #expect(fixture.read("Fotograflar/Tatil/IMG_1.HEIC") != nil)
        #expect(fixture.read("Fotograflar/Tatil/IMG_1 kopya.HEIC") == nil)
        #expect(model.routine(routine.id)?.lastRunAt != nil)

        // Yeniden çalıştırma aynı işleri sıraya alır (yeni iş eklenmez), geçmiş birikir.
        try fixture.write("Ofis/2026/Şubat/satis_raporu_2026-02-28_v2.xlsx", "yeni")
        model.runRoutine(routine.id)
        await model.waitUntilIdle()
        #expect(model.jobs.count == 2)
        #expect(model.jobs(for: routine.id).allSatisfy { $0.history.count == 2 })
        #expect(fixture.read("Raporlar/2026/Şubat/satis_raporu_2026-02-28_v2.xlsx") == "yeni")

        // Düzenleme: ad ve kurallar işlere yansır; silinen rotanın işi sıradan iş olur.
        var edited = try #require(model.routine(routine.id))
        edited.name = "Ofis"
        edited.routes[0].rules = RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "pdf")])
        edited.routes.removeLast()
        #expect(model.saveRoutine(edited) == nil)
        let reportJob = try #require(model.jobs.first { $0.routeID == edited.routes[0].id })
        #expect(reportJob.routineName == "Ofis" && reportJob.options.rules == edited.routes[0].rules)
        #expect(model.jobs(for: routine.id).count == 1)
        #expect(model.jobs.contains { $0.routineID == nil && $0.destination == fixture.url("Fotograflar") })
        model.runRoutine(routine.id)
        await model.waitUntilIdle()
        #expect(fixture.read("Raporlar/2026/Ocak/fatura.pdf") != nil)

        // Çoğaltma, kopyayı yeni bir rutin olarak düzenleme sayfasında açar.
        model.beginDuplicateRoutine(routine.id)
        let duplicate = try #require(model.routineEditor)
        #expect(!duplicate.isExisting && duplicate.routine.id != routine.id && duplicate.routine.name.contains("Ofis"))
        #expect(duplicate.routine.routes.map(\.id) != edited.routes.map(\.id))
        model.routineEditor = nil

        // Silme onay ister; işler kuyrukta kalır, rutinle bağları kopar.
        model.requestDeleteRoutine(routine.id)
        try #require(model.alert).action?()
        #expect(model.routines.isEmpty && model.selectedRoutineID == nil)
        #expect(model.jobs.count == 2 && model.jobs.allSatisfy { $0.routineID == nil })

        // Rutinler diske yazılır ve yeniden açılışta okunur.
        #expect(model.saveRoutine(officeRoutine(fixture)) == nil)
        #expect(fixture.relaunch().routines.map(\.name) == ["Ofis yedeği"])
    }

    /// Bekleyen ya da çalışan işi olan rota yeniden sıraya alınmaz; diski takılı değilken "disk takılınca başla" seçili rutin
    /// yine kaydedilir ve çalıştırılınca diskini bekler.
    @Test func runningRoutesAreNotDuplicatedAndDisksCanBeMissing() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        model.toggleQueueHold()
        let routine = officeRoutine(fixture)
        #expect(model.saveRoutine(routine) == nil)
        model.runRoutine(routine.id)
        model.runRoutine(routine.id)
        #expect(model.jobs.count == 2 && model.jobs.allSatisfy { $0.status == .waiting })

        var away = Routine(name: "Harici", routes: [RoutineRoute(source: fixture.url("Ofis"), destination: URL(fileURLWithPath: "/Volumes/CopiatorYok-\(UUID().uuidString)"))])
        #expect(model.saveRoutine(away) != nil)
        away.options.runWhenConnected = true
        #expect(model.saveRoutine(away) == nil)
        #expect(model.runRoutine(away.id) == nil)
        let waiting = try #require(model.jobs(for: away.id).first)
        #expect(model.isWaitingForDisk(waiting))
        model.toggleQueueHold()
        await model.waitUntilIdle()
        #expect(model.job(waiting.id)?.status == .waiting)
        #expect(model.jobs(for: routine.id).allSatisfy { $0.status == .finished })
    }

    @Test func previewRouteAndShortcuts() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        IntentTarget.model = { model }
        defer { IntentTarget.model = { AppModel.shared } }
        let routine = officeRoutine(fixture)
        let report = try #require(await model.previewRoute(routine.routes[1], of: routine))
        #expect(report.entries.filter { $0.kind == .missing && !$0.isDirectory }.map(\.path) == ["Tatil/IMG_1.HEIC"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url("Fotograflar").path).isEmpty)

        #expect(model.saveRoutine(routine) == nil)
        let entities = try await RoutineEntityQuery().suggestedEntities()
        #expect(entities.map(\.id) == [routine.id] && entities.first?.routeCount == 2)
        #expect(await IntentTarget.runRoutine(routine.id) == fixture.settings.t(.intentRoutineQueued, "Ofis yedeği"))
        await model.waitUntilIdle()
        #expect(model.jobs(for: routine.id).count == 2)
        #expect(await IntentTarget.runRoutine(UUID()) == fixture.settings.t(.intentRoutineNotFound))
    }

    @Test func rulesAreDescribedReadably() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings
        settings.language = .en
        let routine = officeRoutine(fixture)
        #expect(settings.describe(RuleGroup()) == "All files")
        #expect(settings.describe(routine.routes[1].rules) == "Folder name is “tatil” and Kind is “Image” and (none of: Name contains “kopya”)")
        settings.language = .tr
        #expect(settings.describe(RuleGroup(match: .any, conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "jpg"),
                                                                       RuleCondition(attribute: .fileExtension, op: .equals, value: "heic")]))
            == "Uzantı eşittir “jpg” veya Uzantı eşittir “heic”")
        #expect(settings.routineProblem(.missingSource(route: 1)) == "Rota 2: kaynak klasörü seçin.")
    }
}

/// Rutin görünümleri ekran dışı çizilir (ve uygulama penceresindeki gibi bir denetleyicide düzen döngüsü olmadan çalışır).
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct RoutineViewTests {
    @Test func editorDetailSidebarAndMenuBarRender() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let settings = fixture.settings
        await model.refreshEngine()
        var routine = Routine(name: "Ofis", routes: [
            RoutineRoute(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"), rules: RuleGroup(
                conditions: [RuleCondition(attribute: .name, op: .matchesRegex, value: #"^[a-z_]+_\d{4}-\d{2}-\d{2}_v\d+\.xlsx?$"#),
                             RuleCondition(attribute: .kind, op: .equals, value: "spreadsheet")],
                groups: [RuleGroup(match: .any, conditions: [RuleCondition(attribute: .folderName, op: .beginsWith, value: "20"),
                                                            RuleCondition(attribute: .name, op: .matchesRegex, value: "([bozuk")])])),
            RoutineRoute(source: fixture.url("Kaynak"), destination: fixture.url("Hedef")),
        ])
        routine.options.snapshots.enabled = true
        let render = { (view: AnyView, size: NSSize, name: String) in
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = host
            window.layoutIfNeeded()
            window.displayIfNeeded()
            spinRunLoop(0.3)
            if let directory = ProcessInfo.processInfo.environment["COPIATOR_SNAPSHOT_DIR"].map({ URL(fileURLWithPath: $0) }),
               let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
            }
            window.close()
        }
        render(AnyView(RoutineEditorSheet(request: RoutineEditorRequest(routine: routine, isExisting: true))
            .environment(model).environment(settings)), NSSize(width: 680, height: 1300), "routine-editor")
        routine.routes[0].rules.groups[0].conditions.removeLast()
        #expect(model.saveRoutine(routine) == nil)
        model.toggleQueueHold()
        model.runRoutine(routine.id)
        render(AnyView(ContentView().environment(model).environment(settings)), NSSize(width: 1080, height: 680), "routine-detail")
        render(AnyView(MenuBarContent().environment(model).environment(settings)), NSSize(width: 320, height: 320), "menubar-routines")
        model.selectedRoutineID = nil
        render(AnyView(ContentView().environment(model).environment(settings)), NSSize(width: 1080, height: 680), "queue-routines")
    }

    /// Rutin seçiliyken rutinin işi başlar ve biter: pencere düzeni kararlı kalır.
    @Test func runningARoutineFromItsDetailKeepsLayoutStable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        let controller = NSHostingController(rootView: ContentView().environment(model).environment(fixture.settings)
            .frame(minWidth: 820, minHeight: 520))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1080, height: 680))
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        defer { window.close() }
        spinRunLoop(0.5)
        let routine = Routine(name: "Metinler", routes: [RoutineRoute(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"),
            rules: RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "txt")]))])
        #expect(model.saveRoutine(routine) == nil)
        spinRunLoop(0.5)
        model.runRoutine(routine.id)
        spinRunLoop(2)
        await model.waitUntilIdle()
        spinRunLoop(0.5)
        #expect(fixture.read("Hedef/alt/b.txt") == "alt\n")
        #expect(model.jobs(for: routine.id).first?.status == .finished)
    }
}
