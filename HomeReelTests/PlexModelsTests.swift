import XCTest
@testable import HomeReel

final class PlexModelsTests: XCTestCase {
    func testSectionsKeepOnlyMoviesAndShows() throws {
        let dirs = try Fixture.container("sections").Directory ?? []
        XCTAssertEqual(dirs.count, 5)
        XCTAssertEqual(dirs.filter(\.isMovieLibrary).map(\.title), ["Movies"])
        XCTAssertEqual(dirs.filter(\.isShowLibrary).map(\.title), ["TV Shows"])
    }

    func testMoviesDecode() throws {
        let c = try Fixture.container("movies")
        XCTAssertEqual(c.items.count, 3)
        XCTAssertTrue(c.items.allSatisfy { $0.type == .movie })
        XCTAssertGreaterThan(c.totalSize ?? 0, 3)
        XCTAssertNotNil(c.items[0].posterPath)
    }

    func testShowsAndSeasonsAndEpisodesDecode() throws {
        let shows = try Fixture.container("shows").items
        XCTAssertTrue(shows.allSatisfy { $0.type == .show })
        XCTAssertNotNil(shows[0].leafCount)
        let seasonsContainer = try Fixture.container("seasons")
        XCTAssertTrue((seasonsContainer.Directory ?? []).isEmpty, "the 'All episodes' entry is not a library section")
        let seasons = seasonsContainer.items
        XCTAssertTrue(seasons.allSatisfy { $0.type == .season })
        let eps = try Fixture.container("episodes").items
        XCTAssertTrue(eps.allSatisfy { $0.type == .episode })
        XCTAssertEqual(eps[0].episodeCode, "S1 E1")
    }

    func testEpisodeUsesShowPosterAndEpisodeStill() throws {
        let ep = try Fixture.container("episodes").items[0]
        XCTAssertEqual(ep.posterPath, ep.grandparentThumb ?? ep.parentThumb ?? ep.thumb)
        XCTAssertNotNil(ep.landscapePath)
    }

    func testMovieDetailHasCastAndStreams() throws {
        let m = try Fixture.container("movie_detail").items[0]
        XCTAssertFalse((m.Role ?? []).isEmpty)
        let part = try XCTUnwrap(m.primaryPart)
        XCTAssertTrue(part.key.hasPrefix("/library/parts/"))
        XCTAssertTrue((part.Stream ?? []).contains { $0.streamType == 1 })
        XCTAssertTrue((part.Stream ?? []).contains { $0.streamType == 2 })
    }

    func testContinueWatchingDecodes() throws {
        let hubs = try Fixture.container("continue").Hub ?? []
        let items = hubs.flatMap(\.items)
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.contains { $0.progress != nil })
    }

    func testSearchHubsHaveTypes() throws {
        let hubs = try Fixture.container("search").Hub ?? []
        XCTAssertTrue(hubs.contains { $0.type == "movie" || $0.type == "show" })
    }

    func testWatchedLogic() {
        func item(_ type: PlexItemType, view: Int? = nil, offset: Int? = nil, leaf: Int? = nil, viewedLeaf: Int? = nil, duration: Int? = nil) -> PlexItem {
            var i = try! JSONDecoder().decode(PlexItem.self, from: Data(#"{"ratingKey":"1","type":"movie","title":"t"}"#.utf8))
            i.type = type; i.viewCount = view; i.viewOffset = offset; i.leafCount = leaf; i.viewedLeafCount = viewedLeaf; i.duration = duration
            return i
        }
        XCTAssertTrue(item(.movie, view: 1).isWatched)
        XCTAssertFalse(item(.movie, view: 1, offset: 5000).isWatched, "partly watched again is not watched")
        XCTAssertFalse(item(.movie).isWatched)
        XCTAssertTrue(item(.show, leaf: 10, viewedLeaf: 10).isWatched)
        XCTAssertFalse(item(.show, leaf: 10, viewedLeaf: 4).isWatched)
        XCTAssertEqual(item(.show, leaf: 10, viewedLeaf: 4).unwatchedCount, 6)
        XCTAssertEqual(try XCTUnwrap(item(.movie, offset: 500, duration: 1000).progress), 0.5, accuracy: 0.001)
        XCTAssertNil(item(.movie, duration: 1000).progress)
    }

    func testItemsWithSameKeyButDifferentWatchedStateAreNotEqual() throws {
        let a = try Fixture.container("movies").items[0]
        var b = a
        b.viewCount = (a.viewCount ?? 0) + 1
        XCTAssertNotEqual(a, b, "SwiftUI skips redrawing views whose input compares equal")
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertEqual(a.id, b.id)
    }

    func testUnknownTypeDoesNotBreakDecoding() throws {
        let json = #"{"MediaContainer":{"Metadata":[{"ratingKey":"9","type":"clip","title":"x"}]}}"#
        let c = try JSONDecoder().decode(PlexEnvelope<PlexContainer>.self, from: Data(json.utf8)).MediaContainer
        XCTAssertEqual(c.items.first?.type, .other)
    }
}
