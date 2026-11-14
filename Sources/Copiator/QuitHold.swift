// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CopiatorCore
import Observation
import SwiftUI

// MARK: - Çıkmak için ⌘Q'yu basılı tut (Chromium tarayıcılarındaki gibi)

/// ⌘Q basılı tutma durumu; saat dışarıdan verilir (testler). ⌘Q'ya basılınca gösterge açılır, ⌘Q `holdDuration` boyunca
/// basılı kalırsa çıkılır; Q ya da ⌘ erken bırakılırsa, uygulama arka plana geçerse vazgeçilir. Tuş tekrarı yeni bir
/// basılı tutma başlatmaz: vazgeçildikten sonra hâlâ basılı olan tuşlar bırakılıp yeniden basılmalıdır.
struct QuitHoldMachine: Equatable {
    static let holdDuration: TimeInterval = 1.0

    enum Phase: Equatable {
        case idle
        case holding(since: TimeInterval)
        /// Basılı tutma tamamlandı; çıkış istendi (yeni basışlar yok sayılır).
        case confirmed
    }

    enum Effect: Equatable {
        case none
        /// Gösterge açılır (ilerleme 0).
        case show
        case progress(Double)
        /// Gösterge kapanır (solarak).
        case cancel
        /// Basılı tutma onay sayılır: çıkılır.
        case quit
    }

    private(set) var phase: Phase = .idle

    var isHolding: Bool { if case .holding = phase { true } else { false } }

    /// ⌘Q basıldı (yalnızca ⌘ ile).
    mutating func keyDown(isRepeat: Bool, at now: TimeInterval) -> Effect {
        switch phase {
        case .idle:
            guard !isRepeat else { return .none }
            phase = .holding(since: now)
            return .show
        case .holding:
            return tick(at: now)
        case .confirmed:
            return .none
        }
    }

    /// Q bırakıldı.
    mutating func keyUp(at now: TimeInterval) -> Effect { cancel() }

    /// ⌘ bırakıldı (Q hâlâ basılı olsa da).
    mutating func commandReleased(at now: TimeInterval) -> Effect { cancel() }

    /// Uygulama etkinliğini yitirdi, bir pencere ya da kalıcı panel araya girdi.
    mutating func interrupted() -> Effect { cancel() }

    /// Zamanlayıcı: ilerleme ya da süre dolduysa çıkış.
    mutating func tick(at now: TimeInterval) -> Effect {
        guard case .holding(let since) = phase else { return .none }
        let fraction = max(0, now - since) / Self.holdDuration
        if fraction >= 1 {
            phase = .confirmed
            return .quit
        }
        return .progress(fraction)
    }

    /// Çıkış gerçekleşmedi (ör. vazgeçildi): yeni bir basılı tutma yapılabilir.
    mutating func reset() { phase = .idle }

    private mutating func cancel() -> Effect {
        guard isHolding else { return .none }
        phase = .idle
        return .cancel
    }
}

/// Göstergenin içeriği (SwiftUI görünümü okur).
@Observable
final class QuitHoldDisplay {
    var progress: Double = 0
    var activeTransfers = 0
}

/// ⌘Q için yerel olay izleyicisi, gösterge paneli ve zamanlayıcı. Ayar kapalıyken ⌘Q, Çık menü öğesine gider; yalnızca bir
/// pencereye bağlı sayfa (sheet) açıkken burada işlenir: AppKit sayfa açıkken `terminate:`'i sessizce reddeder, bu yüzden
/// onaydan sonra sayfalar kapatılıp çıkılır.
@MainActor
final class QuitHoldController {
    let settings: AppSettings
    let display = QuitHoldDisplay()
    private(set) var machine = QuitHoldMachine()
    /// Saat (testler verir).
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Etkin yedekleme/işlem sayısı (göstergedeki satır).
    var activeTransfers: () -> Int = { 0 }
    /// Çıkış isteği: `true` basılı tutmayla onaylandı (onay penceresi gösterilmez), `false` onay gerekiyorsa sorulur.
    var requestQuit: (Bool) -> Void = { _ in }
    /// Olay işlenebilir mi: kalıcı bir panel (NSAlert, çıkış penceresi, açma paneli) açıkken ya da çıkılırken ⌘Q AppKit'e
    /// bırakılır.
    var canHandle: () -> Bool = { NSApp.modalWindow == nil }
    /// Bir pencereye bağlı sayfa açık mı.
    var hasAttachedSheet: () -> Bool = { NSApp.windows.contains { $0.attachedSheet != nil } }
    /// Ayarlar › Kısayollar bir kısayol kaydediyor mu.
    var isRecordingShortcut: () -> Bool = { ShortcutsSettingsView.isRecording }
    /// Gösterge (testlerde false: panel açılmaz).
    var showsPanel = true

    private var monitor: Any?
    private var timer: Timer?
    private var panel: NSPanel?
    private var resignObserver: NSObjectProtocol?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handle(event) ?? event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.apply(self?.machine.interrupted() ?? .none) }
        }
    }

    /// ⌘Q (başka değiştirici tuş olmadan). Q, Latin olmayan klavye düzenlerinde tuş koduyla tanınır.
    static func isCommandQ(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        return modifiers == .command && isQ(event)
    }

    static func isQ(_ event: NSEvent) -> Bool {
        let characters = (event.charactersIgnoringModifiers ?? "").lowercased()
        if characters == "q" { return true }
        return event.keyCode == 12 && !characters.contains(where: \.isASCII)
    }

    /// Olayı işler; nil: olay tüketildi (menüye gitmez).
    func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            guard Self.isCommandQ(event), canHandle(), !isRecordingShortcut() else { return event }
            guard settings.holdToQuit else {
                // Çık menü öğesi gibi; yalnızca sayfa açıkken burada (AppKit reddederdi).
                guard hasAttachedSheet() else { return event }
                if !event.isARepeat { requestQuit(false) }
                return nil
            }
            apply(machine.keyDown(isRepeat: event.isARepeat, at: now()))
            return nil
        case .keyUp:
            if Self.isQ(event) { apply(machine.keyUp(at: now())) }
            return event
        case .flagsChanged:
            if !event.modifierFlags.contains(.command) { apply(machine.commandReleased(at: now())) }
            return event
        default:
            return event
        }
    }

    /// Zamanlayıcının adımı (testler doğrudan çağırır).
    func tick() {
        apply(machine.tick(at: now()))
    }

    /// Çıkış gerçekleşmedi (vazgeçildi): sonraki ⌘Q yeniden basılı tutmayla çalışır.
    func quitDidNotHappen() {
        machine.reset()
    }

    func apply(_ effect: QuitHoldMachine.Effect) {
        switch effect {
        case .none:
            break
        case .show:
            display.progress = 0
            display.activeTransfers = activeTransfers()
            showPanel()
            startTimer()
        case .progress(let value):
            display.progress = value
        case .cancel:
            stopTimer()
            hidePanel(animated: true)
        case .quit:
            display.progress = 1
            stopTimer()
            hidePanel(animated: false)
            requestQuit(true)
        }
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Gösterge paneli

    private func showPanel() {
        guard showsPanel else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let host = panel.contentView {
            panel.setContentSize(host.fittingSize)
        }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: settings.t(.quitHoldTitle), .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func hidePanel(animated: Bool) {
        guard let panel, panel.isVisible else { return }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.machine.isHolding != true { panel.orderOut(nil) }
                panel.alphaValue = 1
            }
        })
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: QuitHoldHUD(display: display, settings: settings))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

/// Ekranın ortasındaki gösterge: "Copiator'dan çıkmak için ⌘Q'yu basılı tutun", dolan bir halka ve etkin iş varsa kısa bir satır.
struct QuitHoldHUD: View {
    let display: QuitHoldDisplay
    let settings: AppSettings
    static let width: CGFloat = 380

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.3), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: display.progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "power")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)
            Text(settings.t(.quitHoldTitle))
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if display.activeTransfers > 0 {
                Text(settings.t(.quitHoldActive, display.activeTransfers))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("copiator.quitHold")
    }
}
