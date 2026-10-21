// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CopiatorCore
import SwiftUI

/// Hakkında penceresinin gösterdiği lisans belgeleri. Metin uygulamanın kendi dosyalarından okunur ve
/// uygulama içinde salt okunur gösterilir; düzenlenebilir bir metin düzenleyicide açılmaz.
enum LicenseDocument: String, CaseIterable, Identifiable {
    case app, engine, notices

    var id: String { rawValue }

    var title: LKey {
        switch self {
        case .app: .aboutAppLicense
        case .engine: .aboutEngineLicense
        case .notices: .aboutNotices
        }
    }

    var subtitle: LKey {
        switch self {
        case .app: .licenseAppSubtitle
        case .engine: .licenseEngineSubtitle
        case .notices: .licenseNoticesSubtitle
        }
    }

    var systemImage: String {
        switch self {
        case .app: "doc.text"
        case .engine: "doc.text.magnifyingglass"
        case .notices: "list.bullet.rectangle"
        }
    }

    /// Özel adlar ve lisans kısaltmaları her dilde aynıdır, çevrilmez.
    var publisher: String? {
        switch self {
        case .app: "Babadogan Tech and Edu"
        case .engine: "Andrew Tridgell, Wayne Davison"
        case .notices: nil
        }
    }

    var licenseName: String? {
        switch self {
        case .app: "GPL-3.0-or-later"
        case .engine: "GPL-3.0-or-later"
        case .notices: nil
        }
    }

    /// Metnin aranacağı dosyalar, öncelik sırasıyla. Güncellenen rsync motoru kendi lisansını getirir; varsa o gösterilir.
    func candidates(resources: URL?, engineDirectory: URL) -> [URL] {
        switch self {
        case .app:
            [resources?.appendingPathComponent("Copiator-License.txt")].compactMap { $0 }
        case .engine:
            [engineDirectory.appendingPathComponent("COPYING"), resources?.appendingPathComponent("rsync-License.txt")]
                .compactMap { $0 }
        case .notices:
            [resources?.appendingPathComponent("Third-Party-Notices.txt")].compactMap { $0 }
        }
    }

    /// Dosya bulunamazsa açılacak sayfa (yalnızca rsync lisansının resmî bir adresi var).
    var fallbackURL: URL? {
        self == .engine ? AppLinks.engineLicense : nil
    }

    func text(
        resources: URL? = Bundle.main.resourceURL,
        engineDirectory: URL = EngineLocator.managedEngineDirectory
    ) -> String? {
        for url in candidates(resources: resources, engineDirectory: engineDirectory) {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            return Self.displayText(data)
        }
        return nil
    }

    /// CRLF satır sonlu bir metin gelirse görüntülenen ve kopyalanan metin LF kullanır.
    static func displayText(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    }
}

/// Sayfada gösterilen belge ve okunmuş metni.
struct LicenseViewerItem: Identifiable {
    let document: LicenseDocument
    let text: String

    var id: LicenseDocument.ID { document.id }
}

/// Lisans metnini salt okunur gösterir: metin seçilip kopyalanabilir ama değiştirilemez.
struct LicenseViewerSheet: View {
    let item: LicenseViewerItem
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: item.document.systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.t(item.document.title))
                        .font(.headline)
                    Text(settings.t(item.document.subtitle) + " · " + settings.t(.licenseReadOnly))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(settings.t(.buttonClose))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            HStack(spacing: 16) {
                if let publisher = item.document.publisher {
                    HStack(spacing: 6) {
                        Image(systemName: "person.badge.shield.checkmark.fill")
                            .foregroundStyle(.tint)
                        Text(settings.t(.licensePublisher) + ":")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(publisher)
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                if let licenseName = item.document.licenseName {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.green)
                        Text(settings.t(.licenseLabel) + ":")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(licenseName)
                            .font(.caption.bold())
                    }
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(
                        settings.t(copied ? .licenseCopied : .licenseCopyText),
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            ScrollView {
                Text(item.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .textColor))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            HStack {
                Text(settings.t(.aboutCopyright, AppInfo.currentYear))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(settings.t(.buttonClose)) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 640, height: 540)
    }
}
