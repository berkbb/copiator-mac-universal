// SPDX-License-Identifier: GPL-3.0-only
import CopiatorCore
import SwiftUI

/// Anlık görüntü sayfasının kipi: göz atma (ve ada göre arama) ya da iki anlık görüntüyü karşılaştırma.
enum SnapshotBrowserMode: Hashable {
    case browse
    case compare
}

/// Ağır bir okuma işini ana iş parçacığı dışında çalıştırır; çağıran görev iptal edilince (ör. sorgu değişince ya da sayfa
/// kapanınca) iş de durur.
func runCancellable<T: Sendable>(_ work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) -> T) async -> T {
    let flag = CancelFlag()
    return await withTaskCancellationHandler {
        await Task.detached(priority: .userInitiated) { work { flag.isCancelled } }.value
    } onCancel: {
        flag.cancel()
    }
}

/// Ada göre arama sonuçları: her yol, onu içeren anlık görüntü sayısı ve en yenisinin tarihiyle; tıklanınca o anlık
/// görüntüde açılır.
struct SnapshotSearchResultsView: View {
    let results: SnapshotSearch.Results
    let open: (SnapshotSearch.Hit) -> Void
    @Environment(AppSettings.self) private var settings

    /// Sonucun ekran okuyucu adı: yol ve kaç anlık görüntüde olduğu.
    static func label(_ hit: SnapshotSearch.Hit, settings: AppSettings) -> String {
        let path = OpenSafety.visibleName(hit.relativePath)
        guard let newest = hit.snapshots.first else { return path }
        return path + ", " + settings.t(.snapshotsSearchHit, hit.snapshots.count, settings.date(newest.date))
    }

    var body: some View {
        if results.hits.isEmpty {
            ContentUnavailableView(settings.t(.snapshotsSearchNone), systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                List(results.hits) { hit in
                    Button { open(hit) } label: {
                        HStack {
                            Label(OpenSafety.visibleName(hit.relativePath), systemImage: hit.isDirectory ? "folder" : "doc")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let newest = hit.snapshots.first {
                                Text(settings.t(.snapshotsSearchHit, hit.snapshots.count, settings.date(newest.date)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Düz biçimli düğmenin içindeki metinler ekran okuyucuya ad olarak ulaşmıyor (2026-11-04 canlı denemesi).
                    .accessibilityLabel(Self.label(hit, settings: settings))
                }
                .accessibilityIdentifier("copiator.snapshots.searchResults")
                if results.isTruncated {
                    Text(settings.t(.snapshotsSearchTruncated, results.hits.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// İki anlık görüntünün karşılaştırması: eski ve yeni seçilir (varsayılan: en yeni ikisi), eklenen, değişen ve silinen
/// dosyalar listelenir. Dosyalar okunmaz; değişen dosyalar Quick Look ile önizlenebilir.
struct SnapshotCompareView: View {
    let job: TransferJob
    let snapshots: [SnapshotRestore.Snapshot]
    @Binding var previewURL: URL?
    @Environment(AppSettings.self) private var settings

    @State private var older: SnapshotRestore.Snapshot.ID?
    @State private var newer: SnapshotRestore.Snapshot.ID?
    @State private var difference: SnapshotSearch.Difference?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snapshots.count < 2 {
                ContentUnavailableView(settings.t(.snapshotsCompareNeedsTwo), systemImage: "square.split.2x1")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 16) {
                    picker(.snapshotsCompareOlder, selection: $older)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    picker(.snapshotsCompareNewer, selection: $newer)
                }
                if let difference {
                    if difference.isEmpty {
                        ContentUnavailableView(settings.t(.snapshotsCompareSame), systemImage: "equal.circle")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            section(.snapshotsCompareAdded, difference.added, total: difference.addedCount, in: newer, symbol: "plus.circle", tint: .green)
                            section(.snapshotsCompareChanged, difference.changed, total: difference.changedCount, in: newer, symbol: "pencil.circle", tint: .orange)
                            section(.snapshotsCompareRemoved, difference.removed, total: difference.removedCount, in: older, symbol: "minus.circle", tint: .red)
                        }
                        .accessibilityIdentifier("copiator.snapshots.compare")
                    }
                } else {
                    ProgressView(settings.t(.snapshotsComparing))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text(settings.t(.snapshotsCompareNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if newer == nil { newer = snapshots.first?.id }
            if older == nil { older = snapshots.dropFirst().first?.id }
        }
        .task(id: [older ?? "", newer ?? ""]) { await compare() }
    }

    private func picker(_ title: LKey, selection: Binding<SnapshotRestore.Snapshot.ID?>) -> some View {
        Picker(settings.t(title), selection: selection) {
            ForEach(snapshots) { snapshot in
                Text(settings.date(snapshot.date)).tag(Optional(snapshot.id))
            }
        }
        .frame(maxWidth: 300)
    }

    @ViewBuilder
    private func section(_ title: LKey, _ changes: [SnapshotSearch.Change], total: Int, in snapshotID: SnapshotRestore.Snapshot.ID?,
                         symbol: String, tint: Color) -> some View {
        if total > 0 {
            Section(settings.t(title, total)) {
                ForEach(changes) { change in
                    HStack {
                        Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
                        Text(OpenSafety.visibleName(change.relativePath)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(settings.bytes(change.size)).font(.caption).foregroundStyle(.secondary)
                        Text(settings.date(change.modified)).font(.caption).foregroundStyle(.secondary)
                        Button(settings.t(.snapshotsQuickLook), systemImage: "eye") {
                            if let snapshot = snapshots.first(where: { $0.id == snapshotID }) {
                                previewURL = SnapshotRestore.contentRoot(of: snapshot, job: job).appendingPathComponent(change.relativePath)
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help(settings.t(.snapshotsQuickLook))
                    }
                }
                if total > changes.count {
                    Text(settings.t(.snapshotsCompareMore, total - changes.count)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func compare() async {
        difference = nil
        guard let old = snapshots.first(where: { $0.id == older }), let new = snapshots.first(where: { $0.id == newer }) else { return }
        let job = job
        let result = await runCancellable { isCancelled in SnapshotSearch.compare(old, new, job: job, isCancelled: isCancelled) }
        if !Task.isCancelled { difference = result }
    }
}
