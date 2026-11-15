// One-time: swiftc tools/keygen.swift -o build/keygen && build/keygen <private-key-path>
// Writes the Ed25519 private key (base64) to that path and prints the public key to embed in Sources/UpdateKey.swift.
import CryptoKit
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "release-ed25519.key"
guard !FileManager.default.fileExists(atPath: path) else {
    FileHandle.standardError.write("ya existe \(path); no la sobrescribo\n".data(using: .utf8)!)
    exit(1)
}
let key = Curve25519.Signing.PrivateKey()
try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
FileManager.default.createFile(atPath: path, contents: key.rawRepresentation.base64EncodedString().data(using: .utf8),
                               attributes: [.posixPermissions: 0o600])
print(key.publicKey.rawRepresentation.base64EncodedString())
