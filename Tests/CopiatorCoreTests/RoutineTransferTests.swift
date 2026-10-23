// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CopiatorCore

/// Rutin aktarımı: dışa aktarılan rutinler içe aktarılırken yeni kimlik alır, son çalıştırma silinir, çakışan adlara sıra
/// numarası eklenir, yerleşim ve öğrenilmiş klasörler korunur; bu Mac'te bulunmayan klasörler listelenir ve yeniden eşlenir.
/// Bozuk, daha yeni sürümlü ve çok büyük dosyalar reddedilir.
@Test func routinesExportAndImportWithNewIdentities() throws {
    let w = try Workspace()
    try w.mkdir("Kaynak")
    try w.mkdir("Hedef")
    var routine = Routine(name: "Faturalar", routes: [RoutineRoute(source: w.url("Kaynak"), destination: w.url("Hedef"),
                                                                   placement: RoutePlacement(nameTemplate: "{name}", askFolder: true,
                                                                                             learnedFolders: ["enerjisa.pdf": "Elektrik"]))])
    routine.lastRunAt = Date()
    let remote = Routine(name: "Uzak", routes: [RoutineRoute(source: URL(fileURLWithPath: "/Volumes/YokDisk/A"), destination: w.url("Hedef"))])
    let twin = Routine(name: "Uzak", routes: [])
    let data = try RoutineTransfer.export([routine, remote, twin])

    let read = try RoutineTransfer.read(data, existingNames: ["faturalar"])
    #expect(read.map(\.name) == ["Faturalar (2)", "Uzak", "Uzak (2)"])
    #expect(read[0].id != routine.id && read[0].routes[0].id != routine.routes[0].id && read[0].lastRunAt == nil)
    #expect(read[0].routes[0].placement.learnedFolders == ["enerjisa.pdf": "Elektrik"] && read[0].routes[0].placement.askFolder)
    let missing = RoutineTransfer.missingFolders(in: read)
    #expect(missing.count == 1 && missing[0].isSource && missing[0].url.path == "/Volumes/YokDisk/A" && missing[0].routine == read[1].id)
    var remapped = read
    RoutineTransfer.remap(missing[0], to: w.url("Kaynak"), in: &remapped)
    #expect(RoutineTransfer.missingFolders(in: remapped).isEmpty && remapped[1].routes[0].source == w.url("Kaynak"))

    #expect(throws: RoutineTransfer.Failure.notRoutines) { try RoutineTransfer.read(Data("{}".utf8), existingNames: []) }
    #expect(throws: RoutineTransfer.Failure.notRoutines) { try RoutineTransfer.read(Data("bozuk".utf8), existingNames: []) }
    let newer = Data(#"{"format": "copiator-routines", "version": 2, "exportedAt": "2026-10-23T10:00:00Z", "routines": []}"#.utf8)
    #expect(throws: RoutineTransfer.Failure.newerVersion(2)) { try RoutineTransfer.read(newer, existingNames: []) }
    #expect(throws: RoutineTransfer.Failure.tooLarge) { try RoutineTransfer.read(Data(count: RoutineTransfer.maxSize + 1), existingNames: []) }
}
