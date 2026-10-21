// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Testing
@testable import CopiatorCore

private func releaseJSON(tag: String, draft: Bool = false, prerelease: Bool = false, assets: [String]) -> Data {
    let assetObjects = assets.map {
        ["name": $0, "browser_download_url": "https://github.com/berkbb/copiator-mac-universal/releases/download/\(tag)/\($0)"]
    }
    let object: [String: Any] = [
        "tag_name": tag, "html_url": "https://github.com/berkbb/copiator-mac-universal/releases/tag/\(tag)",
        "draft": draft, "prerelease": prerelease, "assets": assetObjects,
    ]
    return try! JSONSerialization.data(withJSONObject: object)
}

@Test func parsesLatestRelease() throws {
    let release = try AppUpdateChecker.parse(releaseJSON(tag: "v1.2.0", assets: ["Copiator-1.2.0.zip", "Copiator-1.2.0.dmg", "Copiator-1.2.0.sha256"]))
    #expect(release.version == "1.2.0")
    #expect(release.pageURL.absoluteString.hasSuffix("/releases/tag/v1.2.0"))
    // .dmg tercih edilir.
    #expect(release.downloadURL?.lastPathComponent == "Copiator-1.2.0.dmg")

    let zipOnly = try AppUpdateChecker.parse(releaseJSON(tag: "1.3.0", assets: ["Copiator-1.3.0.zip"]))
    #expect(zipOnly.downloadURL?.lastPathComponent == "Copiator-1.3.0.zip")
    #expect(try AppUpdateChecker.parse(releaseJSON(tag: "v2.0.0", assets: [])).downloadURL == nil)
}

@Test func ignoresDraftsPrereleasesAndGarbage() {
    #expect(throws: AppUpdateChecker.CheckError.invalidData) {
        try AppUpdateChecker.parse(releaseJSON(tag: "v9.0.0", draft: true, assets: []))
    }
    #expect(throws: AppUpdateChecker.CheckError.invalidData) {
        try AppUpdateChecker.parse(releaseJSON(tag: "v9.0.0-beta", prerelease: true, assets: []))
    }
    #expect(throws: AppUpdateChecker.CheckError.invalidData) {
        try AppUpdateChecker.parse(Data("{\"message\":\"Not Found\"}".utf8))
    }
}

@Test func comparesAppVersions() {
    #expect(AppUpdateChecker.isNewer("1.0.1", than: "1.0.0"))
    #expect(AppUpdateChecker.isNewer("v1.0.10", than: "1.0.9"))
    #expect(AppUpdateChecker.isNewer("2.0", than: "1.9.9"))
    #expect(!AppUpdateChecker.isNewer("1.1", than: "1.1.0"))
    #expect(!AppUpdateChecker.isNewer("1.0.0", than: "1.0.1"))
    #expect(AppUpdateChecker.normalizedVersion("v1.2.3") == "1.2.3")
    #expect(AppUpdateChecker.latestReleaseURL(repository: "berkbb/copiator-mac-universal")?.absoluteString
        == "https://api.github.com/repos/berkbb/copiator-mac-universal/releases/latest")
}

@Test func updateChecksumsParsingAndCalculation() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("copiator-test-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try "hello copiator".data(using: .utf8)!.write(to: tmp)

    let hex = try UpdateChecksums.sha256(of: tmp)
    #expect(!hex.isEmpty)
    #expect(hex.count == 64)

    let checksumsText = """
    \(hex)  Copiator-1.2.0.dmg
    e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 *Copiator-1.2.0.zip
    """
    let map = UpdateChecksums.parse(checksumsText)
    #expect(map["Copiator-1.2.0.dmg"] == hex)
    #expect(map["Copiator-1.2.0.zip"] == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

@Test func updateSignatureVerification() throws {
    let key = Curve25519.Signing.PrivateKey()
    let pubKey = key.publicKey.rawRepresentation.base64EncodedString()

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("copiator-test-dmg-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let data = Data(repeating: 0x42, count: 1024)
    try data.write(to: tmp)

    let sig = try key.signature(for: data).base64EncodedString()
    #expect(try UpdateSignature.isValid(fileURL: tmp, signatureBase64: sig, publicKeyBase64: pubKey))

    // Corrupted signature or payload
    let badSig = sig.reversed().map(String.init).joined()
    #expect(try !UpdateSignature.isValid(fileURL: tmp, signatureBase64: badSig, publicKeyBase64: pubKey))

    let otherKey = Curve25519.Signing.PrivateKey()
    let otherPub = otherKey.publicKey.rawRepresentation.base64EncodedString()
    #expect(try !UpdateSignature.isValid(fileURL: tmp, signatureBase64: sig, publicKeyBase64: otherPub))
}

@Test func embeddedUpdatePublicKeyIsValid() throws {
    let infoPlistURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Support/Info.plist")
    let data = try Data(contentsOf: infoPlistURL)
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    let base64Key = plist?["CopiatorUpdatePublicEDKey"] as? String
    let unwrappedKey = try #require(base64Key)
    let keyData = try #require(Data(base64Encoded: unwrappedKey))
    #expect(keyData.count == 32)
    _ = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
}


