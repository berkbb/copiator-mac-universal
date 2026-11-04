// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CopiatorCore
import SwiftUI

/// Konsol benzeri Günlük penceresi: uygulama, rsync motoru, işler, diskler, bütünlük denetimleri ve güncellemeler.
/// Önceki oturumun kayıtları da (günlük dosyasından) görünür; uygulamayı yeniden açmayı gerektiren bir takılmanın izi
/// kaybolmaz.
struct ConsoleView: View {
    @Environment(AppSettings.self) private var settings
    let store: LogStore
    @State private var selection: Set<AppLog.Entry.ID> = []
    @State private var sortOrder = [KeyPathComparator(\AppLog.Entry.id, order: .reverse)]

    private static let currentProcess = getpid()

    var body: some View {
        @Bindable var store = store
        let visible = store.visibleEntries.sorted(using: sortOrder)
        VSplitView {
            Table(visible, selection: $selection, sortOrder: $sortOrder) {
                TableColumn(settings.t(.consoleColumnTime), value: \.id) { entry in
                    Text(time(entry.date))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 150, ideal: 185)

                TableColumn(settings.t(.consoleColumnType)) { entry in
                    Label(settings.t(entry.level.titleKey), systemImage: entry.level.systemImage)
                        .foregroundStyle(entry.level.tint)
                }
                .width(min: 70, ideal: 95)

                TableColumn(settings.t(.consoleColumnCategory)) { entry in
                    Text(settings.t(entry.category.titleKey))
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 120)

                // Önceki oturumların kayıtları soluk: süreç kimliği farklıdır.
                TableColumn(settings.t(.consoleColumnProcess)) { entry in
                    Text(String(entry.process))
                        .monospacedDigit()
                        .foregroundStyle(entry.process == Self.currentProcess ? .secondary : .tertiary)
                }
                .width(min: 50, ideal: 65)

                TableColumn(settings.t(.consoleColumnMessage), value: \.message) { entry in
                    Text(entry.message)
                        .lineLimit(1)
                }
            }
            .contextMenu(forSelectionType: AppLog.Entry.ID.self) { ids in
                Button(settings.t(.buttonCopy), systemImage: "doc.on.doc") { copy(ids) }
            }
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView {
                        Label(settings.t(.consoleEmptyTitle), systemImage: "text.page.badge.magnifyingglass")
                    } description: {
                        Text(settings.t(.consoleEmptyMessage, AppLog.subsystem))
                    }
                }
            }
            .frame(minHeight: 180)

            ScrollView {
                Text(detailText)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(selectedEntries.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 70, idealHeight: 140)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(settings.t(.consoleTitle), selection: $store.scope) {
                    Text(settings.t(.consoleAllMessages)).tag(LogStore.Scope.all)
                    Text(settings.t(.consoleProblems)).tag(LogStore.Scope.problems)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(settings.t(.buttonCopy), systemImage: "doc.on.doc") {
                    copy(selection.isEmpty ? Set(visible.map(\.id)) : selection)
                }
                .help(settings.t(.buttonCopy))
                .disabled(visible.isEmpty)
                Button(settings.t(.consoleClear), systemImage: "trash") {
                    selection = []
                    store.clear()
                }
                .help(settings.t(.consoleClear))
                .disabled(store.entries.isEmpty)
                Button(settings.t(.buttonShowInFinder), systemImage: "folder") { store.revealFile() }
                    .help(settings.t(.buttonShowInFinder))
                    .disabled(!store.hasFile)
                Button(settings.t(.consoleOpenInConsole), systemImage: "terminal") { store.openInConsole() }
                    .help(settings.t(.consoleOpenInConsole))
                    .disabled(!store.hasFile)
            }
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: Text(settings.t(.consoleSearchPrompt)))
        .navigationTitle(settings.t(.consoleTitle))
        .navigationSubtitle(settings.t(.consoleMessageCount, visible.count))
        .frame(minWidth: 640, minHeight: 360)
        .accessibilityIdentifier("copiator.console")
    }

    private var selectedEntries: [AppLog.Entry] {
        store.entries.filter { selection.contains($0.id) }
    }

    /// Seçili kaydın tamamı (çoklu seçimde hepsi); seçim yoksa ipucu.
    private var detailText: String {
        let entries = selectedEntries
        return entries.isEmpty ? settings.t(.consoleSelectHint) : text(for: entries)
    }

    private func time(_ date: Date) -> String {
        date.formatted(
            .dateTime.day(.twoDigits).month(.twoDigits).year()
                .hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3))
                .locale(settings.locale)
        )
    }

    /// Panoya ve ayrıntı bölmesine giden metin: her kayıt bir başlık satırı ve (varsa) girintili ayrıntı.
    private func text(for entries: [AppLog.Entry]) -> String {
        entries.map { entry in
            let header = [time(entry.date), settings.t(entry.level.titleKey), settings.t(entry.category.titleKey), "[\(entry.process)]", entry.message]
                .joined(separator: "  ")
            guard let detail = entry.detail else { return header }
            return header + "\n" + detail.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    private func copy(_ ids: Set<AppLog.Entry.ID>) {
        let entries = store.entries.filter { ids.contains($0.id) }
        guard !entries.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(for: entries), forType: .string)
    }
}

extension AppLog.Level {
    var titleKey: LKey {
        switch self {
        case .info: .consoleLevelInfo
        case .warning: .consoleLevelWarning
        case .error: .consoleLevelError
        }
    }

    var systemImage: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

extension AppLog.Category {
    var titleKey: LKey {
        switch self {
        case .app: .consoleCategoryApp
        case .engine: .consoleCategoryEngine
        case .job: .consoleCategoryJob
        case .disk: .consoleCategoryDisk
        case .integrity: .consoleCategoryIntegrity
        case .update: .consoleCategoryUpdate
        }
    }
}
