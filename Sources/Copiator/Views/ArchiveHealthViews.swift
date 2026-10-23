// SPDX-License-Identifier: GPL-3.0-or-later
import CopiatorCore
import SwiftUI

/// Bir hedefin arşiv bütünlüğü: son denetim, arka planda denetim (ilerleme ve durdurma), sonuç ve sorunlu dosyalar; isteğe
/// bağlı olarak disk takılınca kendiliğinden denetim.
struct IntegritySheet: View {
    let request: IntegrityRequest
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var manifest: ArchiveIntegrity.Manifest?
    @State private var confirmingRepair = false

    /// Listede gösterilen en çok dosya (her türden).
    static let maxListed = 100

    private var key: String { request.destination.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.t(.integrityTitle)).font(.headline)
                    Text(OpenSafety.visibleName(request.destination.path))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Text(settings.t(.integrityNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let manifest {
                Text(settings.t(.integrityLast, settings.date(manifest.checkedAt), manifest.files.count)).font(.callout)
            } else {
                Text(settings.t(.integrityNever)).font(.callout)
            }
            Toggle(settings.t(.integrityOnConnect), isOn: Binding(
                get: { settings.integrityOnConnect.contains(key) },
                set: { isOn in
                    settings.integrityOnConnect.removeAll { $0 == key }
                    if isOn { settings.integrityOnConnect.append(key) }
                }
            ))
            .accessibilityIdentifier("copiator.integrity.onConnect")
            Divider()
            if let progress = model.integrityRuns[key] {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(settings.t(.integrityChecking, progress.files, settings.bytes(progress.bytes))).font(.callout)
                    Spacer()
                    Button(settings.t(.integrityCancel)) { model.cancelIntegrityCheck(request.destination) }
                }
            } else if let outcome = model.integrityResults[key] {
                result(outcome)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(settings.t(.buttonClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.t(.integrityCheck)) { model.startIntegrityCheck(request.destination) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.integrityRuns[key] != nil)
                    .accessibilityIdentifier("copiator.integrity.check")
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .onAppear { manifest = ArchiveIntegrity.manifest(in: request.destination) }
        .onChange(of: model.integrityResults[key]) { manifest = ArchiveIntegrity.manifest(in: request.destination) }
        .confirmationDialog(settings.t(.integrityRepairConfirmTitle), isPresented: $confirmingRepair) {
            Button(settings.t(.integrityRepairButton)) { model.repairCorrupted(request.destination) }
            Button(settings.t(.buttonCancel), role: .cancel) {}
        } message: {
            Text(settings.t(.integrityRepairConfirmMessage))
        }
    }

    @ViewBuilder
    private func result(_ outcome: IntegrityOutcome) -> some View {
        switch outcome {
        case .failed(let message):
            Label(settings.t(.integrityFailed, message), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .report(let report):
            VStack(alignment: .leading, spacing: 8) {
                if report.isFirstCheck {
                    Text(settings.t(.integrityFirst, report.added)).font(.callout)
                } else {
                    Text(settings.t(.integritySummary, report.intact, report.added, report.updated)).font(.callout)
                }
                if !report.hasProblems {
                    Label(settings.t(.integrityNoProblems), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if model.integrityRepairing.contains(key) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(settings.t(.integrityRepairing)).font(.callout)
                        Spacer()
                        Button(settings.t(.integrityCancel)) { model.cancelRepair(request.destination) }
                    }
                } else if !report.corrupted.isEmpty {
                    Button(settings.t(.integrityRepair), systemImage: "wrench.and.screwdriver") { confirmingRepair = true }
                        .accessibilityIdentifier("copiator.integrity.repair")
                }
                if let repair = model.integrityRepairResults[key] {
                    Label(settings.t(.integrityRepaired, repair.repaired.count), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let repair = model.integrityRepairResults[key] {
                            files(repair.noCopy, title: settings.t(.integrityRepairNoCopy, repair.noCopy.count), color: .red)
                            files(repair.failed, title: settings.t(.integrityRepairFailed, repair.failed.count), color: .red)
                            files(repair.changed, title: settings.t(.integrityRepairChanged, repair.changed.count), color: .secondary)
                        }
                        files(report.corrupted, title: settings.t(.integrityCorrupted, report.corrupted.count), color: .red)
                        files(report.missing, title: settings.t(.integrityMissing, report.missing.count), color: .orange)
                        files(report.unreadable, title: settings.t(.integrityUnreadable, report.unreadable.count), color: .orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func files(_ paths: [String], title: String, color: Color) -> some View {
        if !paths.isEmpty {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(paths.prefix(Self.maxListed), id: \.self) { path in
                Text(OpenSafety.visibleName(path))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if paths.count > Self.maxListed {
                Text(settings.t(.integrityMore, paths.count - Self.maxListed)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Bir hedefte yinelenen dosyalar: aynı içerikli dosya grupları (en çok yer kaplayan önce); her grupta bir dosya kalır
/// (üzerine tıklanarak seçilir), fazlalar onayla Çöp Sepeti'ne taşınır.
struct DuplicatesSheet: View {
    let request: DuplicatesRequest
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [DuplicateFinder.Group]?
    @State private var keep: [String: String] = [:]
    @State private var failure: String?
    @State private var confirming = false

    /// Listede gösterilen en çok grup.
    static let maxListed = 200

    init(request: DuplicatesRequest, groups: [DuplicateFinder.Group]? = nil) {
        self.request = request
        _groups = State(initialValue: groups)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.t(.duplicatesTitle)).font(.headline)
                    Text(OpenSafety.visibleName(request.destination.path))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Text(settings.t(.duplicatesNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Label(settings.t(.duplicatesFailed, failure), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let groups {
                if groups.isEmpty {
                    ContentUnavailableView(settings.t(.duplicatesNone), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let extras = groups.reduce(0) { $0 + $1.paths.count - 1 }
                    Text(settings.t(.duplicatesSummary, groups.count, extras, settings.bytes(groups.reduce(0) { $0 + $1.wasted })))
                        .font(.callout.weight(.semibold))
                    List {
                        ForEach(groups.prefix(Self.maxListed)) { group in
                            Section(settings.t(.duplicatesGroup, group.paths.count, settings.bytes(group.size))) {
                                ForEach(group.paths, id: \.self) { path in
                                    let kept = (keep[group.id] ?? group.paths[0]) == path
                                    Button {
                                        keep[group.id] = path
                                    } label: {
                                        HStack {
                                            Image(systemName: kept ? "checkmark.circle.fill" : "trash").foregroundStyle(kept ? Color.green : Color.secondary)
                                            Text(OpenSafety.visibleName(path)).lineLimit(1).truncationMode(.middle)
                                            Spacer()
                                            if kept { Text(settings.t(.duplicatesKeep)).font(.caption).foregroundStyle(.green) }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if groups.count > Self.maxListed {
                            Text(settings.t(.duplicatesMore, groups.count - Self.maxListed)).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(settings.t(.duplicatesScanning)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button(settings.t(.buttonClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.t(.duplicatesTrash)) { confirming = true }
                    .disabled(groups?.isEmpty != false)
                    .accessibilityIdentifier("copiator.duplicates.trash")
            }
        }
        .padding(20)
        .frame(width: 680, height: 580)
        .task { if groups == nil { await scan() } }
        .confirmationDialog(settings.t(.duplicatesConfirmTitle, groups.map { $0.reduce(0) { $0 + $1.paths.count - 1 } } ?? 0),
                            isPresented: $confirming) {
            Button(settings.t(.duplicatesTrashConfirm), role: .destructive) { trash() }
            Button(settings.t(.buttonCancel), role: .cancel) {}
        } message: {
            Text(settings.t(.duplicatesConfirmMessage))
        }
    }

    private func scan() async {
        let destination = request.destination
        do {
            groups = try await Task.detached(priority: .userInitiated) { try DuplicateFinder.groups(in: destination) }.value
        } catch {
            failure = error.localizedDescription
        }
    }

    private func trash() {
        guard let groups else { return }
        _ = model.trashDuplicates(groups.map { (group: $0, keep: keep[$0.id] ?? $0.paths[0]) }, in: request.destination)
        self.groups = nil
        keep = [:]
        Task { await scan() }
    }
}
