// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CopiatorCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var model = model
        List(selection: Binding<SidebarItem?>(get: { model.sidebarSelection }, set: { model.sidebarSelection = $0 ?? .filter(.all) })) {
            Section(settings.t(.sidebarQueue)) {
                ForEach(JobFilter.allCases) { filter in
                    Label(settings.t(filter.titleKey), systemImage: filter.systemImage)
                        .badge(model.count(for: filter))
                        .tag(SidebarItem.filter(filter))
                }
            }
            Section(settings.t(.sidebarRoutines)) {
                ForEach(model.routines) { routine in
                    Label(OpenSafety.visibleName(routine.name), systemImage: "wand.and.stars")
                        .lineLimit(1)
                        .tag(SidebarItem.routine(routine.id))
                        // Finder'dan bırakılan öğeler bu rutinle kopyalanır.
                        .dropDestination(for: URL.self) { urls, _ in
                            model.runRoutine(routine.id, on: urls.filter(\.isFileURL)) == nil
                        }
                        .contextMenu {
                            Button(settings.t(.routineRun), systemImage: "play.fill") { model.runRoutine(routine.id) }
                            Button(settings.t(.menuEditJob), systemImage: "pencil") { model.beginEditRoutine(routine.id) }
                            Button(settings.t(.menuDuplicateJob), systemImage: "plus.square.on.square") { model.beginDuplicateRoutine(routine.id) }
                            Button(settings.t(.menuExportRoutine), systemImage: "square.and.arrow.up") {
                                RoutineTransferPanels.chooseExport([routine.id], model: model, settings: settings)
                            }
                            Divider()
                            Button(settings.t(.routineDelete), systemImage: "trash", role: .destructive) { model.requestDeleteRoutine(routine.id) }
                        }
                }
                Button {
                    model.beginNewRoutine()
                } label: {
                    Label(settings.t(.menuNewRoutine), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("copiator.sidebar.newRoutine")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            // "rsync hazır" yalnızca karşılama ekranında görünür; kenar çubuğu yalnızca bir sorun (bulunamadı, yanıt
            // vermiyor, kısıtlı kip) olduğunda ve karşılama ekranı görünmüyorken uyarır.
            if !model.jobs.isEmpty, needsAttention {
                EngineStatusView()
                    .font(.caption)
                    .padding(10)
            }
        }
    }

    private var needsAttention: Bool {
        switch model.engineStatus {
        case .ready(_, let limited): limited
        case .checking: false
        case .missing, .blocked: true
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
            VStack(spacing: 0) {
                if settings.queueHeld {
                    // Tek satır: liste üstündeki bandın yüksekliği genişliğe bağlı olmasın (bkz. PowerStatusBanner).
                    Label(settings.t(.queueHeldNotice), systemImage: "pause.circle.fill")
                        .font(.callout)
                        .lineLimit(1)
                        .help(settings.t(.queueHeldNotice))
                        .foregroundStyle(.orange)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.orange.opacity(0.08))
                }
                // İş sürerken: uyku engeli (sistemde doğrulandı mı) ve güç, pil, ekran önerileri.
                if model.runningJobID != nil, let status = model.sleepStatus {
                    PowerStatusBanner(status: status, advice: model.powerAdvice, snapshot: model.powerSnapshot, settings: settings,
                                      wrapsText: false)
                }
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
        if job.isAwaitingDecision {
            Button(settings.t(.menuResolveConflicts), systemImage: "doc.on.doc") { model.conflictPrompt = ConflictPrompt(id: job.id) }
        }
        Divider()
        Button(settings.t(.menuEditJob), systemImage: "pencil") { model.beginEdit(job.id) }
            .disabled(!JobQueue.canEdit(job))
        Button(settings.t(.menuDuplicateJob), systemImage: "plus.square.on.square") { model.beginDuplicate(job.id) }
        Divider()
        Button(settings.t(.menuVerify), systemImage: "checkmark.shield") { model.requestVerify(job.id) }
            .disabled(!JobQueue.canVerify(job) || model.operation != nil)
        Divider()
        Button(settings.t(.menuShowSource), systemImage: "folder") { model.revealSource(job.id) }
        Button(settings.t(.menuShowDestination), systemImage: "externaldrive") { model.revealDestination(job.id) }
        Button(settings.t(.menuDestinationSummary), systemImage: "chart.bar.doc.horizontal") { model.showDestinationSummary(job.destination) }
        if job.options.snapshots.enabled {
            Button(settings.t(.menuSnapshots), systemImage: "clock.arrow.circlepath") { model.showSnapshots(job.id) }
        }
        Button(settings.t(.menuIntegrity), systemImage: "checkmark.shield") { model.showIntegrity(job.destination) }
        Button(settings.t(.menuDuplicates), systemImage: "doc.on.doc") { model.showDuplicates(job.destination) }
        Button(settings.t(.menuCleanupArchived), systemImage: "trash.circle") {
            model.beginCleanup(source: RsyncEngine.isDirectory(job.source) ? job.source : job.source.deletingLastPathComponent(),
                               destination: job.destination)
        }
        Divider()
        Button(settings.t(.menuRemoveJob), systemImage: "trash", role: .destructive) { model.remove(ids) }
            .disabled(!JobQueue.canRemove(job))
        Button(settings.t(.menuRemoveFinished), systemImage: "checkmark.circle") { model.removeFinished() }
            .disabled(!model.jobs.contains { $0.status == .finished })
        Button(settings.t(.menuRemoveAll), systemImage: "trash.slash", role: .destructive) { model.requestRemoveAll() }
            .disabled(model.removableJobs.isEmpty)
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
                    Image(systemName: job.kind == .sync ? "arrow.left.arrow.right" : "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(OpenSafety.visibleName(job.destination.lastPathComponent.isEmpty ? job.destination.path : job.destination.lastPathComponent))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    if let routineName = job.routineName, job.routineID != nil {
                        Label(OpenSafety.visibleName(routineName), systemImage: "wand.and.stars")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    StatusBadge(job: job, settings: settings, isPausing: model.isPausingRunningJob && model.runningJobID == job.id,
                                isWaitingForDisk: model.isWaitingForDisk(job))
                }
                progressBar
                let detail = detailLine
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailIsWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(3)
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
        case .scanning, .verifying:
            ProgressView().progressViewStyle(.linear)
        case .copying where job.progress?.isListing == true:
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
        job.isAwaitingDecision || job.status == .failed || job.progress?.isEstimating == true && job.status == .copying
    }

    private var detailLine: String {
        if job.status == .failed || job.status == .finished || job.isAwaitingDecision, let result = job.result {
            return settings.result(result)
        }
        guard let progress = job.progress else {
            return job.status == .copying && model.engineInfo?.supportsProgress2 == false ? settings.t(.progressLimited) : ""
        }
        if progress.isListing, let listed = progress.filesListed {
            return settings.t(.progressListing, listed)
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
        if job.status == .copying, let item = progress.currentItem {
            var current = settings.t(.progressCurrentItem, OpenSafety.visibleName(item))
            if let fileFraction = progress.fileFraction { current += " · " + settings.t(.progressThisFile, settings.percent(fileFraction)) }
            line += "\n" + current
        }
        return line
    }
}

struct StatusBadge: View {
    let job: TransferJob
    let settings: AppSettings
    var isPausing = false
    /// "Disk takılınca başla" seçili iş diski takılı olmadığı için bekliyor.
    var isWaitingForDisk = false

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
        if job.isAwaitingDecision { return .statusAwaitingDecision }
        return isWaitingForDisk ? .statusWaitingForDisk : job.status.titleKey
    }

    private var color: Color {
        switch job.status {
        case .waiting: .secondary
        case .scanning, .copying, .verifying: .accentColor
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
                        row(.detailTarget, OpenSafety.visibleName(targetPath(job)))
                        if job.options.snapshots.enabled { row(.detailSnapshots, snapshotSummary(job)) }
                        if let routineName = job.routineName, job.routineID != nil { row(.detailRoutine, OpenSafety.visibleName(routineName)) }
                        if let rules = job.options.rules { row(.detailRules, settings.describe(rules), lineLimit: nil) }
                        if let placement = job.options.placement.flatMap(settings.describe) { row(.placementTitle, placement, lineLimit: nil) }
                        if let items = job.options.selectedItems {
                            row(.detailSelectedItems, items.map(OpenSafety.visibleName).joined(separator: ", "), lineLimit: nil)
                        }
                        row(.detailMode, settings.t(job.options.copyMode == .folder ? .modeFolder : .modeContents))
                        row(.detailOptions, optionsSummary(job.options, kind: job.kind), lineLimit: nil)
                        row(.detailStatus, settings.t(job.status.titleKey))
                        if let result = job.result {
                            row(.detailResult, settings.result(result))
                            if let code = result.exitCode { row(.detailExitCode, String(code)) }
                        }
                        row(.detailCreated, settings.date(job.createdAt))
                        if let started = job.startedAt { row(.detailStarted, settings.date(started)) }
                        if let finished = job.finishedAt { row(.detailFinished, settings.date(finished)) }
                    }
                    .font(.callout)

                    if job.id == model.runningJobID, let status = model.sleepStatus {
                        PowerStatusBanner(status: status, advice: model.powerAdvice, snapshot: model.powerSnapshot, settings: settings)
                    }
                    if job.isAwaitingDecision {
                        Button(settings.t(.menuResolveConflicts), systemImage: "doc.on.doc") { model.conflictPrompt = ConflictPrompt(id: job.id) }
                            .buttonStyle(.glassProminent)
                    }
                    Divider()
                    CommandPreview(command: model.commandPreview(for: job))
                    Divider()
                    FillForecastView(job: job)
                    Divider()
                    JobHistoryList(job: job, settings: settings)
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

    private func row(_ key: LKey, _ value: String, lineLimit: Int? = 4) -> some View {
        GridRow {
            Text(settings.t(key))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
        }
    }

    private func optionsSummary(_ options: CopyOptions, kind: JobKind) -> String {
        var parts: [String] = []
        if options.preservePermissions { parts.append(settings.t(.optionPreservePermissions)) }
        if options.preserveExtendedAttributes { parts.append(settings.t(.optionXattrs)) }
        if options.excludeSystemFolders { parts.append(settings.t(.optionExcludeSystem)) }
        if options.deleteExtraneous { parts.append(settings.t(.optionDelete)) }
        if options.trashSourceAfterCopy { parts.append(settings.t(.optionTrashSource)) }
        if options.snapshots.enabled { parts.append(settings.t(.optionSnapshots)) }
        if options.runWhenConnected { parts.append(settings.t(.optionRunWhenConnected)) }
        if options.ejectWhenDone { parts.append(settings.t(.optionEjectWhenDone)) }
        parts.append(settings.t(.optionConflictPolicy) + ": " + settings.title(options.conflictPolicy, kind: kind))
        switch options.verifyAfterCopy {
        case .off: break
        case .quick: parts.append(settings.t(.optionVerifyAfterCopy) + ": " + settings.t(.verifyAfterQuick))
        case .checksum: parts.append(settings.t(.optionVerifyAfterCopy) + ": " + settings.t(.verifyAfterChecksum))
        }
        parts += options.advanced.excludePresets.map { settings.t($0.titleKey) }
        return parts.joined(separator: "\n")
    }

    /// Kaynağın hedefteki karşılığı; anlık görüntü işinde en yeni anlık görüntünün (yoksa bugünün adıyla) içinde.
    private func targetPath(_ job: TransferJob) -> String {
        var job = job
        if job.options.snapshots.enabled {
            let name = SnapshotStore.latest(in: job.destination)?.lastPathComponent ?? SnapshotStore.name(for: Date())
            job.destination = job.destination.appendingPathComponent(name, isDirectory: true)
        }
        return job.target(sourceIsDirectory: RsyncEngine.isDirectory(job.source)).path
    }

    private func snapshotSummary(_ job: TransferJob) -> String {
        let snapshots = SnapshotStore.completeSnapshots(in: job.destination)
        guard let latest = snapshots.last else { return settings.t(.detailSnapshotsNone) }
        return settings.t(.detailSnapshotsCount, snapshots.count, latest)
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

extension JobStatus {
    var titleKey: LKey {
        switch self {
        case .waiting: .statusWaiting
        case .scanning: .statusScanning
        case .copying: .statusCopying
        case .verifying: .statusVerifying
        case .paused: .statusPaused
        case .finished: .statusFinished
        case .failed: .statusFailed
        }
    }
}
