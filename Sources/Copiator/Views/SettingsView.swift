// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CopiatorCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        TabView {
            Tab(settings.t(.settingsGeneral), systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab(settings.t(.settingsCopying), systemImage: "doc.on.doc") {
                CopyingSettingsView()
            }
            Tab(settings.t(.settingsRsync), systemImage: "slider.horizontal.3") {
                RsyncSettingsView()
            }
            Tab(settings.t(.settingsShortcuts), systemImage: "command") {
                ShortcutsSettingsView()
            }
            Tab(settings.t(.settingsAdvanced), systemImage: "wrench.and.screwdriver") {
                AdvancedSettingsView()
            }
        }
        .frame(width: 620)
        .frame(minHeight: 520)
    }
}

/// Yeni işlerin gelişmiş rsync seçenekleri (varsayılanlar). Her iş bunları Yeni İş sayfasında değiştirebilir.
private struct RsyncSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Text(settings.t(.settingsRsyncNote))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let problems = settings.defaultAdvanced.problems(source: nil)
                ForEach(problems.indices, id: \.self) { index in
                    Label(settings.problem(problems[index]), systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            AdvancedOptionsSections(options: $settings.defaultAdvanced, deleteEnabled: true)
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var showRestartAlert = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(settings.t(.settingsLanguage), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text("\(language.flag)  \(language.nativeName ?? settings.t(.languageSystem))")
                            .tag(language)
                    }
                }
                .onChange(of: settings.language) { old, new in
                    if old != new { showRestartAlert = true }
                }
                Picker(settings.t(.settingsAppearance), selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Label(settings.t(appearance.titleKey), systemImage: appearance.systemImage)
                            .tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(settings.t(.restartMenuBarNotice))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(settings.t(.settingsNotify), isOn: $settings.notifyOnFinish)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(settings.t(.settingsResumeInterrupted), isOn: $settings.resumeInterruptedAtLaunch)
                    Text(settings.t(.settingsResumeInterruptedNote))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(settings.t(.settingsPowerSection)) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(settings.t(.settingsKeepDisplayAwake), isOn: $settings.keepDisplayAwake)
                    Text(settings.t(.settingsKeepDisplayAwakeNote))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .alert(settings.t(.restartWarningTitle), isPresented: $showRestartAlert) {
            Button(settings.t(.buttonOK), role: .cancel) {}
        } message: {
            Text(settings.t(.restartMenuBarNotice))
        }
    }
}

private struct CopyingSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(settings.t(.newJobMode), selection: $settings.defaultCopyMode) {
                    Text(settings.t(.modeFolder)).tag(CopyMode.folder)
                    Text(settings.t(.modeContents)).tag(CopyMode.contents)
                }
                note(.optionPreservePermissions, .optionPreservePermissionsNote, $settings.defaultPreservePermissions)
                note(.optionXattrs, .optionXattrsNote, $settings.defaultPreserveXattrs)
                note(.optionExcludeSystem, .optionExcludeSystemNote, $settings.defaultExcludeSystemFolders)
            } header: {
                Text(settings.t(.settingsDefaultsSection))
            } footer: {
                Text(settings.t(.settingsDefaultsNote))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func note(_ title: LKey, _ detail: LKey, _ isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(settings.t(title), isOn: isOn)
            Text(settings.t(detail))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var confirmReset = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LabeledContent(settings.t(.settingsEnginePath)) {
                    Text(model.engineURL?.path ?? settings.t(.settingsEngineNotFound))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(settings.t(.settingsEngineVersion)) {
                    engineVersionLabel
                }
                Toggle(settings.t(.settingsEngineUseCustom), isOn: useCustomEngine)
                if let path = settings.customEnginePath {
                    LabeledContent("rsync") {
                        HStack {
                            Text(path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                            Button(settings.t(.buttonChoose)) { chooseEngine() }
                        }
                    }
                }
                Button(settings.t(.settingsEngineCheck)) {
                    Task { await model.refreshEngine() }
                }
                .disabled(model.runningJobID != nil)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(settings.t(.settingsSandbox), isOn: $settings.sandboxEngine)
                        .disabled(!SandboxProfile.isAvailable)
                    Text(settings.t(.settingsSandboxNote))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(settings.t(.settingsEngine))
            } footer: {
                Text(settings.t(.settingsEngineLimitedNote))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                updateStatus
                HStack {
                    Button(settings.t(.updateCheck)) {
                        Task { await model.checkForUpdates(interactive: false) }
                    }
                    .disabled(model.updateState == .checking || isInstalling)
                    if case .available(let latest, _) = model.updateState {
                        Button(settings.t(.updateInstall, latest)) { model.installUpdate() }
                            .buttonStyle(.glassProminent)
                            .disabled(model.runningJobID != nil || model.operation != nil)
                    }
                }
            } header: {
                Text(settings.t(.updateSection))
            } footer: {
                Text(settings.t(.updateSource) + " " + settings.t(.updateBuildNote))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(settings.t(.appUpdateSection)) {
                LabeledContent(settings.t(.appVersionLabel), value: "\(AppInfo.version) (\(AppInfo.build))")
                appUpdateStatus
                HStack {
                    Button(settings.t(.updateCheck)) {
                        Task { await model.checkForAppUpdate(interactive: false) }
                    }
                    .disabled(model.appUpdateState == .checking)
                    if case .available = model.appUpdateState {
                        Button(settings.t(.appUpdateDownload)) { model.openAppDownload() }
                            .buttonStyle(.glassProminent)
                    }
                }
                // Copiator ve rsync için ortak açılış denetimi; elle değiştirmek de izin yanıtı sayılır.
                Toggle(settings.t(.updateAutoCheck), isOn: $settings.checkUpdatesAtLaunch)
                    .onChange(of: settings.checkUpdatesAtLaunch) { settings.updateConsentAsked = true }
            }

            Section {
                Button(settings.t(.settingsReset), role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(settings.t(.settingsResetConfirm), isPresented: $confirmReset) {
            Button(settings.t(.settingsReset), role: .destructive) {
                settings.resetAll()
                Task { await model.refreshEngine() }
            }
        }
    }

    private var isInstalling: Bool {
        if case .installing = model.updateState { return true }
        return false
    }

    @ViewBuilder
    private var engineVersionLabel: some View {
        switch model.engineStatus {
        case .checking:
            ProgressView().controlSize(.small)
        case .ready(let version, let limited):
            Label(version, systemImage: limited ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(limited ? .orange : .green)
        case .missing:
            Label(settings.t(.settingsEngineNotFound), systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .blocked:
            Label(settings.t(.engineBlockedTitle), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch model.updateState {
        case .idle:
            EmptyView()
        case .checking:
            Label { Text(settings.t(.updateChecking)) } icon: { ProgressView().controlSize(.small) }
        case .available(let latest, let installed):
            Label(settings.t(.updateAvailable, latest, installed ?? settings.t(.unknown)), systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
        case .upToDate(let version):
            Label(settings.t(.updateUpToDate, version), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .installing(let version):
            Label { Text(settings.t(.updateInstalling, version)) } icon: { ProgressView().controlSize(.small) }
        case .installed(let version):
            Label(settings.t(.updateInstalled, version), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var appUpdateStatus: some View {
        switch model.appUpdateState {
        case .idle:
            EmptyView()
        case .checking:
            Label { Text(settings.t(.updateChecking)) } icon: { ProgressView().controlSize(.small) }
        case .available(let release):
            Label(settings.t(.appUpdateAvailable, release.version, AppInfo.version), systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
        case .upToDate:
            Label(settings.t(.appUpdateUpToDate, AppInfo.version), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var useCustomEngine: Binding<Bool> {
        Binding {
            settings.customEnginePath != nil
        } set: { enabled in
            if enabled {
                chooseEngine()
            } else {
                settings.customEnginePath = nil
                Task { await model.refreshEngine() }
            }
        }
    }

    private func chooseEngine() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            settings.customEnginePath = url.path
            Task { await model.refreshEngine() }
        }
    }
}

private struct ShortcutsSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var recordingAction: ShortcutAction? = nil
    @State private var monitor: Any? = nil
    @State private var recordingWarning: String? = nil

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    customShortcutRow(for: action)
                }
            } header: {
                Text(settings.t(.shortcutCustomSection))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.t(.shortcutRecordHelp))
                    if let warning = recordingWarning {
                        Text(warning)
                            .foregroundStyle(.red)
                            .fontWeight(.semibold)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Button(settings.t(.shortcutResetAll)) {
                    stopRecording()
                    settings.resetAllShortcuts()
                }
                .disabled(settings.isAllShortcutsDefault)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onDisappear {
            stopRecording()
        }
    }

    private func customShortcutRow(for action: ShortcutAction) -> some View {
        let currentShortcut = settings.shortcut(for: action)
        let isRecording = recordingAction == action
        let isCustomized = !settings.isDefaultShortcut(for: action)

        return HStack {
            Text(settings.t(action.titleKey))
            Spacer()
            if isCustomized && !isRecording {
                Button {
                    settings.resetShortcut(for: action)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(settings.t(.shortcutResetDefault))
                .accessibilityLabel(settings.t(.shortcutResetDefault))
            }

            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording(for: action)
                }
            } label: {
                HStack(spacing: 4) {
                    if isRecording {
                        ProgressView()
                            .controlSize(.mini)
                        Text(settings.t(.shortcutRecordPrompt))
                            .foregroundStyle(.tint)
                    } else {
                        Text(currentShortcut.displayString)
                    }
                }
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isRecording ? Color.accentColor.opacity(0.15) : Color(nsColor: .quaternaryLabelColor).opacity(0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRecording ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
            // VoiceOver yalnızca "⌘N, düğme" diyordu; hangi işlemin kısayolu olduğu söylenmiyordu.
            .accessibilityLabel(settings.t(action.titleKey))
            .accessibilityValue(isRecording ? settings.t(.shortcutRecordPrompt) : currentShortcut.displayString)
            .accessibilityHint(settings.t(.shortcutRecordHelp))
        }
    }


    private func startRecording(for action: ShortcutAction) {
        stopRecording()
        recordingAction = action
        recordingWarning = nil

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            return handleKeyDown(event, for: action)
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recordingAction = nil
        recordingWarning = nil
    }

    private func handleKeyDown(_ event: NSEvent, for action: ShortcutAction) -> NSEvent? {
        // 1. Esc tuşu: İptal et (keyCode 53)
        if event.keyCode == 53 {
            DispatchQueue.main.async {
                self.stopRecording()
            }
            return nil
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let hasShift = flags.contains(.shift)
        let hasOption = flags.contains(.option)
        let hasControl = flags.contains(.control)

        // 2. Özel tuşlar (Arrow keys, Return, Tab, Backspace vb.)
        let specialKey: (key: String, code: UInt16)?
        switch event.keyCode {
        case 126: specialKey = ("↑", 126)
        case 125: specialKey = ("↓", 125)
        case 123: specialKey = ("←", 123)
        case 124: specialKey = ("→", 124)
        case 36:  specialKey = ("↩", 36)
        case 48:  specialKey = ("⇥", 48)
        case 51:  specialKey = ("⌫", 51)
        default:  specialKey = nil
        }

        // 3. Delete / Backspace ile niteleyicisiz basılırsa varsayılana dön (niteleyicisiz tuş alabilen eylemde
        // varsayılan zaten ⌫'dir).
        if event.keyCode == 51 && !hasCommand && !hasOption && !hasControl {
            DispatchQueue.main.async {
                self.settings.resetShortcut(for: action)
                self.stopRecording()
            }
            return nil
        }

        let keyString: String
        let isSpecial: Bool
        let specialCode: UInt16?

        if let (symbol, code) = specialKey {
            keyString = symbol
            isSpecial = true
            specialCode = code
        } else {
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
                  let firstChar = chars.first else {
                return nil
            }
            if firstChar == " " {
                keyString = "Space"
                isSpecial = true
                specialCode = 49
            } else {
                keyString = String(firstChar).uppercased()
                isSpecial = false
                specialCode = nil
            }
        }

        // 4. Niteleyici denetimi:
        // Standart harf ve sayılar için en az bir komut/seçenek/kontrol tuşu zorunludur.
        // Kenar çubuğunda bir satırın üzerindeyken çalışan eylem (Listeden Kaldır) niteleyicisiz tuş alabilir.
        let hasPrimaryModifier = hasCommand || hasOption || hasControl
        if !hasPrimaryModifier && !action.allowsBareKey {
            NSSound.beep()
            DispatchQueue.main.async {
                self.recordingWarning = self.settings.t(.shortcutModifierRequired)
            }
            return nil
        }

        let newShortcut = KeyboardShortcutData(
            key: keyString,
            isSpecialKey: isSpecial,
            specialKeyCode: specialCode,
            command: hasCommand,
            shift: hasShift,
            option: hasOption,
            control: hasControl
        )

        // 5. Çakışma denetimi: Başka bir eylem bu kısayolu zaten kullanıyor mu?
        if let conflict = ShortcutAction.allCases.first(where: { $0 != action && self.settings.shortcut(for: $0) == newShortcut }) {
            NSSound.beep()
            DispatchQueue.main.async {
                self.recordingWarning = String(format: self.settings.t(.shortcutConflictWarning), self.settings.t(conflict.titleKey))
            }
            return nil
        }

        DispatchQueue.main.async {
            self.settings.setShortcut(newShortcut, for: action)
            self.stopRecording()
        }
        return nil
    }
}
