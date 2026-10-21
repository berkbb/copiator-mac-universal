// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "Copiator",
    platforms: [.macOS(.v26)],
    targets: [
        // rsync komutları, çıktı ayrıştırma, iş kuyruğu mantığı ve yerelleştirme (arayüzden bağımsız, test edilebilir).
        .target(name: "CopiatorCore", linkerSettings: [.linkedFramework("IOKit")]),
        // SwiftUI arayüzü.
        .executableTarget(
            name: "Copiator",
            dependencies: ["CopiatorCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "CopiatorCoreTests", dependencies: ["CopiatorCore"]),
        // Uygulama modeli (AppModel) akışları; gerçek rsync ile çalışır.
        .testTarget(name: "CopiatorAppTests", dependencies: ["Copiator", "CopiatorCore"]),
    ]
)
