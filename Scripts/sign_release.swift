import CryptoKit
import Darwin
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 2 || arguments.count == 4,
      let command = arguments.first else {
    print("Usage: swift Scripts/sign_release.swift generate KEY_FILE")
    print("       swift Scripts/sign_release.swift sign KEY_FILE ARCHIVE SIGNATURE")
    exit(2)
}

let keyFile = URL(filePath: arguments[arguments.startIndex + 1])
switch command {
case "generate" where arguments.count == 2:
    let key = Curve25519.Signing.PrivateKey()
    umask(0o077)
    try key.rawRepresentation.write(to: keyFile, options: .withoutOverwriting)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign" where arguments.count == 4:
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyFile))
    let archive = URL(filePath: arguments[arguments.startIndex + 2])
    let signature = URL(filePath: arguments[arguments.startIndex + 3])
    let digest = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe))
    try key.signature(for: Data(digest)).write(to: signature, options: .withoutOverwriting)
default:
    print("Invalid signing command.")
    exit(2)
}
