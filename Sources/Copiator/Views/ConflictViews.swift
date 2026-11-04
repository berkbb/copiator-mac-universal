// SPDX-License-Identifier: GPL-3.0-only
import CopiatorCore
import SwiftUI

extension AppSettings {
    /// Kararın adı; eşitlemede "değiştir" A'dakinin B'ye, "ters" B'dekinin A'ya yazılmasıdır.
    func title(_ decision: ConflictDecision, kind: JobKind = .rsync) -> String {
        switch decision {
        case .replace: t(kind == .sync ? .conflictSyncUseA : .conflictReplace)
        case .keepBoth: t(.conflictKeepBoth)
        case .skip: t(.conflictSkip)
        case .reverse: t(.conflictSyncUseB)
        }
    }

    func title(_ policy: ConflictPolicy, kind: JobKind = .rsync) -> String {
        switch policy {
        case .ask: t(.conflictPolicyAsk)
        case .replace: t(kind == .sync ? .conflictPolicyUseA : .conflictPolicyReplace)
        case .keepBoth: t(.conflictPolicyKeepBoth)
        case .skip: t(.conflictPolicySkip)
        case .reverse: t(.conflictPolicyUseB)
        case .newer: t(.conflictPolicyNewer)
        }
    }
}

extension ConflictDecision {
    /// Sayfadaki numara ve kısayol: iş türündeki sırası (1 · Değiştir, 2 · İkisini de sakla, 3 · Atla; eşitlemede
    /// 1 · A'dakini B'ye, 2 · B'dekini A'ya, 3 · Atla).
    func number(for kind: JobKind) -> Int {
        (Self.choices(for: kind).firstIndex(of: self) ?? 0) + 1
    }
}

/// "Hedefte aynı adlı dosya varsa" seçimi (Yeni İş, rutin ve Ayarlar › Kopyalama).
struct ConflictPolicyPicker: View {
    @Binding var selection: ConflictPolicy
    /// Eşitleme rutininde "yenisi kazansın", "A kazansın", "B kazansın" sunulur.
    var kind: JobKind = .rsync
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(settings.t(kind == .sync ? .optionSyncPolicy : .optionConflictPolicy), selection: $selection) {
                ForEach(ConflictPolicy.choices(for: kind)) { Text(settings.title($0, kind: kind)).tag($0) }
            }
            .accessibilityIdentifier("copiator.conflictPolicy")
            Text(settings.t(kind == .sync ? .optionSyncPolicyNote : .optionConflictPolicyNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Hedefte aynı adlı dosyalar için karar: tümüne ya da dosya dosya 1 · Değiştir, 2 · İkisini de sakla, 3 · Atla. "Klasörü
/// sor" rotasında klasörü seçilmemiş dosyalar varsa önce onlar sorulur (`PlacementDecisionView`).
struct ConflictSheet: View {
    let prompt: ConflictPrompt
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var decisions: [String: ConflictDecision] = [:]
    /// "Tümüne" kararı: listede olmayanlara (listelenmeyenler, sonradan ortaya çıkanlar) da uygulanır.
    @State private var others: ConflictDecision?
    @State private var remember = false

    var body: some View {
        Group {
            if let job = model.job(prompt.id), let report = job.pendingPlacements {
                PlacementDecisionView(job: job, report: report)
            } else if let job = model.job(prompt.id), let report = job.pendingConflicts {
                content(job, report)
            } else {
                VStack {
                    ContentUnavailableView(settings.t(.verifyNothingToShow), systemImage: "checkmark.circle")
                    Button(settings.t(.buttonClose)) { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding(20)
            }
        }
        .frame(width: 720, height: 540)
    }

    /// Eski (bu ayardan önce kurulmuş) iş ya da rutinde "hatırla" önceden işaretlenir.
    private func suggestsRemembering(_ job: TransferJob) -> Bool {
        job.options.suggestsRememberingConflictChoice
            || job.routineID.flatMap(model.routine)?.options.suggestsRememberingConflictChoice == true
    }

    private func content(_ job: TransferJob, _ report: ConflictReport) -> some View {
        let identical = report.items.lazy.filter(\.identical).count
        let kind = job.kind
        let choices = ConflictDecision.choices(for: kind)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.t(kind == .sync ? .conflictSyncTitle : .conflictTitle, report.total)).font(.headline)
                    Text(kind == .sync
                         ? settings.t(.conflictSyncSubtitle, OpenSafety.visibleName(job.source.path), OpenSafety.visibleName(job.destination.path))
                         : settings.t(.conflictSubtitle, OpenSafety.visibleName(job.source.lastPathComponent), OpenSafety.visibleName(job.destination.path)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if identical > 0 {
                        Text(settings.t(.conflictIdenticalCount, identical)).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                Text(settings.t(.conflictApplyAll))
                ForEach(choices) { decision in
                    Button("\(decision.number(for: kind)) · " + settings.title(decision, kind: kind)) { applyAll(decision, report) }
                        .keyboardShortcut(KeyEquivalent(Character(String(decision.number(for: kind)))), modifiers: [])
                        .buttonStyle(.bordered)
                        .tint(others == decision ? .accentColor : nil)
                        .accessibilityIdentifier("copiator.conflict.all.\(decision.rawValue)")
                }
            }

            Table(report.items) {
                TableColumn(settings.t(.conflictFile)) { item in
                    HStack(spacing: 6) {
                        Text(OpenSafety.visibleName(item.path))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if item.identical {
                            Text(settings.t(.conflictIdentical))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if item.incomingFolder {
                            Text(settings.t(.conflictIncomingFolder))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                TableColumn(settings.t(.conflictDecisionColumn)) { item in
                    Picker(settings.t(.conflictDecisionColumn), selection: binding(for: item)) {
                        ForEach(choices) { decision in
                            Text("\(decision.number(for: kind)) · " + settings.title(decision, kind: kind)).tag(Optional(decision))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                .width(min: 300, ideal: 330)
            }

            VStack(alignment: .leading, spacing: 4) {
                if report.isTruncated {
                    Text(settings.t(.conflictTruncated, report.items.count, report.total))
                }
                Text(settings.t(kind == .sync ? .conflictSyncNote : .conflictKeepBothNote))
                if report.items.contains(where: \.incomingFolder) {
                    Text(settings.t(.conflictKeepBothFolderNote))
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            HStack {
                Toggle(settings.t(job.routineID != nil ? .conflictRememberRoutine : .conflictRememberJob), isOn: $remember)
                    .disabled(uniformDecision(report) == nil)
                Spacer()
                Button(settings.t(.conflictLater)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.t(.conflictContinue)) { submit(report) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!isComplete(report))
                    .accessibilityIdentifier("copiator.conflict.continue")
            }
        }
        .padding(20)
        .onAppear { remember = suggestsRemembering(job) }
    }

    private func binding(for item: FileConflict) -> Binding<ConflictDecision?> {
        Binding(
            get: { decisions[item.path] },
            set: { decisions[item.path] = $0 }
        )
    }

    private func applyAll(_ decision: ConflictDecision, _ report: ConflictReport) {
        others = decision
        for item in report.items { decisions[item.path] = decision }
    }

    /// Her listelenen dosyanın kararı var; liste kısaltıldıysa ötekiler için "Tümüne" kararı da var.
    private func isComplete(_ report: ConflictReport) -> Bool {
        report.items.allSatisfy { decisions[$0.path] != nil } && (!report.isTruncated || others != nil)
    }

    /// Tüm dosyalar için aynı karar verildiyse o (yalnızca o zaman "hatırla" anlamlıdır).
    private func uniformDecision(_ report: ConflictReport) -> ConflictDecision? {
        let values = Set(report.items.compactMap { decisions[$0.path] })
        guard isComplete(report), values.count == 1, let value = values.first, others == nil || others == value else { return nil }
        return value
    }

    private func submit(_ report: ConflictReport) {
        guard isComplete(report) else { return }
        let remembered = remember ? uniformDecision(report)?.policy : nil
        model.resolveConflicts(prompt.id, resolution: ConflictResolution(decisions: decisions, others: others), remember: remembered)
        dismiss()
    }
}
