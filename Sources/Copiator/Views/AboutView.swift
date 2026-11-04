// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CopiatorCore
import SwiftUI

struct AboutView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL
    @State private var license: LicenseViewerItem?

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 116, height: 116)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(settings.t(.appName))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(settings.t(.aboutVersion, AppInfo.version, AppInfo.build))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(settings.t(.appTagline))
                    .font(.callout)
            }

            Divider().padding(.horizontal, 50)

            VStack(spacing: 8) {
                Label(settings.t(.aboutPoweredBy, model.engineVersion ?? settings.t(.unknown)), systemImage: "cpu")
                    .font(.callout.weight(.medium))
                Text(settings.t(.aboutEngineCredit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button(settings.t(.aboutRepository), systemImage: "chevron.left.forwardslash.chevron.right") { openURL(AppLinks.repository) }
                        Button(settings.t(.aboutEngineWebsite), systemImage: "globe") { openURL(AppLinks.engineWebsite) }
                        Button(settings.t(.menuEngineManual), systemImage: "book") { openURL(AppLinks.engineManual) }
                    }
                    HStack(spacing: 8) {
                        ForEach(LicenseDocument.allCases) { document in
                            Button(settings.t(document.title), systemImage: document.systemImage) { showLicense(document) }
                                .accessibilityIdentifier("copiator.about.license.\(document.rawValue)")
                        }
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            Text(settings.t(.aboutCopyright, AppInfo.currentYear))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 30)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(width: 540)
        .containerBackground(.thickMaterial, for: .window)
        .windowMinimizeBehavior(.disabled)
        .sheet(item: $license) { LicenseViewerSheet(item: $0) }
    }

    /// Lisans uygulama içinde salt okunur açılır; dosya bulunamazsa (yalnızca rsync için) resmî metni açılır.
    private func showLicense(_ document: LicenseDocument) {
        if let text = document.text() {
            license = LicenseViewerItem(document: document, text: text)
        } else if let url = document.fallbackURL {
            openURL(url)
        }
    }
}
