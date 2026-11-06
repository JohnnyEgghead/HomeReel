import Foundation

enum BraviaError: Error, Equatable, LocalizedError {
    case noAddress
    case unreachable
    case tvOff
    case needsKey
    case rejectedKey
    case tvError(Int, String)
    case notApplied(String)
    case unexpected

    var errorDescription: String? {
        switch self {
        case .noAddress: return "Enter the TV's address in Settings."
        case .unreachable: return "Could not reach the TV. Check that it is on and the address in Settings is right."
        case .tvOff: return "The TV is off or asleep."
        case .needsKey: return "Add the TV's key in Settings to change the picture mode."
        case .rejectedKey: return "The TV did not accept the key. Check it in Settings."
        case .tvError(let code, let message): return "The TV refused (error \(code)\(message.isEmpty ? "" : ": \(message)"))."
        case .notApplied(let now): return "The TV stayed on \(now)."
        case .unexpected: return "The TV sent something unexpected."
        }
    }
}

/// One picture mode the TV offers, such as "dvBright".
struct PictureChoice: Equatable, Identifiable {
    var value: String
    var id: String { value }
    var label: String { BraviaLabels.label(for: value) }
}

/// What the TV says about its picture mode right now.
struct PictureModes: Equatable {
    var current: String
    var isAvailable: Bool
    var choices: [PictureChoice]
    var currentLabel: String { BraviaLabels.label(for: current) }
}

enum BraviaLabels {
    private static let known = ["dvDark": "Dolby Vision Dark", "dvBright": "Dolby Vision Bright", "dvVivid": "Dolby Vision Vivid"]

    /// A readable name. Unknown values are split at capital letters ("hdr10Bright" becomes "Hdr10 Bright").
    static func label(for value: String) -> String {
        if let k = known[value] { return k }
        var out = ""
        for ch in value {
            if ch.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(out.isEmpty ? Character(ch.uppercased()) : ch)
        }
        return out
    }
}

/// Talks to a Sony BRAVIA TV's REST API (plain HTTP on the home network).
/// Reading needs no key. Changing a setting needs the TV's pre-shared key.
struct BraviaClient: Sendable {
    let host: String
    let psk: String?
    let session: URLSession
    /// The TV can take a moment to apply a change before it reports it.
    var settleDelay: Duration = .seconds(1.5)

    init(host: String, psk: String?, session: URLSession = .shared) {
        self.host = host.trimmingCharacters(in: .whitespaces)
        self.psk = psk.flatMap { $0.isEmpty ? nil : $0 }
        self.session = session
    }

    private func call(_ service: String, _ method: String, params: [Any]) async throws -> [Any] {
        guard !host.isEmpty else { throw BraviaError.noAddress }
        guard let url = URL(string: "http://\(host)/sony/\(service)") else { throw BraviaError.unreachable }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let psk { req.setValue(psk, forHTTPHeaderField: "X-Auth-PSK") }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["method": method, "id": 1, "params": params, "version": "1.0"])
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw BraviaError.unreachable }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw BraviaError.rejectedKey }
        guard (200..<300).contains(code), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BraviaError.unexpected }
        if let err = obj["error"] as? [Any], let n = err.first as? Int {
            if n == 403 { throw BraviaError.rejectedKey }
            throw BraviaError.tvError(n, err.dropFirst().first as? String ?? "")
        }
        return obj["result"] as? [Any] ?? []
    }

    /// "active" when the TV is on, "standby" when it sleeps.
    func powerStatus() async throws -> String {
        let r = try await call("system", "getPowerStatus", params: [])
        return ((r.first as? [String: Any])?["status"] as? String) ?? "unknown"
    }

    func pictureModes() async throws -> PictureModes {
        guard try await powerStatus() == "active" else { throw BraviaError.tvOff }
        let r = try await call("video", "getPictureQualitySettings", params: [["target": "pictureMode"]])
        guard let setting = (r.first as? [Any])?.first as? [String: Any], let current = setting["currentValue"] as? String else {
            throw BraviaError.unexpected
        }
        let candidates = (setting["candidate"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }
        return PictureModes(current: current, isAvailable: setting["isAvailable"] as? Bool ?? true,
                            choices: candidates.map { PictureChoice(value: $0) })
    }

    /// Proves the key works. Reading needs no key, so this writes the mode the TV is already on, which changes nothing.
    func verifyKey(_ modes: PictureModes) async throws {
        _ = try await setPictureMode(modes.current)
    }

    /// Sets the mode, then asks the TV what it is on. Throws if the TV did not change.
    func setPictureMode(_ value: String) async throws -> PictureModes {
        guard psk != nil else { throw BraviaError.needsKey }
        _ = try await call("video", "setPictureQualitySettings", params: [["settings": [["target": "pictureMode", "value": value]]]])
        try? await Task.sleep(for: settleDelay)
        let now = try await pictureModes()
        if now.current != value { throw BraviaError.notApplied(now.currentLabel) }
        return now
    }
}
