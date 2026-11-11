import XCTest
import UIKit
@testable import HomeReel

/// A stand-in for the engine: counts rebuilds, can be held in the middle of one, and can fail.
@MainActor
final class FakeRestorer: ForegroundRestorable {
    var needsForegroundVideoRestore = true
    var rebuilds = 0
    var failure: Error?
    var hold = false
    private var gate: CheckedContinuation<Void, Never>?

    func rebuildPaused() async throws {
        rebuilds += 1
        if hold { await withCheckedContinuation { gate = $0 } }
        if let failure { throw failure }
        needsForegroundVideoRestore = false
    }
    func release() { gate?.resume(); gate = nil }
}

/// J-26: after the app is left and opened again, the picture is rebuilt before anything plays.
@MainActor
final class ForegroundRestoreTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private func model(phase: PlayerModel.Phase = .paused) throws -> (PlayerModel, FakeRestorer) {
        let item = try XCTUnwrap(Fixture.container("movie_detail").items.first)
        let m = PlayerModel(item: item, client: makeClient())
        let r = FakeRestorer()
        m.restorer = r
        m.setPhaseForTesting(phase)
        return (m, r)
    }

    func testReturningAfterTheAppWasLeftRebuildsThePicture() async throws {
        let (m, r) = try model()
        await m.restoreAfterForeground()
        XCTAssertEqual(r.rebuilds, 1)
        XCTAssertFalse(m.isRestoring)
        XCTAssertEqual(m.phase, .paused, "it comes back paused: the viewer chooses when to go on")
    }

    func testTheNotificationForBecomingActiveStartsTheRebuild() async throws {
        let (m, r) = try model()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<100 where r.rebuilds == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(r.rebuilds, 1)
        withExtendedLifetime(m) {}
    }

    func testNothingIsRebuiltWhenTheVideoWasNeverTakenApart() async throws {
        let (m, r) = try model(phase: .playing)
        r.needsForegroundVideoRestore = false           // a system alert, or the volume bar: the app resigned but did not leave
        await m.restoreAfterForeground()
        XCTAssertEqual(r.rebuilds, 0)
    }

    func testNothingCountsWhileItRebuilds() async throws {
        let (m, r) = try model()
        r.hold = true
        let running = Task { await m.restoreAfterForeground() }
        for _ in 0..<100 where !m.isRestoring { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(m.isRestoring)
        XCTAssertFalse(m.canControl, "a press cannot reach a video that is not there yet")
        await m.restoreAfterForeground()                 // a second return during the rebuild
        XCTAssertEqual(r.rebuilds, 1, "one rebuild at a time")
        r.release()
        await running.value
        XCTAssertTrue(m.canControl)
    }

    func testARebuildThatFailsSaysSo() async throws {
        let (m, r) = try model()
        r.failure = URLError(.cannotConnectToHost)
        await m.restoreAfterForeground()
        guard case .failed(let message) = m.phase else { return XCTFail("expected a failure, got \(m.phase)") }
        XCTAssertTrue(message.contains("Press Menu"), message)
        XCTAssertFalse(m.isRestoring)
    }

    func testLeavingDuringTheRebuildIsNotAFailure() async throws {
        let (m, r) = try model()
        r.hold = true
        r.failure = URLError(.cancelled)
        let running = Task { await m.restoreAfterForeground() }
        for _ in 0..<100 where !m.isRestoring { try await Task.sleep(for: .milliseconds(10)) }
        StubURLProtocol.handler = { _ in (200, Data("{}".utf8)) }
        await m.finish()
        r.release()
        await running.value
        XCTAssertEqual(m.phase, .paused, "the viewer was already gone, so there is nothing to tell")
    }

    func testNothingIsRebuiltBeforePlaybackHasStarted() async throws {
        let (m, r) = try model(phase: .loading)
        await m.restoreAfterForeground()
        XCTAssertEqual(r.rebuilds, 0)
    }
}
