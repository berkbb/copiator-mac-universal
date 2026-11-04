// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// İşleri ve ayarları taşıma dosyası: işler yalnızca tür, kaynak, hedef ve seçenekleriyle yazılır; içe aktarılınca yeni
/// kimlik alır, duraklatılmış ve geçmişsiz gelir. Başka biçimdeki, daha yeni sürümdeki ve çok büyük dosyalar nedeni
/// söylenerek reddedilir. Bulunmayan klasörler yeniden eşlenir.
struct SetupTransferTests {
    private struct Settings: Codable, Equatable {
        var reminder: Int
    }

    private func sampleJob() -> TransferJob {
        var options = CopyOptions(copyMode: .contents, snapshots: SnapshotOptions(enabled: true))
        options.verifyAfterCopy = .checksum
        var job = TransferJob(source: URL(fileURLWithPath: "/Users/test/Belgeler", isDirectory: true),
                              destination: URL(fileURLWithPath: "/Volumes/Yedek/Arsiv", isDirectory: true), options: options,
                              status: .finished, createdAt: Date(timeIntervalSince1970: 1_000))
        job.result = JobResult(kind: .succeeded, exitCode: 0)
        job.log = [JobLogEntry(level: .info, key: .logPaused)]
        job.routineName = "Belgeler"
        job.wasInterrupted = true
        return job
    }

    @Test func roundTripKeepsWhatToCopyAndDropsRunState() throws {
        let original = sampleJob()
        let data = try SetupTransfer.export(jobs: [original], settings: Settings(reminder: 14), now: Date(timeIntervalSince1970: 5))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"format\" : \"copiator-setup\"") && text.contains("\"version\" : 1"))
        for key in ["\"log\"", "\"history\"", "\"result\"", "\"routineName\"", "\"wasInterrupted\"", "\"status\"", original.id.uuidString] {
            #expect(!text.contains(key), "\(key)")
        }
        let now = Date(timeIntervalSince1970: 9_000)
        let contents = try SetupTransfer.read(data, settings: Settings.self, now: now)
        #expect(contents.settings == Settings(reminder: 14))
        let job = try #require(contents.jobs.first)
        #expect(contents.jobs.count == 1)
        #expect(job.id != original.id)
        #expect(job.kind == original.kind && job.source == original.source && job.destination == original.destination)
        #expect(job.options == original.options)
        #expect(job.status == .paused)
        #expect(job.result == nil && job.log.isEmpty && job.history.isEmpty && job.routineName == nil && !job.wasInterrupted)
        #expect(job.createdAt == now)
        // Ayarsız dosya da okunur.
        let bare = try SetupTransfer.read(SetupTransfer.export(jobs: [original], settings: Settings?.none), settings: Settings.self)
        #expect(bare.settings == nil && bare.jobs.count == 1)
    }

    @Test func foreignNewerAndHugeFilesAreRefused() throws {
        func read(_ text: String) throws -> SetupTransfer.Contents<Settings> {
            try SetupTransfer.read(Data(text.utf8), settings: Settings.self)
        }
        #expect(throws: SetupTransfer.Failure.notSetup) { try read("{}") }
        #expect(throws: SetupTransfer.Failure.notSetup) { try read("not json") }
        #expect(throws: SetupTransfer.Failure.notSetup) {
            try read(#"{"format":"copiator-routines","version":1,"exportedAt":"2026-11-04T10:00:00Z","jobs":[]}"#)
        }
        // Daha yeni sürüm: dosyanın geri kalanı bu sürümde çözülemese de neden söylenir.
        #expect(throws: SetupTransfer.Failure.newerVersion(2)) {
            try read(#"{"format":"copiator-setup","version":2,"somethingNew":true}"#)
        }
        #expect(throws: SetupTransfer.Failure.tooLarge) {
            try SetupTransfer.read(Data(count: SetupTransfer.maxSize + 1), settings: Settings.self)
        }
        let routines = try RoutineTransfer.export([])
        #expect(throws: SetupTransfer.Failure.notSetup) { try SetupTransfer.read(routines, settings: Settings.self) }
    }

    @Test func missingFoldersCanBeRemapped() throws {
        let w = try Workspace("CopiatorSetupTransfer")
        let present = try w.mkdir("Var")
        var jobs = [
            TransferJob(source: present, destination: w.url("Yok/Hedef")),
            TransferJob(source: w.url("Yok/Kaynak"), destination: present),
        ]
        let missing = SetupTransfer.missingFolders(in: jobs)
        #expect(missing.map(\.isSource) == [false, true])
        #expect(missing.map(\.job) == [jobs[0].id, jobs[1].id])
        let newDestination = try w.mkdir("YeniHedef")
        let newSource = try w.mkdir("YeniKaynak")
        SetupTransfer.remap(missing[0], to: newDestination, in: &jobs)
        SetupTransfer.remap(missing[1], to: newSource, in: &jobs)
        #expect(jobs[0].destination == newDestination && jobs[0].source == present)
        #expect(jobs[1].source == newSource && jobs[1].destination == present)
        #expect(SetupTransfer.missingFolders(in: jobs).isEmpty)
    }
}
