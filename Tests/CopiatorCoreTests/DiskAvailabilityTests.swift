// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import CopiatorCore

/// Takılı olmayan disk eksik klasörden ayrılır: diski bağlı olmayan yol kayda engel değildir, iş hata vermez, disk takılana
/// kadar bekler; bu Mac'te (ya da takılı bir diskte) olmayan klasör ise eskisi gibi sorundur.
@Test func unmountedVolumesAreToldApartFromMissingFolders() throws {
    let disk = "CopiatorYok-\(UUID().uuidString)"
    #expect(VolumeState.unmountedVolume(of: URL(fileURLWithPath: "/Volumes/\(disk)/Özel/Fatura")) == disk)
    #expect(VolumeState.unmountedVolume(of: URL(fileURLWithPath: "/Volumes/\(disk)")) == disk)
    #expect(VolumeState.unmountedVolume(of: FileManager.default.temporaryDirectory.appendingPathComponent("yok")) == nil)
    #expect(VolumeState.unmountedVolume(of: URL(fileURLWithPath: "/")) == nil)
    #expect(VolumeState.unmountedVolume(of: URL(fileURLWithPath: "/Volumes")) == nil)
    if FileManager.default.fileExists(atPath: "/Volumes/Macintosh HD") {
        #expect(VolumeState.unmountedVolume(of: URL(fileURLWithPath: "/Volumes/Macintosh HD/Users")) == nil, "başlangıç diski bağlıdır")
    }

    let w = try Workspace("CopiatorDisks")
    try w.mkdir("Kaynak")
    let away = URL(fileURLWithPath: "/Volumes/\(disk)/Yedek")
    #expect(JobValidation.check(source: w.url("Kaynak"), destination: away, copyMode: .folder) == .destinationMissing)
    #expect(JobValidation.check(source: w.url("Kaynak"), destination: away, copyMode: .folder, allowUnmounted: true) == nil)
    #expect(JobValidation.check(source: away, destination: w.url("Kaynak"), copyMode: .contents, allowUnmounted: true) == nil)
    #expect(JobValidation.check(source: away, destination: away.appendingPathComponent("Ic"), copyMode: .folder, allowUnmounted: true) == .overlapping)
    #expect(JobValidation.check(source: w.url("Kaynak"), destination: w.url("Yok"), copyMode: .folder, allowUnmounted: true) == .destinationMissing,
            "bu Mac'te olmayan klasör sorun kalır")

    // Kuyruk: diski takılı olmayan iş bekler (seçenek kapalı olsa da), sıradaki iş çalışır; bu Mac'te olmayan klasörlü iş
    // beklemez (çalışıp "hedef bulunamadı" ile biter).
    let waiting = TransferJob(source: w.url("Kaynak"), destination: away, status: .waiting)
    let local = TransferJob(source: w.url("Kaynak"), destination: try w.mkdir("Hedef"), status: .waiting)
    let missing = TransferJob(source: w.url("Kaynak"), destination: w.url("Yok"), status: .waiting)
    #expect(waiting.unmountedVolume == disk && local.unmountedVolume == nil)
    #expect(JobQueue.isWaitingForDisk(waiting) && !JobQueue.isWaitingForDisk(missing) && !JobQueue.isWaitingForDisk(local))
    #expect(JobQueue.next(in: [waiting, local]) == local.id)
    #expect(JobQueue.next(in: [waiting, missing]) == missing.id)

    // Rutin: takılı diskte ya da bu Mac'teki rota denetlenir, takılı olmayan diskteki rota kaydı engellemez.
    let routine = Routine(name: "Faturalar", routes: [RoutineRoute(source: w.url("Kaynak"), destination: w.url("Hedef")),
                                                      RoutineRoute(source: w.url("Kaynak"), destination: away)])
    #expect(routine.problems().contains(.path(route: 1, .destinationMissing)))
    #expect(routine.problems(allowUnmounted: true).isEmpty)
}
