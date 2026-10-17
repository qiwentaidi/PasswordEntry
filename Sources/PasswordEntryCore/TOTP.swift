import Foundation
import CryptoKit

public enum TOTP {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func generate(_ config: TotpConfig, date: Date = .now) throws -> String {
        let validated = try config.validated()
        let secret = try decodeBase32(validated.secret)
        let period = max(validated.period, 1)
        let counter = UInt64(date.timeIntervalSince1970 / Double(period))
        var message = Data(repeating: 0, count: 8)
        for index in 0..<8 { message[7 - index] = UInt8((counter >> UInt64(index * 8)) & 0xff) }
        let digest: Data
        let key = SymmetricKey(data: secret)
        switch validated.algorithm.uppercased() {
        case "SHA256": digest = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case "SHA512": digest = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        default: digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        }
        let offset = Int(digest[digest.index(before: digest.endIndex)] & 0x0f)
        guard offset + 3 < digest.count else { throw VaultError.invalidTotp }
        let binary = (UInt32(digest[offset] & 0x7f) << 24) | (UInt32(digest[offset + 1]) << 16) | (UInt32(digest[offset + 2]) << 8) | UInt32(digest[offset + 3])
        let modulus = UInt32(pow(10.0, Double(validated.digits)))
        return String(format: "%0*u", validated.digits, binary % modulus)
    }

    public static func secondsRemaining(_ config: TotpConfig, date: Date = .now) -> Int {
        let period = max(config.period, 1)
        return period - Int(date.timeIntervalSince1970) % period
    }

    public static func decode(_ value: String) throws -> Data { try decodeBase32(value) }

    private static func decodeBase32(_ value: String) throws -> Data {
        let cleaned = value.replacingOccurrences(of: "=", with: "").replacingOccurrences(of: " ", with: "").uppercased()
        var bits = ""
        for character in cleaned {
            guard let index = alphabet.firstIndex(of: character) else { throw VaultError.invalidTotp }
            bits += String(index, radix: 2).leftPadding(toLength: 5, with: "0")
        }
        var result = Data()
        var position = bits.startIndex
        while bits.distance(from: position, to: bits.endIndex) >= 8 {
            let end = bits.index(position, offsetBy: 8)
            result.append(UInt8(bits[position..<end], radix: 2)!)
            position = end
        }
        return result
    }
}

private extension String {
    func leftPadding(toLength length: Int, with character: Character) -> String {
        guard count < length else { return self }
        return String(repeating: character, count: length - count) + self
    }
}
