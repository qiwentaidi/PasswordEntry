import Foundation
import CryptoKit
import Security

public struct ShareEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let algorithm: String
    public let iv: String
    public let ciphertext: String

    public init(schemaVersion: Int = 1, algorithm: String = "A256GCM", iv: String, ciphertext: String) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.iv = iv
        self.ciphertext = ciphertext
    }
}

public struct ShareMaterial: Sendable {
    public let shareID: String
    public let viewSecret: String
    public let revokeSecret: String
    public let revokeTokenHash: String
    public let envelope: ShareEnvelope

    public init(shareID: String, viewSecret: String, revokeSecret: String, revokeTokenHash: String, envelope: ShareEnvelope) {
        self.shareID = shareID
        self.viewSecret = viewSecret
        self.revokeSecret = revokeSecret
        self.revokeTokenHash = revokeTokenHash
        self.envelope = envelope
    }
}

private struct SharedLoginPayload: Codable {
    let schemaVersion: Int
    let kind: String
    let name: String
    let domains: [String]
    let username: String
    let password: String
    let totp: TotpConfig?
}

public enum ShareCrypto {
    public static func prepare(entry: LoginEntry, includeTotp: Bool) throws -> ShareMaterial {
        let shareID = try randomString(byteCount: 16)
        let viewSecret = try randomString(byteCount: 32)
        let revokeSecret = try randomString(byteCount: 32)
        let payload = SharedLoginPayload(
            schemaVersion: 1,
            kind: "login",
            name: entry.name,
            domains: entry.domains,
            username: entry.username,
            password: entry.password,
            totp: includeTotp ? entry.totp : nil
        )
        let clear = try JSONEncoder().encode(payload)
        let key = try decodeBase64URL(viewSecret)
        let iv = try randomBytes(count: 12)
        let aad = Data("password-entry-share:v1:\(shareID)".utf8)
        let sealed = try AES.GCM.seal(clear, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: iv), authenticating: aad)
        let ciphertext = sealed.ciphertext + sealed.tag
        return ShareMaterial(
            shareID: shareID,
            viewSecret: viewSecret,
            revokeSecret: revokeSecret,
            revokeTokenHash: sha256Hex(Data(revokeSecret.utf8)),
            envelope: ShareEnvelope(iv: encodeBase64URL(iv), ciphertext: encodeBase64URL(ciphertext))
        )
    }

    public static func decodeBase64URL(_ value: String) throws -> Data {
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { throw VaultError.invalidFile }
        return data
    }

    public static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(count: Int) throws -> Data {
        var data = Data(repeating: 0, count: count)
        let result = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard result == errSecSuccess else { throw VaultError.authenticationFailed("无法生成安全随机数") }
        return data
    }

    private static func randomString(byteCount: Int) throws -> String {
        var data = Data(repeating: 0, count: byteCount)
        let result = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard result == errSecSuccess else { throw VaultError.authenticationFailed("无法生成安全随机数") }
        return encodeBase64URL(data)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
