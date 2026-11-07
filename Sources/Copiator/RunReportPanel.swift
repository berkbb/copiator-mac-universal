// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CopiatorCore
import UniformTypeIdentifiers

/// Çalıştırma raporunu kaydetme penceresi: dosya adı işin adı ve çalıştırmanın bittiği zamanla önerilir.
@MainActor
enum RunReportPanel {
    static func save(model: AppModel, settings: AppSettings, id: TransferJob.ID) {
        guard let job = model.job(id), let run = job.history.last else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let stamp = run.finishedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let name = model.runReportTitle(job).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = settings.t(.reportFileName, name, stamp)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.saveRunReport(id, to: url)
    }
}
