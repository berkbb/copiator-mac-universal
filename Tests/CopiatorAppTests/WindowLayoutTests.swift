// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Ana iş parçacığının çalışma döngüsünü döndürür: görüntüleme döngüsü ve kısıt güncellemeleri gerçekten çalışır.
@MainActor func spinRunLoop(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// Ana pencere, uygulamadaki gibi bir pencere denetleyicisinde (pencere en küçük boyutu içerikten alır, araç çubuğu
/// köprülenir) ve görüntüleme döngüsü çalışırken. Bölünmüş görünümün bir sütununun en küçük boyutu kendi genişliğine
/// bağlı olursa AppKit kısıtları sonsuz döngüde yeniden hesaplar ve uygulamayı "more Update Constraints in Window passes
/// than there are views in the window" istisnasıyla sonlandırır; bu durumda test süreci de çöker.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct WindowLayoutTests {
    private func makeWindow(_ fixture: Fixture) -> NSWindow {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: ContentView()
            .environment(fixture.model)
            .environment(fixture.settings)
            .frame(minWidth: 820, minHeight: 520))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1080, height: 680))
        // Ekranın dışında: test sırasında pencere görünmez, ama düzen ve kısıt geçişleri yine çalışır.
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        return window
    }

    /// Kullanıcının bildirdiği çökme: boş kuyruğa Yeni İş sayfasından ilk iş (tek bir dosya) eklenince iş başlar, liste
    /// üstünde uyku ve güç bandı belirir, ayrıntılar paneli açılır.
    @Test(arguments: [true, false])
    func addingAndRunningTheFirstJobKeepsLayoutStable(fileSource: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        try fixture.write("Şirket/Dekont1.pdf", String(repeating: "pdf", count: 4096))
        let window = makeWindow(fixture)
        defer { window.close() }
        spinRunLoop(0.5)
        let source = fileSource ? fixture.url("Şirket/Dekont1.pdf") : fixture.url("Kaynak")
        model.newJobRequest = NewJobRequest(source: source, destination: fixture.url("Hedef"))
        spinRunLoop(1)
        #expect(model.addJob(source: source, destination: fixture.url("Hedef"), options: CopyOptions()) == nil)
        model.newJobRequest = nil
        spinRunLoop(2)
        await model.waitUntilIdle()
        spinRunLoop(0.5)
        #expect(model.jobs.first?.status == .finished)
    }

    /// macOS'un kendi rsync'i (kısıtlı kip): kenar çubuğunun altında motor uyarısı görünürken iş eklenip çalışır.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/rsync")))
    func limitedEngineWarningInTheSidebar() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        fixture.settings.customEnginePath = "/usr/bin/rsync"
        await model.refreshEngine()
        guard case .ready(_, true) = model.engineStatus else { return }
        let window = makeWindow(fixture)
        defer { window.close() }
        spinRunLoop(0.5)
        fixture.addJob()
        spinRunLoop(1.5)
        await model.waitUntilIdle()
        for width in stride(from: 1080, through: 820, by: -65) {
            window.setContentSize(NSSize(width: CGFloat(width), height: 520))
            spinRunLoop(0.1)
        }
        let job = try #require(model.jobs.first)
        #expect(job.status == .finished, "\(String(describing: job.result))")
    }

    /// Uzun güç önerileri (pil, Düşük Güç Modu, kapak, ekran) ve dar pencere: bant yine tek satırlıktır.
    @Test func longPowerAdviceInANarrowWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        // Bant çizimini sınar: kritik pilde işin hiç başlamaması (bkz. BatteryPauseTests) burada kapatılır.
        fixture.settings.pauseOnCriticalBattery = false
        model.powerProvider = { PowerSnapshot(source: .battery, hasBattery: true, batteryPercent: 8, lowPowerMode: true) }
        try fixture.writeLargeFile("Kaynak/buyuk.bin", megabytes: 256)
        let window = makeWindow(fixture)
        defer { window.close() }
        spinRunLoop(0.5)
        let id = try #require(fixture.addJob())
        for width in stride(from: 1080, through: 820, by: -40) {
            window.setContentSize(NSSize(width: CGFloat(width), height: 520))
            spinRunLoop(0.1)
        }
        #expect(model.powerAdvice.count >= 3)
        model.pause([id])
        await model.waitUntilIdle()
        spinRunLoop(0.3)
    }
}
