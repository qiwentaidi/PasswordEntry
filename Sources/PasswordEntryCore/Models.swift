import Foundation

public struct TotpConfig: Codable, Equatable, Sendable {
    public var secret: String
    public var issuer: String
    public var algorithm: String
    public var digits: Int
    public var period: Int

    public init(secret: String, issuer: String = "", algorithm: String = "SHA1", digits: Int = 6, period: Int = 30) {
        self.secret = secret.replacingOccurrences(of: " ", with: "").uppercased()
        self.issuer = issuer
        self.algorithm = algorithm.uppercased()
        self.digits = digits
        self.period = period
    }

    public init(otpauthURI: String) throws {
        guard let components = URLComponents(string: otpauthURI), components.scheme == "otpauth", components.host == "totp" else { throw VaultError.invalidTotp }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in item.value.map { (item.name.lowercased(), $0) } })
        guard let secret = values["secret"], !secret.isEmpty else { throw VaultError.invalidTotp }
        self.init(secret: secret, issuer: values["issuer"] ?? "", algorithm: values["algorithm"] ?? "SHA1", digits: Int(values["digits"] ?? "6") ?? 6, period: Int(values["period"] ?? "30") ?? 30)
    }

    public func validated() throws -> TotpConfig {
        guard !secret.isEmpty,
              ["SHA1", "SHA256", "SHA512"].contains(algorithm.uppercased()),
              [6, 8].contains(digits),
              (1...86400).contains(period) else { throw VaultError.invalidTotp }
        _ = try TOTP.decode(secret)
        return self
    }
}

public struct LoginEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var domains: [String]
    public var username: String
    public var password: String
    public var totp: TotpConfig?
    public var faviconData: Data?
    public var faviconMimeType: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, domains: [String], username: String, password: String, totp: TotpConfig? = nil, faviconData: Data? = nil, faviconMimeType: String? = nil, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.domains = domains.compactMap(Self.normalizeDomain)
        self.username = username
        self.password = password
        self.totp = totp
        self.faviconData = faviconData
        self.faviconMimeType = faviconMimeType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func normalizeDomain(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        if let components = URLComponents(string: candidate), let host = components.host?.lowercased(), !host.isEmpty {
            return host.hasSuffix(".") ? String(host.dropLast()) : host
        }
        let host = trimmed.lowercased().split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        return host.isEmpty ? nil : host
    }
}

public struct ShareRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let serverShareID: String
    public let entryID: UUID
    public let viewSecret: String
    public let revokeSecret: String
    public let createdAt: Date
    public let expiresAt: Date
    public var revokedAt: Date?

    public init(id: UUID = UUID(), serverShareID: String, entryID: UUID, viewSecret: String, revokeSecret: String, createdAt: Date = .now, expiresAt: Date, revokedAt: Date? = nil) {
        self.id = id
        self.serverShareID = serverShareID
        self.entryID = entryID
        self.viewSecret = viewSecret
        self.revokeSecret = revokeSecret
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }

    public var isRevoked: Bool { revokedAt != nil }
    public var isExpired: Bool { expiresAt <= .now }

    public func shareURL(baseURL: URL) -> URL? {
        let root = baseURL
            .appendingPathComponent("s", isDirectory: true)
            .appendingPathComponent(serverShareID, isDirectory: false)
        guard var components = URLComponents(url: root, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = viewSecret
        return components.url
    }
}

public struct Vault: Codable, Equatable, Sendable {
    public var version: Int
    public var entries: [LoginEntry]
    public var shares: [ShareRecord]

    public init(version: Int = 1, entries: [LoginEntry] = [], shares: [ShareRecord] = []) {
        self.version = version
        self.entries = entries
        self.shares = shares
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case entries
        case shares
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        entries = try container.decode([LoginEntry].self, forKey: .entries)
        shares = try container.decodeIfPresent([ShareRecord].self, forKey: .shares) ?? []
    }
}

public struct MatchedEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let username: String
    public let hasTotp: Bool
    public let domains: [String]
    public let faviconData: Data?
    public let faviconMimeType: String?

    public init(entry: LoginEntry) {
        id = entry.id
        name = entry.name
        username = entry.username
        hasTotp = entry.totp != nil
        domains = entry.domains
        faviconData = entry.faviconData
        faviconMimeType = entry.faviconMimeType
    }
}
