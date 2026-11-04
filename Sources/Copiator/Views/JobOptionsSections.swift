// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CopiatorCore
import SwiftUI

/// Kopyalama sonrası doğrulama seçimi (Yeni İş sayfası ve Ayarlar › Kopyalama).
struct VerifyAfterCopyPicker: View {
    @Binding var selection: VerifyAfterCopy
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(settings.t(.optionVerifyAfterCopy), selection: $selection) {
                Text(settings.t(.verifyAfterOff)).tag(VerifyAfterCopy.off)
                Text(settings.t(.verifyAfterQuick)).tag(VerifyAfterCopy.quick)
                Text(settings.t(.verifyAfterChecksum)).tag(VerifyAfterCopy.checksum)
            }
            Text(settings.t(.optionVerifyAfterCopyNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Otomatik anlık görüntüler ve saklama kuralları (Yeni İş sayfası).
struct SnapshotSection: View {
    @Binding var options: SnapshotOptions
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(settings.t(.optionSnapshots), isOn: $options.enabled)
                    .accessibilityIdentifier("copiator.newjob.snapshots")
                // Örnek ad bugünün tarihiyle üretilir (sabit bir tarih yazılmaz).
                Text(settings.t(.optionSnapshotsNote, SnapshotStore.name(for: Date()), SnapshotStore.latestLinkName))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if options.enabled {
                CountField(title: settings.t(.snapshotKeepLast), value: $options.keepLast)
                CountField(title: settings.t(.snapshotKeepDaily), value: $options.keepDaily)
                CountField(title: settings.t(.snapshotKeepWeekly), value: $options.keepWeekly)
                CountField(title: settings.t(.snapshotKeepMonthly), value: $options.keepMonthly)
                Text(settings.t(.snapshotRetentionNote))
                    .font(.footnote)
                    .foregroundStyle(options.hasRetention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(settings.t(.sectionSnapshots))
        }
    }
}

/// İsteğe bağlı sayı (en az 1): anahtar kapalıyken kural kullanılmaz.
struct CountField: View {
    let title: String
    @Binding var value: Int?

    var body: some View {
        let enabled = Binding<Bool>(get: { value != nil }, set: { value = $0 ? (value ?? 7) : nil })
        let number = Binding<Int>(get: { value ?? 1 }, set: { value = max(1, $0) })
        HStack {
            Toggle(title, isOn: enabled)
            Spacer()
            TextField(title, value: number, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .disabled(value == nil)
            Stepper(title, value: number, in: 1...9_999)
                .labelsHidden()
                .disabled(value == nil)
        }
    }
}

/// Disk takılınca başlatma, bitince diski çıkarma ve kopyalama sonrası doğrulama (Yeni İş sayfası ve rutin düzenleyici).
struct AutomationSection: View {
    @Binding var options: CopyOptions
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(settings.t(.optionRunWhenConnected), isOn: $options.runWhenConnected)
                    .accessibilityIdentifier("copiator.newjob.runWhenConnected")
                Text(settings.t(.optionRunWhenConnectedNote))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(settings.t(.optionEjectWhenDone), isOn: $options.ejectWhenDone)
                    .accessibilityIdentifier("copiator.newjob.ejectWhenDone")
                Text(settings.t(.optionEjectWhenDoneNote))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(settings.t(.optionExcludeFromTimeMachine), isOn: $options.excludeFromTimeMachine)
                    .accessibilityIdentifier("copiator.newjob.excludeFromTimeMachine")
                Text(settings.t(.optionExcludeFromTimeMachineNote))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VerifyAfterCopyPicker(selection: $options.verifyAfterCopy)
        } header: {
            Text(settings.t(.sectionAutomation))
        }
    }
}

/// Hazır dışlama listeleri (gelişmiş seçeneklerin başında; Ayarlar › rsync'te varsayılan olarak da seçilebilir).
struct ExcludePresetsSection: View {
    @Binding var presets: [ExcludePreset]
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            ForEach(ExcludePreset.allCases) { preset in
                Toggle(settings.t(preset.titleKey), isOn: binding(for: preset))
                    .help(preset.patterns.joined(separator: "  "))
            }
            Text(settings.t(.advExcludePresetsNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(settings.t(.advExcludePresets))
        }
    }

    private func binding(for preset: ExcludePreset) -> Binding<Bool> {
        Binding(
            get: { presets.contains(preset) },
            set: { isOn in
                // Sıra her zaman aynı kalır (komut önizlemesi değişmesin).
                let chosen = Set(presets).union(isOn ? [preset] : []).subtracting(isOn ? [] : [preset])
                presets = ExcludePreset.allCases.filter(chosen.contains)
            }
        )
    }
}

extension ExcludePreset {
    var titleKey: LKey {
        switch self {
        case .developer: .presetDeveloper
        case .versionControl: .presetVersionControl
        case .caches: .presetCaches
        case .macOSJunk: .presetMacOSJunk
        }
    }
}

// MARK: - Önizleme

/// Kuru çalıştırmanın (önizleme) gösterimi.
struct PreviewPresentation: Identifiable {
    let id = UUID()
    let jobName: String
    let report: VerifyReport
    /// `--delete` seçili: hedefte fazla olanlar silinecek.
    let deleteEnabled: Bool
    /// Eşitleme rutininin önizlemesi: "eksik" A → B, "fazla" B → A, "değişmiş" iki yanda farklı.
    var sync = false
}

/// İş eklenmeden önce neyin kopyalanacağını, güncelleneceğini ve (seçiliyse) silineceğini gösterir.
struct PreviewSheet: View {
    let presentation: PreviewPresentation
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var showAttributes = false

    var body: some View {
        let report = presentation.report
        let entries = report.entries.filter { showAttributes || $0.kind != .attributes }
        let deletions = presentation.deleteEnabled ? report.count(.extra) : 0
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.largeTitle)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.t(.previewTitle) + " · " + OpenSafety.visibleName(presentation.jobName))
                        .font(.headline)
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if deletions > 0 {
                Label(settings.t(.previewDeleteWarning, deletions), systemImage: "trash.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Toggle(settings.t(.verifyShowAttributes), isOn: $showAttributes)
                .disabled(report.count(.attributes) == 0)
            if entries.isEmpty {
                ContentUnavailableView(settings.t(.previewNothing), systemImage: "checkmark.circle")
                    .frame(maxHeight: .infinity)
            } else {
                Table(entries) {
                    TableColumn(settings.t(.detailStatus)) { entry in
                        Text(settings.t(key(for: entry.kind)))
                            .foregroundStyle(color(for: entry.kind))
                            .fontWeight(entry.kind == .extra && presentation.deleteEnabled ? .semibold : .regular)
                    }
                    .width(min: 110, ideal: 140, max: 180)
                    TableColumn(settings.t(.detailTarget)) { entry in
                        Label {
                            Text(OpenSafety.visibleName(entry.path))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(settings.t(.buttonClose)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660, height: 500)
    }

    private var summary: String {
        let report = presentation.report
        if !report.result.kind.isSuccess { return settings.t(.verifyFailed) + ": " + settings.result(report.result) }
        if !report.entries.contains(where: { $0.kind != .attributes && ($0.kind != .extra || presentation.deleteEnabled) }) {
            return settings.t(.previewNothing)
        }
        if presentation.sync {
            return settings.t(.syncPreviewSummary, report.count(.missing), report.count(.extra), report.count(.changed))
        }
        let key: LKey = presentation.deleteEnabled ? .previewSummary : .previewSummaryKept
        return settings.t(key, report.count(.missing), report.count(.changed), report.count(.extra))
    }

    private var symbol: String {
        if !presentation.report.result.kind.isSuccess { return "exclamationmark.triangle.fill" }
        return presentation.deleteEnabled && presentation.report.count(.extra) > 0 ? "exclamationmark.triangle.fill" : "eye.circle.fill"
    }

    private var color: Color {
        if !presentation.report.result.kind.isSuccess { return .red }
        return presentation.deleteEnabled && presentation.report.count(.extra) > 0 ? .orange : .accentColor
    }

    private func key(for kind: DiffEntry.Kind) -> LKey {
        if presentation.sync {
            switch kind {
            case .missing: return .syncPreviewToB
            case .extra: return .syncPreviewToA
            case .changed, .attributes: return .syncPreviewDiffer
            }
        }
        return switch kind {
        case .missing: .previewWillCopy
        case .changed: .previewWillUpdate
        case .attributes: .previewAttributes
        case .extra: presentation.deleteEnabled ? .previewWillDelete : .previewKept
        }
    }

    private func color(for kind: DiffEntry.Kind) -> Color {
        if presentation.sync { return kind == .changed ? .orange : .green }
        return switch kind {
        case .missing: .green
        case .changed: .blue
        case .attributes: .secondary
        case .extra: presentation.deleteEnabled ? .red : .secondary
        }
    }
}

// MARK: - Geçmiş

/// İşin önceki çalıştırmaları, en yeniden eskiye (ayrıntılar paneli).
struct JobHistoryList: View {
    let job: TransferJob
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.t(.detailHistory)).font(.headline)
            if job.history.isEmpty {
                Text(settings.t(.detailNoHistory)).foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(job.history.reversed()) { run in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: symbol(run.result.kind))
                            .foregroundStyle(color(run.result.kind))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(settings.result(run.result))
                                .font(.caption.weight(.medium))
                            Text(detail(run))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func detail(_ run: JobRun) -> String {
        var parts = [settings.date(run.startedAt), settings.duration(seconds: Int(run.duration.rounded()))]
        if let bytes = run.bytesTransferred { parts.append(settings.t(.progressBytes, settings.bytes(bytes))) }
        if let files = run.filesTransferred { parts.append(settings.t(.progressFiles, files)) }
        if let snapshot = run.result.snapshot { parts.append(settings.t(.historySnapshot, snapshot)) }
        if let differences = run.result.differenceCount, run.result.kind != .verificationFailed {
            parts.append(settings.t(.historyDifferences, differences))
        }
        return parts.joined(separator: " · ")
    }

    private func symbol(_ kind: JobResultKind) -> String {
        if kind.isSuccess { return "checkmark.circle.fill" }
        switch kind {
        case .cancelled, .stoppedAtLimit: return "pause.circle.fill"
        default: return "xmark.octagon.fill"
        }
    }

    private func color(_ kind: JobResultKind) -> Color {
        if kind.isSuccess { return .green }
        switch kind {
        case .cancelled, .stoppedAtLimit: return .orange
        default: return .red
        }
    }
}
