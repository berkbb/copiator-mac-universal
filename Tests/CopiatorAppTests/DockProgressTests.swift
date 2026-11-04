// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Testing
import UserNotifications
@testable import Copiator
@testable import CopiatorCore

/// Dock simgesinin yerine geçen sahte yüzey: kaç kez çizildiğini sayar.
private final class FakeDockTile: DockTileSurface {
    let size = NSSize(width: 128, height: 128)
    var badgeLabel: String?
    var contentView: NSView?
    var displays = 0
    func display() { displays += 1 }
}

/// Dock simgesi: iş çalışırken çizilmiş bir ilerleme çubuğu ve kopyalama hızı, boştayken ve kapalıyken hiçbir şey; sayı
/// rozeti yok. Sistemin ilerleme denetimi Dock'ta görünmediği için (2026-11-04 elle denemesi) çubuk kendisi çizilir.
@MainActor
struct DockProgressTests {
    @Test func showsBarAndSpeedWhileActiveAndClearsThemWhenIdle() throws {
        let tile = FakeDockTile()
        let dock = DockProgress(tile: tile)
        dock.update(fraction: nil, active: false, enabled: true)
        #expect(tile.badgeLabel == nil && tile.contentView == nil)
        dock.update(fraction: 0.006, active: true, enabled: true, speed: "→ 25,0 MB/sn")
        #expect(tile.badgeLabel == nil, "sayı rozeti yok")
        let view = try #require(tile.contentView as? DockTileView)
        #expect(view.state == DockTileState(showsBar: true, percent: 1, speed: "→ 25,0 MB/sn"))
        dock.update(fraction: nil, active: true, enabled: true)
        #expect(view.state == DockTileState(showsBar: true, percent: nil, speed: nil))
        dock.update(fraction: 0.5, active: false, enabled: true, speed: "→ 25,0 MB/sn")
        #expect(tile.badgeLabel == nil && tile.contentView == nil)
    }

    @Test func turnedOffShowsNothing() {
        let tile = FakeDockTile()
        DockProgress(tile: tile).update(fraction: 0.5, active: true, enabled: false, speed: "→ 1 MB/sn")
        #expect(tile.badgeLabel == nil && tile.contentView == nil)
    }

    @Test func redrawsOnlyWhenSomethingVisibleChanges() {
        let tile = FakeDockTile()
        let dock = DockProgress(tile: tile)
        for _ in 0..<5 { dock.update(fraction: 0.006, active: true, enabled: true, speed: "→ 7,4 MB/sn") }
        #expect(tile.displays == 1)
        dock.update(fraction: 0.006, active: true, enabled: true, speed: "→ 7,5 MB/sn")
        #expect(tile.displays == 2)
    }

    /// Bildirimlere kaydolmuş uygulamanın Dock simgesi içeriği yalnızca simge göstergesi izniyle görünür: izin isteği
    /// rozeti de içermelidir.
    @Test func notificationPermissionIncludesTheBadge() {
        #expect(AppModel.notificationOptions.contains(.badge))
        #expect(AppModel.notificationOptions.contains(.alert) && AppModel.notificationOptions.contains(.sound))
    }

    /// Çalışan işin hızı biçimlendirilir; çalışan iş yokken ya da kopyalama başlamadan hız yoktur.
    @Test func runningSpeedFollowsTheRunningJob() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        #expect(model.runningSpeedText == nil)
        await model.refreshEngine()
        fixture.addJob()
        await model.waitUntilIdle()
        #expect(model.runningSpeedText == nil)
    }

    /// Çubuk ve kutucuk gerçekten çizilir: parlak yeşil dolgu altta, %0'da bile yuvarlak uç; hız kutucuğu üstte, içi koyu;
    /// simgenin üst kısmı açık kalır.
    @Test func drawsABrightBarAndASpeedPill() throws {
        func render(_ state: DockTileState) throws -> NSBitmapImageRep {
            let view = DockTileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
            view.state = state
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        func isBrightGreen(_ color: NSColor?) -> Bool {
            guard let color = color?.usingColorSpace(.sRGB) else { return false }
            return color.greenComponent > 0.8 && color.redComponent < 0.8 && color.blueComponent < 0.6
        }
        let scale = { (rep: NSBitmapImageRep) in CGFloat(rep.pixelsWide) / 128 }
        // Bitmap y ekseni yukarıdan aşağıdır: çubuk 8–30 pt'de (aşağıdan), ortası yukarıdan 109 pt.
        let empty = try render(DockTileState(showsBar: true, percent: 0))
        let barY = Int(109 * scale(empty))
        #expect(isBrightGreen(empty.colorAt(x: Int(18 * scale(empty)), y: barY)), "%0'da yuvarlak dolgu ucu")
        #expect(!isBrightGreen(empty.colorAt(x: Int(100 * scale(empty)), y: barY)))
        let half = try render(DockTileState(showsBar: true, percent: 50, speed: "→ 25,0 MB/sn"))
        #expect(isBrightGreen(half.colorAt(x: Int(50 * scale(half)), y: barY)))
        #expect(!isBrightGreen(half.colorAt(x: Int(100 * scale(half)), y: barY)))
        // Hız kutucuğu çubuğun üstünde (34–58 pt aşağıdan): içi koyu.
        let pillCenterY = Int((128 - 46) * scale(half))
        let inside = try #require(half.colorAt(x: Int(10 * scale(half)), y: pillCenterY)?.usingColorSpace(.sRGB))
        #expect(inside.brightnessComponent < 0.35)
        // Simgenin üst kısmı (yukarıdan 40 pt) çizimden etkilenmez.
        let plain = try render(DockTileState())
        for y in stride(from: 0, to: Int(40 * scale(half)), by: 4) {
            #expect(half.colorAt(x: Int(110 * scale(half)), y: y) == plain.colorAt(x: Int(110 * scale(plain)), y: y))
        }
    }
}
