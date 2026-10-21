// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CopiatorCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var model = model
        List(selection: Binding<JobFilter?>(get: { model.filter }, set: { model.filter = $0 ?? .all })) {
            Section(settings.t(.sidebarQueue)) {
                ForEach(JobFilter.allCases) { filter in
                    Label(settings.t(filter.titleKey), systemImage: filter.systemImage)
                        .badge(model.count(for: filter))
                        .tag(filter)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            EngineStatusView()
                .font(.caption)
                .padding(10)
        }
    }
}

struct JobListView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var model = model
        let jobs = model.visibleJobs
        Group {
            if jobs.isEmpty {
                ContentUnavailableView(settings.t(model.filter.titleKey), systemImage: model.filter.systemImage,
                                       description: Text(settings.t(.emptyFilter)))
            } else {
                List(selection: $model.selection) {
                    ForEach(jobs) { job in
                        JobRow(job: job, model: model, settings: settings)
                            .tag(job.id)
                            .contextMenu { contextMenu(for: job) }
                    }
                    // Sıralama yalnızca tüm işler görünürken anlamlıdır (süzülmüş listede konumlar karışırdı).
                    .onMove(perform: model.filter == .all ? { model.move(from: $0, to: $1) } : nil)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .accessibilityIdentifier("copiator.joblist")
            }
        }
        .safeAreaInset(edge: .top) {
            if settings.queueHeld {
                Label(settings.t(.queueHeldNotice), systemImage: "pause.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.orange.opacity(0.08))
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for job: TransferJob) -> some View {
        let ids: Set<TransferJob.ID> = model.selection.contains(job.id) ? model.selection : [job.id]
        if JobQueue.canResume(job) {
            Button(settings.t(.menuResumeJob), systemImage: "play.fill") { model.resume(ids) }
        }
        if JobQueue.canRunAgain(job) {
            Button(settings.t(.menuRunAgain), systemImage: "arrow.clockwise") { model.resume(ids) }
        }
        if JobQueue.canPause(job) {
            Button(settings.t(.menuPauseJob), systemImage: "pause.fill") { model.pause(ids) }
        }
        Divider()
        Button(settings.t(.menuVerify), systemImage: "checkmark.shield") { model.requestVerify(job.id) }
            .disabled(!JobQueue.canVerify(job) || model.operation != nil)
        Divider()
        Button(settings.t(.menuShowSource), systemImage: "folder") { model.revealSource(job.id) }
        Button(settings.t(.menuShowDestination), systemImage: "externaldrive") { model.revealDestination(job.id) }
        Divider()
        Button(settings.t(.menuRemoveJob), systemImage: "trash", role: .destructive) { model.remove(ids) }
            .disabled(!JobQueue.canRemove(job))
    }
}

/// Bir iş satırı: kaynak → hedef, durum, ilerleme çubuğu, aktarılan bayt, hız, kalan süre.
/// Liste satırları ortamdan değil, açık özelliklerden okur: SwiftUI satırları yeniden eklerken ortam nesnelerini
/// iletmeyebilir (bkz. .agents/rules/ui_rules.md).
struct JobRow: View {
    let job: TransferJob
    let model: AppModel
    let settings: AppSettings

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: job.source.path))
                .resizable()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(OpenSafety.visibleName(job.source.lastPathComponent))
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(OpenSafety.visibleName(job.destination.lastPathComponent.isEmpty ? job.destination.path : job.destination.lastPathComponent))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    StatusBadge(job: job, settings: settings, isPausing: model.isPausingRunningJob && model.runningJobID == job.id)
                }
                progressBar
                let detail = detailLine
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailIsWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .monospacedDigit()
                }
            }
            Button {
                if JobQueue.canPause(job) { model.pause([job.id]) } else { model.resume([job.id]) }
            } label: {
                Image(systemName: JobQueue.canPause(job) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .help(settings.t(JobQueue.canPause(job) ? .menuPauseJob : .menuResumeJob))
            .accessibilityLabel(settings.t(JobQueue.canPause(job) ? .menuPauseJob : .menuResumeJob))
            .accessibilityIdentifier("copiator.job.toggle")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("copiator.job")
    }

    @ViewBuilder
    private var progressBar: some View {
        switch job.status {
        case .scanning:
            ProgressView().progressViewStyle(.linear)
        case .copying:
            if let fraction = job.progress?.fraction, model.engineInfo?.supportsProgress2 != false {
                ProgressView(value: fraction).tint(job.progress?.isEstimating == true ? .orange : .accentColor)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        case .finished:
            ProgressView(value: 1).tint(.green)
        case .failed:
            ProgressView(value: job.progress?.fraction ?? 0).tint(.red)
        case .paused, .waiting:
            ProgressView(value: job.progress?.fraction ?? 0).tint(.gray)
        }
    }

    private var detailIsWarning: Bool {
        job.status == .failed || job.progress?.isEstimating == true && job.status == .copying
    }

    private var detailLine: String {
        if job.status == .failed || job.status == .finished, let result = job.result {
            return settings.result(result)
        }
        guard let progress = job.progress else {
            return job.status == .copying && model.engineInfo?.supportsProgress2 == false ? settings.t(.progressLimited) : ""
        }
        var parts = [settings.t(.progressBytes, settings.bytes(progress.bytesTransferred))]
        if job.status == .copying {
            if let rate = progress.bytesPerSecond, rate > 0 {
                parts.append(settings.t(.progressSpeed, settings.bytes(Int64(rate))))
            }
            if let remaining = progress.remainingSeconds, !progress.isEstimating, progress.fraction ?? 0 < 1 {
                parts.append(settings.t(.progressRemaining, settings.duration(seconds: remaining)))
            }
        }
        parts.append(settings.t(.progressFiles, progress.filesTransferred))
        if let checked = progress.itemsChecked, let total = progress.itemsTotal {
            parts.append(settings.t(.progressChecked, checked, total))
        }
        var line = parts.joined(separator: " · ")
        if progress.isEstimating && job.status == .copying { line += "\n" + settings.t(.progressEstimating) }
        return line
    }
}

struct StatusBadge: View {
    let job: TransferJob
    let settings: AppSettings
    var isPausing = false

    var body: some View {
        HStack(spacing: 4) {
            if job.wasInterrupted {
                Text(settings.t(.statusInterrupted))
                    .foregroundStyle(.orange)
            }
            Text(settings.t(isPausing ? .progressCancelling : titleKey))
                .foregroundStyle(color)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var titleKey: LKey {
        switch job.status {
        case .waiting: .statusWaiting
        case .scanning: .statusScanning
        case .copying: .statusCopying
        case .paused: .statusPaused
        case .finished: .statusFinished
        case .failed: .statusFailed
        }
    }

    private var color: Color {
        switch job.status {
        case .waiting: .secondary
        case .scanning, .copying: .accentColor
        case .paused: .orange
        case .finished: .green
        case .failed: .red
        }
    }
}

struct JobDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if model.selection.count == 1, let id = model.selection.first, let job = model.job(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                        row(.detailSource, OpenSafety.visibleName(job.source.path))
                        row(.detailDestination, OpenSafety.visibleName(job.destination.path))
                        row(.detailTarget, OpenSafety.visibleName(job.target(sourceIsDirectory: RsyncEngine.isDirectory(job.source)).path))
                        row(.detailMode, settings.t(job.options.copyMode == .folder ? .modeFolder : .modeContents))
                        row(.detailOptions, optionsSummary(job.options))
                        row(.detailStatus, settings.t(statusKey(job.status)))
                        if let result = job.result {
                            row(.detailResult, settings.result(result))
                            if let code = result.exitCode { row(.detailExitCode, String(code)) }
                        }
                        row(.detailCreated, settings.date(job.createdAt))
                        if let started = job.startedAt { row(.detailStarted, settings.date(started)) }
                        if let finished = job.finishedAt { row(.detailFinished, settings.date(finished)) }
                    }
                    .font(.callout)

                    Divider()
                    Text(settings.t(.detailLog)).font(.headline)
                    if job.log.isEmpty {
                        Text(settings.t(.detailNoLog)).foregroundStyle(.secondary).font(.callout)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(job.log.reversed()) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: icon(entry.level))
                                        .foregroundStyle(color(entry.level))
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(settings.log(entry))
                                            .font(entry.raw != nil ? .caption.monospaced() : .caption)
                                            .textSelection(.enabled)
                                        Text(settings.date(entry.date))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(settings.t(.detailNoSelection), systemImage: "sidebar.trailing")
        }
    }

    private func row(_ key: LKey, _ value: String) -> some View {
        GridRow {
            Text(settings.t(key))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.middle)
        }
    }

    private func optionsSummary(_ options: CopyOptions) -> String {
        var parts: [String] = []
        if options.preservePermissions { parts.append(settings.t(.optionPreservePermissions)) }
        if options.preserveExtendedAttributes { parts.append(settings.t(.optionXattrs)) }
        if options.excludeSystemFolders { parts.append(settings.t(.optionExcludeSystem)) }
        if options.deleteExtraneous { parts.append(settings.t(.optionDelete)) }
        return parts.joined(separator: "\n")
    }

    private func statusKey(_ status: JobStatus) -> LKey {
        switch status {
        case .waiting: .statusWaiting
        case .scanning: .statusScanning
        case .copying: .statusCopying
        case .paused: .statusPaused
        case .finished: .statusFinished
        case .failed: .statusFailed
        }
    }

    private func icon(_ level: JobLogEntry.Level) -> String {
        switch level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private func color(_ level: JobLogEntry.Level) -> Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
