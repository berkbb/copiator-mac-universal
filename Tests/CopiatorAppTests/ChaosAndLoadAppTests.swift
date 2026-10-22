// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Güvenlik ve dayanıklılık matrisinin uygulama tarafı (yük ve kaos): gerçek kuyruk, kayıt dosyası ve rsync ile.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct ChaosAndLoadAppTests {
    /// Yüz iş art arda kuyruğa girer: hepsi biter, sırayla ve hiçbir zaman ikisi birden çalışmadan; bekleyen sayısı sıfıra
    /// iner, kayıt dosyası da aynı durumu gösterir.
    @Test func loadHundredQueuedJobsDrainInOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshEngine()
        var ids: [TransferJob.ID] = []
        for index in 0..<100 {
            try fixture.write("Kaynaklar/k\(index)/dosya.txt", "\(index)\n")
            let message = model.addJob(source: fixture.url("Kaynaklar/k\(index)"), destination: fixture.url("Hedef"),
                                       options: CopyOptions(conflictPolicy: .replace))
            #expect(message == nil, "\(message ?? "")")
            ids.append(try #require(model.jobs.last?.id))
        }
        await model.waitUntilIdle()
        let jobs = ids.compactMap(model.job)
        #expect(jobs.count == 100)
        #expect(jobs.allSatisfy { $0.status == .finished && $0.result?.kind == .succeeded })
        for (earlier, later) in zip(jobs, jobs.dropFirst()) {
            let finished = try #require(earlier.finishedAt)
            let started = try #require(later.startedAt)
            #expect(finished <= started, "\(earlier.source.lastPathComponent) → \(later.source.lastPathComponent)")
        }
        #expect((0..<100).allSatisfy { fixture.read("Hedef/k\($0)/dosya.txt") == "\($0)\n" })
        #expect(model.pendingCount == 0 && model.runningJobID == nil)
        #expect(try fixture.store.load().filter { $0.status == .finished }.count == 100)
    }

    /// Karar bekleyen işte uygulama kapanıp açılır: soru kaybolmaz (iş kendiliğinden başlamaz, aynı dosya sorulur), karar
    /// verilince iş biter ve hiçbir dosya sormadan değişmez.
    @Test func chaosRelaunchWhileAwaitingDecisionKeepsTheQuestion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("Hedef/Kaynak/not.txt", "hedefteki\n")
        await fixture.model.refreshEngine()
        let id = try #require(fixture.addJob())
        await fixture.model.waitUntilIdle()
        #expect(fixture.model.job(id)?.isAwaitingDecision == true)

        let model = fixture.relaunch()
        await model.refreshEngine()
        await model.waitUntilIdle()
        let restored = try #require(model.job(id))
        #expect(restored.isAwaitingDecision && restored.status == .paused)
        #expect(restored.pendingConflicts?.items.map(\.path) == ["Kaynak/not.txt"])
        #expect(fixture.read("Hedef/Kaynak/not.txt") == "hedefteki\n")

        model.resolveConflicts(id, resolution: ConflictResolution(others: .keepBoth), remember: nil)
        await model.waitUntilIdle()
        #expect(model.job(id)?.status == .finished)
        #expect(fixture.read("Hedef/Kaynak/not.txt") == "hedefteki\n")
        #expect(fixture.read("Hedef/Kaynak/not 2.txt") == "merhaba\n")
    }

    /// İki ayrı karar sayfası: ikincisinde yalnızca yeni ortaya çıkan dosya sorulur ve ilk sayfanın kararı unutulmaz
    /// (yoksa üçüncü çalıştırma ilk dosyayı yeniden sorardı).
    @Test func chaosDecisionsAccumulateAcrossSheets() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        try fixture.write("Hedef/Kaynak/not.txt", "hedefteki not\n")
        await model.refreshEngine()
        let id = try #require(fixture.addJob())
        await model.waitUntilIdle()
        #expect(model.job(id)?.pendingConflicts?.items.map(\.path) == ["Kaynak/not.txt"])

        try fixture.write("Hedef/Kaynak/alt/b.txt", "hedefteki b\n")
        model.resolveConflicts(id, resolution: ConflictResolution(decisions: ["Kaynak/not.txt": .skip]), remember: nil)
        await model.waitUntilIdle()
        #expect(model.job(id)?.pendingConflicts?.items.map(\.path) == ["Kaynak/alt/b.txt"])

        model.resolveConflicts(id, resolution: ConflictResolution(decisions: ["Kaynak/alt/b.txt": .keepBoth]), remember: nil)
        await model.waitUntilIdle()
        #expect(model.job(id)?.status == .finished, "\(model.job(id)?.log.suffix(5) ?? [])")
        #expect(fixture.read("Hedef/Kaynak/not.txt") == "hedefteki not\n")
        #expect(fixture.read("Hedef/Kaynak/alt/b.txt") == "hedefteki b\n")
        #expect(fixture.read("Hedef/Kaynak/alt/b 2.txt") == "alt\n")
    }
}
