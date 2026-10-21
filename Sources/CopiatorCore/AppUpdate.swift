// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// GitHub Releases'teki bir Copiator sürümü.
public struct AppRelease: Sendable, Equatable {
    public let version: String
    public let pageURL: URL
    /// .dmg varsa onun, yoksa .zip'in doğrudan indirme adresi.
    public let downloadURL: URL?

    public init(version: String, pageURL: URL, downloadURL: URL?) {
        self.version = version
        self.pageURL = pageURL
        self.downloadURL = downloadURL
    }
}

/// Copiator'ın kendi güncellemesini GitHub Releases üzerinden denetler.
/// Uygulama ad-hoc imzalı olduğu için kendini kurmaz; kullanıcıya indirme bağlantısı gösterilir.
public enum AppUpdateChecker {
    public enum CheckError: Error, Equatable, Sendable {
        /// Depo özel ya da henüz sürüm yok (GitHub 404 döndürür).
        case noReleases
        case badResponse(Int)
        case invalidData
    }

    public static func latestReleaseURL(repository: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    /// GitHub API yanıtını okur. Taslak ve ön sürümler yok sayılır.
    public static func parse(_ data: Data) throws -> AppRelease {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let page = (object["html_url"] as? String).flatMap(URL.init(string:)),
              object["draft"] as? Bool != true, object["prerelease"] as? Bool != true else {
            throw CheckError.invalidData
        }
        let assets = (object["assets"] as? [[String: Any]]) ?? []
        func asset(withSuffix suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(suffix) == true }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        return AppRelease(
            version: normalizedVersion(tag),
            pageURL: page,
            downloadURL: asset(withSuffix: ".dmg") ?? asset(withSuffix: ".zip")
        )
    }

    /// "v1.2.3" → "1.2.3"
    public static func normalizedVersion(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Sayısal karşılaştırma; eksik bileşenler 0 sayılır ("1.1" == "1.1.0", "1.0.10" > "1.0.9").
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            normalizedVersion(value).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let lhs = parts(candidate), rhs = parts(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// Yalnızca herkese açık sürüm listesi istenir; kullanıcı verisi gönderilmez.
    public static func latest(repository: String, session: URLSession = .shared) async throws -> AppRelease {
        guard let url = latestReleaseURL(repository: repository) else { throw CheckError.invalidData }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw CheckError.noReleases }
        guard (200..<300).contains(status) else { throw CheckError.badResponse(status) }
        return try parse(data)
    }
}

// MARK: - Ed25519 Update Signatures

public enum UpdateSignature {
    public static let publicKeyInfoKey = "CopiatorUpdatePublicEDKey"

    /// The base64 Ed25519 public key that release DMGs must be signed with.
    public static var bundledPublicKey: String? {
        Bundle.main.object(forInfoDictionaryKey: publicKeyInfoKey) as? String
    }

    /// Returns true when `signatureBase64` is a valid Ed25519 signature of the file for `publicKeyBase64`.
    public static func isValid(fileURL: URL, signatureBase64: String, publicKeyBase64: String) throws -> Bool {
        guard
            let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
            let publicKeyData = Data(base64Encoded: publicKeyBase64),
            let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        else {
            return false
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return publicKey.isValidSignature(signature, for: data)
    }
}

// MARK: - SHA-256 Checksums

public enum UpdateChecksums {
    /// Parses `shasum -a 256` output into a file name → lowercase hex digest map.
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let digest = parts[0].lowercased()
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { continue }
            var fileName = parts[1].trimmingCharacters(in: .whitespaces)
            if fileName.hasPrefix("*") {
                fileName.removeFirst()
            }
            result[fileName] = digest
        }
        return result
    }

    /// Streams the file through SHA-256 and returns the lowercase hex digest.
    public static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

