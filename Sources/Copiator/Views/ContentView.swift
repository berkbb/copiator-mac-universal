// SPDX-License-Identifier: GPL-3.0-or-later
import CopiatorCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// İşlem başarıyla bittiğinde kısa bir süre gösterilen son durum (ilerleme tamamlanmış olarak).
    @State private var finishingOperation: OperationState?
    @State private var lastOperation: OperationState?
    @State private var overlayShownAt = ContinuousClock.now
    @State private var lingerTask: Task<Void, Never>?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            ZStack {
                if model.jobs.isEmpty {
                    WelcomeView()
                        .transition(.opacity)
                } else {
                    JobListView()
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: model.jobs.isEmpty)
            .inspector(isPresented: $model.isInspectorVisible) {
                JobDetailView()
                    .inspectorColumnWidth(min: 260, ideal: 320, max: 440)
            }
        }
        .navigationTitle(settings.t(.appName))
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
            return !urls.isEmpty
        } isTargeted: { model.isDropTargeted = $0 }
        .overlay {
            if let operation = model.operation ?? finishingOperation {
                ProgressOverlay(operation: operation, isFinishing: model.operation == nil)
                    // Bitmiş işlemin kalan gösterimi tıklamaları engellemesin.
                    .allowsHitTesting(model.operation != nil)
            }
        }
        .onChange(of: model.operation?.id, initial: true) { _, id in operationChanged(id) }
        .onChange(of: model.operation?.progress) { _, _ in lastOperation = model.operation ?? lastOperation }
        .overlay(alignment: .bottom) {
            // Bildirim, ilerleme penceresi kaybolduktan sonra gelir: ikisi üst üste görünmesin.
            if let toast = model.toast, finishingOperation == nil {
                ToastView(toast: toast)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.35), value: model.operation != nil || finishingOperation != nil)
        .sheet(item: $model.newJobRequest) { NewJobSheet(request: $0) }
        .sheet(item: $model.verifyPresentation) { VerifyResultSheet(presentation: $0) }
        .confirmationDialog(
            settings.t(.verifyChooseTitle),
            isPresented: Binding(get: { model.verifyChoice != nil }, set: { if !$0 { model.verifyChoice = nil } }),
            titleVisibility: .visible
        ) {
            Button(settings.t(.verifyQuick)) { if let id = model.verifyChoice { model.verify(id, checksum: false) } }
            Button(settings.t(.verifyChecksum)) { if let id = model.verifyChoice { model.verify(id, checksum: true) } }
            Button(settings.t(.buttonCancel), role: .cancel) { model.verifyChoice = nil }
        } message: {
            Text(settings.t(.verifyChooseMessage))
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { alert in
            if let actionTitle = alert.actionTitle, let action = alert.action {
                Button(actionTitle, role: alert.isDestructive ? .destructive : nil, action: action)
                Button(alert.cancelTitle ?? settings.t(.buttonCancel), role: .cancel) { alert.cancelAction?() }
            } else {
                Button(settings.t(.buttonOK)) {}
            }
        } message: { alert in
            Text(alert.message)
        }
    }

    /// İşlem başladığında zamanı kaydeder; bittiğinde pencere en az süreyi doldurmadıysa son durumu (ilerleme
    /// tamamlanmış olarak) kalan süre boyunca gösterir. Model zamanlaması değişmez: yalnızca görünüm bekletilir.
    private func operationChanged(_ id: OperationState.ID?) {
        if id != nil {
            lingerTask?.cancel()
            lingerTask = nil
            finishingOperation = nil
            if lastOperation == nil { overlayShownAt = .now }
            lastOperation = model.operation
            return
        }
        guard let last = lastOperation else { return }
        lastOperation = nil
        guard let remaining = OverlayTiming.remaining(
            shownAt: overlayShownAt, now: .now, outcome: model.lastOperationOutcome, isDeterminate: last.progress != nil
        ) else { return }
        finishingOperation = OverlayTiming.finished(last)
        lingerTask = Task {
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
            finishingOperation = nil
        }
    }

    private var subtitle: String {
        guard let id = model.runningJobID, let job = model.job(id) else {
            return settings.queueHeld ? settings.t(.queueHeldNotice) : ""
        }
        return settings.t(job.status == .scanning ? .statusScanning : .statusCopying) + " · " + job.source.lastPathComponent
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        let selected = model.selectedJobs
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.beginNewJob()
            } label: {
                Label(settings.t(.toolbarNewJob), systemImage: "plus")
            }
            .help(settings.t(.menuNewJob))
            .accessibilityIdentifier("copiator.toolbar.newjob")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.resume(model.selection)
            } label: {
                Label(settings.t(.toolbarResume), systemImage: "play.fill")
            }
            .help(settings.t(.menuResumeJob))
            .disabled(!selected.contains { JobQueue.canResume($0) || JobQueue.canRunAgain($0) })

            Button {
                model.pause(model.selection)
            } label: {
                Label(settings.t(.toolbarPause), systemImage: "pause.fill")
            }
            .help(settings.t(.menuPauseJob))
            .disabled(!selected.contains(where: JobQueue.canPause))

            Button {
                if let id = selected.first?.id { model.requestVerify(id) }
            } label: {
                Label(settings.t(.toolbarVerify), systemImage: "checkmark.shield")
            }
            .help(settings.t(.menuVerify))
            .disabled(selected.count != 1 || !selected.allSatisfy(JobQueue.canVerify) || model.operation != nil)

            Button {
                model.remove(model.selection)
            } label: {
                Label(settings.t(.toolbarRemove), systemImage: "trash")
            }
            .help(settings.t(.menuRemoveJob))
            .disabled(!selected.contains(where: JobQueue.canRemove))
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.toggleQueueHold()
            } label: {
                Label(
                    settings.t(settings.queueHeld ? .toolbarReleaseQueue : .toolbarHoldQueue),
                    systemImage: settings.queueHeld ? "play.circle" : "pause.circle"
                )
            }
            .help(settings.t(settings.queueHeld ? .toolbarReleaseQueue : .toolbarHoldQueue))

            Button {
                model.toggleInspector()
            } label: {
                Label(settings.t(.toolbarInspector), systemImage: "sidebar.trailing")
            }
            .help(settings.t(.menuInspector))
            .disabled(model.jobs.isEmpty)
        }
    }
}

/// İlerleme penceresinin gösterim süresi hesabı (görünümden ayrı, test edilebilir).
enum OverlayTiming {
    /// Pencere bir kez göründüyse en az bu kadar ekranda kalır: hızlı işlemlerde göz kırpar gibi açılıp kapanmasın.
    static let minimumDuration: Duration = .milliseconds(700)

    /// İlerleme çubuğu olan işlem başarıyla bitince çubuğun dolu (%100) göründüğü kısa an.
    static let completionBeat: Duration = .milliseconds(350)

    /// İşlem bittiğinde pencerenin daha ne kadar gösterileceği; nil ise hemen kapanır.
    /// İptal ve hatada beklenmez; başarıda en az süre ve tamamlanma anı uygulanır.
    static func remaining(
        shownAt: ContinuousClock.Instant, now: ContinuousClock.Instant, outcome: OperationOutcome?, isDeterminate: Bool,
        minimum: Duration = minimumDuration
    ) -> Duration? {
        guard outcome != .cancelled, outcome != .failed else { return nil }
        let remaining = minimum - (now - shownAt)
        if outcome == .succeeded, isDeterminate { return max(remaining, completionBeat) }
        return remaining > .zero ? remaining : nil
    }

    /// Kalan süre boyunca gösterilen bitmiş durum: ilerleme çubuğu varsa tamamlanmış (%100) görünür.
    static func finished(_ operation: OperationState) -> OperationState {
        var finished = operation
        if finished.progress != nil { finished.progress = 1 }
        return finished
    }
}

struct ProgressOverlay: View {
    let operation: OperationState
    /// İşlem bitti; pencere yalnızca en az gösterim süresini dolduruyor (iptal edilecek bir şey yok).
    var isFinishing = false
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.14))
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.bounce.up.byLayer, options: .repeating.speed(0.7), isActive: !reduceMotion && !operation.isCancelling)
                    .frame(height: 56)
                    .accessibilityHidden(true)
                Text(settings.t(operation.isCancelling ? .progressCancelling : operation.titleKey))
                    .font(.headline)
                    .contentTransition(.opacity)
                if let progress = operation.progress {
                    ProgressView(value: progress)
                        .frame(width: 300)
                    Text(settings.percent(progress))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                }
                Button(settings.t(.buttonCancel), role: .cancel) { model.cancelOperation() }
                    .buttonStyle(.glass)
                    // Dilden bağımsız kimlik: Scripts/stress-test.sh düğmeyi bununla bulur (VoiceOver okumaz).
                    .accessibilityIdentifier("copiator.progress.cancel")
                    .disabled(isFinishing || operation.isCancelling)
            }
            .padding(30)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("copiator.progress")
            .scaleEffect(appeared || reduceMotion ? 1 : 0.92)
            .opacity(appeared || reduceMotion ? 1 : 0)
        }
        .transition(.opacity)
        .onAppear {
            withAnimation(.spring(duration: 0.45, bounce: 0.25)) { appeared = true }
        }
    }

    private var symbol: String {
        switch operation.titleKey {
        case .progressVerifying: "checkmark.shield"
        case .progressUpdatingEngine: "arrow.triangle.2.circlepath"
        default: "externaldrive.badge.timemachine"
        }
    }
}

struct ToastView: View {
    let toast: Toast
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(.green)
            Text(toast.message)
                .lineLimit(1)
            if let url = toast.revealURL {
                Button(settings.t(.buttonShowInFinder)) { model.reveal(url) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: .capsule)
    }
}
