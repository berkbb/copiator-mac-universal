// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CopiatorCore
import Observation

/// Günlük (konsol) penceresinin verisi: `AppLog` kayıtlarını ana iş parçacığında tutar, yeni kayıt gelince yenilenir.
@Observable
final class LogStore {
    static let shared = LogStore(log: .shared)

    /// Konsol'daki gibi: tüm iletiler ya da yalnızca hatalar ve uyarılar.
    enum Scope: String, CaseIterable, Identifiable {
        case all, problems

        var id: String { rawValue }
    }

    private(set) var entries: [AppLog.Entry]
    var scope: Scope = .all
    var searchText = ""
    @ObservationIgnored let log: AppLog
    @ObservationIgnored private var observer: UUID?
    /// Art arda gelen kayıtlar (ör. diskteki işlerin başlaması) tek yenilemede toplanır.
    @ObservationIgnored private var refreshPending = false

    init(log: AppLog) {
        self.log = log
        entries = log.entries
        observer = log.observe { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    isolated deinit {
        if let observer { log.removeObserver(observer) }
    }

    /// Kapsama ve aramaya uyan kayıtlar, eskiden yeniye.
    var visibleEntries: [AppLog.Entry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (scope == .all || entry.level.isProblem)
                && (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query)
                    || entry.detail?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    /// Günlük dosyası diskte var mı? (Finder'da gösterme ve Konsol'da açma için.)
    var hasFile: Bool {
        log.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func refresh() {
        refreshPending = false
        entries = log.entries
    }

    func clear() {
        log.clear()
        refresh()
    }

    func revealFile() {
        guard hasFile, let url = log.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Günlük dosyasını macOS'un Konsol uygulamasında açar (canlı kayıtlar Konsol'da alt sistemle de izlenir).
    func openInConsole() {
        guard hasFile, let url = log.fileURL,
              let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor in self.refresh() }
    }
}
