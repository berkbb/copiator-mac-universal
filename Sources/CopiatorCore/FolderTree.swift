// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Bir klasörün ağacı Markdown olarak ("├── Faturalar/", "│   └── El_10_26.pdf"): klasörler "/" ile biter, adlar harf
/// sırasıyla (Finder gibi); gizli öğeler, macOS sistem klasörleri ve Windows/Office artıkları yazılmaz, paketlerin ve
/// bağlantıların içine girilmez. Klasör yalnızca okunur.
public enum FolderTree {
    /// En çok satır; fazlası yazılmaz ve metin bunu söyler.
    public static let maxLines = 50_000

    public struct Output: Equatable, Sendable {
        public var text: String
        public var truncated: Bool
    }

    /// - Parameter text: Çeviri işlevi (başlıklar için; değişkenler metin olarak).
    public static func markdown(of root: URL, text: (LKey, [String]) -> String, isCancelled: () -> Bool = { false }) -> Output {
        var lines: [String] = []
        var truncated = false
        func walk(_ folder: URL, prefix: String) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
            let entries = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
                .filter { url in
                    let name = url.lastPathComponent
                    return !RsyncCommand.systemExclusions.contains(name) && !RsyncCommand.isWindowsLeftover(name)
                }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for (index, url) in entries.enumerated() {
                if truncated || isCancelled() { return }
                guard lines.count < maxLines else {
                    truncated = true
                    return
                }
                let last = index == entries.count - 1
                let values = try? url.resourceValues(forKeys: Set(keys))
                let descend = values?.isDirectory == true && values?.isPackage != true && values?.isSymbolicLink != true
                let name = OpenSafety.visibleName(url.lastPathComponent)
                lines.append(prefix + (last ? "└── " : "├── ") + name + (values?.isDirectory == true && values?.isSymbolicLink != true ? "/" : ""))
                if descend { walk(url, prefix: prefix + (last ? "    " : "│   ")) }
            }
        }
        walk(root, prefix: "")
        var output = [text(.folderTreeTitle, [OpenSafety.visibleName(root.lastPathComponent)]), "",
                      text(.folderTreeRoot, ["`" + OpenSafety.visibleName(root.path) + "`"]), "", "```",
                      OpenSafety.visibleName(root.lastPathComponent) + "/"]
        output += lines
        output.append("```")
        if truncated { output += ["", text(.folderTreeTruncated, [String(maxLines)])] }
        return Output(text: output.joined(separator: "\n") + "\n", truncated: truncated)
    }
}
