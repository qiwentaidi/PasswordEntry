import Foundation

public enum ShareAPIError: LocalizedError, Sendable {
    case invalidBaseURL
    case server(status: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "分享服务地址无效"
        case .server(let status, let message): return message.isEmpty ? "分享服务请求失败（HTTP \(status)）" : message
        case .invalidResponse: return "分享服务返回了无效响应"
        }
    }
}

private struct CreateShareRequest: Encodable {
    let shareID: String
    let schemaVersion: Int
    let algorithm: String
    let iv: String
    let ciphertext: String
    let expiresAt: Date
    let revokeTokenHash: String

    enum CodingKeys: String, CodingKey {
        case shareID = "shareId"
        case schemaVersion
        case algorithm
        case iv
        case ciphertext
        case expiresAt
        case revokeTokenHash
    }
}

private struct CreateShareResponse: Decodable {
    let shareID: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case shareID = "shareId"
        case expiresAt
    }
}

public final class ShareAPIClient: @unchecked Sendable {
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:8787")!
    public let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseURL: URL? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.session = session
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public static func isAllowedBaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    }

    public func create(material: ShareMaterial, expiresAt: Date) async throws -> String {
        guard Self.isAllowedBaseURL(baseURL) else { throw ShareAPIError.invalidBaseURL }
        let endpoint = baseURL.appendingPathComponent("v1/shares", isDirectory: false)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(CreateShareRequest(
            shareID: material.shareID,
            schemaVersion: material.envelope.schemaVersion,
            algorithm: material.envelope.algorithm,
            iv: material.envelope.iv,
            ciphertext: material.envelope.ciphertext,
            expiresAt: expiresAt,
            revokeTokenHash: material.revokeTokenHash
        ))
        let response: CreateShareResponse = try await send(request)
        return response.shareID
    }

    public func revoke(shareID: String, revokeSecret: String) async throws {
        guard Self.isAllowedBaseURL(baseURL) else { throw ShareAPIError.invalidBaseURL }
        let endpoint = baseURL.appendingPathComponent("v1/shares/\(shareID)", isDirectory: false)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue(revokeSecret, forHTTPHeaderField: "X-Revoke-Token")
        _ = try await sendEmpty(request)
    }

    public func makeShareURL(shareID: String, viewSecret: String) -> URL? {
        guard Self.isAllowedBaseURL(baseURL) else { return nil }
        let root = baseURL.appendingPathComponent("s", isDirectory: true).appendingPathComponent(shareID, isDirectory: false)
        guard var components = URLComponents(url: root, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = viewSecret
        return components.url
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw ShareAPIError.invalidResponse }
    }

    private func sendEmpty(_ request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ShareAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
            throw ShareAPIError.server(status: http.statusCode, message: message)
        }
    }
}
