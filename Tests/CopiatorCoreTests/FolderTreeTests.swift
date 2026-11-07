// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// Klasör ağacı: harf sırasıyla, klasörler "/" ile; gizli öğeler, macOS sistem klasörleri, Windows/Office artıkları ve
/// paketlerin içi yazılmaz; görünmez karakterler görünür olur; satır sınırı söylenir.
@Test func folderTreeIsMarkdownWithoutClutter() throws {
    let w = try Workspace("CopiatorFolderTree")
    try w.write("Arsiv/Faturalar/El_10_26.pdf", "1")
    try w.write("Arsiv/Faturalar/El_09_26.pdf", "1")
    try w.write("Arsiv/Faturalar/Thumbs.db", "x")
    try w.write("Arsiv/Tapu/2026/tapu.pdf", "1")
    try w.write("Arsiv/.DS_Store", "x")
    try w.write("Arsiv/.Trashes/x", "x")
    try w.write("Arsiv/Uygulama.app/Contents/Info.plist", "x")
    try w.write("Arsiv/not 2.txt", "x")
    try w.write("Arsiv/not 10.txt", "x")
    let output = FolderTree.markdown(of: w.url("Arsiv"), text: { key, arguments in ([key.rawValue] + arguments).joined(separator: "|") })
    #expect(!output.truncated)
    #expect(output.text == """
    folderTreeTitle|Arsiv

    folderTreeRoot|`\(w.url("Arsiv").path)`

    ```
    Arsiv/
    ├── Faturalar/
    │   ├── El_09_26.pdf
    │   └── El_10_26.pdf
    ├── not 2.txt
    ├── not 10.txt
    ├── Tapu/
    │   └── 2026/
    │       └── tapu.pdf
    └── Uygulama.app/
    ```

    """)
}
