#if DEBUG
import Foundation

/// A pretend Plex server for UI tests and screenshots: `-fixture <mode>`. docs/DESIGN.md lists the modes.
/// It answers from the saved JSON in HomeReel/Fixtures, so no network or real server is needed.
final class FixtureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var mode = "normal"
    nonisolated(unsafe) static var pinChecks = 0
    nonisolated(unsafe) static var scanPolls = 0
    /// Items taken off Continue Watching during this run (by menu, or by a watched mark).
    nonisolated(unsafe) static var removedFromContinue: Set<String> = []
    /// The pretend Sony TV's picture mode.
    nonisolated(unsafe) static var tvMode = "dvBright"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (code, data, type) = Self.answer(request)
        if code == -1 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func session(mode: String) -> URLSession {
        self.mode = mode
        pinChecks = 0
        scanPolls = 0
        removedFromContinue = []
        tvMode = "dvBright"
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FixtureURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    // MARK: Answers

    private static func file(_ name: String) -> Data {
        guard let url = Bundle(for: AppModel.self).url(forResource: name, withExtension: "json"),
              let d = try? Data(contentsOf: url) else { return Data() }
        return d
    }

    /// The sample person with a biography of 12 long paragraphs, each starting "Paragraph N".
    private static func longBiography(_ data: Data) -> Data {
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var mc = obj["MediaContainer"] as? [String: Any], var list = mc["Metadata"] as? [[String: Any]], !list.isEmpty else { return data }
        let sentence = "This sentence is part of a very long fictional biography made for testing the biography page. "
        list[0]["summary"] = (1...12).map { n in "Paragraph \(n). " + String(repeating: sentence, count: 6) }.joined(separator: "\n")
        mc["Metadata"] = list
        obj["MediaContainer"] = mc
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? data
    }

    private static func json(_ name: String) -> (Int, Data, String) { (200, file(name), "application/json") }

    /// A container holding just the given items.
    private static func container(_ items: [[String: Any]], total: Int? = nil) -> (Int, Data, String) {
        let mc: [String: Any] = ["size": items.count, "totalSize": total ?? items.count, "Metadata": items]
        return (200, (try? JSONSerialization.data(withJSONObject: ["MediaContainer": mc])) ?? Data(), "application/json")
    }

    private static func items(_ name: String) -> [[String: Any]] {
        let obj = (try? JSONSerialization.jsonObject(with: file(name))) as? [String: Any]
        return ((obj?["MediaContainer"] as? [String: Any])?["Metadata"] as? [[String: Any]]) ?? []
    }

    private static func answer(_ req: URLRequest) -> (Int, Data, String) {
        let url = req.url!
        let path = url.path
        if mode == "offline" { return (-1, Data(), "") }

        // plex.tv sign-in
        if url.host == "plex.tv" {
            if path.hasSuffix("/pins") && req.httpMethod == "POST" {
                return (201, Data(#"{"id":1,"code":"ABCD","authToken":null}"#.utf8), "application/json")
            }
            if path.contains("/pins/") {
                pinChecks += 1
                let token = pinChecks >= 2 ? "\"fixture-token\"" : "null"
                return (200, Data(#"{"id":1,"code":"ABCD","authToken":\#(token)}"#.utf8), "application/json")
            }
            if path.hasSuffix("/resources") {
                let r = #"[{"name":"Fixture NAS","provides":"server","owned":true,"connections":[{"uri":"http://10.0.0.5:32400","address":"10.0.0.5","port":32400,"local":true,"relay":false,"protocol":"http"}]}]"#
                return (200, Data(r.utf8), "application/json")
            }
        }
        if url.host == "image.tmdb.org" || url.host == "metadata-static.plex.tv" { return (200, placeholderPNG, "image/png") }
        // Plex's online database (people, credits)
        if url.host == "discover.provider.plex.tv" {
            if mode == "discovererror" { return (500, Data(), "") }
            if path.hasSuffix("/credits") { return json("person_credits") }
            if path.hasSuffix("/person_known_for") { return json("person_knownfor") }
            // `longbio`: a biography far taller than the screen, in paragraphs.
            if mode == "longbio", path.hasPrefix("/library/people/"), !path.contains("/credits"), !path.contains("/person_known_for") {
                return (200, longBiography(file("person")), "application/json")
            }
            if path.hasPrefix("/library/people/") { return json("person") }
            if path.hasPrefix("/library/metadata/") { return mode == "detailerror" ? (500, Data(), "") : json("discover_detail") }
            return (404, Data(), "")
        }
        if path.hasPrefix("/sony/") { return tv(req, path: path) }
        if mode == "unauthorized" { return (401, Data(), "") }
        if path == "/identity" { return (200, Data("{}".utf8), "application/json") }
        if path.hasPrefix("/photo/") { return (200, placeholderPNG, "image/png") }
        if mode == "watcherror", path.hasSuffix("/scrobble") { return (500, Data(), "") }
        if path.hasPrefix("/:/") {
            // Watched or unwatched marks both take a title off Continue Watching, as the real server does.
            if path.hasSuffix("scrobble"), let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value {
                removedFromContinue.insert(key)
            }
            return (200, Data(), "text/plain")
        }
        if path == "/actions/removeFromContinueWatching" {
            if mode == "removeerror" { return (500, Data(), "") }
            if let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ratingKey" })?.value {
                removedFromContinue.insert(key)
            }
            return (200, Data(), "text/plain")
        }
        if path.hasPrefix("/library/sections/"), path.hasSuffix("/refresh") {
            if mode == "scanerror" { return (500, Data(), "") }
            scanPolls = 2
            return (200, Data(), "text/plain")
        }
        if path == "/library/sections", scanPolls > 0, mode != "empty" {
            // While a pretend scan runs, both libraries report it for the next two requests.
            scanPolls -= 1
            let obj = (try? JSONSerialization.jsonObject(with: file("sections"))) as? [String: Any]
            var mc = obj?["MediaContainer"] as? [String: Any] ?? [:]
            mc["Directory"] = ((mc["Directory"] as? [[String: Any]]) ?? []).map { var d = $0; d["refreshing"] = true; return d }
            return (200, (try? JSONSerialization.data(withJSONObject: ["MediaContainer": mc])) ?? Data(), "application/json")
        }
        if path == "/library/sections" {
            if mode == "empty" { return (200, Data(#"{"MediaContainer":{"size":0,"Directory":[]}}"#.utf8), "application/json") }
            return json("sections")
        }
        if mode == "libraryerror", path.hasPrefix("/library/sections/"), path.hasSuffix("/all") { return (500, Data(), "") }
        // The person's record in this role finds nothing (Plex keeps a separate record per role), so only
        // matching their online credits against the whole library can show what you own.
        if mode == "rolemiss", path.hasPrefix("/library/sections/"), path.hasSuffix("/all"),
           let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name),
           !Set(names).isDisjoint(with: ["actor", "director", "writer", "producer"]) { return container([]) }
        if mode == "libraryerror", path == "/hubs/continueWatching" { return (500, Data(), "") }
        if path.hasPrefix("/library/sections/1/") { return path.hasSuffix("/recentlyAdded") ? json("recent") : json("movies") }
        if path.hasPrefix("/library/sections/2/") { return json("shows") }
        if path == "/hubs/continueWatching" {
            guard !removedFromContinue.isEmpty,
                  var obj = (try? JSONSerialization.jsonObject(with: file("continue"))) as? [String: Any],
                  var mc = obj["MediaContainer"] as? [String: Any],
                  var hubs = mc["Hub"] as? [[String: Any]] else { return json("continue") }
            hubs = hubs.map { hub in
                var h = hub
                h["Metadata"] = ((hub["Metadata"] as? [[String: Any]]) ?? []).filter { !removedFromContinue.contains($0["ratingKey"] as? String ?? "") }
                return h
            }
            mc["Hub"] = hubs
            obj["MediaContainer"] = mc
            return (200, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(), "application/json")
        }
        if path == "/hubs/search" { return json("search") }
        if path.hasPrefix("/library/metadata/") {
            let parts = path.split(separator: "/").map(String.init)      // library, metadata, KEY, [children]
            let key = parts.count > 2 ? parts[2] : ""
            if parts.count > 3, parts[3] == "children" {
                let show = items("shows").first?["ratingKey"] as? String
                return key == show ? json("seasons") : json("episodes")
            }
            let all = items("movie_detail") + items("show_detail") + items("episode_detail") + items("movies") + items("shows") + items("seasons") + items("episodes")
            let wanted = key.split(separator: ",").map(String.init)
            let hits = wanted.compactMap { k in all.first(where: { ($0["ratingKey"] as? String) == k }) }
            if !hits.isEmpty { return container(hits) }
            return json("movie_detail")
        }
        return (404, Data(), "")
    }

    /// A pretend Sony BRAVIA TV. Key "fixture-key" is the only one it accepts for changes.
    /// Modes: `tvoff` (no answer), `tvasleep` (reports standby), `tvstuck` (ignores changes).
    private static func tv(_ req: URLRequest, path: String) -> (Int, Data, String) {
        if mode == "tvoff" { return (-1, Data(), "") }
        func reply(_ result: Any) -> (Int, Data, String) {
            (200, (try? JSONSerialization.data(withJSONObject: ["result": result, "id": 1])) ?? Data(), "application/json")
        }
        var body = Data()
        if let stream = req.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            stream.close()
        } else if let b = req.httpBody { body = b }
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        switch obj["method"] as? String {
        case "getPowerStatus": return reply([["status": mode == "tvasleep" ? "standby" : "active"]])
        case "getPictureQualitySettings":
            return reply([[["target": "pictureMode", "currentValue": tvMode, "isAvailable": true,
                            "candidate": [["value": "dvDark"], ["value": "dvBright"], ["value": "dvVivid"]]]]])
        case "setPictureQualitySettings":
            guard req.value(forHTTPHeaderField: "X-Auth-PSK") == "fixture-key" else { return (403, Data(), "") }
            let settings = ((obj["params"] as? [[String: Any]])?.first?["settings"] as? [[String: Any]]) ?? []
            if mode != "tvstuck", let v = settings.first?["value"] as? String { tvMode = v }
            return reply([])
        default: return (404, Data(), "")
        }
    }

    /// A small flat picture for posters, so lists look filled in without any real artwork.
    private static let placeholderPNG: Data = {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAGCAYAAADgzO9IAAAAFElEQVR4nGP4z8Dwn4EBCP4zEAsAAF8DAf1LbN4AAAAASUVORK5CYII="
        return Data(base64Encoded: base64) ?? Data()
    }()
}
#endif
