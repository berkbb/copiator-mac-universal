// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

// Belirli tohumlu (deterministik) bulanıklık (fuzz) testleri: saf ayrıştırıcılar hostil girdilerle beslenir. Amaç bir
// çökme (taşma tuzağı, dizin aşımı, zorla çözme) ya da sonsuz döngü bulmak; bir başarısızlık tohum ve yineleme
// numarasıyla yeniden üretilebilir. Çökme = test sürecinin çökmesidir.

/// Tohumlanabilir, hızlı üreteç (SplitMix64); testin tekrarlanabilir olması için `Int.random`/`Date` kullanılmaz.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// rsync çıktısına benzeyen "ilginç" belirteçler; saf rastgele metinden çok daha fazla dal gezer.
private let tokens: [String] = [
    " ", "  ", "\t", "\n", "\r", "%", "100%", "0%", "101%", "-5%", "29.70K", "209.72M", "1.02G", "9.99P", "nanK", "infM",
    "1,234,567", "99999999999999999999999", "-1", "0", "0.61kB/s", "624.90MB/s", "1.5GB/s", "kB/s", "0:00:47", "??:??:??",
    "99999:99:99", "1:61:61", "(xfr#4801,", "xfr#", "xfr#-3,", "to-chk=1199/6041)", "ir-chk=1050/1091)", "to-chk=/)",
    "to-chk=5/", "ir-chk=-1/-2)", ">f+++++++++", ".d..t......", "*deleting", "cL+++++++++", "hf+++++++++", ">fcs.......",
    " -> ", " => ", "\\#012", "\\#", "\\#99", "\\#303\\#274", "src/", "a/b/c.txt", "./", "..", "/", "rsync:", "[receiver]",
    "rsync error:", "file has vanished:", "failed to set times on ", "chown \"", "set_acl: ", "link_stat ",
    ": No space left on device (28)", ": Read-only file system (30)", ": Permission denied (13)", ": Operation not permitted (1)",
    "rsync  version 3.5.1  protocol version 33", "openrsync:", "version", "Capabilities:", "ACLs, xattrs", "Optimizations:",
    "\u{202E}", "\u{0000}", "ğüşıöç", "🚀",
]

private func randomScalar(_ g: inout SplitMix64) -> Unicode.Scalar {
    while true {
        let pick = UInt64.random(in: 0..<100, using: &g)
        let value: UInt32
        if pick < 40 {
            value = UInt32.random(in: 0...0x7F, using: &g)
        } else if pick < 70 {
            value = UInt32.random(in: 0x80...0xFFFF, using: &g)
        } else {
            value = UInt32.random(in: 0x1_0000...0x10_FFFF, using: &g)
        }
        if (0xD800...0xDFFF).contains(value) { continue }
        if let scalar = Unicode.Scalar(value) { return scalar }
    }
}

/// Belirteçleri ve rastgele unicode parçalarını birleştirerek dilbilgisine yakın girdi üretir.
private func spliced(_ g: inout SplitMix64, maxParts: Int = 14) -> String {
    let parts = Int(UInt64.random(in: 0...UInt64(maxParts), using: &g))
    var text = ""
    for _ in 0..<parts {
        if UInt64.random(in: 0..<4, using: &g) == 0 {
            var scalars = String.UnicodeScalarView()
            for _ in 0..<Int(UInt64.random(in: 0...8, using: &g)) { scalars.append(randomScalar(&g)) }
            text += String(scalars)
        } else {
            text += tokens[Int(UInt64.random(in: 0..<UInt64(tokens.count), using: &g))]
        }
    }
    return text
}

private let iterations = 4_000

@Test(arguments: [UInt64(1), 42, 0xC0FFEE])
func progressParserNeverCrashesAndKeepsInvariants(seed: UInt64) {
    var g = SplitMix64(seed: seed)
    for _ in 0..<iterations {
        let line = spliced(&g)
        guard let progress = RsyncProgressParser.parse(line) else { continue }
        #expect(progress.bytesTransferred >= 0, "\(seed): \(line.debugDescription)")
        #expect((0...1).contains(progress.fraction ?? 0))
        #expect((progress.bytesPerSecond ?? 0) >= 0)
        #expect((progress.remainingSeconds ?? 0) >= 0)
        #expect(progress.filesTransferred >= 0)
        if let checked = progress.itemsChecked { #expect(checked >= 0) }
    }
}

@Test(arguments: [UInt64(7), 99, 0xBADC0DE])
func itemizeParserNeverCrashes(seed: UInt64) {
    var g = SplitMix64(seed: seed)
    for _ in 0..<iterations {
        let text = (0..<Int(UInt64.random(in: 1...6, using: &g))).map { _ in spliced(&g) }.joined(separator: "\n")
        for entry in ItemizeParser.parse(text) {
            #expect(!entry.path.isEmpty, "\(seed): \(text.debugDescription)")
            #expect(entry.path != ".")
            #expect(!(entry.path.count > 1 && entry.path.hasSuffix("/")))
        }
        // Kaçış çözme hiçbir zaman çökmez ve kaçışsız metni değiştirmez.
        let plain = spliced(&g).replacingOccurrences(of: "\\#", with: "")
        #expect(ItemizeParser.unescape(plain) == plain)
        _ = ItemizeParser.unescape(spliced(&g))
    }
}

@Test(arguments: [UInt64(3), 1234])
func outcomeClassifierIsTotal(seed: UInt64) {
    var g = SplitMix64(seed: seed)
    let codes: [Int32] = [0, 1, 2, 3, 4, 5, 10, 11, 12, 13, 14, 19, 20, 21, 22, 23, 24, 25, 30, 35, 124, 127, 255, -1]
    let systems: [FileSystemKind] = [.apfs, .hfs, .exfat, .fat, .ntfs, .network, .other]
    for _ in 0..<iterations {
        let stderr = (0..<Int(UInt64.random(in: 0...5, using: &g))).map { _ in spliced(&g) }.joined(separator: "\n")
        let code = codes[Int(UInt64.random(in: 0..<UInt64(codes.count), using: &g))]
        let fs = systems[Int(UInt64.random(in: 0..<UInt64(systems.count), using: &g))]
        let result = RsyncOutcome.classify(exitCode: code, stderr: stderr, destinationFileSystem: fs)
        // 0 her zaman başarı; başarısız bir kod hiçbir zaman "tam başarı" sayılmaz.
        if code == 0 { #expect(result.kind == .succeeded) } else { #expect(result.kind != .succeeded) }
        #expect(result.noteCount >= 0)
        _ = RsyncOutcome.errorLines(in: stderr, destinationFileSystem: fs)
    }
}

@Test func versionParserNeverCrashes() {
    var g = SplitMix64(seed: 77)
    for _ in 0..<iterations {
        let text = spliced(&g)
        if let info = EngineLocator.parse(text) {
            #expect(!info.version.isEmpty)
            #expect(info.version.split(separator: ".").count >= 2)
        }
        _ = EngineLocator.isNewer(spliced(&g), than: spliced(&g))
    }
}

/// Kaçışlanan her ad rsync kalıbında yalnızca düz karakter olarak kalır: özel karakterlerden önce her zaman "\" vardır.
@Test func escapedPatternsHaveNoBareWildcards() {
    var g = SplitMix64(seed: 5)
    for _ in 0..<iterations {
        let name = spliced(&g) + String(["*", "?", "[", "\\"][Int(UInt64.random(in: 0..<4, using: &g))])
        let escaped = Array(RsyncCommand.escapePattern(name))
        // Joker karakter yoksa rsync kalıbı harfi harfine karşılaştırır: ad olduğu gibi kalır.
        guard name.contains(where: { "*?[".contains($0) }) else {
            #expect(String(escaped) == name)
            continue
        }
        var index = 0
        while index < escaped.count {
            if escaped[index] == "\\" {
                #expect(index + 1 < escaped.count && "*?[\\".contains(escaped[index + 1]))
                index += 2
                continue
            }
            #expect(!"*?[".contains(escaped[index]), "\(name.debugDescription)")
            index += 1
        }
    }
}

/// Rastgele baytlardan oluşan kayıt dosyası hiçbir zaman çöktürmez: ya okunur ya da hata verir.
@Test func jobStoreSurvivesGarbage() throws {
    var g = SplitMix64(seed: 11)
    let workspace = try Workspace()
    let store = JobStore(url: workspace.url("jobs.json"))
    for _ in 0..<300 {
        var text = "{\"version\":1,\"jobs\":[{" + spliced(&g) + "}]}"
        if UInt64.random(in: 0..<3, using: &g) == 0 { text = spliced(&g) }
        try Data(text.utf8).write(to: store.url)
        _ = try? store.load()
    }
}

/// Argüman üreteci her girdi için güvenli kalır: yollar "--"dan sonra, mutlak ve kaynağı değiştiren seçenek yok.
@Test func commandBuilderInvariantsHoldForRandomPaths() {
    var g = SplitMix64(seed: 21)
    for _ in 0..<iterations {
        let source = "/" + spliced(&g, maxParts: 4).replacingOccurrences(of: "\u{0}", with: "")
        let destination = "/" + spliced(&g, maxParts: 4).replacingOccurrences(of: "\u{0}", with: "")
        let options = CopyOptions(
            copyMode: Bool.random(using: &g) ? .folder : .contents, preservePermissions: Bool.random(using: &g),
            preserveExtendedAttributes: Bool.random(using: &g), deleteExtraneous: Bool.random(using: &g),
            excludeSystemFolders: Bool.random(using: &g)
        )
        let job = TransferJob(source: URL(fileURLWithPath: source), destination: URL(fileURLWithPath: destination), options: options)
        let environment = RsyncCommand.Environment(
            engine: Bool.random(using: &g) ? fullEngine : openrsyncEngine,
            destinationFileSystem: [FileSystemKind.apfs, .exfat, .fat][Int(UInt64.random(in: 0..<3, using: &g))],
            sourceIsDirectory: Bool.random(using: &g), protectedPaths: [spliced(&g, maxParts: 3)]
        )
        for arguments in [RsyncCommand.transfer(job, environment: environment), RsyncCommand.verify(job, environment: environment, checksum: true)] {
            let separator = arguments.lastIndex(of: "--")
            #expect(separator == arguments.count - 3)
            #expect(arguments.suffix(2).allSatisfy { $0.hasPrefix("/") })
            #expect(arguments.last?.hasSuffix("/") == true)
            #expect(!arguments.contains { $0.contains("remove-source") })
            #expect(arguments.contains("--delete") == (options.deleteExtraneous || arguments.contains("-n")))
        }
    }
}
