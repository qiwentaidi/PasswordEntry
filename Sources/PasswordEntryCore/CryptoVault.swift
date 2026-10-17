import Foundation
import CryptoKit
import CommonCrypto

public enum VaultError: LocalizedError, Sendable {
    case invalidPassword
    case weakPassword
    case invalidFile
    case keychain(OSStatus)
    case locked
    case noMatch
    case invalidTotp
    case authenticationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPassword: return "主密码错误或保险库已损坏"
        case .weakPassword: return "主密码至少需要 12 个字符"
        case .invalidFile: return "保险库文件格式无效"
        case .keychain(let status): return "无法读取 macOS 钥匙串（\(status)）；旧版本保险库迁移时只需在系统提示中允许一次"
        case .locked: return "桌面端已锁定"
        case .noMatch: return "当前网站没有匹配的登录项"
        case .invalidTotp: return "TOTP 配置无效"
        case .authenticationFailed(let message): return message
        }
    }
}

private struct EncryptedVault: Codable {
    let version: Int
    let salt: String
    let sealed: String
}

public final class VaultStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var key: SymmetricKey?
    private var vault: Vault?
    private var salt = Data()
    private var encryptionVersion = 2
    private let deviceSecretOverride: Data?
    private let iterations: UInt32 = 600_000

    public init(fileURL: URL? = nil, deviceSecretOverride: Data? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Password Entry", isDirectory: true)
        self.fileURL = fileURL ?? support.appendingPathComponent("vault.json")
        self.deviceSecretOverride = deviceSecretOverride
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
    }

    public var hasVault: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
    public var isUnlocked: Bool { lock.withLock { key != nil && vault != nil } }
    public var hasBiometricUnlock: Bool { KeychainStore.hasBiometricVaultKey }

    public func unlock(password: String) throws {
        let record: EncryptedVault? = hasVault ? try loadRecord() : nil
        let salt = record.map { Data(base64Encoded: $0.salt) ?? Data() } ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        if let record {
            let legacySecret: Data?
            if record.version <= 1 { legacySecret = try deviceSecretOverride ?? KeychainStore.deviceSecret() } else { legacySecret = nil }
            let derived = deriveKey(password: password, deviceSecret: legacySecret, salt: salt)
            try activate(derived, record: record, salt: salt)
            let migratedOrigins = migrateOriginsIfNeeded()
            encryptionVersion = record.version
            if record.version <= 1 {
                // Migrate legacy vaults away from the ordinary login-keychain device secret.
                let migrated = deriveKey(password: password, deviceSecret: nil, salt: salt)
                lock.withLock { key = migrated }
                encryptionVersion = 2
                try save()
            } else if migratedOrigins {
                try save()
            }
        } else {
            guard password.count >= 12 else { throw VaultError.weakPassword }
            let derived = deriveKey(password: password, deviceSecret: nil, salt: salt)
            lock.withLock { key = derived; vault = Vault(); self.salt = salt }
            encryptionVersion = 2
            try save()
        }
    }

    public func unlockWithBiometrics() throws {
        guard hasVault else { throw VaultError.invalidFile }
        let record = try loadRecord()
        let data = try KeychainStore.biometricVaultKey(reason: "使用 Touch ID 解锁 Password Entry 保险库")
        guard data.count == 32 else { throw VaultError.invalidFile }
        try activate(SymmetricKey(data: data), record: record, salt: Data(base64Encoded: record.salt) ?? Data())
        encryptionVersion = record.version
        if migrateOriginsIfNeeded() { try save() }
    }

    public func enableBiometricUnlock() throws {
        guard let key else { throw VaultError.locked }
        try KeychainStore.saveBiometricVaultKey(keyData(key))
    }

    public func disableBiometricUnlock() throws {
        try KeychainStore.deleteBiometricVaultKey()
    }

    public func lockVault() {
        lock.withLock { key = nil; vault = nil }
    }

    public func entries() throws -> [LoginEntry] {
        try requireVault().entries
    }

    public func shares() throws -> [ShareRecord] {
        try requireVault().shares
    }

    public func saveEntry(_ entry: LoginEntry) throws {
        var current = try requireVault()
        if let index = current.entries.firstIndex(where: { $0.id == entry.id }) { current.entries[index] = entry } else { current.entries.append(entry) }
        lock.withLock { vault = current }
        try save()
    }

    public func upsertLogin(name: String, domain: String, origin: String? = nil, username: String, password: String, faviconData: Data? = nil, faviconMimeType: String? = nil) throws {
        let normalizedDomain = LoginEntry.normalizeDomain(domain) ?? domain.lowercased()
        let normalizedOrigin = origin.flatMap(LoginEntry.normalizeOrigin) ?? LoginEntry.normalizeOrigin(domain)
        var current = try requireVault()
        if let index = current.entries.firstIndex(where: {
            guard $0.username == username else { return false }
            if let normalizedOrigin, !$0.origins.isEmpty { return $0.origins.contains(normalizedOrigin) }
            return $0.domains.contains(normalizedDomain)
        }) {
            var entry = current.entries[index]
            entry.name = name.isEmpty ? entry.name : name
            entry.password = password
            if let faviconData {
                entry.faviconData = faviconData
                entry.faviconMimeType = faviconMimeType
            }
            if let normalizedOrigin, !entry.origins.contains(normalizedOrigin) { entry.origins.append(normalizedOrigin) }
            entry.updatedAt = .now
            current.entries[index] = entry
        } else {
            current.entries.append(LoginEntry(name: name.isEmpty ? normalizedDomain : name, domains: [normalizedDomain], origins: normalizedOrigin.map { [$0] }, username: username, password: password, faviconData: faviconData, faviconMimeType: faviconMimeType))
        }
        lock.withLock { vault = current }
        try save()
    }

    public func deleteEntry(id: UUID) throws {
        var current = try requireVault()
        current.entries.removeAll { $0.id == id }
        current.shares.removeAll { $0.entryID == id }
        lock.withLock { vault = current }
        try save()
    }

    public func saveShare(_ share: ShareRecord) throws {
        var current = try requireVault()
        if let index = current.shares.firstIndex(where: { $0.id == share.id }) {
            current.shares[index] = share
        } else {
            current.shares.append(share)
        }
        lock.withLock { vault = current }
        try save()
    }

    public func revokeShare(id: UUID, at date: Date = .now) throws {
        var current = try requireVault()
        guard let index = current.shares.firstIndex(where: { $0.id == id }) else { throw VaultError.invalidFile }
        current.shares[index].revokedAt = date
        lock.withLock { vault = current }
        try save()
    }

    public func match(urlString: String) throws -> LoginEntry {
        guard let entry = try matches(urlString: urlString).first else { throw VaultError.noMatch }
        return entry
    }

    public func matches(urlString: String) throws -> [LoginEntry] {
        let host = URL(string: urlString)?.host?.lowercased() ?? ""
        let origin = LoginEntry.normalizeOrigin(urlString)
        guard !host.isEmpty, let origin else { return [] }
        return try requireVault().entries.filter { item in
            if !item.origins.isEmpty { return item.origins.contains(origin) }
            return item.domains.contains(host)
        }
    }

    private func requireVault() throws -> Vault {
        try lock.withLock { guard let vault else { throw VaultError.locked }; return vault }
    }

    @discardableResult
    private func migrateOriginsIfNeeded() -> Bool {
        lock.withLock {
            guard var current = vault else { return false }
            var changed = false
            for index in current.entries.indices where current.entries[index].origins.isEmpty {
                current.entries[index].origins = current.entries[index].domains.compactMap(LoginEntry.normalizeOrigin)
                changed = true
            }
            if changed { vault = current }
            return changed
        }
    }

    private func loadRecord() throws -> EncryptedVault {
        guard let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(EncryptedVault.self, from: data) else { throw VaultError.invalidFile }
        return decoded
    }

    private func activate(_ derived: SymmetricKey, record: EncryptedVault, salt: Data) throws {
        guard let sealedData = Data(base64Encoded: record.sealed), let box = try? AES.GCM.SealedBox(combined: sealedData), let clear = try? AES.GCM.open(box, using: derived), let decoded = try? JSONDecoder().decode(Vault.self, from: clear) else { throw VaultError.invalidPassword }
        lock.withLock { key = derived; vault = decoded; self.salt = salt }
    }

    private func keyData(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    private func save() throws {
        guard let key, let vault else { throw VaultError.locked }
        let clear = try JSONEncoder().encode(vault)
        let box = try AES.GCM.seal(clear, using: key)
        let finalRecord = EncryptedVault(version: encryptionVersion, salt: salt.base64EncodedString(), sealed: box.combined!.base64EncodedString())
        try JSONEncoder().encode(finalRecord).write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func deriveKey(password: String, deviceSecret: Data?, salt: Data) -> SymmetricKey {
        var input = Data(password.utf8)
        if let deviceSecret { input.append(deviceSecret) }
        var output = Data(repeating: 0, count: 32)
        let outputLength = output.count
        output.withUnsafeMutableBytes { outputBuffer in
            input.withUnsafeBytes { inputBuffer in
                salt.withUnsafeBytes { saltBuffer in
                    _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), inputBuffer.bindMemory(to: Int8.self).baseAddress, input.count, saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, outputBuffer.bindMemory(to: UInt8.self).baseAddress, outputLength)
                }
            }
        }
        return SymmetricKey(data: output)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
