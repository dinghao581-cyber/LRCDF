// Signs (or checks) the update manifest with the project's Ed25519 key. Run with: swift packaging/sign_manifest.swift …
//   keygen <private key file>              makes the key once (file mode 600) and prints the public key (base64)
//   public <private key file>              prints the public key
//   sign <private key file> <manifest>     writes <manifest>.sig (base64 signature of the manifest's bytes)
//   verify <public key base64> <manifest>  exit 0 when <manifest>.sig is valid
// The private key never leaves the publisher's Mac and is not in the repository; the public key is built into the apps.
import CryptoKit
import Foundation

let a = CommandLine.arguments
func fail(_ text: String) -> Never { FileHandle.standardError.write((text + "\n").data(using: .utf8)!); exit(1) }
guard a.count >= 3 else { fail("usage: keygen|public <key file> | sign <key file> <manifest> | verify <public key> <manifest>") }
func key(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8), let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("cannot read the key \(path)") }
    return k
}
switch a[1] {
case "keygen":
    guard !FileManager.default.fileExists(atPath: a[2]) else { fail("\(a[2]) exists: a key is made once") }
    let k = Curve25519.Signing.PrivateKey()
    try! FileManager.default.createDirectory(atPath: (a[2] as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: a[2], contents: k.rawRepresentation.base64EncodedString().data(using: .utf8), attributes: [.posixPermissions: 0o600])
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(key(a[2]).publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard a.count >= 4, let data = FileManager.default.contents(atPath: a[3]) else { fail("cannot read the manifest") }
    let sig = try! key(a[2]).signature(for: data)
    try! sig.base64EncodedString().write(toFile: a[3] + ".sig", atomically: true, encoding: .utf8)
case "verify":
    guard a.count >= 4, let data = FileManager.default.contents(atPath: a[3]), let raw = Data(base64Encoded: a[2]),
          let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
          let text = try? String(contentsOfFile: a[3] + ".sig", encoding: .utf8), let sig = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("cannot read") }
    exit(pub.isValidSignature(sig, for: data) ? 0 : 2)
default: fail("unknown command")
}
