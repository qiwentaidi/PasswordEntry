import Foundation
import Security
import LocalAuthentication

public enum KeychainStore {
    private static let service = "com.passwordentry.desktop"
    private static let account = "device-secret"
    private static let biometricService = "com.passwordentry.desktop.biometric"
    private static let biometricAccount = "vault-unlock-key"
    private static let compatibilityService = "com.passwordentry.desktop.biometric.compatibility"

    public static func deviceSecret() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return data }
        guard status == errSecItemNotFound else { throw VaultError.keychain(status) }
        let data = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else { throw VaultError.keychain(addStatus) }
        return data
    }

    public static var hasBiometricVaultKey: Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricService,
            kSecAttrAccount as String: biometricAccount,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess || status == errSecInteractionNotAllowed { return true }
        let fallback: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: compatibilityService,
            kSecAttrAccount as String: biometricAccount,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var fallbackResult: CFTypeRef?
        return SecItemCopyMatching(fallback as CFDictionary, &fallbackResult) == errSecSuccess
    }

    public static func saveBiometricVaultKey(_ key: Data) throws {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, &accessError) else {
            let message = accessError?.takeRetainedValue().localizedDescription ?? "无法创建 Touch ID 访问控制"
            throw VaultError.authenticationFailed(message)
        }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricService,
            kSecAttrAccount as String: biometricAccount
        ]
        SecItemDelete(identity as CFDictionary)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricService,
            kSecAttrAccount as String: biometricAccount,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: key
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecMissingEntitlement || status == errSecParam else { throw VaultError.keychain(status) }

        // Unsigned local development builds cannot create a Data Protection Keychain
        // item with an access-control object. Keep the key in the traditional keychain,
        // but require a fresh Touch ID check before every read.
        try LocalAuth.authenticateBiometrics(reason: "确认启用 Password Entry 的 Touch ID 解锁")
        let fallbackIdentity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: compatibilityService,
            kSecAttrAccount as String: biometricAccount
        ]
        SecItemDelete(fallbackIdentity as CFDictionary)
        let fallbackAttributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: compatibilityService,
            kSecAttrAccount as String: biometricAccount,
            kSecValueData as String: key
        ]
        let fallbackStatus = SecItemAdd(fallbackAttributes as CFDictionary, nil)
        guard fallbackStatus == errSecSuccess else { throw VaultError.keychain(fallbackStatus) }
    }

    public static func biometricVaultKey(reason: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = reason
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
            throw VaultError.authenticationFailed(authError?.localizedDescription ?? "此 Mac 没有可用的 Touch ID")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricService,
            kSecAttrAccount as String: biometricAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return data }
        if status != errSecItemNotFound && status != errSecMissingEntitlement && status != errSecParam {
            if status == errSecUserCanceled || status == errSecAuthFailed { throw VaultError.authenticationFailed("Touch ID 验证未通过") }
            throw VaultError.keychain(status)
        }

        try LocalAuth.authenticateBiometrics(reason: reason)
        let fallback: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: compatibilityService,
            kSecAttrAccount as String: biometricAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var fallbackResult: CFTypeRef?
        let fallbackStatus = SecItemCopyMatching(fallback as CFDictionary, &fallbackResult)
        guard fallbackStatus == errSecSuccess, let data = fallbackResult as? Data else {
            if fallbackStatus == errSecItemNotFound { throw VaultError.authenticationFailed("尚未启用 Touch ID 解锁") }
            throw VaultError.keychain(fallbackStatus)
        }
        return data
    }

    public static func deleteBiometricVaultKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricService,
            kSecAttrAccount as String: biometricAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
        let fallback: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: compatibilityService,
            kSecAttrAccount as String: biometricAccount
        ]
        let fallbackStatus = SecItemDelete(fallback as CFDictionary)
        guard fallbackStatus == errSecSuccess || fallbackStatus == errSecItemNotFound else { throw VaultError.keychain(fallbackStatus) }
    }
}
