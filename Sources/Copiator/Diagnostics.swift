// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CopiatorCore
import SwiftUI
import UniformTypeIdentifiers

/// Önizlenen tanılama raporu.
struct DiagnosticPresentation: Identifiable {
    let id = UUID()
    var text: String
}

extension AppModel {
    /// Raporda en çok kaç iş ve her işin son kaç günlük satırı yer alır.
    static let diagnosticJobLimit = 50
    static let diagnosticLogLimit = 20

    /// Tanılama raporunu hazırlar ve önizleme sayfasını açar. Rapor yalnızca bu Mac'te oluşturulur; kullanıcı kaydetmedikçe
    /// hiçbir yere yazılmaz ve uygulama onu hiçbir yere göndermez.
    func showDiagnostics() {
        diagnostics = DiagnosticPresentation(text: diagnosticReport())
    }

    /// Hata bildirimleri için düz metin rapor: sürümler, izinler, ayarlar, rutin sayısı ve işler (seçenekleri, rsync
    /// komutu, son günlük satırları). Kullanıcı adı, ev klasörü, disk, klasör ve dosya adları maskelenir
    /// (`DiagnosticMasker`). Biçim teknik ve İngilizcedir (geliştiriciye gönderilmek üzere); günlük satırları uygulamanın
    /// dilindedir.
    func diagnosticReport(now: Date = Date(), masker given: DiagnosticMasker? = nil) -> String {
        let masker = given ?? DiagnosticMasker(home: homeDirectory.path, userNames: [NSUserName(), NSFullUserName()])
        let process = ProcessInfo.processInfo
        let os = process.operatingSystemVersion
        var architecture = "unknown"
        #if arch(arm64)
        architecture = "arm64"
        #elseif arch(x86_64)
        architecture = "x86_64"
        #endif
        func flag(_ value: Bool) -> String { value ? "on" : "off" }
        var lines = [
            "Copiator diagnostic report",
            "Created: " + ISO8601DateFormatter().string(from: now),
            "Copiator: \(AppInfo.version) (\(AppInfo.build)) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(architecture)"
                + " · in Applications: \(isInApplicationsFolder ? "yes" : "no")",
            "rsync: " + engineSummary + " · sandbox-exec: " + (SandboxProfile.isAvailable ? "available" : "missing"),
            "Permissions: notifications=\(notificationPermission) · full disk access="
                + (fullDiskAccessGranted.map(flag) ?? "unknown") + " · open at login=\(loginItemState)",
            "Settings: language=\(settings.language.rawValue) appearance=\(settings.appearance.rawValue)"
                + " sandbox=\(flag(settings.sandboxEngine)) lowPriorityIO=\(flag(settings.lowPriorityIO))"
                + " notifyOnFinish=\(flag(settings.notifyOnFinish)) backupReminderDays=\(settings.backupReminderDays)"
                + " integrityOnConnect=\(settings.integrityOnConnect.count) resumeInterrupted=\(flag(settings.resumeInterruptedAtLaunch))"
                + " keepDisplayAwake=\(flag(settings.keepDisplayAwake)) queueHeld=\(flag(settings.queueHeld))"
                + " defaultCopyMode=\(settings.defaultCopyMode.rawValue) verifyAfterCopy=\(settings.defaultVerifyAfterCopy.rawValue)"
                + " conflictPolicy=\(settings.defaultConflictPolicy.rawValue) customEngine=\(settings.customEnginePath == nil ? "no" : "yes")"
                + " menuBar=\(flag(settings.showMenuBarIcon)) dockProgress=\(flag(settings.showDockProgress))"
                + " aiSuggestions=\(flag(settings.aiSuggestions)) aiProvider=\(settings.aiProvider.rawValue)"
                + " updatesAtLaunch=\(flag(settings.checkUpdatesAtLaunch))",
            "Routines: \(routines.count) (\(routines.reduce(0) { $0 + $1.routes.count }) routes)",
            "Jobs: \(jobs.count)" + (jobs.count > Self.diagnosticJobLimit ? " (showing the last \(Self.diagnosticJobLimit))" : ""),
        ]
        let known = jobs.flatMap { [$0.source.path, $0.destination.path] }
        for (index, job) in jobs.suffix(Self.diagnosticJobLimit).enumerated() {
            let options = job.options
            let snapshots = options.snapshots
            lines.append("")
            lines.append("[\(index + 1)] " + masker.path(job.source.path) + " → " + masker.path(job.destination.path))
            lines.append("    kind=\(job.kind.rawValue) status=\(job.status.rawValue) result=" + (job.result.map { $0.kind.rawValue } ?? "none")
                + (job.result?.exitCode.map { " exit=\($0)" } ?? "") + " runs=\(job.history.count) routine=\(job.routineID == nil ? "no" : "yes")")
            lines.append("    options: mode=\(options.copyMode.rawValue) delete=\(flag(options.deleteExtraneous))"
                + " permissions=\(flag(options.preservePermissions)) xattrs=\(flag(options.preserveExtendedAttributes))"
                + " verify=\(options.verifyAfterCopy.rawValue) conflicts=\(options.conflictPolicy.rawValue)"
                + " snapshots=\(flag(snapshots.enabled))" + (snapshots.hasRetention ? "+retention" : "")
                + " runWhenConnected=\(flag(options.runWhenConnected)) ejectWhenDone=\(flag(options.ejectWhenDone))"
                + " trashSource=\(flag(options.trashSourceAfterCopy)) rules=\(options.rules == nil ? "no" : "yes")"
                + " placement=\(options.placement == nil ? "no" : "yes")")
            lines.append("    command: " + RsyncCommand.displayString(arguments: commandArguments(for: job).map(masker.argument)))
            if let detail = job.result?.detail, !detail.isEmpty {
                lines.append("    detail:")
                lines += detail.split(whereSeparator: \.isNewline).map { "      " + masker.text(String($0), knownPaths: known) }
            }
            let log = job.log.suffix(Self.diagnosticLogLimit)
            if !log.isEmpty {
                lines.append("    log (last \(log.count) of \(job.log.count)):")
                for entry in log {
                    let text = masker.text(settings.log(entry), knownPaths: known)
                    lines.append("      " + ISO8601DateFormatter().string(from: entry.date) + " \(entry.level.rawValue) " + text)
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private var engineSummary: String {
        guard let info = engineInfo else { return "not found" }
        let kind = info.isOpenrsync ? "openrsync (limited)" : (settings.customEnginePath == nil ? "bundled or system" : "custom")
        return "\(info.version) · \(kind)"
    }
}

/// Tanılama raporu önizlemesi: tam metin okunabilir ve seçilebilir; "Kaydet…" bir metin dosyasına yazar. Uygulama raporu
/// hiçbir yere göndermez.
struct DiagnosticSheet: View {
    let presentation: DiagnosticPresentation
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "stethoscope").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                Text(settings.t(.diagnosticsTitle)).font(.headline)
            }
            Text(settings.t(.diagnosticsNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(presentation.text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("copiator.diagnostics.text")
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(settings.t(.buttonClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.t(.diagnosticsSave)) { save() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("copiator.diagnostics.save")
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = settings.t(.diagnosticsFileName)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(presentation.text.utf8).write(to: url, options: .atomic)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
