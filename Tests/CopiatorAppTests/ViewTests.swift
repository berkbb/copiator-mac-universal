// SPDX-License-Identifier: GPL-3.0-only
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
        #expect(notices.contains("GPL-3.0-only") && notices.contains("Babadogan Tech and Edu") && notices.contains("rsync"))
        #expect(!notices.contains("Permission is hereby granted, free of charge"))
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
        // Pencere arka planı görünümün altına çizilir: PNG'de koyu kipteki açık renkli metin saydam zeminde kaybolmasın.
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
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

    /// Anlık görüntü, otomasyon ve önizleme; düzenleme sayfası; menü çubuğu penceresi; geçmiş listesi.
    @Test func automationViewsRender() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let settings = fixture.settings
        await model.refreshEngine()
        var options = CopyOptions(verifyAfterCopy: .checksum, runWhenConnected: true)
        options.snapshots = SnapshotOptions(enabled: true, keepLast: 10, keepDaily: 7, keepMonthly: 12)
        options.advanced.excludePresets = [.developer, .macOSJunk]
        model.toggleQueueHold()
        let id = try #require(fixture.addJob(options: options))
        render(NewJobSheet(request: NewJobRequest(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"), options: options, editing: id))
            .environment(model).environment(settings), size: NSSize(width: 620, height: 1100), name: "editjob")

        let entries = [
            DiffEntry(kind: .missing, path: "Kaynak/yeni.txt", isDirectory: false, code: ">f+++++++++"),
            DiffEntry(kind: .changed, path: "Kaynak/degisen.txt", isDirectory: false, code: ">f.st......"),
            DiffEntry(kind: .extra, path: "Kaynak/eski", isDirectory: true, code: "*deleting"),
        ]
        for deleting in [true, false] {
            let report = VerifyReport(entries: entries, result: JobResult(kind: .succeeded), checksum: false)
            render(PreviewSheet(presentation: PreviewPresentation(jobName: "Kaynak", report: report, deleteEnabled: deleting))
                .environment(settings), size: NSSize(width: 660, height: 500), name: deleting ? "preview-delete" : "preview")
        }

        var job = try #require(model.job(id))
        job.startedAt = Date(timeIntervalSinceNow: -120)
        job.progress = TransferProgress(bytesTransferred: 1 << 30, fraction: 1, filesTransferred: 1200)
        JobQueue.finish(&job, with: JobResult(kind: .succeeded, snapshot: SnapshotStore.name(for: Date()), differenceCount: 0))
        JobQueue.finish(&job, with: JobResult(kind: .verificationFailed, differenceCount: 4))
        render(ScrollView { JobHistoryList(job: job, settings: settings).padding() }, size: NSSize(width: 360, height: 300), name: "history")
        render(MenuBarContent().environment(model).environment(settings), size: NSSize(width: 320, height: 240), name: "menubar")
        model.selection = [id]
        render(ContentView().environment(model).environment(settings), name: "inspector-automation")
    }

    /// Anlık görüntü karşılaştırması ve arama sonuçları, izin bantları, Ayarlar'daki izin satırları ve "Girişte aç"
    /// her durumda çizilir.
    @Test func snapshotAndPermissionViewsRender() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let settings = fixture.settings
        try fixture.write("Yedek/2026-11-01-100000/Kaynak/eski.txt", "eski")
        try fixture.write("Yedek/2026-11-02-100000/Kaynak/yeni.txt", "yeni")
        let job = TransferJob(source: fixture.url("Kaynak"), destination: fixture.url("Yedek"),
                              options: CopyOptions(snapshots: SnapshotOptions(enabled: true)))
        let snapshots = SnapshotRestore.snapshots(of: job)
        #expect(snapshots.count == 2)
        for list in [snapshots, Array(snapshots.prefix(1))] {
            render(SnapshotCompareView(job: job, snapshots: list, previewURL: .constant(nil)).environment(settings),
                   size: NSSize(width: 580, height: 420), name: list.count == 2 ? "snapshot-compare" : "")
        }
        let results = SnapshotSearch.search("txt", in: snapshots, job: job)
        for found in [results, SnapshotSearch.Results(hits: [], isTruncated: false), SnapshotSearch.Results(hits: results.hits, isTruncated: true)] {
            render(SnapshotSearchResultsView(results: found, open: { _ in }).environment(settings),
                   size: NSSize(width: 580, height: 300), name: found.isTruncated ? "snapshot-search" : "")
        }
        model.notificationPermission = .denied
        model.fullDiskAccessGranted = false
        model.homeDirectory = fixture.url("Kaynak")
        fixture.addJob()
        for state in [LoginItemState.off, .on, .needsApproval] {
            model.loginItemState = state
            render(Form { OpenAtLoginRow() }.formStyle(.grouped).environment(model).environment(settings),
                   size: NSSize(width: 560, height: 200), name: state == .needsApproval ? "login-approval" : "")
        }
        render(Form { PermissionStatusSection() }.formStyle(.grouped).environment(model).environment(settings),
               size: NSSize(width: 560, height: 260), name: "settings-permissions")
        #expect(model.permissionBanners == [.notifications, .fullDiskAccess])
        render(PermissionBanners().environment(model).environment(settings), size: NSSize(width: 900, height: 200), name: "permission-banners")
    }

    @Test func fillForecastRenders() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let id = try #require(fixture.addJob())
        await fixture.model.waitUntilIdle()
        let job = try #require(fixture.model.job(id))
        render(ScrollView { FillForecastView(job: job).padding() }.environment(fixture.model).environment(fixture.settings),
               size: NSSize(width: 340, height: 260), name: "fill-forecast")
        // Şifresiz hedef disk: uyarı panelde ve hedef özetinde çizilir.
        fixture.model.volumeEncryption = { _ in false }
        render(ScrollView { FillForecastView(job: job).padding() }.environment(fixture.model).environment(fixture.settings),
               size: NSSize(width: 340, height: 360), name: "fill-forecast-unencrypted")
        let summary = DestinationSummary(totalCapacity: 1 << 40, availableCapacity: 1 << 39, isEncrypted: false)
        render(DestinationSummarySheet(request: DestinationSummaryRequest(destination: fixture.url("Hedef")), summary: summary)
            .environment(fixture.settings), size: NSSize(width: 560, height: 560), name: "summary-unencrypted")
    }

    /// Arşivde arama: üç eşleşme türü (ad, içerik, fotoğraf bilgisi), sınır notu ve boş sonuç.
    @Test func archiveSearchSheetRenders() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var results = ArchiveSearch.Results(hits: [
            ArchiveSearch.Hit(relativePath: "Tapu/Isparta tapu.pdf", match: .name, snippet: "", size: 120_000, modified: nil),
            ArchiveSearch.Hit(relativePath: "Faturalar/2026/El_10_26.pdf", match: .content, snippet: "…ENERJİSA elektrik faturası…",
                              size: 48_000, modified: nil),
            ArchiveSearch.Hit(relativePath: "Foto/IMG_0001.jpg", match: .photo, snippet: "2026-08-15 14:03 · iPhone", size: 2_400_000, modified: nil),
        ], limited: true, scanned: 1_204)
        let request = ArchiveSearchRequest(destination: fixture.url("Hedef"))
        render(ArchiveSearchSheet(request: request, query: "fatura", results: results).environment(fixture.model).environment(fixture.settings),
               size: NSSize(width: 680, height: 560), name: "archive-search")
        results.hits = []
        render(ArchiveSearchSheet(request: request, query: "yok", results: results).environment(fixture.model).environment(fixture.settings),
               size: NSSize(width: 680, height: 560), name: "archive-search-empty")
    }

    @Test func diagnosticSheetRenders() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        render(DiagnosticSheet(presentation: DiagnosticPresentation(text: fixture.model.diagnosticReport()))
            .environment(fixture.settings), size: NSSize(width: 720, height: 560), name: "diagnostics")
    }

    /// İşleri ve ayarları içe aktarma sayfası: bulunmayan klasörler ve ayar seçeneğiyle, ayarsız dosyada seçeneksiz çizilir.
    @Test func setupImportSheetRenders() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let jobs = [
            TransferJob(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"), status: .paused),
            TransferJob(source: fixture.url("Yok/Kaynak"), destination: fixture.url("Yok/Hedef"), status: .paused),
        ]
        for settings in [PortableSettings(fixture.settings), nil] {
            render(SetupImportSheet(request: SetupImportRequest(jobs: jobs, settings: settings))
                .environment(fixture.model).environment(fixture.settings),
                   size: NSSize(width: 640, height: 520), name: settings == nil ? "" : "setup-import")
        }
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

/// Anlık görüntü arama sonucunun ekran okuyucu adı yolu ve kaç anlık görüntüde olduğunu söyler.
@Suite(.serialized)
@MainActor
struct SnapshotSearchAccessibilityTests {
    @Test func resultLabelNamesThePathAndSnapshots() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings
        settings.language = .tr
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = SnapshotRestore.Snapshot(name: "2026-11-02-100000", date: date, url: fixture.url("Yedek/2026-11-02-100000"))
        let hit = SnapshotSearch.Hit(relativePath: "Tatil/foto.jpg", isDirectory: false, snapshots: [snapshot, snapshot])
        #expect(SnapshotSearchResultsView.label(hit, settings: settings) == "Tatil/foto.jpg, " + settings.t(.snapshotsSearchHit, 2, settings.date(date)))
        let bare = SnapshotSearch.Hit(relativePath: "Tatil", isDirectory: true, snapshots: [])
        #expect(SnapshotSearchResultsView.label(bare, settings: settings) == "Tatil")
    }
}
