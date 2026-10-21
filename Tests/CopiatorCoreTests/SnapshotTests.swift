// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

/// Testlerde sabit saat dilimi ve takvim: sonuçlar makinenin ayarından bağımsızdır.
private let utc = TimeZone(identifier: "UTC")!
private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
}

/// Bugünden bağımsız sabit bir başlangıç (2001-01-01 + 25 yıl civarı): zamana bağlı test yok.
private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func name(_ date: Date) -> String { SnapshotStore.name(for: date, timeZone: utc) }

// MARK: - Adlar

@Test func snapshotNamesRoundTripAndRejectLookalikes() throws {
    let stamp = name(base)
    #expect(stamp.count == 17)
    #expect(SnapshotStore.date(fromName: stamp, timeZone: utc) == base)
    #expect(SnapshotStore.isSnapshotName(stamp, timeZone: utc))
    let shifted = name(base.addingTimeInterval(1))
    #expect(shifted > stamp)
    for bad in ["Latest", stamp + ".partial", "x" + stamp, stamp + " ", String(stamp.dropLast()), "9999-99-99-999999",
                "2026-13-01-000000", "2026-02-30-120000", "2026-10-21-246000", "２０２６-10-21-143005", ""] {
        #expect(!SnapshotStore.isSnapshotName(bad, timeZone: utc), "\(bad)")
    }
}

// MARK: - Saklama kuralları

@Test func retentionWithoutRulesKeepsEverything() {
    let names = (0..<10).map { name(base.addingTimeInterval(Double($0) * 3600)) } + ["Latest", "notlar"]
    let keep = SnapshotStore.retained(names, options: SnapshotOptions(enabled: true), calendar: utcCalendar)
    #expect(keep == Set(names.filter { SnapshotStore.isSnapshotName($0, timeZone: utc) }))
}

@Test func retentionKeepLastAndNewestAlwaysStays() {
    let names = (0..<6).map { name(base.addingTimeInterval(Double($0) * 60)) }
    let keep = SnapshotStore.retained(names, options: SnapshotOptions(enabled: true, keepLast: 2), calendar: utcCalendar)
    #expect(keep == Set(names.suffix(2)))
    // Sayı 0 olsa da (geçersiz; arayüz izin vermez) en yeni kalır.
    let none = SnapshotStore.retained(names, options: SnapshotOptions(enabled: true, keepLast: 0), calendar: utcCalendar)
    #expect(none == [names.last!])
}

@Test func retentionKeepsNewestPerDayWeekAndMonth() {
    let day: TimeInterval = 86_400
    // 60 gün, günde üç anlık görüntü (sabah, öğle, akşam).
    let calendar = utcCalendar
    let midnight = calendar.startOfDay(for: base)
    var names: [String] = []
    for offset in 0..<60 {
        for hour in [8.0, 12.0, 20.0] { names.append(name(midnight.addingTimeInterval(Double(offset) * day + hour * 3600))) }
    }
    func dayKey(_ n: String) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: SnapshotStore.date(fromName: n, timeZone: utc)!)
    }

    let daily = SnapshotStore.retained(names, options: SnapshotOptions(enabled: true, keepDaily: 7), calendar: calendar)
    #expect(daily.count == 7)
    // Her gün o günün en yenisi (akşam) kalır; son 7 gün.
    let lastSeven = Set(names.suffix(21).enumerated().filter { $0.offset % 3 == 2 }.map(\.element))
    #expect(daily == lastSeven)
    #expect(Set(daily.map(dayKey)).count == 7)

    let weekly = SnapshotStore.retained(names, options: SnapshotOptions(enabled: true, keepWeekly: 4), calendar: calendar)
    #expect(weekly.count == 4)
    #expect(weekly.contains(names.last!))
    let weeks = Set(weekly.map { n in
        calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: SnapshotStore.date(fromName: n, timeZone: utc)!)
    })
    #expect(weeks.count == 4)

    let monthly = SnapshotStore.retained(names, options: SnapshotOptions(enabled: true, keepMonthly: 12), calendar: calendar)
    // 60 gün en çok 3 takvim ayına yayılır: her ayın en yenisi.
    let months = Set(names.map { n in calendar.dateComponents([.year, .month], from: SnapshotStore.date(fromName: n, timeZone: utc)!) })
    #expect(monthly.count == months.count)

    // Kurallar birleşir: herhangi biri tutuyorsa kalır.
    let combined = SnapshotStore.retained(names, options: SnapshotOptions(enabled: true, keepLast: 2, keepDaily: 7, keepWeekly: 4),
                                          calendar: calendar)
    #expect(combined == daily.union(weekly).union(Set(names.suffix(2))))
}

@Test func snapshotOptionsValidationAndDecoding() throws {
    #expect(SnapshotOptions(enabled: true, keepLast: 1).isValid)
    #expect(!SnapshotOptions(enabled: true, keepDaily: 0).isValid)
    #expect(!SnapshotOptions(enabled: false, keepLast: 3).hasRetention)
    #expect(SnapshotOptions(enabled: true, keepMonthly: 3).hasRetention)
    var options = CopyOptions(snapshots: SnapshotOptions(enabled: true, keepWeekly: 0))
    #expect(options.problems(source: nil) == [.invalidRetention])
    // Anlık görüntü kipinde "önceki yedek" kendiliğinden seçilir: boş bırakılmış ayar sorun sayılmaz.
    options.snapshots.keepWeekly = 2
    options.advanced.referenceMode = .linkDest
    #expect(options.problems(source: nil).isEmpty)
    options.snapshots.enabled = false
    #expect(options.problems(source: nil) == [.missingReferenceDirectory])

    let decoded = try JSONDecoder().decode(SnapshotOptions.self, from: Data(#"{"enabled": true, "keepDaily": "yedi", "x": 1}"#.utf8))
    #expect(decoded == SnapshotOptions(enabled: true))
}

// MARK: - Klasörler

@Test func prepareResumeFinalizeAndLatestLink() throws {
    let workspace = try Workspace()
    let root = try workspace.mkdir("Yedekler")
    let first = try SnapshotStore.prepare(in: root, now: base, timeZone: utc)
    #expect(!first.resumed && first.previous == nil)
    #expect(first.partial.lastPathComponent == name(base) + ".partial")
    #expect(FileManager.default.fileExists(atPath: first.partial.path))
    // Yarım kalan sürdürülür (yeni klasör açılmaz).
    let again = try SnapshotStore.prepare(in: root, now: base.addingTimeInterval(500), timeZone: utc)
    #expect(again.resumed && again.partial == first.partial)
    #expect(SnapshotStore.partialSnapshots(in: root, timeZone: utc) == [name(base) + ".partial"])

    try workspace.write("Yedekler/\(name(base)).partial/a.txt", "a")
    let done = try SnapshotStore.finalize(partial: first.partial, in: root, now: base.addingTimeInterval(600), timeZone: utc)
    #expect(done.lastPathComponent == name(base.addingTimeInterval(600)))
    #expect(workspace.read("Yedekler/Latest/a.txt") == "a")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("Latest").path) == done.lastPathComponent)
    #expect(SnapshotStore.partialSnapshots(in: root, timeZone: utc).isEmpty)

    // Sonraki çalıştırma öncekine bağlanır; saat geri alınmış olsa da yeni ad en yenisinden sonra gelir.
    let second = try SnapshotStore.prepare(in: root, now: base, timeZone: utc)
    #expect(second.previous?.lastPathComponent == done.lastPathComponent)
    let job = SnapshotStore.apply(second, to: TransferJob(source: workspace.url("Kaynak"), destination: root))
    #expect(job.destination == second.partial)
    #expect(job.options.advanced.referenceMode == .linkDest)
    #expect(job.options.advanced.referenceDirectory == done.path)
    let secondDone = try SnapshotStore.finalize(partial: second.partial, in: root, now: base, timeZone: utc)
    #expect(secondDone.lastPathComponent > done.lastPathComponent)
    #expect(SnapshotStore.latest(in: root, timeZone: utc) == secondDone)
    #expect(SnapshotStore.completeSnapshots(in: root, timeZone: utc) == [done.lastPathComponent, secondDone.lastPathComponent])
}

/// "Latest" adında gerçek bir klasör varsa ona dokunulmaz; anlık görüntü yine tamamlanır.
@Test func latestLinkNeverReplacesARealItem() throws {
    let workspace = try Workspace()
    let root = try workspace.mkdir("Yedekler")
    try workspace.write("Yedekler/Latest/benim.txt", "kullanıcının")
    let prepared = try SnapshotStore.prepare(in: root, now: base, timeZone: utc)
    let done = try SnapshotStore.finalize(partial: prepared.partial, in: root, now: base, timeZone: utc)
    #expect(FileManager.default.fileExists(atPath: done.path))
    #expect(workspace.read("Yedekler/Latest/benim.txt") == "kullanıcının")
    #expect(!SnapshotStore.updateLatestLink(in: root, to: done.lastPathComponent))
}

/// Budama yalnızca adı tam biçimdeki tamamlanmış anlık görüntüleri siler; salt okunur klasörleri de siler; yarım
/// anlık görüntüye, bağlantılara, başka dosyalara ve korunan (yeni) anlık görüntüye dokunmaz.
@Test func pruneRemovesOnlyExpiredSnapshots() throws {
    let workspace = try Workspace()
    let root = try workspace.mkdir("Yedekler")
    let names = (0..<5).map { name(base.addingTimeInterval(Double($0) * 3600)) }
    for snapshot in names {
        try workspace.write("Yedekler/\(snapshot)/Belgeler/a.txt", snapshot)
        chmod(workspace.url("Yedekler/\(snapshot)/Belgeler").path, 0o555)
        chmod(workspace.url("Yedekler/\(snapshot)").path, 0o555)
    }
    try workspace.mkdir("Yedekler/\(name(base.addingTimeInterval(99_999))).partial")
    try workspace.write("Yedekler/notlar.txt", "dokunma")
    try workspace.mkdir("Yedekler/9999-99-99-999999")
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(name(base.addingTimeInterval(-3600))).path,
                                               withDestinationPath: names[0])
    SnapshotStore.updateLatestLink(in: root, to: names[4])

    let result = SnapshotStore.prune(in: root, options: SnapshotOptions(enabled: true, keepLast: 2), protecting: names[1],
                                     calendar: utcCalendar)
    #expect(Set(result.removed) == [names[0], names[2]])
    #expect(result.failed.isEmpty)
    #expect(SnapshotStore.completeSnapshots(in: root, timeZone: utc) == [names[1], names[3], names[4]])
    #expect(workspace.exists("Yedekler/notlar.txt"))
    #expect(workspace.exists("Yedekler/9999-99-99-999999"))
    #expect(workspace.exists("Yedekler/\(name(base.addingTimeInterval(99_999))).partial"))
    #expect(workspace.read("Yedekler/Latest/Belgeler/a.txt") == names[4])

    // Kural yoksa hiçbir şey silinmez.
    let none = SnapshotStore.prune(in: root, options: SnapshotOptions(enabled: true), protecting: names[4], calendar: utcCalendar)
    #expect(none.removed.isEmpty)
}

// MARK: - Gerçek rsync ile

@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct SnapshotEngineTests {
    private func run(_ job: TransferJob) async throws -> (JobResult, [JobLogEntry]) {
        let events = Collected<TransferEvent>()
        let result = await RsyncEngine().run(job, context: try await engineContext()) { events.add($0) }
        let logs = events.values.flatMap { event -> [JobLogEntry] in
            switch event {
            case .log(let entry): [entry]
            case .logBatch(let entries): entries
            default: []
            }
        }
        return (result, logs)
    }

    private func inode(_ url: URL) -> ino_t {
        var info = stat()
        lstat(url.path, &info)
        return info.st_ino
    }

    /// Üç çalıştırma: her biri ayrı anlık görüntü; değişmeyen dosya sabit bağlantıyla paylaşılır, değişen paylaşılmaz;
    /// "Latest" en yenisini gösterir; "son 2" kuralıyla en eskisi silinir. Kum havuzunda.
    @Test func snapshotsLinkUnchangedFilesAndPrune() async throws {
        let workspace = try Workspace()
        try workspace.write("Kaynak/sabit.txt", "değişmez\n")
        try workspace.write("Kaynak/degisen.txt", "1\n")
        let root = try workspace.mkdir("Yedekler")
        let options = CopyOptions(snapshots: SnapshotOptions(enabled: true, keepLast: 2))
        let job = TransferJob(source: workspace.url("Kaynak"), destination: root, options: options)

        let (first, firstLogs) = try await run(job)
        #expect(first.kind == .succeeded, "\(first)")
        let firstName = try #require(first.snapshot)
        #expect(firstLogs.contains { $0.key == LKey.logSnapshotFirst.rawValue })
        #expect(workspace.read("Yedekler/\(firstName)/Kaynak/sabit.txt") == "değişmez\n")

        try workspace.write("Kaynak/degisen.txt", "2, daha uzun\n")
        let (second, secondLogs) = try await run(job)
        #expect(second.kind == .succeeded, "\(second)")
        let secondName = try #require(second.snapshot)
        #expect(secondName > firstName)
        #expect(secondLogs.contains { $0.key == LKey.logSnapshotStarted.rawValue && $0.arguments.last == firstName })
        #expect(inode(workspace.url("Yedekler/\(firstName)/Kaynak/sabit.txt")) == inode(workspace.url("Yedekler/\(secondName)/Kaynak/sabit.txt")))
        #expect(inode(workspace.url("Yedekler/\(firstName)/Kaynak/degisen.txt")) != inode(workspace.url("Yedekler/\(secondName)/Kaynak/degisen.txt")))
        #expect(workspace.read("Yedekler/Latest/Kaynak/degisen.txt") == "2, daha uzun\n")

        let (third, thirdLogs) = try await run(job)
        #expect(third.kind == .succeeded, "\(third)")
        let thirdName = try #require(third.snapshot)
        #expect(thirdLogs.contains { $0.key == LKey.logSnapshotPruned.rawValue && $0.arguments.last == firstName })
        #expect(SnapshotStore.completeSnapshots(in: root) == [secondName, thirdName])
        #expect(workspace.read("Yedekler/\(secondName)/Kaynak/sabit.txt") == "değişmez\n")

        // Doğrulama en yeni anlık görüntüyle karşılaştırır.
        let report = await RsyncEngine().verify(job, context: try await engineContext(), checksum: true)
        #expect(report.isIdentical, "\(report.entries)")
    }

    /// Duraklatılan (iptal edilen) anlık görüntü yarım kalır ve sonraki çalıştırma onu sürdürür.
    @Test func cancelledSnapshotStaysPartialAndResumes() async throws {
        let workspace = try Workspace()
        try workspace.write("Kaynak/a.txt", "a\n")
        let root = try workspace.mkdir("Yedekler")
        let prepared = try SnapshotStore.prepare(in: root)
        try workspace.write("Yedekler/\(prepared.partial.lastPathComponent)/Kaynak/eski-yarim.txt", "yarım\n")
        let job = TransferJob(source: workspace.url("Kaynak"), destination: root, options: CopyOptions(snapshots: SnapshotOptions(enabled: true)))
        let (result, logs) = try await run(job)
        #expect(result.kind == .succeeded)
        #expect(logs.contains { $0.key == LKey.logSnapshotResumed.rawValue && $0.arguments == [prepared.partial.lastPathComponent] })
        let name = try #require(result.snapshot)
        #expect(workspace.read("Yedekler/\(name)/Kaynak/a.txt") == "a\n")
        #expect(SnapshotStore.partialSnapshots(in: root).isEmpty)
    }

    /// Henüz anlık görüntü yokken doğrulama (önizleme) her şeyi "eksik" gösterir ve hiçbir yere yazmaz.
    @Test func previewBeforeFirstSnapshotListsEverything() async throws {
        let workspace = try Workspace()
        try workspace.write("Kaynak/a.txt", "a\n")
        try workspace.write("Kaynak/alt/b.txt", "b\n")
        let root = try workspace.mkdir("Yedekler")
        let job = TransferJob(source: workspace.url("Kaynak"), destination: root, options: CopyOptions(snapshots: SnapshotOptions(enabled: true)))
        let report = await RsyncEngine().verify(job, context: try await engineContext(), checksum: false)
        #expect(report.result.kind == .succeeded, "\(report.result)")
        #expect(Set(report.entries.filter { $0.kind == .missing }.map(\.path)).isSuperset(of: ["Kaynak/a.txt", "Kaynak/alt/b.txt"]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

// MARK: - Kopyalama sonrası doğrulama

@Suite(.enabled(if: vendoredRsync != nil, "Vendor/rsync/rsync yok"), .serialized)
struct VerifyAfterCopyTests {
    @Test func passingVerificationKeepsTheResult() async throws {
        let workspace = try Workspace()
        try workspace.write("Kaynak/a.txt", "a\n")
        try workspace.mkdir("Hedef")
        try workspace.write("Hedef/Kaynak/fazla.txt", "hedefte kalır\n")
        for mode in [VerifyAfterCopy.quick, .checksum] {
            let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"), options: CopyOptions(verifyAfterCopy: mode))
            let events = Collected<TransferEvent>()
            let result = await RsyncEngine().run(job, context: try await engineContext()) { events.add($0) }
            #expect(result.kind == .succeeded, "\(result)")
            #expect(result.differenceCount == 0)
            #expect(events.values.contains(.phase(.verifying)))
            let keys = events.values.compactMap { if case .log(let entry) = $0 { entry.key } else { nil } }
            #expect(keys.contains(mode == .checksum ? LKey.logVerifyAfterCopyChecksum.rawValue : LKey.logVerifyAfterCopyQuick.rawValue))
            #expect(keys.contains(LKey.logVerifyAfterCopyPassed.rawValue))
        }
    }

    /// Hedef kaynaktan farklıysa (ör. kopyalama sırasında kaynak değişti) iş "doğrulanamadı" olur; farklar günlüğe
    /// yazılır. `--delete` seçili değilken hedefteki fazla dosya fark sayılmaz, seçiliyken sayılır.
    @Test func differencesFailTheJob() async throws {
        let workspace = try Workspace()
        try workspace.write("Kaynak/a.txt", "yeni içerik, daha uzun\n")
        try workspace.write("Kaynak/b.txt", "b\n")
        try workspace.write("Hedef/Kaynak/a.txt", "eski\n")
        try workspace.write("Hedef/Kaynak/fazla.txt", "fazla\n")
        let engine = RsyncEngine()
        let context = try await engineContext()
        for (deleting, expected) in [(false, 2), (true, 3)] {
            let job = TransferJob(source: workspace.url("Kaynak"), destination: workspace.url("Hedef"),
                                  options: CopyOptions(deleteExtraneous: deleting, verifyAfterCopy: .quick))
            let events = Collected<TransferEvent>()
            let result = await engine.verifyAfterCopy(job, context: context, copyResult: JobResult(kind: .succeeded, exitCode: 0)) { events.add($0) }
            #expect(result.kind == .verificationFailed)
            #expect(result.differenceCount == expected)
            #expect(result.exitCode == 0)
            let raw = events.values.flatMap { event -> [String] in
                if case .logBatch(let entries) = event { return entries.compactMap(\.raw) }
                return []
            }
            #expect(raw.contains { $0.hasSuffix("Kaynak/a.txt") } && raw.contains { $0.hasSuffix("Kaynak/b.txt") })
            #expect(raw.contains { $0.hasSuffix("Kaynak/fazla.txt") } == deleting)
        }
        // Hiçbir şey yazılmadı.
        #expect(workspace.read("Hedef/Kaynak/a.txt") == "eski\n")
        #expect(workspace.exists("Hedef/Kaynak/fazla.txt"))
    }
}
