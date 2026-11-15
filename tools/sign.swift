// build/tools/sign <private-key-path> <file>  → prints the base64 Ed25519 signature of <file>
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 3,
      let keyText = try? String(contentsOfFile: args[1], encoding: .utf8),
      let keyData = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData),
      let file = FileManager.default.contents(atPath: args[2]) else {
    FileHandle.standardError.write("uso: sign <clave privada> <archivo>\n".data(using: .utf8)!)
    exit(1)
}
print(try key.signature(for: file).base64EncodedString())
