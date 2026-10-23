// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CopiatorCore
import SwiftUI

/// Bir işin anlık görüntülerine göz atma ve geri yükleme: solda anlık görüntüler (en yeni önce), sağda seçilen anlık
/// görüntüde klasör klasör gezinme, seçilen dosyanın sürümleri ve geri yükleme. Geri yükleme kuyruğa sıradan bir
/// kopyalama işi ekler; aynı adlı dosya sorulur, hiçbir şey silinmez.
struct SnapshotBrowserSheet: View {
    let request: SnapshotBrowserRequest
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var snapshots: [SnapshotRestore.Snapshot] = []
    @State private var selected: SnapshotRestore.Snapshot.ID?
    @State private var path = ""
    @State private var items: [SnapshotRestore.Item] = []
    @State private var selectedItem: SnapshotRestore.Item.ID?
    @State private var versions: [SnapshotRestore.Version] = []
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let job = model.job(request.jobID) {
                header(job)
                if snapshots.isEmpty {
                    ContentUnavailableView(settings.t(.snapshotsNone), systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        List(snapshots, selection: $selected) { snapshot in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(settings.date(snapshot.date))
                                Text(snapshot.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            .tag(snapshot.id)
                        }
                        .frame(width: 220)
                        .accessibilityIdentifier("copiator.snapshots.list")
                        browser(job)
                    }
                }
                footer(job)
            }
        }
        .padding(20)
        .frame(width: 820, height: 560)
        .onAppear(perform: load)
        .onChange(of: selected) {
            path = ""
            refresh()
        }
        .onChange(of: selectedItem) { loadVersions() }
    }

    private func header(_ job: TransferJob) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(settings.t(.snapshotsTitle, OpenSafety.visibleName(job.source.lastPathComponent))).font(.headline)
                Text(OpenSafety.visibleName(job.destination.path))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func browser(_ job: TransferJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(settings.t(.snapshotsUp), systemImage: "chevron.up") {
                    path = (path as NSString).deletingLastPathComponent
                    refresh()
                }
                .disabled(path.isEmpty)
                Text(path.isEmpty ? settings.t(.snapshotsRoot) : OpenSafety.visibleName(path))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if items.isEmpty {
                ContentUnavailableView(settings.t(.snapshotsEmptyFolder), systemImage: "folder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items, selection: $selectedItem) { item in
                    HStack {
                        Label(OpenSafety.visibleName(item.name), systemImage: item.isDirectory ? "folder" : "doc")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if !item.isDirectory {
                            Text(settings.bytes(item.size)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(settings.date(item.modified)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(item.id)
                }
                // Çift tıklama ya da Return: klasöre girilir.
                .contextMenu(forSelectionType: SnapshotRestore.Item.ID.self) { _ in } primaryAction: { ids in
                    guard let id = ids.first, let item = items.first(where: { $0.id == id }), item.isDirectory else { return }
                    path = item.relativePath
                    refresh()
                }
                .accessibilityIdentifier("copiator.snapshots.items")
            }
            if versions.count > 0 {
                Text(settings.t(.snapshotsVersions)).font(.headline)
                ForEach(versions) { version in
                    HStack {
                        Text(settings.date(version.snapshot.date))
                        Text(settings.bytes(version.size)).foregroundStyle(.secondary)
                        Spacer()
                        Button(settings.t(.snapshotsRestoreVersion)) { restore(from: version.snapshot, to: nil) }
                    }
                    .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func footer(_ job: TransferJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.t(.snapshotsRestoreNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(settings.t(.buttonClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.t(.snapshotsRestoreElsewhere)) { chooseFolder() }
                    .disabled(currentSnapshot == nil)
                    .accessibilityIdentifier("copiator.snapshots.restoreElsewhere")
                Button(settings.t(.snapshotsRestoreOriginal)) {
                    if let snapshot = currentSnapshot { restore(from: snapshot, to: nil) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(currentSnapshot == nil)
                .accessibilityIdentifier("copiator.snapshots.restoreOriginal")
            }
        }
    }

    private var currentSnapshot: SnapshotRestore.Snapshot? { snapshots.first { $0.id == selected } }

    /// Seçili öğe; seçim yoksa açık klasör.
    private var targetPath: String { selectedItem ?? path }

    private func load() {
        guard let job = model.job(request.jobID) else { return }
        snapshots = SnapshotRestore.snapshots(of: job)
        selected = snapshots.first?.id
        refresh()
    }

    private func refresh() {
        selectedItem = nil
        versions = []
        guard let job = model.job(request.jobID), let snapshot = currentSnapshot else {
            items = []
            return
        }
        items = SnapshotRestore.items(in: SnapshotRestore.contentRoot(of: snapshot, job: job), at: path)
    }

    private func loadVersions() {
        guard let job = model.job(request.jobID), let id = selectedItem, let item = items.first(where: { $0.id == id }), !item.isDirectory else {
            versions = []
            return
        }
        versions = SnapshotRestore.versions(of: item.relativePath, job: job)
    }

    private func restore(from snapshot: SnapshotRestore.Snapshot, to folder: URL?) {
        message = model.restore(targetPath, from: snapshot, of: request.jobID, to: folder)
        if message == nil { dismiss() }
    }

    private func chooseFolder() {
        guard let snapshot = currentSnapshot else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = settings.t(.snapshotsChooseFolder)
        if panel.runModal() == .OK, let folder = panel.url { restore(from: snapshot, to: folder) }
    }
}
