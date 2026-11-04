// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CopiatorCore
import SwiftUI

/// Menü çubuğu penceresi: çalışan işin ilerlemesi, sıradaki işler, tümünü duraklat/sürdür, pencereyi aç, çık.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let id = model.runningJobID, let job = model.job(id) {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: job.source.path))
                        .resizable()
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                    Text(OpenSafety.visibleName(job.source.lastPathComponent))
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    StatusBadge(job: job, settings: settings, isPausing: model.isPausingRunningJob)
                }
                if let fraction = model.runningFraction {
                    ProgressView(value: fraction)
                    Text(progressLine(job, fraction: fraction))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            } else {
                Label(settings.t(.menuBarIdle), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            let awaiting = model.jobsAwaitingDecision
            if let first = awaiting.first {
                Button {
                    model.presentMainWindow()
                    model.conflictPrompt = ConflictPrompt(id: first.id)
                } label: {
                    Label(settings.t(.menuBarAwaiting, awaiting.count), systemImage: "doc.on.doc.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
            }
            let waiting = model.jobs.lazy.filter { $0.status == .waiting }.count
            if waiting > 0 {
                Text(settings.t(.menuBarWaiting, waiting))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.routines.isEmpty {
                Divider()
                Text(settings.t(.menuBarRoutines)).font(.caption).foregroundStyle(.secondary)
                ForEach(model.routines.prefix(6)) { routine in
                    Button {
                        model.runRoutine(routine.id)
                    } label: {
                        Label(OpenSafety.visibleName(routine.name), systemImage: "play.circle")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .help(settings.t(.routineRun))
                }
            }
            Divider()
            HStack {
                Button(settings.t(.menuPauseAll), systemImage: "pause.fill") { model.pauseAll() }
                    .disabled(!model.jobs.contains(where: JobQueue.canPause))
                Button(settings.t(.menuResumeAll), systemImage: "play.fill") { model.resumeAll() }
                    .disabled(!model.jobs.contains(where: JobQueue.canResume))
            }
            Divider()
            HStack {
                Button(settings.t(.menuBarOpen)) { model.presentMainWindow() }
                Spacer()
                Button(settings.t(.menuBarQuit)) { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func progressLine(_ job: TransferJob, fraction: Double) -> String {
        var parts = [settings.t(.menuBarProgress, settings.percent(fraction))]
        if let progress = job.progress {
            if let rate = progress.bytesPerSecond, rate > 0 { parts.append(settings.t(.progressSpeed, settings.bytes(Int64(rate)))) }
            if let remaining = progress.remainingSeconds, !progress.isEstimating {
                parts.append(settings.t(.progressRemaining, settings.duration(seconds: remaining)))
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Menü çubuğu simgesi: iş çalışırken dönen oklar.
struct MenuBarLabel: View {
    let isRunning: Bool
    let title: String

    var body: some View {
        Image(systemName: isRunning ? "arrow.triangle.2.circlepath.circle.fill" : "externaldrive.badge.timemachine")
            .accessibilityLabel(title)
    }
}

/// Dock simgesinin yüzeyi (`NSDockTile`); testlerde sahtesi verilir.
protocol DockTileSurface: AnyObject {
    var size: NSSize { get }
    var badgeLabel: String? { get set }
    var contentView: NSView? { get set }
    func display()
}

extension NSDockTile: DockTileSurface {}

/// Dock simgesinde gösterilenler: çalışan işin ilerlemesi (nil: belirsiz) ve kopyalama hızı. Sayı rozeti yoktur:
/// bekleyen işler menü çubuğu penceresinde ve kenar çubuğundadır. Bildirimlere kaydolmuş bir uygulamanın simgesine
/// çizilen içerik macOS 26'da yalnızca bildirim ayarlarında simge göstergesi açıkken görünür (bkz.
/// `AppModel.notificationOptions`).
struct DockTileState: Equatable {
    var showsBar = false
    var percent: Int?
    var speed: String?

    var isEmpty: Bool { !showsBar && speed == nil }
}

/// Dock simgesinde çalışan işin ilerleme çubuğu ve kopyalama hızı. Sistemin ilerleme denetimi (`NSProgressIndicator`)
/// Dock simgesinde görünmüyordu (2026-11-04 elle denemesi); simge, çubuk ve hız artık `DockTileView` ile çizilir.
final class DockProgress {
    /// Uygulama temsilcisi NSApp hazır olmadan kurulur; gerçek Dock simgesi ilk güncellemede alınır.
    private let injectedTile: DockTileSurface?
    private var tileView: DockTileView?
    private(set) var lastState: DockTileState?

    init(tile: DockTileSurface? = nil) {
        injectedTile = tile
    }

    /// - Parameters:
    ///   - fraction: Çalışan işin ilerlemesi (bilinmiyorsa nil).
    ///   - active: Bir iş çalışıyor.
    ///   - speed: Biçimlendirilmiş kopyalama hızı; nil ise gösterilmez.
    func update(fraction: Double?, active: Bool, enabled: Bool, speed: String? = nil) {
        let tile = injectedTile ?? NSApplication.shared.dockTile
        let state = enabled && active
            ? DockTileState(showsBar: true, percent: fraction.map { Int(($0 * 100).rounded()) }, speed: speed)
            : DockTileState()
        // Dock simgesi yalnızca görünen bir şey değişince yeniden çizilir (ilerleme saniyede birkaç kez gelir).
        if state == lastState { return }
        lastState = state
        tile.badgeLabel = nil
        if state.isEmpty {
            tile.contentView = nil
        } else {
            let view = tileView ?? DockTileView(frame: NSRect(origin: .zero, size: tile.size))
            tileView = view
            view.state = state
            tile.contentView = view
        }
        tile.display()
    }
}

/// Dock simgesinin içeriği: uygulama simgesi, altta parlak, kalın bir ilerleme çubuğu ve üstünde hız kutucuğu. Koyu
/// zemin ve beyaz kenar simgenin renkleri üstünde de seçilir; ölçüler 128 pt'lik simgeye göredir.
final class DockTileView: NSView {
    var state = DockTileState() { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let unit = bounds.width / 128
        NSApplication.shared.applicationIconImage.draw(in: bounds)
        // Her şey simgenin alt yarısında kalır: simgenin kendisi seçilir kalır.
        var pillY = 8 * unit
        if state.showsBar {
            drawBar(NSRect(x: 8 * unit, y: 8 * unit, width: 112 * unit, height: 22 * unit))
            pillY = 34 * unit
        }
        if let speed = state.speed {
            drawPill(speed, color: Self.speedColor, frame: NSRect(x: 4 * unit, y: pillY, width: 120 * unit, height: 24 * unit))
        }
    }

    static let fillStart = NSColor(srgbRed: 0.20, green: 0.90, blue: 0.40, alpha: 1)
    static let fillEnd = NSColor(srgbRed: 0.65, green: 1.00, blue: 0.40, alpha: 1)
    static let speedColor = NSColor(srgbRed: 0.40, green: 1.00, blue: 0.50, alpha: 1)

    private func drawBar(_ frame: NSRect) {
        let radius = frame.height / 2
        let track = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.75).setFill()
        track.fill()
        NSColor.white.setStroke()
        track.lineWidth = max(1, frame.height / 10)
        track.stroke()
        let inner = frame.insetBy(dx: frame.height * 0.18, dy: frame.height * 0.18)
        // Toplamı henüz bilinmeyen iş (rsync dosya listesini tarıyor): çubuk soluk ve tam boy; %0'da bile dolgunun
        // yuvarlak ucu görünür.
        let fraction = state.percent.map { min(1, max(0, Double($0) / 100)) }
        var fill = inner
        fill.size.width = fraction.map { max(inner.height, inner.width * $0) } ?? inner.width
        let fillPath = NSBezierPath(roundedRect: fill, xRadius: inner.height / 2, yRadius: inner.height / 2)
        let alpha: CGFloat = fraction == nil ? 0.45 : 1
        NSGradient(starting: Self.fillStart.withAlphaComponent(alpha), ending: Self.fillEnd.withAlphaComponent(alpha))?
            .draw(in: fillPath, angle: 0)
    }

    private func drawPill(_ text: String, color: NSColor, frame: NSRect) {
        let radius = frame.height / 2
        let pill = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.8).setFill()
        pill.fill()
        color.setStroke()
        pill.lineWidth = max(1, frame.height / 14)
        pill.stroke()
        // Uzun hızlar ("→ 112,4 MB/sn") kutucuğa sığana kadar küçültülür.
        var size = frame.height * 0.72
        var attributes: [NSAttributedString.Key: Any] = [:]
        var measured = NSSize.zero
        repeat {
            attributes = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold), .foregroundColor: NSColor.white]
            measured = (text as NSString).size(withAttributes: attributes)
            size -= 1
        } while measured.width > frame.width - frame.height * 0.6 && size > 6
        let origin = NSPoint(x: frame.midX - measured.width / 2, y: frame.midY - measured.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}

/// Disk takma ve çıkarma bildirimlerini modele iletir.
final class VolumeWatcher {
    private var tokens: [NSObjectProtocol] = []

    func start(model: AppModel) {
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (URL) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                MainActor.assumeIsolated { handler(url) }
            })
        }
        observe(NSWorkspace.didMountNotification) { model.volumeDidMount($0) }
        observe(NSWorkspace.willUnmountNotification) { model.volumeWillUnmount($0) }
        observe(NSWorkspace.didUnmountNotification) { model.volumeDidUnmount($0) }
    }
}
