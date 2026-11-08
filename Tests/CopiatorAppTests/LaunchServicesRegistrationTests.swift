// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Copiator

/// Yeniden kayıt yalnızca derleme değişince ve yalnızca gerçek Copiator paketinde yapılır.
struct LaunchServicesRegistrationTests {
    @Test func reRegistersOnlyWhenTheBuildChanges() {
        #expect(LaunchServicesRegistration.needsRegistration(lastBuild: nil, currentBuild: "8"))
        #expect(LaunchServicesRegistration.needsRegistration(lastBuild: "7", currentBuild: "8"))
        #expect(LaunchServicesRegistration.needsRegistration(lastBuild: "9", currentBuild: "8"), "geri dönüşte de kayıt yenilenir")
        #expect(!LaunchServicesRegistration.needsRegistration(lastBuild: "8", currentBuild: "8"))
    }

    @Test @MainActor func testBundleIsNeverRegistered() throws {
        let store = try TestDefaults("CopiatorLaunchServices")
        defer { store.remove() }
        // Bundle.main testlerde xctest'tir: kimlik Copiator değil, hiçbir şey kaydedilmez ve derleme yazılmaz.
        LaunchServicesRegistration.registerIfBuildChanged(bundle: .main, defaults: store.defaults)
        #expect(store.defaults.string(forKey: LaunchServicesRegistration.registeredBuildKey) == nil)
    }
}
