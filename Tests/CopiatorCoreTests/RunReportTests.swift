// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// Çalıştırma raporu: değişen dosyalar (eklenen, güncellenen, silinen), yerleştirilen rotada kaynaktaki adları,
/// "Taşı" ile Çöp'e giden kaynaklar; yalnızca son çalıştırmada tutulur; metni okunur ve görünmez karakterleri gösterir.
@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct RunReportTests {
    private func context(_ w: Workspace) async throws -> EngineContext {
        var context = try await engineContext()
        context.scratchDirectory = try w.mkdir("Gecici")
        let bin = try w.mkdir(".Trash")
        context.trashItem = { url in
            let target = bin.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            return (try? FileManager.default.moveItem(at: url, to: target)) != nil ? target : nil
        }
        return context
    }

    @Test func reportListsAddedUpdatedAndDeletedFiles() async throws {
        let w = try Workspace("CopiatorRunReport")
        try w.write("Kaynak/a.txt", "yeni içerik, daha uzun")
        try w.write("Kaynak/alt/b.txt", "b")
        try w.write("Hedef/Kaynak/a.txt", "eski")
        try w.write("Hedef/Kaynak/fazla.txt", "fazla")
        var job = TransferJob(source: w.url("Kaynak"), destination: w.url("Hedef"),
                              options: CopyOptions(deleteExtraneous: true, conflictPolicy: .replace))
        let result = await RsyncEngine().run(job, context: try await context(w)) { _ in }
        #expect(result.kind.isSuccess, "\(result)")
        let report = try #require(result.report)
        #expect(Set(report.items.map { "\($0.action.rawValue) \($0.path)" })
            == ["added Kaynak/alt/b.txt", "updated Kaynak/a.txt", "deleted Kaynak/fazla.txt"], "\(report.items)")
        #expect(report.items.allSatisfy { $0.source == nil } && !report.truncated && report.trashedSources.isEmpty)

        JobQueue.finish(&job, with: result)
        JobQueue.finish(&job, with: JobResult(kind: .succeeded))
        #expect(job.history.map { $0.result.report == nil } == [true, true], "yalnızca son çalıştırmada; sonuncunun raporu yok")
        let saved = try JSONDecoder().decode(JobResult.self, from: JSONEncoder().encode(result))
        #expect(saved.report == report)
        #expect(try JSONDecoder().decode(JobResult.self, from: Data(#"{"kind":"succeeded"}"#.utf8)).report == nil)
    }

    /// Yerleştirilen rota: hedefteki yeni ad ile kaynaktaki eski ad birlikte; "Taşı" ile Çöp'e giden kaynak da raporda.
    @Test func placedRouteReportsTheSourceNameAndTrashedSources() async throws {
        let w = try Workspace("CopiatorRunReport")
        try w.write("Gelen/Enerjisa Ekim 2026.pdf", "fatura\n")
        try w.write("Gelen/baska.txt", "başka\n")
        try w.mkdir("Arsiv")
        let rules = RuleGroup(conditions: [RuleCondition(attribute: .fileExtension, op: .equals, value: "pdf")])
        let options = CopyOptions(copyMode: .contents, rules: rules, conflictPolicy: .replace,
                                  placement: RoutePlacement(folderTemplate: "{year}/{month}", nameTemplate: "El_{month}_{yy}", dateSource: .fileName),
                                  trashSourceAfterCopy: true)
        let job = TransferJob(source: w.url("Gelen"), destination: w.url("Arsiv"), options: options)
        let result = await RsyncEngine().run(job, context: try await context(w)) { _ in }
        #expect(result.kind.isSuccess, "\(result)")
        let report = try #require(result.report)
        #expect(report.items == [RunReport.Item(action: .added, path: "2026/10/El_10_26.pdf", source: "Enerjisa Ekim 2026.pdf")])
        #expect(report.trashedSources == ["Enerjisa Ekim 2026.pdf"])
    }

    @Test func reportTextHasSectionsAndShowsHiddenCharacters() {
        var result = JobResult(kind: .succeeded)
        result.report = RunReport(items: [
            RunReport.Item(action: .added, path: "2026/10/El_10_26.pdf", source: "Enerjisa Ekim 2026.pdf"),
            RunReport.Item(action: .added, path: "satır\nkırık.txt"),
            RunReport.Item(action: .deleted, path: "eski.txt"),
        ], truncated: true, trashedSources: ["Enerjisa Ekim 2026.pdf"])
        let job = TransferJob(source: URL(fileURLWithPath: "/Gelen"), destination: URL(fileURLWithPath: "/Arsiv"))
        let run = JobRun(startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 60), result: result)
        let text = RunReport.text(title: "Faturalar", job: job, run: run, result: "tamam", problems: ["uyarı"],
                                  text: { key, arguments in ([key.rawValue] + arguments).joined(separator: "|") }, date: { "\($0.timeIntervalSince1970)" })
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(Array(lines.prefix(6)) == ["reportTitle|Faturalar", "reportSource|/Gelen", "reportDestination|/Arsiv", "reportStarted|0.0",
                                           "reportFinished|60.0", "reportResult|tamam"])
        #expect(lines.contains("reportAdded|2") && lines.contains("  Enerjisa Ekim 2026.pdf  →  2026/10/El_10_26.pdf"))
        #expect(lines.contains("reportDeleted|1") && !lines.contains { $0.hasPrefix("reportUpdated") })
        #expect(lines.contains("reportTruncated|\(RunReport.maxItems)") && lines.contains("reportTrashed|1") && lines.contains("reportProblems|1"))
        #expect(!lines.contains("kırık.txt"), "satır sonu içeren ad tek satırda kalır")
    }
}
