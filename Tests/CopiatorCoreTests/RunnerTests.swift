// SPDX-License-Identifier: GPL-3.0-only
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

/// Ortak GCD havuzu bloklanan işlerle doluyken de zaman aşımı zamanında çalışır: zamanlayıcı uygulamanın kendi kuyruğundadır.
/// (Ortak havuzdaki bir zamanlayıcı havuz boşalana kadar beklerdi; süreç o arada biter ve zaman aşımı hiç bildirilmezdi.)
/// Havuz kısa süre dolu tutulur (yaklaşık 1,2 sn); süreç ondan önce biter, yani ortak havuzdaki bir zamanlayıcı zaman aşımını
/// hiç bildirmezdi. Sürecin bittiği bildirim Foundation'ın kendi kuyruğundan geldiği için toplam süre ölçülmez.
@Test func runnerTimesOutWhileTheSharedPoolIsBusy() async {
    for _ in 0..<80 { DispatchQueue.global().async { Thread.sleep(forTimeInterval: 1.2) } }
    await #expect(throws: EngineError.timedOut) {
        _ = try await shell.run(["-c", "sleep 0.8"], timeout: 0.3)
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

/// Düşük öncelik: süreç arka plan hizmet sınıfıyla başlar (macOS zamanlama önceliğini 4'e indirir, disk G/Ç'sini
/// kısar); normal süreç böyle başlamaz.
@Test func lowPriorityRunsTheProcessInTheBackgroundClass() async throws {
    func priority(_ runner: CommandRunner) async throws -> Int? {
        Int(try await runner.run(["-c", "/bin/ps -o pri= -p $$"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let low = try #require(try await priority(CommandRunner(executableURL: shell.executableURL, lowPriority: true)))
    let normal = try #require(try await priority(shell))
    #expect(low == 4)
    #expect(normal > low)
}

/// Kum havuzundaki program da düşük öncelikte çalışır: sandbox-exec'in başlattığı program sınıfı korur ve kurallar
/// düşük öncelikli kopyada da geçerlidir.
@Test(.enabled(if: SandboxProfile.isAvailable)) func lowPriorityReachesTheSandboxedProgram() async throws {
    let w = try Workspace("CopiatorLowPriority")
    let folder = try w.mkdir("Klasor")
    let marker = "31.\(Int.random(in: 1000...9999))"
    let profile = SandboxProfile.forTransfer(sources: [folder], destination: folder)
    let runner = CommandRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"), lowPriority: true).sandboxed(profile)
    #expect(runner.lowPriority && runner.sandbox != nil)
    let task = Task { try await runner.run([marker]) }
    defer { task.cancel() }
    var found: Int?
    for _ in 0..<50 where found == nil {
        try await Task.sleep(for: .milliseconds(100))
        let pids = try await CommandRunner(executableURL: URL(fileURLWithPath: "/usr/bin/pgrep")).run(["-f", "sleep \(marker)"]).stdout
        if let pid = pids.split(separator: "\n").first {
            let pri = try await shell.run(["-c", "/bin/ps -o pri= -p \(pid)"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            found = Int(pri)
        }
    }
    #expect(found == 4)
}

/// Motor bağlamındaki düşük öncelik gerçek rsync'e ulaşır: yavaşlatılmış bir kopya sürerken rsync süreçleri arka plan
/// sınıfındadır; bayrak kapalıyken değildir.
@Test(.enabled(if: vendoredRsync != nil && SandboxProfile.isAvailable)) func lowPriorityReachesTheRsyncOfAJob() async throws {
    for low in [true, false] {
        let w = try Workspace("CopiatorLowPriorityJob")
        try Data(count: 4 << 20).write(to: w.mkdir("Kaynak").appendingPathComponent("buyuk.bin"))
        let destination = try w.mkdir("Hedef-\(UUID().uuidString)")
        var options = CopyOptions()
        options.advanced.bandwidthLimitKiB = 256
        let job = TransferJob(source: w.url("Kaynak"), destination: destination, options: options)
        var context = try await engineContext()
        context.scratchDirectory = try w.mkdir("Gecici")
        context.lowPriority = low
        let run = Task { await RsyncEngine().run(job, context: context) { _ in } }
        defer { run.cancel() }
        var priorities: [Int] = []
        for _ in 0..<60 where priorities.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            let pids = try await CommandRunner(executableURL: URL(fileURLWithPath: "/usr/bin/pgrep")).run(["-f", destination.lastPathComponent]).stdout
            for pid in pids.split(separator: "\n") {
                let pri = try await shell.run(["-c", "/bin/ps -o pri= -p \(pid)"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = Int(pri) { priorities.append(value) }
            }
        }
        #expect(!priorities.isEmpty, "rsync bulunamadı")
        #expect(priorities.allSatisfy { low ? $0 == 4 : $0 > 4 }, "\(low) \(priorities)")
        run.cancel()
        _ = await run.value
    }
}
