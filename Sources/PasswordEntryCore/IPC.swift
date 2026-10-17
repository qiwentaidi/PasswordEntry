import Foundation
import Darwin
import Security

public enum AgentAction: String, Codable, Sendable {
    case status
    case listMatches = "list_matches"
    case fillLogin = "fill_login"
    case generateTotp = "generate_totp"
    case saveLogin = "save_login"
    case lock
}

public struct AgentRequest: Codable, Sendable {
    public var action: AgentAction
    public var url: String?
    public var entryId: UUID?
    public var name: String?
    public var username: String?
    public var password: String?
    public var faviconData: String?
    public var faviconMimeType: String?
    fileprivate var sessionToken: String?

    public init(action: AgentAction, url: String? = nil, entryId: UUID? = nil, name: String? = nil, username: String? = nil, password: String? = nil, faviconData: String? = nil, faviconMimeType: String? = nil) {
        self.action = action; self.url = url; self.entryId = entryId; self.name = name; self.username = username; self.password = password; self.faviconData = faviconData; self.faviconMimeType = faviconMimeType; self.sessionToken = nil
    }
}

public struct AgentResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var running: Bool?
    public var unlocked: Bool?
    public var initialized: Bool?
    public var entries: [MatchedEntry]?
    public var username: String?
    public var password: String?
    public var code: String?
    public var saved: Bool?

    public init(ok: Bool, error: String? = nil, running: Bool? = nil, unlocked: Bool? = nil, initialized: Bool? = nil) {
        self.ok = ok; self.error = error; self.running = running; self.unlocked = unlocked; self.initialized = initialized
    }
}

public enum AgentSocket {
    public static let maxRequestBytes = 512 * 1024
    public static let maxResponseBytes = 4 * 1024 * 1024

    public static var path: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Password Entry/agent.sock").path
    }

    public static var tokenPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Password Entry/agent.token").path
    }

    fileprivate static func configure(_ fd: Int32, timeout: TimeInterval) {
        var value = timeval(tv_sec: Int(timeout), tv_usec: __darwin_suseconds_t((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    fileprivate static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    public static func request(_ request: AgentRequest, timeout: TimeInterval = 5) throws -> AgentResponse {
        guard let token = try? Data(contentsOf: URL(fileURLWithPath: tokenPath)), token.count == 32 else {
            throw VaultError.authenticationFailed("桌面端会话未就绪")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VaultError.authenticationFailed("无法连接桌面端") }
        defer { close(fd) }
        configure(fd, timeout: timeout)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() where index < buffer.count { buffer[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) } }
        guard connected == 0 else { throw VaultError.authenticationFailed("桌面端未运行，请先打开 Password Entry") }
        var authenticatedRequest = request
        authenticatedRequest.sessionToken = token.base64EncodedString()
        let body = try JSONEncoder().encode(authenticatedRequest) + Data([10])
        guard body.count <= maxRequestBytes else { throw VaultError.invalidFile }
        _ = body.withUnsafeBytes { write(fd, $0.baseAddress, body.count) }
        var response = Data()
        var byte: UInt8 = 0
        while response.count < maxResponseBytes, read(fd, &byte, 1) == 1 { if byte == 10 { break }; response.append(byte) }
        guard response.count < maxResponseBytes else { throw VaultError.invalidFile }
        guard !response.isEmpty else { throw VaultError.authenticationFailed("桌面端没有返回结果") }
        return try JSONDecoder().decode(AgentResponse.self, from: response)
    }
}

public final class AgentServer: @unchecked Sendable {
    private let store: VaultStore
    public var onVaultChanged: (() -> Void)?
    private let acceptQueue = DispatchQueue(label: "com.passwordentry.agent.accept", qos: .utility)
    private let clientQueue = DispatchQueue(label: "com.passwordentry.agent.client", qos: .userInitiated, attributes: .concurrent)
    private var serverFD: Int32 = -1
    private var running = false
    private var sessionToken = Data()

    public init(store: VaultStore) { self.store = store }

    public func start() {
        acceptQueue.async { [weak self] in self?.run() }
    }

    public func stop() {
        running = false
        sessionToken = Data()
        if serverFD >= 0 { shutdown(serverFD, SHUT_RDWR); close(serverFD); serverFD = -1 }
        unlink(AgentSocket.path)
        unlink(AgentSocket.tokenPath)
    }

    private func run() {
        let directory = URL(fileURLWithPath: AgentSocket.path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        unlink(AgentSocket.path)
        unlink(AgentSocket.tokenPath)
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { return }
        AgentSocket.configure(serverFD, timeout: 5)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(AgentSocket.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in for (index, byte) in pathBytes.enumerated() where index < buffer.count { buffer[index] = byte } }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFD, $0, length) } }
        guard bound == 0, listen(serverFD, 12) == 0 else { return }
        sessionToken = Data(repeating: 0, count: 32)
        let randomStatus = sessionToken.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { return }
        do {
            try sessionToken.write(to: URL(fileURLWithPath: AgentSocket.tokenPath), options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AgentSocket.tokenPath)
        } catch { return }
        chmod(AgentSocket.path, 0o600); running = true
        while running {
            let client = accept(serverFD, nil, nil)
            if client >= 0 { AgentSocket.configure(client, timeout: 5); clientQueue.async { [weak self] in self?.handle(client) } }
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var requestData = Data(); var byte: UInt8 = 0
        while requestData.count < AgentSocket.maxRequestBytes, read(fd, &byte, 1) == 1 { if byte == 10 { break }; requestData.append(byte) }
        let response: AgentResponse
        do {
            guard requestData.count < AgentSocket.maxRequestBytes else { throw VaultError.invalidFile }
            response = try handle(try JSONDecoder().decode(AgentRequest.self, from: requestData))
        }
        catch { response = AgentResponse(ok: false, error: error.localizedDescription) }
        if let data = try? JSONEncoder().encode(response) { _ = (data + Data([10])).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }
    }

    private func handle(_ request: AgentRequest) throws -> AgentResponse {
        guard let encodedToken = request.sessionToken,
              let presentedToken = Data(base64Encoded: encodedToken),
              AgentSocket.constantTimeEqual(presentedToken, sessionToken) else {
            throw VaultError.authenticationFailed("IPC 客户端未通过验证")
        }
        switch request.action {
        case .status:
            return AgentResponse(ok: true, unlocked: store.isUnlocked, initialized: store.hasVault)
        case .listMatches:
            let entries = try store.matches(urlString: request.url ?? "")
            guard !entries.isEmpty else { throw VaultError.noMatch }
            var result = AgentResponse(ok: true); result.entries = entries.map(MatchedEntry.init); return result
        case .fillLogin:
            let entry = try requestedEntry(request)
            var result = AgentResponse(ok: true); result.username = entry.username; result.password = entry.password; return result
        case .generateTotp:
            let entry = try requestedEntry(request)
            guard let totp = entry.totp else { throw VaultError.invalidTotp }
            try LocalAuth.authenticate(reason: "允许 Password Entry 读取并填入验证码")
            var result = AgentResponse(ok: true); result.code = try TOTP.generate(totp); return result
        case .saveLogin:
            guard let username = request.username, let password = request.password else { throw VaultError.invalidFile }
            guard let url = request.url,
                  let domain = URL(string: url)?.host,
                  !domain.isEmpty,
                  let origin = LoginEntry.normalizeOrigin(url) else { throw VaultError.invalidFile }
            let faviconData = request.faviconData.flatMap { Data(base64Encoded: $0) }
            try store.upsertLogin(name: request.name ?? domain, domain: domain, origin: origin, username: username, password: password, faviconData: faviconData, faviconMimeType: request.faviconMimeType)
            onVaultChanged?()
            var result = AgentResponse(ok: true); result.saved = true; return result
        case .lock:
            store.lockVault(); return AgentResponse(ok: true)
        }
    }

    private func requestedEntry(_ request: AgentRequest) throws -> LoginEntry {
        if let id = request.entryId, let entry = try store.entries().first(where: { $0.id == id }) { return entry }
        return try store.match(urlString: request.url ?? "")
    }
}
