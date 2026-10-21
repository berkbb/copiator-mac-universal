// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Hakkında penceresindeki lisanslar düzenlenebilir bir metin düzenleyicide değil, uygulama içinde salt okunur açılır.
@Suite(.serialized)
@MainActor
struct LicenseViewerTests {
    private func makeWorkspace() throws -> (root: URL, resources: URL, engine: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CopiatorLicenseTests-\(UUID().uuidString)", isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let engine = root.appendingPathComponent("Engine", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        return (root, resources, engine)
    }

    /// build_app.sh'ın pakete kopyaladığı dosyalar değiştirilmeden gösterilir.
    @Test func bundledFilesAreShownVerbatim() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        for (source, name) in [("LICENSE", "Copiator-License.txt"), ("THIRD_PARTY_NOTICES.md", "Third-Party-Notices.txt"),
                               ("Vendor/rsync/COPYING", "rsync-License.txt")] {
            try FileManager.default.copyItem(at: packageRoot.appendingPathComponent(source), to: workspace.resources.appendingPathComponent(name))
        }
        func original(_ path: String) throws -> String { try String(contentsOf: packageRoot.appendingPathComponent(path), encoding: .utf8) }
        let app = try #require(LicenseDocument.app.text(resources: workspace.resources, engineDirectory: workspace.engine))
        #expect(app == (try original("LICENSE")))
        #expect(app.contains("GNU GENERAL PUBLIC LICENSE") && app.contains("Version 3, 29 June 2007"))
        let notices = try #require(LicenseDocument.notices.text(resources: workspace.resources, engineDirectory: workspace.engine))
        #expect(notices == (try original("THIRD_PARTY_NOTICES.md")))
        #expect(notices.contains("MIT License") && notices.contains("Berk Babadoğan") && notices.contains("rsync"))
        let engine = try #require(LicenseDocument.engine.text(resources: workspace.resources, engineDirectory: workspace.engine))
        #expect(engine == (try original("Vendor/rsync/COPYING")))
        #expect(engine.contains("GNU GENERAL PUBLIC LICENSE"))
    }

    /// Güncellenen motorun kendi lisansı önceliklidir; o yoksa ya da boşsa paketteki gösterilir.
    @Test func enginePrefersUpdatedEngineLicense() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let bundled = workspace.resources.appendingPathComponent("rsync-License.txt")
        let updated = workspace.engine.appendingPathComponent("COPYING")
        try Data("bundled".utf8).write(to: bundled)
        try Data("updated\r\nline".utf8).write(to: updated)
        func text() -> String? { LicenseDocument.engine.text(resources: workspace.resources, engineDirectory: workspace.engine) }
        #expect(text() == "updated\nline")
        try Data().write(to: updated)
        #expect(text() == "bundled")
        try FileManager.default.removeItem(at: bundled)
        #expect(text() == nil)
        #expect(LicenseDocument.engine.fallbackURL == AppLinks.engineLicense)
        #expect(LicenseDocument.app.fallbackURL == nil && LicenseDocument.notices.fallbackURL == nil)
    }

    /// Görüntüleyicinin aradığı adlar, paketleyicinin kopyaladığı adlarla aynı kalmalı.
    @Test func buildScriptBundlesEveryLicenseFile() throws {
        let script = try String(contentsOf: packageRoot.appendingPathComponent("Scripts/build_app.sh"), encoding: .utf8)
        let resources = URL(fileURLWithPath: "/Resources")
        for document in LicenseDocument.allCases {
            let names = document.candidates(resources: resources, engineDirectory: URL(fileURLWithPath: "/Engine"))
                .filter { $0.deletingLastPathComponent().path == resources.path }.map(\.lastPathComponent)
            #expect(!names.isEmpty)
            for name in names { #expect(script.contains("Contents/Resources/\(name)"), "\(name)") }
        }
    }

    @Test func sheetRendersEveryDocument() throws {
        _ = NSApplication.shared
        let suite = "CopiatorLicense-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, bundle: .main)
        for document in LicenseDocument.allCases {
            let item = LicenseViewerItem(document: document, text: String(repeating: "Lorem ipsum dolor sit amet.\n", count: 400))
            let host = NSHostingView(rootView: LicenseViewerSheet(item: item).environment(settings))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.layoutIfNeeded()
            window.displayIfNeeded()
            #expect(host.fittingSize == NSSize(width: 640, height: 540), "\(document)")
            window.close()
        }
    }
}

/// Ana pencere görünümleri ekran dışı bir pencerede çizilir: ortam nesnesi eksikliği ya da düzen çökmesi yakalanır.
@Suite(.serialized)
@MainActor
struct ViewRenderTests {
    /// COPIATOR_SNAPSHOT_DIR verilirse her çizim o klasöre PNG olarak da yazılır (ekran kaydı izni gerekmeden
    /// arayüzü incelemek için).
    private static let snapshotDirectory = ProcessInfo.processInfo.environment["COPIATOR_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }

    private func render<V: View>(_ view: V, size: NSSize = NSSize(width: 1080, height: 680), name: String = "") {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.layoutIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if let directory = Self.snapshotDirectory, !name.isEmpty, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
        window.close()
    }

    @Test func mainWindowRendersEmptyAndWithJobs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        render(ContentView().environment(model).environment(fixture.settings), name: "welcome")
        model.toggleQueueHold()
        fixture.addJob()
        fixture.addJob(options: CopyOptions(copyMode: .contents, deleteExtraneous: true))
        model.pause([model.jobs[1].id])
        model.selection = [model.jobs[0].id]
        model.operation = OperationState(titleKey: .progressVerifying, progress: 0.3)
        model.toast = Toast(message: "x", systemImage: "checkmark", revealURL: nil)
        render(ContentView().environment(model).environment(fixture.settings), name: "overlay")
        model.operation = nil
        model.toast = nil
        render(ContentView().environment(model).environment(fixture.settings), name: "queue")
        for filter in JobFilter.allCases {
            model.filter = filter
            render(ContentView().environment(model).environment(fixture.settings))
        }
    }

    @Test func sheetsAndSettingsRender() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let settings = fixture.settings
        render(NewJobSheet(request: NewJobRequest(source: fixture.url("Kaynak"), destination: fixture.url("Hedef")))
            .environment(model).environment(settings), size: NSSize(width: 560, height: 640), name: "newjob")
        let report = VerifyReport(entries: [
            DiffEntry(kind: .missing, path: "a/b.txt", isDirectory: false, code: ">f+++++++++"),
            DiffEntry(kind: .extra, path: "a/eski", isDirectory: true, code: "*deleting"),
            DiffEntry(kind: .attributes, path: "a", isDirectory: true, code: ".d..t......"),
        ], result: JobResult(kind: .succeeded), checksum: true)
        render(VerifyResultSheet(presentation: VerifyPresentation(jobID: UUID(), jobName: "Kaynak", report: report))
            .environment(settings), size: NSSize(width: 640, height: 480), name: "verify")
        render(SettingsView().environment(model).environment(settings), size: NSSize(width: 580, height: 520), name: "settings")
        render(AboutView().environment(model).environment(settings), size: NSSize(width: 540, height: 560), name: "about")

        // Gelişmiş seçenekler varsayılanı değiştirilmişse Yeni İş sayfası onları açık gösterir (tüm denetimler çizilir).
        settings.defaultAdvanced.hardLinks = true
        settings.defaultAdvanced.referenceMode = .linkDest
        settings.defaultAdvanced.keepBackups = true
        settings.defaultAdvanced.batchMode = .write
        settings.defaultAdvanced.maxDelete = 10
        settings.defaultAdvanced.stopAt = Date().addingTimeInterval(3600)
        render(NewJobSheet(request: NewJobRequest(source: fixture.url("Kaynak"), destination: fixture.url("Hedef")))
            .environment(model).environment(settings), size: NSSize(width: 620, height: 1600), name: "newjob-advanced")
        render(PowerStatusBanner(
            status: SleepGuard.Status(systemSleepPrevented: true, displaySleepPrevented: false),
            advice: [.batteryLow, .lowPowerMode, .lidClosesSleep, .displayMaySleep],
            snapshot: PowerSnapshot(source: .battery, hasBattery: true, batteryPercent: 15, lowPowerMode: true),
            settings: settings
        ), size: NSSize(width: 700, height: 160), name: "power")
        render(CommandPreview(command: "rsync -rltDhX --info=progress2 --partial -H -- /a/ /b/").environment(settings),
               size: NSSize(width: 500, height: 120), name: "command")
        render(Form { SandboxLimitsSection() }.formStyle(.grouped).environment(settings),
               size: NSSize(width: 620, height: 640), name: "sandbox-limits")
        #expect(SandboxLimitsSection.items.count == 5)
    }
}

/// Ayrıntılar paneli iş yokken görünmez (karşılama ekranını daraltmasın); kullanıcının tercihi korunur.
@Suite(.serialized)
@MainActor
struct InspectorTests {
    @Test func inspectorIsHiddenWithoutJobsAndKeepsThePreference() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.showInspector = true
        #expect(!model.isInspectorVisible)
        // İş yokken açma/kapama hiçbir şey yapmaz; sistemin kapatma isteği tercihi silmez.
        model.toggleInspector()
        model.isInspectorVisible = false
        #expect(model.showInspector)

        model.toggleQueueHold()
        fixture.addJob()
        #expect(model.isInspectorVisible)
        model.toggleInspector()
        #expect(!model.showInspector && !model.isInspectorVisible)
        model.isInspectorVisible = true
        #expect(model.showInspector)

        // Son iş kaldırılınca panel kaybolur; tercih yine korunur.
        model.remove(Set(model.jobs.map(\.id)))
        #expect(!model.isInspectorVisible)
        #expect(model.showInspector)
    }
}
