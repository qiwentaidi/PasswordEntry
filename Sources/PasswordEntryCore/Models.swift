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
    /// Canonical origins used for autofill matching. Empty for legacy records that only stored hosts.
    public var origins: [String]
    public var username: String
    public var password: String
    public var totp: TotpConfig?
    public var faviconData: Data?
    public var faviconMimeType: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, domains: [String], origins: [String]? = nil, username: String, password: String, totp: TotpConfig? = nil, faviconData: Data? = nil, faviconMimeType: String? = nil, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.domains = domains.compactMap(Self.normalizeDomain)
        self.origins = (origins ?? self.domains.map { "https://\($0):443" }).compactMap(Self.normalizeOrigin)
        self.username = username
        self.password = password
        self.totp = totp
        self.faviconData = faviconData
        self.faviconMimeType = faviconMimeType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, domains, origins, username, password, totp, faviconData, faviconMimeType, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        domains = try container.decode([String].self, forKey: .domains).compactMap(Self.normalizeDomain)
        // Old vaults have no origin list. Keep their host-only behavior until the next save migrates them.
        origins = try container.decodeIfPresent([String].self, forKey: .origins)?.compactMap(Self.normalizeOrigin) ?? []
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        totp = try container.decodeIfPresent(TotpConfig.self, forKey: .totp)
        faviconData = try container.decodeIfPresent(Data.self, forKey: .faviconData)
        faviconMimeType = try container.decodeIfPresent(String.self, forKey: .faviconMimeType)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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

    public static func normalizeOrigin(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        let normalizedHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(normalizedHost):\(port)"
    }
}

public struct ShareRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let serverShareID: String
    public let apiBaseURL: String
    public let entryID: UUID
    public let viewSecret: String
    public let revokeSecret: String
    public let createdAt: Date
    public let expiresAt: Date
    public var revokedAt: Date?

    public init(id: UUID = UUID(), serverShareID: String, apiBaseURL: String = "", entryID: UUID, viewSecret: String, revokeSecret: String, createdAt: Date = .now, expiresAt: Date, revokedAt: Date? = nil) {
        self.id = id
        self.serverShareID = serverShareID
        self.apiBaseURL = apiBaseURL
        self.entryID = entryID
        self.viewSecret = viewSecret
        self.revokeSecret = revokeSecret
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case serverShareID
        case apiBaseURL
        case entryID
        case viewSecret
        case revokeSecret
        case createdAt
        case expiresAt
        case revokedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        serverShareID = try container.decode(String.self, forKey: .serverShareID)
        apiBaseURL = try container.decodeIfPresent(String.self, forKey: .apiBaseURL) ?? ""
        entryID = try container.decode(UUID.self, forKey: .entryID)
        viewSecret = try container.decode(String.self, forKey: .viewSecret)
        revokeSecret = try container.decode(String.self, forKey: .revokeSecret)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        revokedAt = try container.decodeIfPresent(Date.self, forKey: .revokedAt)
    }

    public var isRevoked: Bool { revokedAt != nil }
    public var isExpired: Bool { expiresAt <= .now }

    public func shareURL(baseURL: URL) -> URL? {
        let configuredBase = URL(string: apiBaseURL).flatMap(Self.validBaseURL) ?? baseURL
        let root = configuredBase
            .appendingPathComponent("s", isDirectory: true)
            .appendingPathComponent(serverShareID, isDirectory: false)
        guard var components = URLComponents(url: root, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = viewSecret
        return components.url
    }

    private static func validBaseURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        return url
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
