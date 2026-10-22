// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CopiatorCore
import SwiftUI

/// rsync'in kum havuzunda kullanılabilen gelişmiş seçenekleri. Ayarlar › rsync (yeni işlerin varsayılanları) ve Yeni İş
/// sayfası (o işe özel) aynı formu kullanır. Bir `Form` içinde bölümler olarak yerleştirilir.
struct AdvancedOptionsSections: View {
    @Binding var options: AdvancedOptions
    /// "Kaynakta olmayanları hedeften sil" açık mı (silme ayrıntıları yalnızca o zaman uygulanır).
    var deleteEnabled: Bool
    /// Otomatik anlık görüntüler açık mı (önceki yedek o zaman kendiliğinden seçilir).
    var snapshotsEnabled = false
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ExcludePresetsSection(presets: $options.excludePresets)

        Section {
            patternsField(.advFilterRules, $options.filterRules)
            patternsField(.advIncludePatterns, $options.includePatterns)
            patternsField(.advExcludePatterns, $options.excludePatterns)
            note(settings.t(.advPatternsNote))
            Toggle(settings.t(.advUseFilterFiles), isOn: $options.useFilterFiles)
            pathField(.advIncludeFrom, $options.includeFromFile, kind: .openFile)
            pathField(.advExcludeFrom, $options.excludeFromFile, kind: .openFile)
            pathField(.advFilesFrom, $options.filesFromFile, kind: .openFile)
            note(settings.t(.advFilesFromNote))
            sizeField(.advMaxSize, $options.maxSizeBytes)
            sizeField(.advMinSize, $options.minSizeBytes)
            Toggle(settings.t(.advIgnoreExisting), isOn: $options.ignoreExisting)
            Toggle(settings.t(.advExistingOnly), isOn: $options.existingOnly)
            Toggle(settings.t(.advUpdateOnly), isOn: $options.updateOnly)
            Toggle(settings.t(.advPruneEmpty), isOn: $options.pruneEmptyDirectories)
        } header: {
            Text(settings.t(.advSelection))
        }

        Section {
            Toggle(settings.t(.advHardLinks), isOn: $options.hardLinks)
            note(settings.t(.advHardLinksNote))
            Toggle(settings.t(.advCreationTimes), isOn: $options.creationTimes)
            Toggle(settings.t(.advAccessTimes), isOn: $options.accessTimes)
            Toggle(settings.t(.advNumericIDs), isOn: $options.numericIDs)
            Toggle(settings.t(.advOneFileSystem), isOn: $options.oneFileSystem)
            textField(.advChmod, $options.chmod)
            note(settings.t(.advChmodNote))
        } header: {
            Text(settings.t(.advAttributes))
        }

        Section {
            Picker(settings.t(.advSymlinks), selection: $options.symlinks) {
                Text(settings.t(.symlinkPreserve)).tag(SymlinkMode.preserve)
                Text(settings.t(.symlinkCopyTargets)).tag(SymlinkMode.copyTargets)
                Text(settings.t(.symlinkCopyUnsafe)).tag(SymlinkMode.copyUnsafeTargets)
                Text(settings.t(.symlinkSkipUnsafe)).tag(SymlinkMode.skipUnsafe)
            }
        } header: {
            Text(settings.t(.advLinks))
        }

        Section {
            Toggle(settings.t(.advSparse), isOn: $options.sparse)
            Toggle(settings.t(.advInplace), isOn: $options.inplace)
            note(settings.t(.advInplaceNote))
            Toggle(settings.t(.advWholeFile), isOn: $options.wholeFile)
            note(settings.t(.advWholeFileNote))
            Picker(settings.t(.advAppend), selection: $options.appendMode) {
                Text(settings.t(.appendOff)).tag(AppendMode.off)
                Text(settings.t(.appendOn)).tag(AppendMode.append)
                Text(settings.t(.appendVerify)).tag(AppendMode.appendVerify)
            }
        } header: {
            Text(settings.t(.advWriting))
        } footer: {
            note(settings.t(.advUnavailableNote))
        }

        Section {
            Picker(settings.t(.advDeleteTiming), selection: $options.deleteTiming) {
                Text(settings.t(.deleteDuring)).tag(DeleteTiming.during)
                Text(settings.t(.deleteBefore)).tag(DeleteTiming.before)
                Text(settings.t(.deleteAfter)).tag(DeleteTiming.after)
                Text(settings.t(.deleteDelay)).tag(DeleteTiming.delay)
            }
            Toggle(settings.t(.advDeleteExcluded), isOn: $options.deleteExcluded)
            numberField(.advMaxDelete, $options.maxDelete)
            Toggle(settings.t(.advIgnoreErrors), isOn: $options.ignoreErrors)
        } header: {
            Text(settings.t(.advDeletion))
        } footer: {
            note(settings.t(.advDeleteNote))
                .foregroundStyle(deleteEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        }

        Section {
            Toggle(settings.t(.advSizeOnly), isOn: $options.sizeOnly)
            numberField(.advModifyWindow, $options.modifyWindowSeconds)
            numberField(.advBandwidth, $options.bandwidthLimitKiB)
            numberField(.advStopAfter, $options.stopAfterMinutes)
            stopAtField
            note(settings.t(.advStopNote))
            textField(.advIconv, $options.iconv)
            note(settings.t(.advIconvNote))
        } header: {
            Text(settings.t(.advComparison))
        }

        Section {
            if snapshotsEnabled {
                note(settings.t(.snapshotReferenceIgnored))
            } else {
                Picker(settings.t(.advReferenceMode), selection: $options.referenceMode) {
                    Text(settings.t(.referenceNone)).tag(ReferenceMode.none)
                    Text(settings.t(.referenceLink)).tag(ReferenceMode.linkDest)
                    Text(settings.t(.referenceCompare)).tag(ReferenceMode.compareDest)
                    Text(settings.t(.referenceCopy)).tag(ReferenceMode.copyDest)
                }
                if options.referenceMode != .none {
                    pathField(.advReferenceDirectory, $options.referenceDirectory, kind: .directory)
                }
                note(settings.t(.advReferenceNote))
            }
            Toggle(settings.t(.advKeepBackups), isOn: $options.keepBackups)
            if options.keepBackups {
                pathField(.advBackupDirectory, $options.backupDirectory, kind: .directory)
                textField(.advBackupSuffix, $options.backupSuffix)
            }
            note(settings.t(.advBackupsNote))
        } header: {
            Text(settings.t(.advSnapshots))
        }

        Section {
            Picker(settings.t(.advProgressDetail), selection: $options.progressDetail) {
                Text(settings.t(.progressDetailTotal)).tag(ProgressDetail.total)
                Text(settings.t(.progressDetailPerFile)).tag(ProgressDetail.perFile)
            }
            Toggle(settings.t(.advShowFileNames), isOn: $options.showFileNames)
            Toggle(settings.t(.advPreciseProgress), isOn: $options.preciseProgress)
            note(settings.t(.advPreciseNote))
            Toggle(settings.t(.advFileListProgress), isOn: $options.fileListProgress)
                .disabled(!options.preciseProgress)
            note(settings.t(.advFileListNote))
            Toggle(settings.t(.advShowStats), isOn: $options.showStats)
            Toggle(settings.t(.advLogChanges), isOn: $options.logChanges)
            note(settings.t(.advLogChangesNote))
            pathField(.advLogFile, $options.logFile, kind: .saveFile)
            Picker(settings.t(.advBatchMode), selection: $options.batchMode) {
                Text(settings.t(.batchOff)).tag(BatchMode.off)
                Text(settings.t(.batchWrite)).tag(BatchMode.write)
                Text(settings.t(.batchOnlyWrite)).tag(BatchMode.onlyWrite)
            }
            if options.batchMode != .off {
                pathField(.advBatchFile, $options.batchFile, kind: .saveFile)
            }
        } header: {
            Text(settings.t(.advProgress))
        }
    }

    // MARK: - Alan yardımcıları

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Her satıra bir kalıp: dizi ↔ çok satırlı metin.
    private func patternsField(_ key: LKey, _ patterns: Binding<[String]>) -> some View {
        let text = Binding<String>(
            get: { patterns.wrappedValue.joined(separator: "\n") },
            set: { patterns.wrappedValue = $0.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(settings.t(key))
            TextField(settings.t(key), text: text, axis: .vertical)
                .font(.body.monospaced())
                .lineLimit(2...6)
                .labelsHidden()
        }
    }

    /// İsteğe bağlı metin: boş bırakılınca seçenek verilmez.
    private func textField(_ key: LKey, _ value: Binding<String?>) -> some View {
        let text = Binding<String>(
            get: { value.wrappedValue ?? "" },
            set: { value.wrappedValue = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        )
        return TextField(settings.t(key), text: text)
            .font(.body.monospaced())
    }

    /// İsteğe bağlı tam sayı: anahtar kapalıyken seçenek verilmez.
    private func numberField(_ key: LKey, _ value: Binding<Int?>) -> some View {
        let enabled = Binding<Bool>(
            get: { value.wrappedValue != nil },
            set: { value.wrappedValue = $0 ? (value.wrappedValue ?? 1) : nil }
        )
        let number = Binding<Int>(get: { value.wrappedValue ?? 0 }, set: { value.wrappedValue = max(0, $0) })
        return HStack {
            Toggle(settings.t(key), isOn: enabled)
            Spacer()
            TextField(settings.t(key), value: number, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .disabled(value.wrappedValue == nil)
        }
    }

    /// Boyut sınırı (MB, 1024 tabanlı) ↔ bayt.
    private func sizeField(_ key: LKey, _ bytes: Binding<Int64?>) -> some View {
        let megabyte: Int64 = 1 << 20
        let enabled = Binding<Bool>(
            get: { bytes.wrappedValue != nil },
            set: { bytes.wrappedValue = $0 ? (bytes.wrappedValue ?? 100 * megabyte) : nil }
        )
        let megabytes = Binding<Double>(
            get: { Double(bytes.wrappedValue ?? 0) / Double(megabyte) },
            set: { bytes.wrappedValue = Int64(max(0, $0) * Double(megabyte)) }
        )
        return HStack {
            Toggle(settings.t(key), isOn: enabled)
            Spacer()
            TextField(settings.t(key), value: megabytes, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .disabled(bytes.wrappedValue == nil)
        }
    }

    private var stopAtField: some View {
        let enabled = Binding<Bool>(
            get: { options.stopAt != nil },
            set: { options.stopAt = $0 ? (options.stopAt ?? Date().addingTimeInterval(3600)) : nil }
        )
        let date = Binding<Date>(get: { options.stopAt ?? Date() }, set: { options.stopAt = $0 })
        return HStack {
            Toggle(settings.t(.advStopAt), isOn: enabled)
            Spacer()
            DatePicker(settings.t(.advStopAt), selection: date, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .disabled(options.stopAt == nil)
        }
    }

    enum PathKind { case openFile, saveFile, directory }

    /// Mutlak yol seçimi: panelle seçilir, temizlenebilir.
    private func pathField(_ key: LKey, _ path: Binding<String?>, kind: PathKind) -> some View {
        LabeledContent(settings.t(key)) {
            HStack {
                Text(path.wrappedValue.map(OpenSafety.visibleName) ?? settings.t(.advNotSet))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                Button(settings.t(.buttonChoose)) { choosePath(path, kind: kind) }
                if path.wrappedValue != nil {
                    Button(settings.t(.buttonClear)) { path.wrappedValue = nil }
                }
            }
        }
    }

    private func choosePath(_ path: Binding<String?>, kind: PathKind) {
        switch kind {
        case .saveFile:
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
        case .openFile, .directory:
            let panel = NSOpenPanel()
            panel.canChooseFiles = kind == .openFile
            panel.canChooseDirectories = kind == .directory
            panel.canCreateDirectories = kind == .directory
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
        }
    }
}

/// İşin çalıştıracağı rsync komutu: salt okunur, seçilebilir ve kopyalanabilir.
struct CommandPreview: View {
    let command: String
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(settings.t(.newJobCommand)).font(.headline)
                Spacer()
                Button(settings.t(.buttonCopy), systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help(settings.t(.buttonCopy))
                .accessibilityLabel(settings.t(.buttonCopy))
            }
            Text(command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("copiator.command")
        }
    }
}

/// Çalışan işin uyku engeli durumu ve güç önerileri.
struct PowerStatusBanner: View {
    let status: SleepGuard.Status
    let advice: [PowerAdvice]
    let snapshot: PowerSnapshot?
    let settings: AppSettings
    /// Satırlar sarılır (kaydırılabilir bir alanda, ör. ayrıntılar paneli). Kapalıyken her satır tek satırdır, uzun metin
    /// kısaltılır ve tamamı ipucunda görünür: bant iş listesinin üstündeyken (`safeAreaInset`) yüksekliği sütun
    /// genişliğine bağlı olmamalı. Bağlı olursa bölünmüş görünüm sütun boyutlarını sonsuz döngüde yeniden hesaplar ve
    /// AppKit uygulamayı sonlandırır ("more Update Constraints in Window passes than there are views").
    var wrapsText = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(settings.t(status.systemSleepPrevented ? .sleepBadge : .sleepPreventedUnverified),
                  systemImage: status.systemSleepPrevented ? "cup.and.saucer.fill" : "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(status.systemSleepPrevented ? Color.green : Color.orange)
                .lineLimit(wrapsText ? nil : 1)
                .help(settings.t(.sleepBadgeHelp))
            ForEach(advice, id: \.self) { item in
                let text = settings.t(item.titleKey, arguments: snapshot.map { item.arguments($0, settings) } ?? [])
                if wrapsText {
                    Label(text, systemImage: item.systemImage)
                        .font(.caption)
                        .foregroundStyle(item.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(text, systemImage: item.systemImage)
                        .font(.caption)
                        .foregroundStyle(item.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(text)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("copiator.power")
    }
}

/// rsync kum havuzunda (sandbox-exec) çalıştığı için yapılamayanlar. Ayrıntısı: docs/rsync-not-possible-in-sandbox.md.
struct SandboxLimitsSection: View {
    @Environment(AppSettings.self) private var settings

    /// Her satır: simge, başlık, açıklama.
    static let items: [(symbol: String, title: LKey, detail: LKey)] = [
        ("network.slash", .sandboxLimitNetworkTitle, .sandboxLimitNetwork),
        ("lock.doc", .sandboxLimitSourceTitle, .sandboxLimitSource),
        ("terminal", .sandboxLimitProgramsTitle, .sandboxLimitPrograms),
        ("person.badge.key", .sandboxLimitPersonalTitle, .sandboxLimitPersonal),
        ("minus.circle", .sandboxLimitNotOfferedTitle, .sandboxLimitNotOffered),
    ]

    var body: some View {
        Section {
            ForEach(Self.items, id: \.title) { item in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.t(item.title))
                            .font(.callout.weight(.semibold))
                        Text(settings.t(item.detail))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: item.symbol)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
            }
        } header: {
            Label(settings.t(.sandboxLimitsTitle), systemImage: "info.circle")
        } footer: {
            Text(settings.t(.sandboxLimitsFooter))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("copiator.sandbox.limits")
    }
}
