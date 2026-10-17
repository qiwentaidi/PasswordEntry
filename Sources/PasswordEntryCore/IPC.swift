import Foundation
import Darwin

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

    public init(action: AgentAction, url: String? = nil, entryId: UUID? = nil, name: String? = nil, username: String? = nil, password: String? = nil, faviconData: String? = nil, faviconMimeType: String? = nil) {
        self.action = action; self.url = url; self.entryId = entryId; self.name = name; self.username = username; self.password = password; self.faviconData = faviconData; self.faviconMimeType = faviconMimeType
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
    public static var path: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Password Entry/agent.sock").path
    }

    public static func request(_ request: AgentRequest, timeout: TimeInterval = 5) throws -> AgentResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VaultError.authenticationFailed("无法连接桌面端") }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() where index < buffer.count { buffer[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) } }
        guard connected == 0 else { throw VaultError.authenticationFailed("桌面端未运行，请先打开 Password Entry") }
        let body = try JSONEncoder().encode(request) + Data([10])
        _ = body.withUnsafeBytes { write(fd, $0.baseAddress, body.count) }
        var response = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 { if byte == 10 { break }; response.append(byte) }
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

    public init(store: VaultStore) { self.store = store }

    public func start() {
        acceptQueue.async { [weak self] in self?.run() }
    }

    public func stop() {
        running = false
        if serverFD >= 0 { shutdown(serverFD, SHUT_RDWR); close(serverFD); serverFD = -1 }
        unlink(AgentSocket.path)
    }

    private func run() {
        let directory = URL(fileURLWithPath: AgentSocket.path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        unlink(AgentSocket.path)
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { return }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(AgentSocket.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in for (index, byte) in pathBytes.enumerated() where index < buffer.count { buffer[index] = byte } }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFD, $0, length) } }
        guard bound == 0, listen(serverFD, 12) == 0 else { return }
        chmod(AgentSocket.path, 0o600); running = true
        while running {
            let client = accept(serverFD, nil, nil)
            if client >= 0 { clientQueue.async { [weak self] in self?.handle(client) } }
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var requestData = Data(); var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 { if byte == 10 { break }; requestData.append(byte) }
        let response: AgentResponse
        do { response = try handle(try JSONDecoder().decode(AgentRequest.self, from: requestData)) }
        catch { response = AgentResponse(ok: false, error: error.localizedDescription) }
        if let data = try? JSONEncoder().encode(response) { _ = (data + Data([10])).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }
    }

    private func handle(_ request: AgentRequest) throws -> AgentResponse {
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
            let domain = URL(string: request.url ?? "")?.host ?? ""
            let faviconData = request.faviconData.flatMap { Data(base64Encoded: $0) }
            try store.upsertLogin(name: request.name ?? domain, domain: domain, username: username, password: password, faviconData: faviconData, faviconMimeType: request.faviconMimeType)
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
