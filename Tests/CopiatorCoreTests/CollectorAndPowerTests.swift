// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import CopiatorCore

private func collector(_ configure: (inout AdvancedOptions) -> Void) -> (RsyncOutputCollector, Collected<TransferProgress>, Collected<[String]>) {
    var options = AdvancedOptions()
    configure(&options)
    let progress = Collected<TransferProgress>()
    let changes = Collected<[String]>()
    let collector = RsyncOutputCollector(advanced: options, onProgress: { progress.add($0) }, onChanges: { changes.add($0) })
    return (collector, progress, changes)
}

// MARK: - rsync çıktısı (gerçek 3.5.1 çıktısından)

/// `--info=progress2,name1,flist2,stats2`: adlar ilerlemeye eklenir, istatistikler ayrı toplanır, gürültü atılır.
@Test func collectsNamesProgressAndStatistics() {
    let (c, progress, _) = collector { $0.showFileNames = true; $0.showStats = true }
    let records = [
        "sending incremental file list", "created directory /tmp/d1", "src/",
        "              0   0%    0.00kB/s    0:00:00 (xfr#0, to-chk=6/8)", "src/a/", "src/a/abs -> /etc/hosts",
        "src/a/f1", "              3  12%    0.00kB/s    0:00:00  ", "              3  12%    0.00kB/s    0:00:00 (xfr#1, to-chk=4/8)",
        "src/a/sat\\#305r.txt", "              6  25%    2.93kB/s    0:00:00 (xfr#2, to-chk=3/8)",
        "Number of files: 8 (reg: 4, dir: 2, link: 2)", "Total file size: 24 bytes", "Total bytes sent: 398",
    ]
    records.forEach(c.consume)
    let values = progress.values
    #expect(values.last?.currentItem == "src/a/sat\u{C5}r.txt" || values.last?.currentItem?.hasPrefix("src/a/sat") == true)
    #expect(values.contains { $0.currentItem == "src/a/f1" && $0.bytesTransferred == 3 })
    #expect(!values.contains { $0.currentItem?.contains("->") == true })
    #expect(c.statistics == ["Number of files: 8 (reg: 4, dir: 2, link: 2)", "Total file size: 24 bytes", "Total bytes sent: 398"])
    #expect(!values.contains { $0.currentItem == "sending incremental file list" || $0.currentItem?.hasPrefix("created directory") == true })
}

/// Dosya başı ilerleme: bayt ve yüzde o dosyanındır; toplam bayt biten dosyalardan, genel oran denetlenenlerden gelir.
@Test func perFileProgressAccumulatesTotals() {
    let (c, progress, _) = collector { $0.progressDetail = .perFile }
    [
        "              3 100%    0.00kB/s    0:00:00  ", "              3 100%    0.00kB/s    0:00:00 (xfr#1, to-chk=4/8)",
        "          2.00K  40%    1.00kB/s    0:00:03  ", "          5.00K 100%    2.93kB/s    0:00:00 (xfr#2, to-chk=3/8)",
    ].forEach(c.consume)
    let values = progress.values
    #expect(values[0].bytesTransferred == 3 && values[0].fileFraction == 1)
    #expect(values[1].bytesTransferred == 3 && values[1].fraction == 0.5)
    #expect(values[2].bytesTransferred == 2003 && values[2].fileFraction == 0.4 && values[2].fraction == 0.5)
    #expect(values[3].bytesTransferred == 5003 && values[3].fraction == 5.0 / 8.0)
    #expect(values.allSatisfy { $0.remainingSeconds == nil })
}

/// `--no-inc-recursive` ile `flist2`: liste çıkarılırken sayaç; gerçek ilerleme gelince sayaç biter.
@Test func fileListCounterBeforeCopying() {
    let (c, progress, _) = collector { $0.preciseProgress = true; $0.fileListProgress = true }
    ["building file list ... ", " 0 files...", " 1000 files...", "6 files to consider",
     "              4  21%    0.00kB/s    0:00:00 (xfr#1, to-chk=1/6)", " 2000 files..."].forEach(c.consume)
    let values = progress.values
    #expect(values[0].filesListed == 0 && values[0].isListing)
    #expect(values[1].filesListed == 1000 && values[1].isListing)
    #expect(values.count == 3)
    #expect(!values[2].isListing)
    #expect(RsyncOutputCollector.listedCount(" 12 files...") == 12)
    #expect(RsyncOutputCollector.listedCount("files...") == nil)
    #expect(RsyncOutputCollector.listedCount("x files...") == nil)
}

/// `-i`: değişiklik satırları toplu bildirilir (kayıt dosyası satır başına yazılmaz), en çok son 500 satır tutulur.
@Test func changeLinesAreBatched() {
    let (c, progress, changes) = collector { $0.logChanges = true }
    c.consume("              0   0%    0.00kB/s    0:00:00 (xfr#0, to-chk=2/3)")
    for index in 0..<1200 { c.consume(">f+++++++++ klasör/dosya\(index).txt") }
    c.consume("*deleting   eski.txt")
    c.flush()
    let batches = changes.values
    #expect(batches.count <= 3)
    let all = batches.flatMap { $0 }
    #expect(all.last == "*deleting   eski.txt")
    #expect(all.count <= RsyncOutputCollector.maxBufferedChanges + 1)
    #expect(progress.values.last?.currentItem == "eski.txt" || progress.values.last?.currentItem?.contains("eski") == true)
}

// MARK: - Güç önerileri

@Test func powerAdviceRules() {
    let desktop = PowerSnapshot(source: .ac, hasBattery: false)
    #expect(PowerAdvisor.advice(for: desktop, keepDisplayAwake: false) == [.displayMaySleep])
    #expect(PowerAdvisor.advice(for: desktop, keepDisplayAwake: true).isEmpty)

    let laptopPlugged = PowerSnapshot(source: .ac, hasBattery: true, batteryPercent: 80, isCharging: true)
    #expect(PowerAdvisor.advice(for: laptopPlugged, keepDisplayAwake: true) == [.lidClosesSleep])

    let onBattery = PowerSnapshot(source: .battery, hasBattery: true, batteryPercent: 64, lowPowerMode: true)
    #expect(PowerAdvisor.advice(for: onBattery, keepDisplayAwake: false) == [.onBattery, .lowPowerMode, .lidClosesSleep, .displayMaySleep])
    #expect(PowerAdvisor.advice(for: PowerSnapshot(source: .battery, hasBattery: true, batteryPercent: 15), keepDisplayAwake: true).first == .batteryLow)
    #expect(PowerAdvisor.advice(for: PowerSnapshot(source: .battery, hasBattery: true, batteryPercent: 4), keepDisplayAwake: true).first == .batteryCritical)

    // İş sürerken yalnızca yeni çıkan uyarılar bildirilir.
    let before = PowerAdvisor.advice(for: laptopPlugged, keepDisplayAwake: false)
    let after = PowerAdvisor.advice(for: PowerSnapshot(source: .battery, hasBattery: true, batteryPercent: 15), keepDisplayAwake: false)
    #expect(PowerAdvisor.newWarnings(previous: before, current: after) == [.batteryLow])
    #expect(PowerAdvisor.newWarnings(previous: after, current: after).isEmpty)
}

@Test func currentPowerSnapshotIsReadable() {
    let snapshot = PowerSnapshot.current()
    #expect(snapshot.source != .unknown || !snapshot.hasBattery)
    if let percent = snapshot.batteryPercent { #expect((0...100).contains(percent)) }
}

// MARK: - Uyku engeli

/// Uyku engeli alınır, sistemin engel listesinde doğrulanır ve bırakılınca listeden çıkar; ekran engeli isteğe bağlıdır.
@Test func sleepGuardIsVerifiedAgainstTheSystem() {
    let reason = "Copiator test guard \(UUID().uuidString)"
    let guardian = SleepGuard(reason: reason)
    let status = guardian.begin(keepDisplayAwake: false)
    #expect(status.systemSleepPrevented)
    #expect(!status.displaySleepPrevented)
    #expect(!status.unverified)
    #expect(SleepAssertion.activeAssertionNames().contains(reason))

    let withDisplay = guardian.begin(keepDisplayAwake: true)
    #expect(withDisplay.systemSleepPrevented && withDisplay.displaySleepPrevented && !withDisplay.unverified)
    #expect(SleepAssertion.activeAssertionNames().contains(reason + " (display)"))

    #expect(guardian.end() == false)
    let names = SleepAssertion.activeAssertionNames()
    #expect(!names.contains(reason) && !names.contains(reason + " (display)"))
    #expect(!guardian.isHeld)
    #expect(guardian.status(expectDisplay: false).unverified)
}

@Test func displayAssertionTypeIsUsed() {
    let reason = "Copiator display \(UUID().uuidString)"
    let assertion = SleepAssertion(reason: reason, type: kIOPMAssertionTypePreventUserIdleDisplaySleep)
    #expect(assertion.acquire())
    #expect(SleepAssertion.activeAssertionNames().contains(reason))
    assertion.release()
    #expect(!SleepAssertion.activeAssertionNames().contains(reason))
}
