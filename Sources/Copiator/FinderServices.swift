// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Info.plist'teki NSServices girdisinin hedefi. Finder'da seçili öğeler panodan okunur.
final class FinderServices: NSObject {
    /// "Copiator ile Yedekle": Yeni İş sayfasını seçili öğe kaynak olarak doldurulmuş açar.
    @objc func backUp(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let url = Self.fileURLs(from: pasteboard).first else { return }
        AppModel.shared.presentMainWindow()
        AppModel.shared.beginNewJob(source: url)
    }

    /// "Copiator Rutinine Gönder": seçili öğeler için rutin seçme sayfasını açar; rutinin rotaları yalnızca bu öğelere
    /// uygulanır.
    @objc func sendToRoutine(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return }
        AppModel.shared.presentMainWindow()
        AppModel.shared.beginSendToRoutine(urls)
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}
