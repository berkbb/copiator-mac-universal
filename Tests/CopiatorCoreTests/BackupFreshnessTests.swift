// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// Eski yedekler: son başarılı yedeği eşikten eski işler ve rutinler (hiç yedeği olmayanlar kuruluşlarından eşik kadar
/// sonra); "disk takılınca başla" seçili olanlar, bekleyen ya da çalışanlar ve başka diskteki hedefler sayılmaz.
@Test func staleBackupsAreFoundWithoutRunningAnything() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400
    func job(_ name: String, _ destination: String, success: Double?, failure: Double? = nil, created: Double = 400,
             status: JobStatus = .finished, onConnect: Bool = false) -> TransferJob {
        var job = TransferJob(source: URL(fileURLWithPath: "/Users/x/" + name), destination: URL(fileURLWithPath: destination),
                              options: CopyOptions(runWhenConnected: onConnect), status: status, createdAt: now - created * day)
        if let success {
            job.history.append(JobRun(startedAt: now - success * day - 60, finishedAt: now - success * day, result: JobResult(kind: .succeeded)))
        }
        if let failure {
            job.history.append(JobRun(startedAt: now - failure * day - 60, finishedAt: now - failure * day, result: JobResult(kind: .failed)))
        }
        return job
    }
    var routineJob = job("Belgeler", "/Volumes/Arsiv/R", success: 35)
    let routine = Routine(name: "Belgeler rutini", routes: [RoutineRoute(source: URL(fileURLWithPath: "/Users/x/Belgeler"),
                                                                         destination: URL(fileURLWithPath: "/Volumes/Arsiv/R"))])
    routineJob.routineID = routine.id
    routineJob.routeID = routine.routes[0].id
    let jobs = [
        job("Fotograflar", "/Volumes/Arsiv/A", success: 40),
        job("Muzik", "/Volumes/Arsiv/B", success: 10),
        job("Yeni", "/Volumes/Arsiv/C", success: nil, created: 50),
        job("Cokyeni", "/Volumes/Arsiv/D", success: nil, created: 2),
        job("Kendiliginden", "/Volumes/Arsiv/E", success: 100, onConnect: true),
        job("Bekleyen", "/Volumes/Arsiv/F", success: 100, status: .waiting),
        job("Baska", "/Volumes/Diger/G", success: 100),
        job("Hatali", "/Volumes/Arsiv/H", success: 45, failure: 1),
        routineJob,
    ]
    let onArchive = { (url: URL) in url.path.hasPrefix("/Volumes/Arsiv/") }
    let stale = BackupFreshness.stale(jobs: jobs, routines: [routine], onDestination: onArchive, now: now, thresholdDays: 30)
    #expect(stale.map(\.name) == ["Yeni", "Hatali", "Fotograflar", "Belgeler rutini"])
    #expect(stale.map(\.days) == [nil, 45, 40, 35])
    #expect(BackupFreshness.stale(jobs: jobs, routines: [routine], onDestination: onArchive, now: now, thresholdDays: 0).isEmpty)
    #expect(BackupFreshness.stale(jobs: jobs, routines: [routine], onDestination: onArchive, now: now, thresholdDays: 60).map(\.name) == [])
    #expect(BackupFreshness.lastSuccess([jobs[0], jobs[1]]) == now - 10 * day)
}
