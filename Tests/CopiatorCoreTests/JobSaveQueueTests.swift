// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// İş kaydının sırası: art arda gelen kayıtlar birleşir, son kayıt her zaman diske ulaşır.
struct JobSaveQueueTests {
    /// Yazılanları sırayla tutar; ilk yazma `gate` açılana kadar bekletilebilir.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var written: [[String]] = []
        let gate = DispatchSemaphore(value: 0)
        var holdsFirstWrite = false

        func write(_ jobs: [TransferJob]) {
            lock.lock()
            let isFirst = written.isEmpty
            written.append(jobs.map(\.destination.lastPathComponent))
            lock.unlock()
            if isFirst, holdsFirstWrite { gate.wait() }
        }

        var writes: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return written
        }
    }

    private func jobs(_ name: String) -> [TransferJob] {
        [TransferJob(source: URL(fileURLWithPath: "/tmp/kaynak"), destination: URL(fileURLWithPath: "/tmp/" + name), options: CopyOptions())]
    }

    /// Bir yazma sürerken gelen ertelenmiş kayıtlardan yalnızca sonuncusu yazılır.
    @Test func deferredSavesCoalesceToTheNewest() {
        let recorder = Recorder()
        recorder.holdsFirstWrite = true
        let queue = JobSaveQueue { recorder.write($0) }
        queue.saveSoon(jobs("ilk")) { _ in }
        while recorder.writes.isEmpty { usleep(1000) }
        for index in 0..<50 { queue.saveSoon(jobs("ara\(index)")) { _ in } }
        queue.saveSoon(jobs("son")) { _ in }
        recorder.gate.signal()
        queue.flush()
        #expect(recorder.writes == [["ilk"], ["son"]])
    }

    /// `flush` döndüğünde son kayıt yazılmıştır; kayıt istemek çağıranı bekletmez.
    @Test func flushWaitsForTheLastSave() {
        let recorder = Recorder()
        recorder.holdsFirstWrite = true
        let queue = JobSaveQueue { recorder.write($0) }
        queue.saveSoon(jobs("ilk")) { _ in }
        queue.saveSoon(jobs("son")) { _ in }
        // İlk yazma kapıda beklerken çağıran buraya ulaşabildi; kapı açılınca sıra boşalır.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { recorder.gate.signal() }
        queue.flush()
        #expect(recorder.writes.last == ["son"])
    }

    /// Yazma hatası bildirilir.
    @Test func failuresAreReported() {
        struct Failure: Error {}
        let queue = JobSaveQueue { _ in throw Failure() }
        let reported = DispatchSemaphore(value: 0)
        queue.saveSoon(jobs("a")) { _ in reported.signal() }
        #expect(reported.wait(timeout: .now() + 5) == .success)
    }
}
