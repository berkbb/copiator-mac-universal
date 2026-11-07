// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CopiatorCore
import SwiftUI

/// Arşivde arama: bir hedefte ada, isterse PDF ve metin içeriğine ve fotoğraf bilgisine göre (bkz. `ArchiveSearch`).
/// Seçilen sonuç Finder'da gösterilir, açılır (kod çalıştırabilen türler açılmaz), kopyası başka yere kaydedilir ya da
/// onaydan sonra Çöp Sepeti'ne taşınır. Arama dosyaları yalnızca okur.
struct ArchiveSearchSheet: View {
    let request: ArchiveSearchRequest
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var contents = false
    @State private var results: ArchiveSearch.Results?
    @State private var searching = false
    @State private var selection: ArchiveSearch.Hit.ID?
    /// Sonuçları yeniden aramak için (Çöp'e taşımadan sonra).
    @State private var generation = 0

    /// Arama en az bu kadar karakterle başlar.
    static let minimumQuery = 2

    /// - Parameter results: Önceden hesaplanmış sonuçlar (görünüm testleri için).
    init(request: ArchiveSearchRequest, query: String = "", results: ArchiveSearch.Results? = nil) {
        self.request = request
        _query = State(initialValue: query)
        _results = State(initialValue: results)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(settings.t(.archiveSearchTitle), systemImage: "magnifyingglass").font(.headline)
            Text(OpenSafety.visibleName(request.destination.path))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(OpenSafety.visibleName(request.destination.path))
            TextField(settings.t(.archiveSearchTitle), text: $query, prompt: Text(settings.t(.archiveSearchPrompt)))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("copiator.archiveSearch.query")
            Toggle(settings.t(.archiveSearchContents), isOn: $contents)
                .help(settings.t(.archiveSearchContentsNote))
            resultList
            footer
            HStack {
                Group {
                    Button(settings.t(.archiveSearchReveal), systemImage: "folder") { act { model.revealArchived($0) } }
                    Button(settings.t(.archiveSearchOpen), systemImage: "arrow.up.forward.app") { act { model.openArchived($0) } }
                    Button(settings.t(.archiveSearchSaveCopy), systemImage: "square.and.arrow.down") { act(saveCopy) }
                    Button(settings.t(.archiveSearchTrash), systemImage: "trash") {
                        act { url in model.requestTrashArchived(url) { generation += 1 } }
                    }
                }
                .disabled(selected == nil)
                Spacer()
                Button(settings.t(.buttonClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 560)
        .task(id: "\(query)\u{0}\(contents)\u{0}\(generation)") { await search() }
    }

    @ViewBuilder private var resultList: some View {
        if let results, !results.hits.isEmpty {
            List(results.hits, selection: $selection) { hit in
                row(hit).tag(hit.id)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        } else if searching {
            ProgressView(settings.t(.archiveSearchSearching)).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results != nil {
            ContentUnavailableView(settings.t(.archiveSearchNone), systemImage: "magnifyingglass")
        } else {
            ContentUnavailableView(settings.t(.archiveSearchHint), systemImage: "text.magnifyingglass")
        }
    }

    @ViewBuilder private var footer: some View {
        if let results {
            HStack(spacing: 8) {
                Text(settings.t(.archiveSearchCount, results.hits.count, results.scanned))
                if results.limited { Text(settings.t(.archiveSearchLimited, results.hits.count)).foregroundStyle(.orange) }
                if searching { ProgressView().controlSize(.small) }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func row(_ hit: ArchiveSearch.Hit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Label(OpenSafety.visibleName((hit.relativePath as NSString).lastPathComponent), systemImage: icon(hit.match))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(settings.t(matchKey(hit.match))).font(.caption).foregroundStyle(.secondary)
                Text(settings.bytes(hit.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(OpenSafety.visibleName((hit.relativePath as NSString).deletingLastPathComponent))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            if !hit.snippet.isEmpty {
                Text(OpenSafety.visibleName(hit.snippet)).font(.caption).lineLimit(2)
            }
        }
        .contextMenu {
            Button(settings.t(.archiveSearchReveal)) { model.revealArchived(url(hit)) }
            Button(settings.t(.archiveSearchOpen)) { model.openArchived(url(hit)) }
            Button(settings.t(.archiveSearchSaveCopy)) { saveCopy(url(hit)) }
            Divider()
            Button(settings.t(.archiveSearchTrash), role: .destructive) { model.requestTrashArchived(url(hit)) { generation += 1 } }
        }
    }

    private var selected: ArchiveSearch.Hit? { results?.hits.first { $0.id == selection } }

    private func url(_ hit: ArchiveSearch.Hit) -> URL { request.destination.appendingPathComponent(hit.relativePath) }

    /// Seçili sonuçla bir eylem (seçim yoksa hiçbir şey olmaz).
    private func act(_ action: (URL) -> Void) {
        guard let selected else { return }
        action(url(selected))
    }

    private func icon(_ match: ArchiveSearch.Match) -> String {
        switch match {
        case .name: "doc"
        case .content: "doc.text.magnifyingglass"
        case .photo: "photo"
        }
    }

    private func matchKey(_ match: ArchiveSearch.Match) -> LKey {
        switch match {
        case .name: .archiveSearchMatchName
        case .content: .archiveSearchMatchContent
        case .photo: .archiveSearchMatchPhoto
        }
    }

    private func saveCopy(_ url: URL) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK, let target = panel.url else { return }
        model.copyArchived(url, to: target)
    }

    /// Yazmaya kısa bir ara verilince aranır; yeni sorgu öncekini durdurur.
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minimumQuery else {
            if !text.isEmpty || results?.hits.isEmpty == false { results = nil }
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        searching = true
        let root = request.destination, inContents = contents
        let found = await runCancellable { isCancelled in ArchiveSearch.search(text, in: root, contents: inContents, isCancelled: isCancelled) }
        if !Task.isCancelled {
            results = found
            if let selection, !found.hits.contains(where: { $0.id == selection }) { self.selection = nil }
        }
        searching = false
    }
}
