// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Testing
@testable import Copiator
@testable import CopiatorCore

@MainActor
struct QuitHoldTests {
    private func keyEvent(
        type: NSEvent.EventType,
        key: String = "q",
        keyCode: UInt16 = 12,
        modifiers: NSEvent.ModifierFlags = [.command],
        isRepeat: Bool = false
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: isRepeat,
            keyCode: keyCode
        ))
    }

    @Test func holdMachineLifecycle() {
        var machine = QuitHoldMachine()
        #expect(machine.keyDown(isRepeat: false, at: 10) == .show)
        #expect(machine.isHolding)
        #expect(machine.tick(at: 10.5) == .progress(0.5))
        #expect(machine.keyUp(at: 10.6) == .cancel)
        #expect(!machine.isHolding)
        #expect(machine.keyDown(isRepeat: true, at: 10.7) == .none)
        #expect(machine.keyDown(isRepeat: false, at: 10.7) == .show)
        #expect(machine.tick(at: 11.7) == .quit)
        #expect(machine.keyDown(isRepeat: false, at: 12) == .none)
        machine.reset()
        #expect(machine.keyDown(isRepeat: false, at: 13) == .show)
    }

    @Test func controllerHoldsAndQuits() throws {
        let suite = try TestDefaults("CopiatorQuitHold")
        defer { suite.remove() }
        let settings = AppSettings(defaults: suite.defaults)
        #expect(settings.confirmQuit)
        #expect(settings.holdToQuit)

        let controller = QuitHoldController(settings: settings)
        controller.showsPanel = false
        controller.canHandle = { true }
        controller.isRecordingShortcut = { false }
        controller.activeTransfers = { 2 }
        var time: TimeInterval = 100
        controller.now = { time }
        var quitCalledWith: Bool?
        controller.requestQuit = { quitCalledWith = $0 }

        // ⌘Q basılı tutulur: olay tüketilir (nil) ve gösterge açılır.
        let down = try keyEvent(type: .keyDown)
        #expect(controller.handle(down) == nil)
        #expect(controller.display.activeTransfers == 2)
        #expect(quitCalledWith == nil)

        // Erken bırakılınca vazgeçilir.
        time = 100.4
        controller.tick()
        #expect(controller.display.progress > 0.39 && controller.display.progress < 0.41)
        let up = try keyEvent(type: .keyUp)
        _ = controller.handle(up)
        #expect(quitCalledWith == nil)
        #expect(!controller.machine.isHolding)

        // Yeniden basılıp 1 saniye tutulursa çıkış istenir (confirmedByHold: true).
        time = 200
        #expect(controller.handle(down) == nil)
        time = 201.05
        controller.tick()
        #expect(quitCalledWith == true)
    }

    @Test func controllerRespectsDisabledHoldSettingAndRecording() throws {
        let suite = try TestDefaults("CopiatorQuitHoldOff")
        defer { suite.remove() }
        let settings = AppSettings(defaults: suite.defaults)
        settings.holdToQuit = false

        let controller = QuitHoldController(settings: settings)
        controller.showsPanel = false
        controller.canHandle = { true }
        controller.hasAttachedSheet = { false }
        controller.isRecordingShortcut = { false }

        let down = try keyEvent(type: .keyDown)
        // Ayar kapalı ve sayfa yokken olay AppKit menüsüne bırakılır.
        #expect(controller.handle(down) != nil)

        // Sayfa açıkken controller işler ve confirmedByHold: false ile çıkar.
        var quitCalledWith: Bool?
        controller.hasAttachedSheet = { true }
        controller.requestQuit = { quitCalledWith = $0 }
        #expect(controller.handle(down) == nil)
        #expect(quitCalledWith == false)

        // Kısayol kaydedilirken ⌘Q tutulmaz.
        settings.holdToQuit = true
        controller.isRecordingShortcut = { true }
        #expect(controller.handle(down) != nil)

        settings.confirmQuit = false
        settings.holdToQuit = false
        settings.resetAll()
        #expect(settings.confirmQuit)
        #expect(settings.holdToQuit)
    }
}
