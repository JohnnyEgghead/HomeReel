import XCTest
@testable import HomeReel

final class PlaybackPolicyTests: XCTestCase {
    private func item(offsetSec: Double?, durationSec: Double?) -> PlexItem {
        var i = try! JSONDecoder().decode(PlexItem.self, from: Data(#"{"ratingKey":"1","type":"movie","title":"t"}"#.utf8))
        i.viewOffset = offsetSec.map { Int($0 * 1000) }
        i.duration = durationSec.map { Int($0 * 1000) }
        return i
    }

    func testResumeOnlyWhenMeaningful() {
        XCTAssertNil(PlaybackPolicy.resumePosition(for: item(offsetSec: nil, durationSec: 6000)))
        XCTAssertNil(PlaybackPolicy.resumePosition(for: item(offsetSec: 10, durationSec: 6000)), "first 30 seconds does not count")
        XCTAssertEqual(PlaybackPolicy.resumePosition(for: item(offsetSec: 1800, durationSec: 6000)), 1800)
        XCTAssertNil(PlaybackPolicy.resumePosition(for: item(offsetSec: 5800, durationSec: 6000)), "credits do not count")
        XCTAssertNil(PlaybackPolicy.resumePosition(for: item(offsetSec: 1800, durationSec: nil)))
    }

    func testWatchedAtNinetyPercent() {
        XCTAssertFalse(PlaybackPolicy.countsAsWatched(time: 5399, duration: 6000))
        XCTAssertTrue(PlaybackPolicy.countsAsWatched(time: 5400, duration: 6000))
        XCTAssertFalse(PlaybackPolicy.countsAsWatched(time: 100, duration: 0))
    }

    func testTimelineReportShape() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, Data()) }
        let it = item(offsetSec: nil, durationSec: 6000)
        await makeClient().reportTimeline(it, state: .paused, time: 12.5, duration: 6000)
        let url = try XCTUnwrap(StubURLProtocol.seen.first?.url)
        XCTAssertEqual(url.path, "/:/timeline")
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        XCTAssertEqual(q["state"], "paused")
        XCTAssertEqual(q["time"], "12500")
        XCTAssertEqual(q["duration"], "6000000")
        XCTAssertEqual(q["ratingKey"], "1")
        XCTAssertEqual(q["key"], "/library/metadata/1")
        XCTAssertEqual(StubURLProtocol.seen.first?.value(forHTTPHeaderField: "X-Plex-Token"), "SECRET")
    }

    func testTimelineFailureDoesNotThrowOrCrash() async {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (500, Data()) }
        await makeClient().reportTimeline(item(offsetSec: nil, durationSec: 10), state: .stopped, time: 1, duration: 10)
    }

    func testScrubSpanScalesWithLengthWithinBounds() {
        XCTAssertEqual(PlaybackPolicy.scrubSpan(duration: 1320), 79.2, accuracy: 0.01, "22 minute episode")
        XCTAssertEqual(PlaybackPolicy.scrubSpan(duration: 7200), 420, "long film is capped")
        XCTAssertEqual(PlaybackPolicy.scrubSpan(duration: 180), 45, "short clip has a minimum")
    }

    func testScrubStepIsProportionalAndClamped() {
        let d = 7200.0
        XCTAssertEqual(PlaybackPolicy.scrubStep(position: 1000, dx: 500, width: 1000, boost: 1, duration: d), 1210, accuracy: 0.01)
        XCTAssertEqual(PlaybackPolicy.scrubStep(position: 1000, dx: -500, width: 1000, boost: 1, duration: d), 790, accuracy: 0.01)
        XCTAssertEqual(PlaybackPolicy.scrubStep(position: 10, dx: -1000, width: 1000, boost: 1, duration: d), 0)
        XCTAssertEqual(PlaybackPolicy.scrubStep(position: 7190, dx: 1000, width: 1000, boost: 3, duration: d), 7199)
        XCTAssertEqual(PlaybackPolicy.scrubStep(position: 50, dx: 900, width: 1000, boost: 1, duration: 0), 50)
        XCTAssertEqual(PlaybackPolicy.scrubStep(position: 50, dx: 900, width: 0, boost: 1, duration: 100), 50)
    }

    func testBoostOnlyForQuickFlicks() {
        XCTAssertEqual(PlaybackPolicy.scrubBoost(speed: 0), 1)
        XCTAssertEqual(PlaybackPolicy.scrubBoost(speed: 1), 1, "medium swipes get no boost")
        XCTAssertEqual(PlaybackPolicy.scrubBoost(speed: 2), 1.5, accuracy: 0.001)
        XCTAssertEqual(PlaybackPolicy.scrubBoost(speed: 50), 3, "capped at 3x")
    }

    func testSmallStepsAddUpTheSameAsOneBigMove() {
        var p = 0.0
        for _ in 0..<100 { p = PlaybackPolicy.scrubStep(position: p, dx: 5, width: 1000, boost: 1, duration: 7200) }
        XCTAssertEqual(p, PlaybackPolicy.scrubStep(position: 0, dx: 500, width: 1000, boost: 1, duration: 7200), accuracy: 0.001)
    }

    func testClockFormat() {
        XCTAssertEqual(TransportOverlay.clock(65), "1:05")
        XCTAssertEqual(TransportOverlay.clock(3725), "1:02:05")
        XCTAssertEqual(TransportOverlay.clock(-4), "0:00")
    }
}

final class TrackLabelTests: XCTestCase {
    func testLanguageNames() {
        XCTAssertEqual(TrackLabels.languageName("eng"), "English")
        XCTAssertEqual(TrackLabels.languageName("en"), "English")
        XCTAssertEqual(TrackLabels.languageName("jpn"), "Japanese")
        XCTAssertEqual(TrackLabels.languageName("spa"), "Spanish")
        XCTAssertNil(TrackLabels.languageName("und"))
        XCTAssertNil(TrackLabels.languageName(nil))
    }

    func testSameLanguageAcrossCodeStyles() {
        XCTAssertTrue(TrackLabels.sameLanguage("eng", "en"))
        XCTAssertTrue(TrackLabels.sameLanguage("en-US", "eng"))
        XCTAssertTrue(TrackLabels.sameLanguage("fre", "fr"))
        XCTAssertTrue(TrackLabels.sameLanguage("ger", "de"))
        XCTAssertFalse(TrackLabels.sameLanguage("eng", "spa"))
        XCTAssertFalse(TrackLabels.sameLanguage(nil, "en"))
    }

    func testSubtitleRowText() {
        let t = TrackDescriptor(id: 3, codec: "hdmv_pgs_subtitle", language: "eng", isForced: true)
        XCTAssertEqual(TrackLabels.subtitle(t).title, "English")
        XCTAssertEqual(TrackLabels.subtitle(t).detail, "PGS · Forced")
        let ext = TrackDescriptor(id: 100_000, codec: "subrip", language: "spa", isHearingImpaired: true, isExternal: true)
        XCTAssertEqual(TrackLabels.subtitle(ext).detail, "SRT · SDH · File")
        XCTAssertEqual(TrackLabels.subtitle(TrackDescriptor(id: 9, name: "Signs")).title, "Signs")
    }

    func testAudioRowText() {
        let a = TrackDescriptor(id: 1, codec: "eac3", language: "eng", channels: 6, isDefault: true, isAtmos: true)
        XCTAssertEqual(TrackLabels.audio(a).title, "English")
        XCTAssertEqual(TrackLabels.audio(a).detail, "Dolby Digital Plus 5.1 Atmos · Default")
    }
}

final class SubtitleChoiceTests: XCTestCase {
    private let tracks = [
        TrackDescriptor(id: 1, codec: "subrip", language: "eng", isForced: true),
        TrackDescriptor(id: 2, codec: "subrip", language: "eng", isHearingImpaired: true),
        TrackDescriptor(id: 3, codec: "subrip", language: "eng"),
        TrackDescriptor(id: 4, codec: "subrip", language: "eng", isCommentary: true),
        TrackDescriptor(id: 5, codec: "ass", language: "spa"),
    ]

    func testSavedOffWins() {
        XCTAssertEqual(SubtitleChooser.decide(tracks: tracks, saved: .off, defaultLanguage: "en"), .off)
    }

    func testSavedLanguagePicksFullDialogueTrack() {
        XCTAssertEqual(SubtitleChooser.decide(tracks: tracks, saved: .language("eng"), defaultLanguage: nil), .track(3))
        XCTAssertEqual(SubtitleChooser.decide(tracks: tracks, saved: .language("spa"), defaultLanguage: nil), .track(5))
    }

    func testSavedLanguageMissingFallsBackToOff() {
        XCTAssertEqual(SubtitleChooser.decide(tracks: tracks, saved: .language("fra"), defaultLanguage: nil), .off)
    }

    func testDefaultLanguageUsedWhenNothingSaved() {
        XCTAssertEqual(SubtitleChooser.decide(tracks: tracks, saved: nil, defaultLanguage: "en"), .track(3))
        XCTAssertEqual(SubtitleChooser.decide(tracks: tracks, saved: nil, defaultLanguage: "fr"), .leaveAsIs)
        XCTAssertEqual(SubtitleChooser.decide(tracks: tracks, saved: nil, defaultLanguage: nil), .leaveAsIs)
    }

    func testBestFallsBackThroughHearingImpairedThenForced() {
        let onlyForcedAndSDH = [tracks[0], tracks[1]]
        XCTAssertEqual(SubtitleChooser.best(in: onlyForcedAndSDH, language: "en")?.id, 2)
        XCTAssertEqual(SubtitleChooser.best(in: [tracks[0]], language: "en")?.id, 1)
        XCTAssertNil(SubtitleChooser.best(in: [tracks[3]], language: "en"), "commentary is never picked")
    }

    func testPreferencesRoundTripAndDefaultLanguage() {
        let suite = UserDefaults(suiteName: "HomeReelTests-\(UUID().uuidString)")!
        let prefs = SubtitlePreferences(defaults: suite)
        XCTAssertNil(prefs.record(for: "show1"))
        prefs.save(.language("eng"), for: "show1")
        XCTAssertEqual(prefs.record(for: "show1"), .language("eng"))
        XCTAssertNil(prefs.record(for: "show2"))
        XCTAssertNil(prefs.defaultLanguage)
        suite.set("es", forKey: SubtitlePreferences.defaultLanguageKey)
        XCTAssertEqual(prefs.defaultLanguage, "es")
        suite.set("off", forKey: SubtitlePreferences.defaultLanguageKey)
        XCTAssertNil(prefs.defaultLanguage)
    }
}

extension SubtitleChoiceTests {
    func testPickingATrackWithoutALanguageRemembersNothing() {
        XCTAssertNil(SubtitleChoiceRecord.remembered(afterPicking: TrackDescriptor(id: 7, name: "Signs")))
        XCTAssertNil(SubtitleChoiceRecord.remembered(afterPicking: TrackDescriptor(id: 7, language: "und")))
        XCTAssertNil(SubtitleChoiceRecord.remembered(afterPicking: TrackDescriptor(id: 7, language: "")))
        XCTAssertEqual(SubtitleChoiceRecord.remembered(afterPicking: TrackDescriptor(id: 7, language: "eng")), .language("eng"))
    }

    func testForgettingAChoiceLetsTheSettingsDefaultApply() {
        let suite = UserDefaults(suiteName: "HomeReelTests-\(UUID().uuidString)")!
        let prefs = SubtitlePreferences(defaults: suite)
        prefs.save(.off, for: "show1")
        prefs.save(nil, for: "show1")
        XCTAssertNil(prefs.record(for: "show1"))
        XCTAssertEqual(SubtitleChooser.decide(tracks: tracks, saved: prefs.record(for: "show1"), defaultLanguage: "en"), .track(3),
                       "an unlabeled pick is not read as Off")
    }

    func testChoicesSavedByEarlierVersionsStillRead() {
        let suite = UserDefaults(suiteName: "HomeReelTests-\(UUID().uuidString)")!
        let prefs = SubtitlePreferences(defaults: suite)
        suite.set(Data(#"{"off":true}"#.utf8), forKey: "subtitleChoice.a")
        suite.set(Data(#"{"off":false,"language":"eng"}"#.utf8), forKey: "subtitleChoice.b")
        suite.set(Data(#"{"off":false,"language":null}"#.utf8), forKey: "subtitleChoice.c")   // what an unlabeled pick used to save
        suite.set(Data(#"{"off":false}"#.utf8), forKey: "subtitleChoice.d")
        XCTAssertEqual(prefs.record(for: "a"), .off)
        XCTAssertEqual(prefs.record(for: "b"), .language("eng"))
        XCTAssertNil(prefs.record(for: "c"), "the old unlabeled pick means no choice, not Off")
        XCTAssertNil(prefs.record(for: "d"))
    }
}

final class ExternalSubtitleTests: XCTestCase {
    func testOnlyTextSidecarsBecomeSpecs() throws {
        let json = #"""
        {"id":1,"key":"/library/parts/1/file.mkv","Stream":[
          {"id":10,"streamType":3,"codec":"srt","format":"srt","key":"/library/streams/10","displayTitle":"English (SRT External)","languageCode":"eng","forced":false},
          {"id":11,"streamType":3,"codec":"srt","key":"/library/streams/11","displayTitle":"Spanish","languageCode":"spa","hearingImpaired":true},
          {"id":12,"streamType":3,"codec":"vobsub","key":"/library/streams/12","languageCode":"fra"},
          {"id":13,"streamType":3,"codec":"srt","languageCode":"eng"},
          {"id":14,"streamType":2,"codec":"aac","key":"/library/streams/14"}
        ]}
        """#
        let part = try JSONDecoder().decode(PlexPart.self, from: Data(json.utf8))
        let specs = ExternalSubtitles.specs(for: part, client: makeClient())
        XCTAssertEqual(specs.count, 2, "no vobsub, no embedded (no key), no audio")
        XCTAssertEqual(specs[0].language, "eng")
        XCTAssertEqual(specs[0].url.path, "/library/streams/10")
        XCTAssertFalse(specs[0].url.absoluteString.contains("SECRET"), "the player sends the token as a header")
        XCTAssertTrue(specs[1].isHearingImpaired)
        XCTAssertEqual(specs[1].format, "srt")
    }
}
