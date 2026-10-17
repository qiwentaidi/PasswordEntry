import Foundation
import PasswordEntryCore

func readExactly(_ count: Int) -> Data? {
    var data = Data()
    while data.count < count {
        guard let chunk = try? FileHandle.standardInput.read(upToCount: count - data.count), !chunk.isEmpty else { return nil }
        data.append(chunk)
    }
    return data
}

func send(_ response: AgentResponse) {
    guard let body = try? JSONEncoder().encode(response) else { return }
    var length = UInt32(body.count).littleEndian
    let header = withUnsafeBytes(of: &length) { Data($0) }
    FileHandle.standardOutput.write(header)
    FileHandle.standardOutput.write(body)
}

while let header = readExactly(4) {
    let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    guard length <= 1024 * 1024, let body = readExactly(Int(length)) else { break }
    do {
        let request = try JSONDecoder().decode(AgentRequest.self, from: body)
        send(try AgentSocket.request(request))
    } catch {
        send(AgentResponse(ok: false, error: error.localizedDescription))
    }
}
