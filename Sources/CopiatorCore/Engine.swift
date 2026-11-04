// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Bir motor ikilisinin `--version` çıktısından okunan bilgi.
public struct EngineInfo: Sendable, Equatable {
    /// "3.5.1"; openrsync için uyumlu olduğu rsync sürümü ("2.6.9").
    public let version: String
    /// macOS'un /usr/bin/rsync'i (openrsync): `--info=progress2`, `-X` kısa bayrağı ve ACL desteği yoktur.
    public let isOpenrsync: Bool
    public let supportsACLs: Bool
    public let supportsXattrs: Bool

    public init(version: String, isOpenrsync: Bool, supportsACLs: Bool, supportsXattrs: Bool) {
        self.version = version
        self.isOpenrsync = isOpenrsync
        self.supportsACLs = supportsACLs
        self.supportsXattrs = supportsXattrs
    }

    /// `--info=progress2` rsync 3.1.0 ile geldi; yoksa ilerleme kısıtlı kipte (belirsiz) gösterilir.
    public var supportsProgress2: Bool {
        !isOpenrsync && !EngineLocator.isNewer("3.1.0", than: version)
    }
}

/// rsync programını bulur, sürümünü okur ve kullanılacak kopyayı seçer.
public enum EngineLocator {
    public static let executableName = "rsync"
    public static let homebrewPaths = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync"]
    /// macOS'un kendi rsync'i (openrsync, "2.6.9 uyumlu"); yalnızca başka hiçbir kopya yoksa kullanılır.
    public static let systemPath = "/usr/bin/rsync"

    /// Uygulama paketi yazılamadığında güncelleyicinin rsync'i kurduğu yedek klasör.
    public static var managedEngineDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Copiator/engine", isDirectory: true)
    }

    /// Sıra: kullanıcının seçtiği → uygulamayla gelen → yedek klasör → Homebrew → sistem. Seçim sürüme göre yapılır
    /// (`choose`); sıra yalnızca eşit sürümlerde öncelik belirler.
    public static func candidates(customPath: String?, managedDirectory: URL = managedEngineDirectory, bundle: Bundle = .main) -> [URL] {
        var result: [URL] = []
        if let customPath, !customPath.isEmpty { result.append(URL(fileURLWithPath: customPath)) }
        if let bundled = bundle.url(forAuxiliaryExecutable: executableName) { result.append(bundled) }
        result.append(managedDirectory.appendingPathComponent(executableName))
        result += homebrewPaths.map { URL(fileURLWithPath: $0) }
        result.append(URL(fileURLWithPath: systemPath))
        // Aynı dosyayı gösteren adaylar (ör. /usr/local/bin bağlantısı) bir kez sınansın.
        var seen = Set<String>()
        return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Kullanılacak motor. Kullanıcının seçtiği, çalışıyorsa her zaman kazanır. Aksi hâlde tam özellikli (openrsync
    /// olmayan) kopyaların en yenisi seçilir; eşitlikte listedeki ilk aday (paketteki) kazanır. Sistem rsync'i yalnızca
    /// başka bir kopya yoksa seçilir.
    public static func choose(_ probed: [(url: URL, info: EngineInfo?)], customPath: String? = nil) -> (url: URL, info: EngineInfo)? {
        if let customPath, !customPath.isEmpty,
           let custom = probed.first(where: { $0.url.path == customPath }), let info = custom.info {
            return (custom.url, info)
        }
        var best: (url: URL, info: EngineInfo)?
        for candidate in probed {
            guard let info = candidate.info else { continue }
            guard let current = best else { best = (candidate.url, info); continue }
            if current.info.isOpenrsync != info.isOpenrsync {
                if current.info.isOpenrsync { best = (candidate.url, info) }
            } else if isNewer(info.version, than: current.info.version) {
                best = (candidate.url, info)
            }
        }
        return best
    }

    /// "rsync  version 3.5.1  protocol version 33" ya da openrsync'in
    /// "openrsync: protocol version 29\nrsync version 2.6.9 compatible" çıktısını okur.
    public static func parse(_ output: String) -> EngineInfo? {
        let isOpenrsync = output.contains("openrsync")
        var version: String?
        for line in output.split(whereSeparator: \.isNewline) where line.lowercased().contains("rsync") {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            if let index = tokens.firstIndex(of: "version"), index + 1 < tokens.count,
               tokens[..<index].contains(where: { $0.lowercased().hasSuffix("rsync") }),
               let parsed = versionToken(tokens[index + 1]) {
                version = parsed
                break
            }
        }
        guard let version else { return nil }
        // "Capabilities:" bölümü: "..., ACLs, xattrs, ..." ya da "no ACLs", "no xattrs".
        let capabilities = output.components(separatedBy: "Capabilities:").dropFirst().first?
            .components(separatedBy: "Optimizations:").first ?? ""
        let items = capabilities.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return EngineInfo(
            version: version,
            isOpenrsync: isOpenrsync,
            supportsACLs: !isOpenrsync && items.contains("ACLs"),
            supportsXattrs: !isOpenrsync && items.contains("xattrs")
        )
    }

    /// "3.5.1", "3.5.1pre1", "3.2.7-g1234" → sayısal kısım ("3.5.1", "3.5.1", "3.2.7"). En az iki bileşen gerekir.
    static func versionToken(_ token: Substring) -> String? {
        let numeric = token.prefix { $0.isNumber || $0 == "." }
        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && $0.count <= 6 }) else {
            return nil
        }
        return String(numeric)
    }

    /// "3.5.1" ile "3.10.0" gibi sürümleri sayısal olarak karşılaştırır; eksik bileşenler 0 sayılır.
    public static func isNewer(_ candidate: String, than current: String?) -> Bool {
        guard let current else { return true }
        func parts(_ value: String) -> [Int] { value.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let lhs = parts(candidate), rhs = parts(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// Adayı çalıştırıp sürüm bilgisini okur (çalışmıyorsa nil). rsync `--version` ile 0 koduyla çıkar.
    public static func probe(_ url: URL, timeout: TimeInterval = 10) async -> EngineInfo? {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        guard let result = try? await CommandRunner(executableURL: url).run(["--version"], timeout: timeout) else { return nil }
        return parse(result.stdout + "\n" + result.stderr)
    }
}

/// update-rsync.sh betiğinin KEY=value çıktısı.
public struct EngineUpdateResult: Sendable, Equatable {
    public enum Status: String, Sendable {
        case upToDate = "up-to-date"
        case updateAvailable = "update-available"
        case installed
        case error
    }

    public var status: Status
    public var latestVersion: String?
    public var currentVersion: String?
    public var installedPath: String?
    public var sourceURL: URL?
    public var errorMessage: String?

    public static func parse(_ output: String) -> EngineUpdateResult? {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        guard let rawStatus = values["STATUS"], let status = Status(rawValue: rawStatus) else { return nil }
        let current = values["CURRENT"].flatMap { $0 == "none" || $0.isEmpty ? nil : $0 }
        return EngineUpdateResult(
            status: status,
            latestVersion: values["LATEST"],
            currentVersion: current,
            installedPath: values["INSTALLED"],
            sourceURL: values["SOURCE"].flatMap(URL.init(string:)),
            errorMessage: values["ERROR"]
        )
    }
}

/// Güncelleme betiğini çalıştırır; arayüz ile komut satırı aynı mantığı kullanır.
public struct EngineUpdater: Sendable {
    public let scriptURL: URL
    /// Boşsa betik hedefi kendisi seçer: uygulamanın içindeyse o uygulamanın rsync'i güncellenir.
    public let targets: [String]
    /// Uygulamanın kullandığı rsync'in sürümü. Betik yazılamayan bir paketten yedek klasöre geçtiğinde
    /// (henüz orada rsync yokken) kurulu sürümü "yok" sanıp sahte güncelleme bildirmesin.
    public let currentVersion: String?

    public init(scriptURL: URL, targets: [String] = [], currentVersion: String? = nil) {
        self.scriptURL = scriptURL
        self.targets = targets
        self.currentVersion = currentVersion
    }

    public func arguments(command: String) -> [String] {
        [scriptURL.path, command] + targets + (currentVersion.map { ["--current", $0] } ?? [])
    }

    public func check() async throws -> EngineUpdateResult {
        try await run(command: "check", timeout: 60)
    }

    /// Kurulum kaynaktan derler (rsync yalnızca kaynak kodu yayımlar); birkaç dakika sürebilir.
    public func install() async throws -> EngineUpdateResult {
        try await run(command: "install", timeout: 1800)
    }

    private func run(command: String, timeout: TimeInterval) async throws -> EngineUpdateResult {
        let runner = CommandRunner(executableURL: URL(fileURLWithPath: "/bin/bash"))
        let result = try await runner.run(arguments(command: command), timeout: timeout)
        guard let parsed = EngineUpdateResult.parse(result.stdout) else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineError.failed(code: result.exitCode, message: message)
        }
        if parsed.status == .error {
            throw EngineError.failed(code: result.exitCode, message: parsed.errorMessage ?? "")
        }
        return parsed
    }
}
