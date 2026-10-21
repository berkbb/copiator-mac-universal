// SPDX-License-Identifier: GPL-3.0-or-later
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
            let waiting = model.jobs.lazy.filter { $0.status == .waiting }.count
            if waiting > 0 {
                Text(settings.t(.menuBarWaiting, waiting))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

/// Dock simgesinde çalışan işin ilerleme çubuğu ve bekleyen işlerin sayısı (rozet).
final class DockProgress {
    private let progress = NSProgressIndicator()
    private var tileView: NSView?
    private var lastState: (percent: Int?, badge: Int, active: Bool)?

    /// - Parameters:
    ///   - fraction: Çalışan işin ilerlemesi (bilinmiyorsa nil).
    ///   - active: Bir iş çalışıyor.
    ///   - badge: Çalışan ve bekleyen işlerin sayısı.
    func update(fraction: Double?, active: Bool, badge: Int, enabled: Bool) {
        let tile = NSApp.dockTile
        let percent = fraction.map { Int(($0 * 100).rounded()) }
        let state = (percent: enabled ? percent : nil, badge: enabled ? badge : 0, active: enabled && active)
        // Dock simgesi yalnızca görünen bir şey değişince yeniden çizilir (ilerleme saniyede birkaç kez gelir).
        if let lastState, lastState.percent == state.percent, lastState.badge == state.badge, lastState.active == state.active { return }
        lastState = state
        tile.badgeLabel = state.badge > 0 ? String(state.badge) : nil
        if state.active {
            let view = tileView ?? makeTileView(size: tile.size)
            tileView = view
            progress.isIndeterminate = state.percent == nil
            progress.doubleValue = Double(state.percent ?? 0)
            tile.contentView = view
        } else {
            tile.contentView = nil
        }
        tile.display()
    }

    private func makeTileView(size: NSSize) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        let icon = NSImageView(frame: view.bounds)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(icon)
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 100
        progress.controlSize = .small
        progress.frame = NSRect(x: size.width * 0.12, y: size.height * 0.08, width: size.width * 0.76, height: size.height * 0.12)
        view.addSubview(progress)
        return view
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
