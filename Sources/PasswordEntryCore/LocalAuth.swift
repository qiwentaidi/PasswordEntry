import Foundation
import LocalAuthentication

public enum LocalAuth {
    public static func canUseBiometrics() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    public static func authenticate(reason: String) throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw VaultError.authenticationFailed(error?.localizedDescription ?? "macOS 身份验证不可用")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let result = AuthResult()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, authError in
            result.success = success
            if let authError { result.message = authError.localizedDescription }
            semaphore.signal()
        }
        semaphore.wait()
        guard result.success else { throw VaultError.authenticationFailed(result.message) }
    }

    public static func authenticateBiometrics(reason: String) throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw VaultError.authenticationFailed(error?.localizedDescription ?? "此 Mac 没有可用的 Touch ID")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let result = AuthResult()
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, authError in
            result.success = success
            if let authError { result.message = authError.localizedDescription }
            semaphore.signal()
        }
        semaphore.wait()
        guard result.success else { throw VaultError.authenticationFailed("Touch ID 验证未通过") }
    }
}

private final class AuthResult: @unchecked Sendable {
    var success = false
    var message = "身份验证失败"
}
