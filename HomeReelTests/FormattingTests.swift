import XCTest
@testable import HomeReel

final class FormattingTests: XCTestCase {
    func testRuntime() {
        XCTAssertEqual(Fmt.runtime(ms: 7_246_953), "2h 0m")
        XCTAssertEqual(Fmt.runtime(ms: 2_820_000), "47m")
        XCTAssertNil(Fmt.runtime(ms: nil))
        XCTAssertNil(Fmt.runtime(ms: 0))
    }

    func testAudioLabels() {
        XCTAssertEqual(Fmt.audioLabel(codec: "eac3", channels: 6), "Dolby Digital Plus 5.1")
        XCTAssertEqual(Fmt.audioLabel(codec: "truehd", channels: 8), "Dolby TrueHD 7.1")
        XCTAssertEqual(Fmt.audioLabel(codec: "dca", channels: 6), "DTS 5.1")
        XCTAssertEqual(Fmt.audioLabel(codec: "aac", channels: 2), "AAC 2.0")
        XCTAssertEqual(Fmt.audioLabel(codec: "opus", channels: nil), "OPUS")
    }

    func testVideoLabels() {
        func s(dovi: Bool? = nil, trc: String? = nil) -> PlexStream {
            PlexStream(id: 1, streamType: 1, colorTrc: trc, DOVIPresent: dovi)
        }
        XCTAssertEqual(Fmt.videoLabel(s(dovi: true, trc: "smpte2084")), "Dolby Vision")
        XCTAssertEqual(Fmt.videoLabel(s(trc: "smpte2084")), "HDR10")
        XCTAssertEqual(Fmt.videoLabel(s(trc: "arib-std-b67")), "HLG")
        XCTAssertEqual(Fmt.videoLabel(s()), "SDR")
    }

    func testFileSummaryFromFixture() throws {
        let m = try Fixture.container("movie_detail").items[0]
        let line = try XCTUnwrap(Fmt.fileSummary(m))
        XCTAssertTrue(line.contains("·"))
        XCTAssertTrue(line.uppercased().contains(m.primaryMedia?.container?.uppercased() ?? "?"))
    }

    func testMetaLine() throws {
        let m = try Fixture.container("movie_detail").items[0]
        XCTAssertTrue(Fmt.metaLine(m).contains(String(m.year ?? 0)))
    }
}

final class AlphaIndexTests: XCTestCase {
    func testLettersAndNumbers() {
        XCTAssertEqual(AlphaIndex.letter(forTitle: "Q*R*S*T"), "Q")
        XCTAssertEqual(AlphaIndex.letter(forTitle: "30 Lanterns"), "#")
        XCTAssertEqual(AlphaIndex.letter(forTitle: "'Quiet"), "#")
        XCTAssertEqual(AlphaIndex.letter(forTitle: "  zorro"), "Z")
        XCTAssertEqual(AlphaIndex.letter(forTitle: ""), "#")
    }

    func testAccentsFoldToPlainLetter() {
        XCTAssertEqual(AlphaIndex.letter(forTitle: "Émile"), "E")
        XCTAssertEqual(AlphaIndex.letter(forTitle: "Ünited"), "U")
    }

    func testPlexSortTitleWinsOverTitle() throws {
        var item = try Fixture.container("movies").items[0]
        item.title = "The Abyss"
        item.titleSort = "Abyss"
        XCTAssertEqual(AlphaIndex.letter(for: item), "A", "a leading The is ignored by Plex's sort title")
        item.titleSort = nil
        XCTAssertEqual(AlphaIndex.letter(for: item), "T")
    }

    func testStripHasHashThenAtoZ() {
        XCTAssertEqual(AlphaIndex.letters.count, 27)
        XCTAssertEqual(AlphaIndex.letters.first, "#")
        XCTAssertEqual(AlphaIndex.letters[1], "A")
        XCTAssertEqual(AlphaIndex.letters.last, "Z")
    }
}
