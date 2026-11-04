// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

/// Ekran okuyucu denetimi (kaynak taraması): düz biçimli düğmelerin içindeki metinler ve yalnızca simgeden oluşan
/// düğmeler ekran okuyucuya ad olarak ulaşmayabilir (2026-11-04 canlı turunda arama sonucu adsızdı). Böyle her düğmenin
/// yakınında açık bir `.accessibilityLabel` bulunur.
@Test func plainAndIconOnlyButtonsHaveLabels() throws {
    let views = packageRoot.appendingPathComponent("Sources/Copiator")
    let files = try FileManager.default.subpathsOfDirectory(atPath: views.path).filter { $0.hasSuffix(".swift") }
    var missing: [String] = []
    for file in files {
        let lines = try String(contentsOf: views.appendingPathComponent(file), encoding: .utf8).components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let nearby = lines[max(0, index - 16)...min(lines.count - 1, index + 4)].joined(separator: "\n")
            if line.contains(".buttonStyle(.plain)"), !nearby.contains(".accessibilityLabel(") {
                missing.append("\(file):\(index + 1) düz biçimli düğme")
            }
            // "label: { Image(...) }" ya da tek satırlık simge etiketi.
            if line.contains("} label: {") || line.hasSuffix("label: {") {
                let label = lines[(index + 1)..<min(lines.count, index + 6)].prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("}") }
                let text = label.joined(separator: "\n")
                if text.contains("Image("), !text.contains("Text("), !text.contains("Label("), !nearby.contains(".accessibilityLabel(")
                    && !lines[index..<min(lines.count, index + 12)].joined().contains(".accessibilityLabel(") {
                    missing.append("\(file):\(index + 1) simge düğmesi")
                }
            }
        }
    }
    #expect(missing.isEmpty, "\(missing)")
}
