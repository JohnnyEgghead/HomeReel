import XCTest
@testable import HomeReel

final class BraviaTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private static func body(_ r: URLRequest) -> [String: Any] {
        var data = Data()
        if let s = r.httpBodyStream {
            s.open(); var buf = [UInt8](repeating: 0, count: 2048)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            s.close()
        } else if let b = r.httpBody { data = b }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func answer(power: String = "active", current: String = "dvBright", available: Bool = true) {
        StubURLProtocol.handler = { r in
            let b = Self.body(r)
            switch b["method"] as? String {
            case "getPowerStatus": return (200, Data(#"{"result":[{"status":"\#(power)"}],"id":1}"#.utf8))
            case "getPictureQualitySettings":
                return (200, Data(#"{"result":[[{"target":"pictureMode","currentValue":"\#(current)","isAvailable":\#(available),"candidate":[{"value":"dvDark"},{"value":"dvBright"},{"value":"dvVivid"}]}]],"id":1}"#.utf8))
            default:
                return (200, Data(#"{"result":[],"id":1}"#.utf8))
            }
        }
    }

    private func client(psk: String? = "KEY") -> BraviaClient {
        var c = BraviaClient(host: "10.0.0.9", psk: psk, session: StubURLProtocol.session())
        c.settleDelay = .milliseconds(1)
        return c
    }

    func testReadsCurrentModeAndCandidates() async throws {
        answer()
        let m = try await client().pictureModes()
        XCTAssertEqual(m.current, "dvBright")
        XCTAssertEqual(m.currentLabel, "Dolby Vision Bright")
        XCTAssertEqual(m.choices.map(\.label), ["Dolby Vision Dark", "Dolby Vision Bright", "Dolby Vision Vivid"])
        XCTAssertTrue(m.isAvailable)
    }

    func testRequestsGoToTheTVsVideoServiceWithTheKey() async throws {
        answer()
        _ = try await client().pictureModes()
        let video = try XCTUnwrap(StubURLProtocol.seen.last)
        XCTAssertEqual(video.url?.absoluteString, "http://10.0.0.9/sony/video")
        XCTAssertEqual(video.httpMethod, "POST")
        XCTAssertEqual(video.value(forHTTPHeaderField: "X-Auth-PSK"), "KEY")
        XCTAssertEqual(StubURLProtocol.seen.first?.url?.path, "/sony/system", "power is checked first")
    }

    func testTVInStandbyIsReportedAsOff() async {
        answer(power: "standby")
        do { _ = try await client().pictureModes(); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? BraviaError, .tvOff) }
    }

    func testSetSendsTheModeThenReadsItBack() async throws {
        nonisolated(unsafe) var mode = "dvBright"
        StubURLProtocol.handler = { r in
            let b = Self.body(r)
            switch b["method"] as? String {
            case "getPowerStatus": return (200, Data(#"{"result":[{"status":"active"}],"id":1}"#.utf8))
            case "getPictureQualitySettings":
                return (200, Data(#"{"result":[[{"target":"pictureMode","currentValue":"\#(mode)","isAvailable":true,"candidate":[{"value":"dvDark"},{"value":"dvBright"}]}]],"id":1}"#.utf8))
            default:
                mode = (((b["params"] as? [[String: Any]])?.first?["settings"] as? [[String: Any]])?.first?["value"] as? String) ?? mode
                return (200, Data(#"{"result":[],"id":1}"#.utf8))
            }
        }
        let after = try await client().setPictureMode("dvDark")
        XCTAssertEqual(after.current, "dvDark")
        let set = try XCTUnwrap(StubURLProtocol.seen.first { Self.body($0)["method"] as? String == "setPictureQualitySettings" })
        XCTAssertEqual(set.value(forHTTPHeaderField: "X-Auth-PSK"), "KEY")
    }

    func testSetWithoutAKeyNeverSendsAnything() async {
        answer()
        do { _ = try await client(psk: nil).setPictureMode("dvDark"); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? BraviaError, .needsKey) }
        XCTAssertTrue(StubURLProtocol.seen.isEmpty)
    }

    func testTVThatStaysPutIsReportedWithItsRealMode() async {
        answer(current: "dvBright")
        do { _ = try await client().setPictureMode("dvDark"); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? BraviaError, .notApplied("Dolby Vision Bright")) }
    }

    func testRejectedKeyIsReported() async {
        StubURLProtocol.handler = { _ in (403, Data()) }
        do { _ = try await client().pictureModes(); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? BraviaError, .rejectedKey) }
    }

    func testUnknownModesGetReadableNames() {
        XCTAssertEqual(BraviaLabels.label(for: "hdr10Bright"), "Hdr10 Bright")
        XCTAssertEqual(BraviaLabels.label(for: "cinema"), "Cinema")
    }
}

final class PictureTabVisibilityTests: XCTestCase {
    func testPictureTabOnlyAppearsWhenTVControlIsOn() {
        XCTAssertEqual(PanelTab.visible(tvEnabled: false), [.info, .subtitles, .audio])
        XCTAssertEqual(PanelTab.visible(tvEnabled: true), [.info, .subtitles, .audio, .picture])
    }
}

final class BraviaAddressTests: XCTestCase {
    func testNoAddressSaysSoInsteadOfGuessing() async {
        StubURLProtocol.reset()
        let c = BraviaClient(host: "", psk: "KEY", session: StubURLProtocol.session())
        do { _ = try await c.pictureModes(); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? BraviaError, .noAddress) }
        XCTAssertTrue(StubURLProtocol.seen.isEmpty)
    }
}
