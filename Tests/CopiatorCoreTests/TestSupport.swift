// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import CopiatorCore

/// Paket kökü (Tests/CopiatorCoreTests/… → kök).
let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Gerçek rsync: projedeki Vendor/rsync/rsync (yoksa COPIATOR_RSYNC).
let vendoredRsync: URL? = {
    let candidates = [
        ProcessInfo.processInfo.environment["COPIATOR_RSYNC"],
        packageRoot.appendingPathComponent("Vendor/rsync/rsync").path,
    ].compactMap { $0 }
    return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

/// 3.5.1 gibi tam özellikli bir rsync'in yetenekleri (argüman testleri için; çalıştırılmaz).
let fullEngine = EngineInfo(version: "3.5.1", isOpenrsync: false, supportsACLs: true, supportsXattrs: true)
/// macOS'un /usr/bin/rsync'i (openrsync).
let openrsyncEngine = EngineInfo(version: "2.6.9", isOpenrsync: true, supportsACLs: false, supportsXattrs: false)

/// Her test için ayrı, sonunda silinen geçici klasör (realpath'li: /private/var/...).
final class Workspace {
    let root: URL

    init(_ name: String = "CopiatorTest") throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = SandboxProfile.resolved(base)
    }

    deinit {
        // Salt okunur bırakılmış klasörler de silinebilsin.
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let path as String in enumerator { chmod(root.appendingPathComponent(path).path, 0o755) }
        }
        chmod(root.path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    @discardableResult
    func write(_ path: String, _ text: String) throws -> URL {
        let url = url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @discardableResult
    func mkdir(_ path: String) throws -> URL {
        let url = url(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func read(_ path: String) -> String? {
        (try? Data(contentsOf: url(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(url(path).path, &info) == 0
    }
}

/// Eşzamanlı kapanışlardan toplanan değerler.
final class Collected<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func add(_ value: T) { lock.withLock { storage.append(value) } }
    var values: [T] { lock.withLock { storage } }
}

func engineContext(sandboxed: Bool = true, home: URL? = nil) async throws -> EngineContext {
    guard let url = vendoredRsync, let info = await EngineLocator.probe(url) else { throw EngineError.engineNotFound }
    return EngineContext(executable: url, info: info, sandboxed: sandboxed, home: home ?? FileManager.default.homeDirectoryForCurrentUser)
}
