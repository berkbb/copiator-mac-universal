// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Copiator
@testable import CopiatorCore

/// Ana Ekran satırı, rutinlerin sıralanması ve birden çok dosyadan içe aktarma.
@Suite(.enabled(if: rsyncURL != nil, "Vendor/rsync/rsync yok"), .serialized)
@MainActor
struct HomeAndRoutineLibraryTests {
    private func routine(_ name: String, _ fixture: Fixture) -> Routine {
        Routine(name: name, routes: [RoutineRoute(source: fixture.url("Kaynak"), destination: fixture.url("Hedef"))])
    }

    /// Uygulama Ana Ekran ile açılır; iş eklenince liste görünür, ama Ana Ekran iş varken de her zaman seçilebilir.
    @Test func homeIsAlwaysAvailable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var model = fixture.model
        #expect(model.sidebarSelection == .home && model.isHomeVisible)

        // Eklenen iş görünsün diye listeye geçilir.
        fixture.addJob()
        #expect(model.sidebarSelection == .filter(.all) && !model.isHomeVisible)
        // İş varken de ana ekran: iş listesi onu engellemez.
        model.sidebarSelection = .home
        #expect(model.isHomeVisible && model.jobs.count == 1)
        // Bir süzgeç seçmek (kenar çubuğundan ya da doğrudan) listeyi gösterir.
        model.filter = .finished
        #expect(model.sidebarSelection == .filter(.finished) && !model.isHomeVisible)

        // Rutin seçiliyken onun ayrıntısı görünür; silinince önceki görünüme dönülür.
        model.sidebarSelection = .home
        let saved = routine("Belgeler", fixture)
        #expect(model.saveRoutine(saved) == nil)
        #expect(model.sidebarSelection == .routine(saved.id) && !model.isHomeVisible)
        model.deleteRoutine(saved.id)
        #expect(model.sidebarSelection == .home && model.isHomeVisible)

        // Kuyrukta iş varken yeniden açılınca da ana ekran hazırdır.
        model = fixture.relaunch()
        #expect(model.jobs.count == 1 && model.sidebarSelection == .home && model.isHomeVisible)
    }
}
