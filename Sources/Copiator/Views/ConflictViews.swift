// SPDX-License-Identifier: GPL-3.0-or-later
import CopiatorCore
import SwiftUI

extension AppSettings {
    func title(_ decision: ConflictDecision) -> String {
        switch decision {
        case .replace: t(.conflictReplace)
        case .keepBoth: t(.conflictKeepBoth)
        case .skip: t(.conflictSkip)
        }
    }

    func title(_ policy: ConflictPolicy) -> String {
        switch policy {
        case .ask: t(.conflictPolicyAsk)
        case .replace: t(.conflictPolicyReplace)
        case .keepBoth: t(.conflictPolicyKeepBoth)
        case .skip: t(.conflictPolicySkip)
        }
    }
}

extension ConflictDecision {
    /// Sayfadaki numara ve kısayol (1 · Değiştir, 2 · İkisini de sakla, 3 · Atla).
    var number: Int {
        switch self {
        case .replace: 1
        case .keepBoth: 2
        case .skip: 3
        }
    }
}

/// "Hedefte aynı adlı dosya varsa" seçimi (Yeni İş, rutin ve Ayarlar › Kopyalama).
struct ConflictPolicyPicker: View {
    @Binding var selection: ConflictPolicy
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(settings.t(.optionConflictPolicy), selection: $selection) {
                ForEach(ConflictPolicy.allCases) { Text(settings.title($0)).tag($0) }
            }
            .accessibilityIdentifier("copiator.conflictPolicy")
            Text(settings.t(.optionConflictPolicyNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Hedefte aynı adlı dosyalar için karar: tümüne ya da dosya dosya 1 · Değiştir, 2 · İkisini de sakla, 3 · Atla.
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
            if let job = model.job(prompt.id), let report = job.pendingConflicts {
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
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.t(.conflictTitle, report.total)).font(.headline)
                    Text(settings.t(.conflictSubtitle, OpenSafety.visibleName(job.source.lastPathComponent),
                                    OpenSafety.visibleName(job.destination.path)))
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
                ForEach(ConflictDecision.allCases) { decision in
                    Button("\(decision.number) · " + settings.title(decision)) { applyAll(decision, report) }
                        .keyboardShortcut(KeyEquivalent(Character(String(decision.number))), modifiers: [])
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
                        ForEach(ConflictDecision.allCases) { decision in
                            Text("\(decision.number) · " + settings.title(decision)).tag(Optional(decision))
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
                Text(settings.t(.conflictKeepBothNote))
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
