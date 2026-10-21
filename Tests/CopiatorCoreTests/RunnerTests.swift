// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

private let shell = CommandRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))

@Test func runnerCapturesOutputAndExitCode() async throws {
    let result = try await shell.run(["-c", "echo merhaba; echo hata >&2; exit 3"])
    #expect(result.exitCode == 3)
    #expect(result.stdout == "merhaba\n")
    #expect(result.stderr == "hata\n")
}

/// rsync ilerleme satırlarını "\r" ile, dosya satırlarını "\n" ile bitirir; parçalara bölünmüş satır da tek kayıttır.
@Test func runnerSplitsRecordsOnCarriageReturnAndNewline() async throws {
    let records = Collected<String>()
    _ = try await shell.run(["-c", "printf 'bir\\riki\\nüç'; sleep 0.1; printf ' dört\\r\\r'; printf 'son'"]) { records.add($0) }
    #expect(records.values == ["bir", "iki", "üç dört", "son"])
}

/// Akış kipinde stdout biriktirilmez: saatlerce süren bir kopyanın ilerleme satırları belleği doldurmaz.
@Test func runnerStreamingKeepsOnlyTheTail() async throws {
    let records = Collected<String>()
    let result = try await shell.run(
        ["-c", "i=0; while [ $i -lt 3000 ]; do printf '%080d\\r' $i; i=$((i+1)); done"],
        retainStdout: false
    ) { records.add($0) }
    #expect(records.values.count == 3000)
    #expect(result.stdout.utf8.count <= CommandRunner.streamTailBytes)
    #expect(result.stdout.hasSuffix(String(format: "%080d\r", 2999)))
}

@Test func runnerTimesOut() async {
    await #expect(throws: EngineError.timedOut) {
        _ = try await shell.run(["-c", "sleep 5"], timeout: 0.3)
    }
}

@Test func runnerCancels() async {
    let task = Task { try await shell.run(["-c", "sleep 5"]) }
    try? await Task.sleep(for: .milliseconds(200))
    task.cancel()
    await #expect(throws: EngineError.cancelled) {
        _ = try await task.value
    }
}

/// SIGTERM'i yok sayan süreç 2 saniye sonra SIGKILL ile durdurulur; iptal hiçbir zaman asılı kalmaz.
@Test func runnerKillsProcessThatIgnoresTerm() async {
    let start = ContinuousClock.now
    let task = Task { try await shell.run(["-c", "trap '' TERM; sleep 30"]) }
    try? await Task.sleep(for: .milliseconds(300))
    task.cancel()
    await #expect(throws: EngineError.cancelled) { _ = try await task.value }
    #expect(ContinuousClock.now - start < .seconds(10))
}

@Test func runnerReportsMissingExecutable() async {
    await #expect(throws: EngineError.engineNotFound) {
        _ = try await CommandRunner(executableURL: URL(fileURLWithPath: "/nonexistent/rsync")).run([])
    }
}

/// Sınırı aşan çıktı (ör. milyonlarca farkı olan bir kuru çalıştırma) süreci durdurur ve hata verir.
@Test func runnerCapsHugeOutput() async {
    await #expect(throws: EngineError.self) {
        _ = try await shell.run(["-c", "yes 0123456789"], maxOutputBytes: 1 << 20)
    }
}

@Test func runnerFeedsInput() async throws {
    let result = try await CommandRunner(executableURL: URL(fileURLWithPath: "/bin/cat")).run([], input: Data("girdi".utf8))
    #expect(result.stdout == "girdi")
}

@Test func diagnosticPrefersRsyncErrorLines() {
    let output = """
    sending incremental file list
    rsync: [receiver] mkstemp "/x/.a.XYZ" failed: Permission denied (13)
    rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1412) [sender=3.5.1]
    """
    let diagnostic = EngineError.diagnostic(from: output)
    #expect(diagnostic.contains("Permission denied"))
    #expect(!diagnostic.contains("incremental"))
}
