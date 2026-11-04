// SPDX-License-Identifier: GPL-3.0-only
// Ed25519 (EdDSA) signing for Copiator update DMGs.
//
// The private key lives in the login keychain; a backup copy is written to a
// gitignored file. The public key is embedded in the app's Info.plist under
// `CopiatorUpdatePublicEDKey`.
//
// Usage (run with `xcrun swift Scripts/update_signing.swift <command>`):
//   generate <backup-file>        Create a key pair, store it, print the public key.
//   import <backup-file>          Store a private key from a backup file.
//   public-key                    Print the public key of the stored private key.
//   sign <file>                   Print the base64 signature of <file>.
//   verify <file> <sig> <pubkey>  Exit 0 if the base64 signature is valid.

import CryptoKit
import Foundation
import Security

let keychainService = "com.babadogantech.copiator.update-signing"
let keychainAccount = "ed25519-private-key"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func keychainQuery() -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
    ]
}

func storedPrivateKey() -> Curve25519.Signing.PrivateKey? {
    var query = keychainQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
        fail("could not read signing key from keychain (\(status))")
    }
    guard let raw = Data(base64Encoded: data), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("signing key in keychain is malformed")
    }
    return key
}

func requirePrivateKey() -> Curve25519.Signing.PrivateKey {
    guard let key = storedPrivateKey() else {
        fail("no signing key in keychain; run `generate` or `import` first")
    }
    return key
}

func store(_ key: Curve25519.Signing.PrivateKey) {
    var item = keychainQuery()
    item[kSecAttrLabel as String] = "Copiator update signing key (Ed25519)"
    item[kSecValueData as String] = Data(key.rawRepresentation.base64EncodedString().utf8)
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else {
        fail("could not store signing key in keychain (\(status))")
    }
}

func writeBackup(_ key: Curve25519.Signing.PrivateKey, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard !FileManager.default.fileExists(atPath: url.path) else {
        fail("backup file already exists: \(path)")
    }
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let created = FileManager.default.createFile(
            atPath: url.path,
            contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
            attributes: [.posixPermissions: 0o600]
        )
        guard created else { fail("could not write backup file: \(path)") }
    } catch {
        fail("could not write backup file: \(error.localizedDescription)")
    }
}

func publicKeyString(_ key: Curve25519.Signing.PrivateKey) -> String {
    key.publicKey.rawRepresentation.base64EncodedString()
}

func readFile(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("could not read \(path)")
    }
    return data
}

var arguments = CommandLine.arguments.dropFirst()
guard let command = arguments.popFirst() else {
    fail("missing command (generate, import, public-key, sign, verify)")
}

switch (command, Array(arguments)) {
case ("generate", let args) where args.count == 1:
    guard storedPrivateKey() == nil else {
        fail("a signing key already exists in the keychain; refusing to overwrite it")
    }
    let key = Curve25519.Signing.PrivateKey()
    writeBackup(key, to: args[0])
    store(key)
    print(publicKeyString(key))

case ("import", let args) where args.count == 1:
    guard storedPrivateKey() == nil else {
        fail("a signing key already exists in the keychain; refusing to overwrite it")
    }
    let text = String(decoding: readFile(args[0]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("backup file does not contain a valid Ed25519 private key")
    }
    store(key)
    print(publicKeyString(key))

case ("public-key", let args) where args.isEmpty:
    print(publicKeyString(requirePrivateKey()))

case ("sign", let args) where args.count == 1:
    let signature = try requirePrivateKey().signature(for: readFile(args[0]))
    print(signature.base64EncodedString())

case ("verify", let args) where args.count == 3:
    guard
        let signature = Data(base64Encoded: args[1]),
        let publicKeyData = Data(base64Encoded: args[2]),
        let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    else {
        fail("malformed signature or public key")
    }
    guard publicKey.isValidSignature(signature, for: readFile(args[0])) else {
        fail("signature is NOT valid for \(args[0])")
    }
    print("signature OK")

default:
    fail("invalid command or arguments; see the header of \(#file) for usage")
}
