// Ed25519 signing for update archives.
//   swift Scripts/sign-update.swift generate      — create the key (once) and print the public key
//   swift Scripts/sign-update.swift sign <file>   — print the base64 signature of <file>
// The private key lives outside the repo and must never be committed.
import CryptoKit
import Foundation

let keyURL = URL(fileURLWithPath: NSString(string: "~/.config/imessage-checker/update_signing_key").expandingTildeInPath)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyURL, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("No signing key at \(keyURL.path). Run: swift Scripts/sign-update.swift generate") }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    if FileManager.default.fileExists(atPath: keyURL.path) {
        print(loadKey().publicKey.rawRepresentation.base64EncodedString())
    } else {
        let key = Curve25519.Signing.PrivateKey()
        try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.rawRepresentation.base64EncodedString().write(to: keyURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        print(key.publicKey.rawRepresentation.base64EncodedString())
    }
case "sign":
    guard let path = args.dropFirst().first, let data = FileManager.default.contents(atPath: path) else { fail("Usage: sign <file>") }
    print(try loadKey().signature(for: data).base64EncodedString())
default:
    fail("Usage: sign-update.swift generate | sign <file>")
}
