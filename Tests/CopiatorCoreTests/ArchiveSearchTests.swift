// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CopiatorCore

/// Çekim tarihi ve kamera modeli taşıyan küçük bir JPEG.
private func writePhoto(_ url: URL, taken: String, camera: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    let properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: taken],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: camera],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

/// Arşivde arama: adda (harf, aksan ve Türkçe I/ı farkı gözetilmeden), içerikte (PDF ve metin; çevresiyle) ve
/// fotoğrafın çekim tarihi ile kamerasında; gizli öğeler ve bağlantılar taranmaz, paketin içine girilmez; dosyalar
/// değişmez; sınır aşılınca söylenir.
@Test func archiveSearchFindsNamesContentsAndPhotoDetails() throws {
    let w = try Workspace("CopiatorArchiveSearch")
    try w.write("Arsiv/Tapu/ISPARTA tapu.txt", "tapu")
    try w.write("Arsiv/Fatura/ekim.txt", "Abone no 128820964\nENERJİSA elektrik faturası, son ödeme 15.11.2026")
    try w.write("Arsiv/.gizli/isparta.txt", "gizli")
    try w.write("Arsiv/Uygulama.app/Contents/isparta.txt", "paketin içi")
    try FileManager.default.createSymbolicLink(at: w.url("Arsiv/isparta-baglanti"), withDestinationURL: w.url("Arsiv/Tapu"))
    try writePhoto(w.url("Arsiv/Foto/IMG_0001.jpg"), taken: "2026:08:15 14:03:00", camera: "Test Kamera X")

    let names = ArchiveSearch.search("ısparta", in: w.url("Arsiv"), contents: false)
    #expect(names.hits.map(\.relativePath) == ["Tapu/ISPARTA tapu.txt"] && names.hits.first?.match == .name)
    let app = ArchiveSearch.search("uygulama", in: w.url("Arsiv"), contents: false)
    #expect(app.hits.map(\.relativePath) == ["Uygulama.app"], "paket adıyla bulunur, içi taranmaz")

    let content = ArchiveSearch.search("enerjisa", in: w.url("Arsiv"), contents: true)
    let hit = try #require(content.hits.first)
    #expect(content.hits.count == 1 && hit.match == .content && hit.relativePath == "Fatura/ekim.txt")
    #expect(hit.snippet.contains("ENERJİSA elektrik") && !hit.snippet.contains("\n"), "\(hit.snippet)")
    #expect(ArchiveSearch.search("enerjisa", in: w.url("Arsiv"), contents: false).hits.isEmpty, "içerik yalnızca istenince")

    let taken = ArchiveSearch.search("2026-08-15", in: w.url("Arsiv"), contents: true)
    #expect(taken.hits.map(\.relativePath) == ["Foto/IMG_0001.jpg"] && taken.hits.first?.match == .photo)
    #expect(taken.hits.first?.snippet == "2026-08-15 14:03 · Test Kamera X")
    #expect(ArchiveSearch.search("kamera x", in: w.url("Arsiv"), contents: true).hits.count == 1)

    let limited = ArchiveSearch.search("t", in: w.url("Arsiv"), contents: false, limit: 1)
    #expect(limited.limited && limited.hits.count == 1)
    #expect(ArchiveSearch.search("   ", in: w.url("Arsiv"), contents: true).hits.isEmpty)
    #expect(w.read("Arsiv/Fatura/ekim.txt")?.hasPrefix("Abone no") == true)
}

@Test func snippetsStayOnOneLineAroundTheMatch() {
    let text = String(repeating: "a", count: 100) + "\nFATURA\n" + String(repeating: "b", count: 100)
    let snippet = ArchiveSearch.snippet(in: text, around: "fatura")
    #expect(snippet == "…" + String(repeating: "a", count: 39) + " FATURA " + String(repeating: "b", count: 39) + "…")
    #expect(ArchiveSearch.snippet(in: "kısa fatura", around: "fatura") == "kısa fatura")
    #expect(ArchiveSearch.snippet(in: "yok", around: "fatura") == nil)
}

