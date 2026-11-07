// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Arşivde arama uygulamada: kod çalıştırabilen türler açılmaz (Finder'da gösterilir), kopyası seçilen yere yazılır,
/// Çöp'e taşıma onaydan sonra olur ve yalnızca Çöp'e.
@Suite(.serialized)
@MainActor
struct ArchiveSearchAppTests {
    @Test func actionsAreSafe() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        var opened: [URL] = []
        var revealed: [URL] = []
        model.openFile = { opened.append($0) }
        model.revealFile = { revealed.append($0) }
        try fixture.write("Hedef/belge.pdf", "pdf")
        try fixture.write("Hedef/calistir.command", "echo merhaba")

        model.openArchived(fixture.url("Hedef/belge.pdf"))
        #expect(opened == [fixture.url("Hedef/belge.pdf")] && model.alert == nil)
        model.openArchived(fixture.url("Hedef/calistir.command"))
        #expect(opened.count == 1 && revealed == [fixture.url("Hedef/calistir.command")], "çalıştırılabilir tür açılmaz")
        #expect(model.alert?.title == fixture.settings.t(.warningTitle))
        model.alert = nil

        #expect(model.copyArchived(fixture.url("Hedef/belge.pdf"), to: fixture.url("Disari/belge.pdf")) == false, "klasör yok")
        model.alert = nil
        try FileManager.default.createDirectory(at: fixture.url("Disari"), withIntermediateDirectories: true)
        #expect(model.copyArchived(fixture.url("Hedef/belge.pdf"), to: fixture.url("Disari/belge.pdf")))
        #expect(fixture.read("Disari/belge.pdf") == "pdf" && fixture.read("Hedef/belge.pdf") == "pdf")

        var done = 0
        model.requestTrashArchived(fixture.url("Hedef/belge.pdf")) { done += 1 }
        let alert = try #require(model.alert)
        #expect(alert.isDestructive && FileManager.default.fileExists(atPath: fixture.url("Hedef/belge.pdf").path), "onaydan önce dokunulmaz")
        alert.action?()
        #expect(!FileManager.default.fileExists(atPath: fixture.url("Hedef/belge.pdf").path) && done == 1)
        let trashed = (try? FileManager.default.contentsOfDirectory(atPath: fixture.url("Cop").path)) ?? []
        #expect(trashed.contains { $0.hasSuffix("belge.pdf") }, "test Çöp'üne taşındı")
    }
}
