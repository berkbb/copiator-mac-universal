// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

/// Büyük ağaçlarla stres turu (Scripts/stress-test.sh açar): COPIATOR_STRESS_FILES=20000 swift test --filter StressTests
private let stressFiles = Int(ProcessInfo.processInfo.environment["COPIATOR_STRESS_FILES"] ?? "") ?? 0

@Suite(.enabled(if: vendoredRsync != nil && stressFiles > 0, "COPIATOR_STRESS_FILES verilmedi"), .serialized)
struct StressTests {
    /// Çok sayıda küçük dosya + büyük bir dosya: kopyala, ortada kes, sürdür, doğrula. Kaynak hiç değişmez,
    /// ilerleme olayları seyreltilir (arayüz boğulmaz), ir-chk tahmin kipi görülür.
    @Test func largeTreeCopyCancelResumeVerify() async throws {
        let workspace = try Workspace("CopiatorStress")
        try workspace.mkdir("Hedef")
        let perFolder = 200
        for folder in 0..<max(1, stressFiles / perFolder) {
            let directory = try workspace.mkdir(String(format: "Kaynak/klasör%03d", folder))
            for file in 0..<perFolder {
                FileManager.default.createFile(atPath: directory.appendingPathComponent(String(format: "dosya%04d.txt", file)).path,
                                               contents: Data("\(folder)-\(file)\n".utf8))
            }
        }
        let big = workspace.url("Kaynak/buyuk.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        for _ in 0..<1024 { handle.write(Data(repeating: 0x33, count: 1 << 20)) }
        try handle.close()
        let sourceBefore = try FileManager.default.subpathsOfDirectory(atPath: workspace.url("Kaynak").path).sorted()

        let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"))
        let context = try await engineContext()
        let events = Collected<TransferEvent>()
        let started = ContinuousClock.now
        let first = Task { await RsyncEngine().run(job, context: context) { events.add($0) } }
        try await Task.sleep(for: .seconds(1))
        first.cancel()
        let cancelStarted = ContinuousClock.now
        #expect(await first.value.kind == .cancelled)
        // İptal hızlıdır: rsync SIGTERM'e uyar, en geç 2 sn sonra SIGKILL.
        #expect(ContinuousClock.now - cancelStarted < .seconds(5))

        let resumed = await RsyncEngine().run(job, context: context) { events.add($0) }
        #expect(resumed.kind == .succeeded, "\(resumed)")
        let elapsed = ContinuousClock.now - started
        let progress = events.values.compactMap { if case .progress(let p) = $0 { p } else { nil } }
        // Seyreltme: saniyede en çok ~4 olay (+ tarama/kopyalama geçişleri).
        let seconds = Double(elapsed.components.seconds) + 1
        #expect(Double(progress.count) <= seconds * 4 + 20, "\(progress.count) olay / \(seconds) sn")
        #expect(progress.last?.fraction == 1)

        let report = await RsyncEngine().verify(job, context: context, checksum: false)
        #expect(report.isIdentical, "\(report.entries.prefix(5))")
        let copied = try FileManager.default.subpathsOfDirectory(atPath: workspace.url("Hedef/Kaynak").path).sorted()
        #expect(copied == sourceBefore)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: workspace.url("Kaynak").path).sorted() == sourceBefore)
    }
}
