import XCTest

/// Presses the Siri Remote against a pretend Plex server (`-fixture`), so no real server or network is involved.
/// Fixture ids: movie 8217 (The Quiet Street), show 1002 (Harbor Lights), season 1003, episode 1004 (First Light).
final class AppFlowTests: XCTestCase {
    private func launch(_ fixture: String, _ args: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-fixture", fixture, "-mute", "1"] + args
        app.launch()
        return app
    }

    private func wait(_ e: XCUIElement, _ seconds: TimeInterval = 15, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.waitForExistence(timeout: seconds), msg.isEmpty ? "missing \(e)" : msg, file: file, line: line)
    }

    // MARK: Sign in and connection states

    func testSignedOutShowsSignInOptions() {
        let app = launch("signedout")
        wait(app.buttons["Sign In with a Code"])
        wait(app.buttons["Enter Server Address and Token"])
    }

    func testSignInWithCodeShowsCodeThenHome() {
        let app = launch("signedout")
        wait(app.buttons["Sign In with a Code"])
        XCUIRemote.shared.press(.select)
        wait(app.staticTexts["ABCD"], 10, "the link code should appear")
        wait(app.staticTexts["Continue Watching"], 30, "after the code is approved, Home appears")
    }

    func testRejectedLoginReturnsToSignIn() {
        let app = launch("unauthorized")
        wait(app.buttons["Sign In with a Code"])
        wait(text(app, containing: "did not accept"), 5, "the sign-in screen should say why it came back")
    }

    func testOfflineShowsRetryAndSignOut() {
        let app = launch("offline")
        wait(app.staticTexts["Could not connect"])
        wait(app.buttons["Try Again"])
        wait(app.buttons["Sign Out"])
    }

    // MARK: Home and libraries

    func testHomeShowsShelves() {
        let app = launch("normal")
        wait(app.staticTexts["Continue Watching"])
        wait(app.staticTexts["Recently Added Movies"])
        wait(app.staticTexts["Recently Added TV Shows"])
    }

    func testMoviesGridHasSortAndFilter() {
        let app = launch("normal", ["-tab", "movies"])
        wait(app.staticTexts["Movies"])
        wait(app.staticTexts["Sort: Title"])
        wait(app.buttons["All"])
    }

    func testSortMenuChangesLabel() {
        let app = launch("normal", ["-tab", "movies"])
        wait(app.staticTexts["Sort: Title"])
        XCUIRemote.shared.press(.down)         // onto Sort
        XCUIRemote.shared.press(.select)       // open the menu
        sleep(1)
        XCUIRemote.shared.press(.down)         // Date Added
        XCUIRemote.shared.press(.select)
        wait(app.staticTexts["Sort: Date Added"])
    }

    func testEmptyServerShowsNoLibraryMessage() {
        let app = launch("empty", ["-tab", "movies"])
        wait(app.staticTexts["No library found"])
    }

    func testLibraryErrorShowsRetry() {
        let app = launch("libraryerror", ["-tab", "movies"])
        wait(app.staticTexts["Could not load the library"])
        wait(app.buttons["Try Again"])
    }

    func testHomeErrorShowsRetry() {
        let app = launch("libraryerror")
        wait(app.staticTexts["Could not load Home"])
        wait(app.buttons["Try Again"])
    }

    // MARK: Details and navigation

    func testMovieDetailHasPlayAndWatchedButtons() {
        let app = launch("normal", ["-open", "8217"])
        wait(app.buttons["Play"])
        XCTAssertTrue(app.buttons["Mark Watched"].exists || app.buttons["Mark Unwatched"].exists)
    }

    func testShowDetailListsSeasons() {
        let app = launch("normal", ["-open", "1002"])
        wait(app.staticTexts["Harbor Lights"])
        wait(app.staticTexts["Seasons"])
    }

    func testSeasonListsEpisodes() {
        let app = launch("normal", ["-open", "1003"])
        wait(app.staticTexts["Season 1"])
        wait(app.buttons.matching(NSPredicate(format: "label CONTAINS 'First Light'")).firstMatch)
    }

    func testChoosingTVShowsTabFromAnEpisodeShowsTheShowList() {
        let app = launch("normal", ["-open", "1003", "-autoepisode", "1"])
        wait(app.buttons["Play"])                   // on the episode page
        XCUIRemote.shared.press(.up)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)             // TV Shows
        XCUIRemote.shared.press(.select)
        wait(app.staticTexts["TV Shows"])
        XCTAssertFalse(app.buttons["Play"].exists, "the episode page should be gone")
    }

    // MARK: Ratings, crew, and people

    private func text(_ app: XCUIApplication, containing s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    func testMoviePageShowsAllFourRatings() {
        let app = launch("normal", ["-open", "8217"])
        wait(app.buttons["Play"])
        for source in ["RT Critics", "RT Audience", "TMDB", "IMDb"] {
            wait(text(app, containing: source), 10, "missing \(source) rating")
        }
    }

    func testEpisodePageShowsImdbAndTmdbButNoRottenTomatoes() {
        let app = launch("normal", ["-open", "1003", "-autoepisode", "1"])
        wait(app.buttons["Play"])
        wait(text(app, containing: "IMDb"))
        wait(text(app, containing: "TMDB"))
        XCTAssertFalse(text(app, containing: "RT Critics").exists)
    }

    func testMoviePageListsCastAndCrew() {
        let app = launch("normal", ["-open", "8217"])
        wait(app.buttons["Play"])
        wait(app.staticTexts["Cast"])
        wait(app.staticTexts["Crew"])
    }

    func testSelectingACastMemberOpensTheirPage() {
        let app = launch("normal", ["-open", "8217"])
        wait(app.buttons["Play"])
        let member = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fabio Ashby'")).firstMatch
        wait(member)
        func waitForFocus(_ label: String) {
            let focusedNow = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND label CONTAINS %@", label)).firstMatch
            XCTAssertTrue(focusedNow.waitForExistence(timeout: 10), "focus should reach \(label)")
        }
        // A page opened by the `-open` launch option starts with focus on the tab bar, so Play comes first.
        XCUIRemote.shared.press(.down)
        waitForFocus("Play")
        XCUIRemote.shared.press(.down)              // from the buttons to the cast row
        waitForFocus("Fabio Ashby")
        XCUIRemote.shared.press(.select)
        wait(text(app, containing: "Fictional biography"), 20, "the biography should appear")
        wait(text(app, containing: "Born March 4, 1971"))
    }

    func testLongBiographyCanBeScrolledBackToTheTop() {
        let app = launch("longbio", ["-open", "8217", "-person", "1"])
        wait(text(app, containing: "Paragraph 1."), 20)
        func focused(_ predicate: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND " + predicate)).firstMatch
        }
        // The name is on the page behind the sheet too, and that copy is never on screen, so ask whether any copy is.
        func nameIsOnScreen() -> Bool {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Zane Castellan'")).allElementsBoundByIndex
                .contains { $0.isHittable && $0.frame.minY >= 0 }
        }
        for _ in 0..<3 where !focused("label CONTAINS 'Paragraph 1.'").exists { XCUIRemote.shared.press(.down); sleep(1) }
        XCUIRemote.shared.press(.select)
        wait(app.staticTexts["Zane Castellan"], 10, "the biography sheet opens, with the name at the top")
        sleep(1)
        XCTAssertTrue(nameIsOnScreen(), "the sheet starts with the name on the screen")
        // Down through the whole biography to the last piece.
        for _ in 0..<80 {
            if focused("label CONTAINS 'Paragraph 12.'").exists { break }
            XCUIRemote.shared.press(.down); usleep(250_000)
        }
        // The last paragraph is long, so it is in more than one piece. Keep going to the very last.
        for _ in 0..<4 { XCUIRemote.shared.press(.down); usleep(250_000) }
        sleep(1)
        XCTAssertFalse(nameIsOnScreen(), "scrolled down, the name is off the screen")
        // Back up: the name must come back into view.
        for _ in 0..<80 {
            if focused("label == 'Zane Castellan'").exists { break }
            XCUIRemote.shared.press(.up); usleep(250_000)
        }
        sleep(1)
        XCTAssertTrue(focused("label == 'Zane Castellan'").exists, "Up reaches the name again")
        XCTAssertTrue(nameIsOnScreen(), "and the name is back on the screen")
    }

    func testPersonPageShowsLibraryKnownForAndCredits() {
        let app = launch("normal", ["-open", "8217", "-person", "1"])
        wait(text(app, containing: "Fictional biography"), 20)
        wait(app.staticTexts["In Your Library"])
        wait(text(app, containing: "Known For"))
        wait(text(app, containing: "Actor ("))
    }

    func testPersonPageFindsOwnedTitlesEvenWhenTheRoleRecordFindsNone() {
        // The same name as a writer and as a director can be separate records on the server.
        let app = launch("rolemiss", ["-open", "8217", "-person", "1"])
        wait(app.staticTexts["In Your Library"], 20, "owned titles come from matching the person's online credits")
        wait(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Harbor Lights'")).firstMatch)
    }

    func testPersonPageSurvivesOnlineLookupFailure() {
        let app = launch("discovererror", ["-open", "8217", "-person", "1"])
        wait(text(app, containing: "Could not reach Plex's online database"), 20)
        wait(app.buttons["Try Again"])
        wait(app.staticTexts["In Your Library"])
    }

    // MARK: Episode lists and the end of an episode

    func testEpisodeListShowsScoresForEachEpisode() {
        let app = launch("normal", ["-open", "1003"])
        wait(text(app, containing: "IMDb"), 20, "the pilot has an IMDb score once season details load")
        XCTAssertGreaterThanOrEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS 'TMDB'")).count, 2, "every episode shows a TMDB score")
    }

    func testEndOfEpisodeOffersTheNextEpisode() {
        let app = launch("normal", ["-open", "1003", "-autoepisode", "1", "-autoplay", "1", "-showend", "1"])
        wait(app.staticTexts["Up Next"], 20)
        wait(app.staticTexts["Second Wind"])
        wait(app.buttons["Play Next Episode"])
        wait(app.buttons["Episode List"])
    }

    func testPlayNextEpisodeMovesOn() {
        let app = launch("normal", ["-open", "1003", "-autoepisode", "1", "-autoplay", "1", "-showend", "1"])
        wait(app.buttons["Play Next Episode"], 20)
        XCUIRemote.shared.press(.select)
        wait(app.staticTexts["Third Door"], 20, "after the next episode, the screen offers the one after it")
    }

    func testFailedNextEpisodeLookupIsNotCalledTheLastEpisode() {
        let app = launch("normal", ["-open", "1003", "-autoepisode", "1", "-autoplay", "1", "-showend", "1", "-nextfail", "1"])
        wait(app.staticTexts["Could not find the next episode"], 20)
        XCTAssertFalse(app.staticTexts["That was the last episode"].exists)
        wait(app.buttons["Try Again"])
        XCUIRemote.shared.press(.select)
        wait(app.staticTexts["Up Next"], 20, "a retry that works shows the next episode")
    }

    func testAWatchedMarkThatCannotBeSavedSaysSo() {
        let app = launch("watcherror", ["-open", "1003", "-autoepisode", "1", "-autoplay", "1", "-showend", "1"])
        wait(app.buttons["Play Next Episode"], 20)
        XCUIRemote.shared.press(.menu)
        wait(app.staticTexts["Season 1"], 10, "leaving never waits on the network")
        wait(text(app, containing: "as watched"), 20, "after the tries run out, a message says what happened")
    }

    func testPersonPageSaysWhenItCouldNotReadYourLibrary() {
        let app = launch("libraryerror", ["-open", "8217", "-person", "1"])
        wait(text(app, containing: "Could not read your library"), 20)
    }

    func testMenuAfterAnEpisodeEndsShowsTheEpisodeList() {
        let app = launch("normal", ["-open", "1003", "-autoepisode", "1", "-autoplay", "1", "-showend", "1"])
        wait(app.buttons["Play Next Episode"], 20)
        XCUIRemote.shared.press(.menu)
        wait(app.staticTexts["Season 1"], 20)
        wait(app.buttons.matching(NSPredicate(format: "label CONTAINS 'First Light'")).firstMatch)
        XCTAssertFalse(app.buttons["Play Next Episode"].exists)
    }

    func testPersonWorkIsAList() {
        let app = launch("normal", ["-open", "8217", "-person", "1"])
        wait(text(app, containing: "Actor ("), 20)
        for _ in 0..<5 { XCUIRemote.shared.press(.down); sleep(1) }     // bio, library, known for, the role filter, then the first row
        // A list row reads as one button: title, type, year, and role.
        wait(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Paper Summit' AND label CONTAINS 'as Lucian Brandt'")).firstMatch)
    }

    func testTitleNotInLibraryShowsTheFullDescriptionAndCast() {
        let app = launch("normal", ["-open", "8217", "-person", "1"])
        wait(text(app, containing: "Actor ("), 20)
        for _ in 0..<5 { XCUIRemote.shared.press(.down); sleep(1) }
        XCUIRemote.shared.press(.select)
        wait(app.staticTexts["Not in your library"], 10)
        wait(text(app, containing: "A tired surveyor and a runaway cartographer"), 10, "the description")
        wait(text(app, containing: "what it costs them."), 10, "the whole description, not a cut")
        wait(app.staticTexts["Cast"])
        wait(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Ada Fenwick'")).firstMatch)
        XCUIRemote.shared.press(.menu)
        wait(text(app, containing: "Actor ("), 10, "Menu goes back to the person's page")
    }

    func testCastMemberOfATitleYouDoNotOwnOpensTheirPage() {
        let app = launch("normal", ["-open", "8217", "-person", "1"])
        wait(text(app, containing: "Actor ("), 20)
        for _ in 0..<5 { XCUIRemote.shared.press(.down); sleep(1) }
        XCUIRemote.shared.press(.select)
        wait(app.staticTexts["Not in your library"], 10)
        let ada = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Ada Fenwick'")).firstMatch
        wait(ada)
        for _ in 0..<6 where !ada.hasFocus { XCUIRemote.shared.press(.down); sleep(1) }
        XCTAssertTrue(ada.hasFocus, "could not focus the cast member")
        XCUIRemote.shared.press(.select)
        wait(text(app, containing: "Fictional biography"), 20, "the person's online page opens")
        XCTAssertFalse(text(app, containing: "has no online page").exists)
    }

    func testTitleNotInLibrarySaysWhenTheDetailsFailedToLoad() {
        let app = launch("detailerror", ["-open", "8217", "-person", "1"])
        wait(text(app, containing: "Actor ("), 20)
        for _ in 0..<5 { XCUIRemote.shared.press(.down); sleep(1) }
        XCUIRemote.shared.press(.select)
        wait(app.staticTexts["Not in your library"], 10)
        wait(text(app, containing: "Could not load the details"), 10)
        wait(app.buttons["Try Again"])
    }

    func testRoleFilterNarrowsTheFilmography() {
        let app = launch("normal", ["-open", "8217", "-person", "1"])
        wait(text(app, containing: "Actor ("), 20)
        wait(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All ('")).firstMatch)
        let writer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Writer ('")).firstMatch
        wait(writer)
        let writerLabel = writer.label     // "Writer (N)": the list heading reads the same
        // Down to the filter row (the focus is never assumed: bio, library, and known for come first). It lands on
        // whichever chip is nearest the poster above, so then move sideways until Writer has focus.
        let chips = ["All (", "Actor (", "Writer (", "Appearances (", "Producer ("]
        func onChip() -> Bool { chips.contains { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", $0)).firstMatch.hasFocus } }
        for _ in 0..<8 where !onChip() { XCUIRemote.shared.press(.down); sleep(1) }
        for _ in 0..<6 where !writer.hasFocus { XCUIRemote.shared.press(.left); sleep(1) }
        for _ in 0..<6 where !writer.hasFocus { XCUIRemote.shared.press(.right); sleep(1) }
        XCTAssertTrue(writer.hasFocus, "could not focus the Writer button")
        XCUIRemote.shared.press(.select)
        wait(app.staticTexts[writerLabel], 10, "the Writer list stays")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Actor ('")).firstMatch.waitForExistence(timeout: 2),
                       "the other roles go away")
    }

    func testTitleNotInLibraryOpensItsPage() {
        let app = launch("normal", ["-open", "8217", "-person", "1"])
        wait(text(app, containing: "Actor ("), 20)
        for _ in 0..<5 { XCUIRemote.shared.press(.down); sleep(1) }     // down to the first row of Actor
        XCUIRemote.shared.press(.select)
        wait(app.staticTexts["Not in your library"], 10)
    }

    // MARK: Scanning for new files

    private func pressScanButton(_ app: XCUIApplication) {
        wait(app.staticTexts["Sort: Title"])
        wait(app.buttons["Scan Library"])
        XCUIRemote.shared.press(.down)         // onto Sort
        XCUIRemote.shared.press(.right)        // All
        XCUIRemote.shared.press(.right)        // Scan Library
        XCUIRemote.shared.press(.select)
    }

    func testMoviesScanShowsProgressThenFinished() {
        let app = launch("normal", ["-tab", "movies"])
        pressScanButton(app)
        wait(app.staticTexts["Scan finished"], 20)
    }

    func testTVShowsHaveTheScanButtonToo() {
        let app = launch("normal", ["-tab", "shows"])
        pressScanButton(app)
        wait(app.staticTexts["Scan finished"], 20)
    }

    func testFailedScanSaysSo() {
        let app = launch("scanerror", ["-tab", "movies"])
        pressScanButton(app)
        wait(text(app, containing: "Scan failed"), 20)
    }

    // MARK: Home menus, TV sorts, episode Menu, info panel

    /// Down from the tab bar, then left or right until the Continue Watching card with this label has focus.
    private func focusContinueCard(_ app: XCUIApplication, _ label: String) {
        wait(app.staticTexts["Continue Watching"])
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        wait(card)
        XCUIRemote.shared.press(.down)
        sleep(1)
        for _ in 0..<4 where !card.hasFocus { XCUIRemote.shared.press(.right); sleep(1) }
        for _ in 0..<4 where !card.hasFocus { XCUIRemote.shared.press(.left); sleep(1) }
        XCTAssertTrue(card.hasFocus, "could not focus the card \(label)")
    }

    private func buttonLabeled(_ app: XCUIApplication, _ s: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    /// Menu items (hold menu, Sort menu) are not buttons in the accessibility tree, so look for any element.
    private func item(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// A menu opens with its first row highlighted (the accessibility tree does not say which row is highlighted,
    /// so count rows). Checks the row is there, moves down to it, and presses Select.
    private func chooseMenuItem(_ app: XCUIApplication, _ label: String, row: Int, file: StaticString = #filePath, line: UInt = #line) {
        wait(item(app, label), 10, "menu item \(label) missing", file: file, line: line)
        for _ in 0..<row { XCUIRemote.shared.press(.down); usleep(500_000) }
        XCUIRemote.shared.press(.select)
    }

    func testHoldingAMovieInContinueWatchingOffersFourChoices() {
        let app = launch("normal")
        focusContinueCard(app, "Copper Lantern")
        XCUIRemote.shared.press(.select, forDuration: 1.2)
        wait(item(app, "Resume"), 10)
        wait(item(app, "Start from Beginning"))
        wait(item(app, "Mark Watched"))
        wait(item(app, "Mark Unwatched"))
    }

    func testMarkingAMovieUnwatchedRemovesItFromContinueWatching() {
        let app = launch("normal")
        wait(buttonLabeled(app, "Copper Lantern"))
        focusContinueCard(app, "Copper Lantern")
        XCUIRemote.shared.press(.select, forDuration: 1.2)
        chooseMenuItem(app, "Mark Unwatched", row: 3)
        // Copper Lantern is also on the Recently Added Movies shelf, so one card should be left, not none.
        let cards = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Copper Lantern'"))
        let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: cards)
        XCTAssertEqual(XCTWaiter().wait(for: [e], timeout: 15), .completed, "Copper Lantern should leave Continue Watching")
    }

    func testHoldingAnEpisodeInContinueWatchingOffersSeriesSeasonRemoveAndPlay() {
        let app = launch("normal")
        focusContinueCard(app, "Harbor Lights, S1 E1")
        XCUIRemote.shared.press(.select, forDuration: 1.2)
        wait(item(app, "Open Series"), 10)
        wait(item(app, "Open Season"))
        wait(item(app, "Remove from Continue Watching"))
        wait(item(app, "Resume"), 5, "this episode is part way through, so Play Episode reads Resume")
    }

    func testRemovingAnEpisodeFromContinueWatching() {
        let app = launch("normal")
        focusContinueCard(app, "Harbor Lights, S1 E1")
        XCUIRemote.shared.press(.select, forDuration: 1.2)
        chooseMenuItem(app, "Remove from Continue Watching", row: 2)
        let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                          object: app.buttons.matching(NSPredicate(format: "label CONTAINS 'First Light'")).firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [e], timeout: 15), .completed, "the episode should leave Continue Watching")
    }

    func testOpenSeasonFromTheHoldMenuShowsTheEpisodeList() {
        let app = launch("normal")
        focusContinueCard(app, "Harbor Lights, S1 E1")
        XCUIRemote.shared.press(.select, forDuration: 1.2)
        chooseMenuItem(app, "Open Season", row: 1)
        wait(app.staticTexts["Season 1"], 20)
    }

    func testOpenSeriesFromTheHoldMenuShowsTheShowPage() {
        let app = launch("normal")
        focusContinueCard(app, "Harbor Lights, S1 E1")
        XCUIRemote.shared.press(.select, forDuration: 1.2)
        chooseMenuItem(app, "Open Series", row: 0)
        wait(app.staticTexts["Harbor Lights"], 20)
        wait(app.staticTexts["Seasons"])
    }

    func testTVSortOffersRecentlyAiredEpisode() {
        let app = launch("normal", ["-tab", "shows"])
        wait(app.staticTexts["Sort: Title"])
        XCUIRemote.shared.press(.down)         // the TV Shows tab sits over the middle button
        XCUIRemote.shared.press(.left)         // onto Sort
        sleep(1)
        XCUIRemote.shared.press(.select)       // open the menu
        chooseMenuItem(app, "Recently Aired Episode", row: 2)
        wait(app.staticTexts["Sort: Recently Aired Episode"])
    }

    func testMovieSortHasNoRecentlyAiredEpisode() {
        let app = launch("normal", ["-tab", "movies"])
        wait(app.staticTexts["Sort: Title"])
        XCUIRemote.shared.press(.down)         // onto Sort
        XCUIRemote.shared.press(.select)       // open the menu
        wait(item(app, "Date Added"), 10)
        XCTAssertFalse(item(app, "Recently Aired Episode").exists)
    }

    func testMenuOnAnEpisodeOpenedFromHomeGoesToTheSeasonList() {
        // -open pushes the episode the way Home or Search would, not from its season list.
        let app = launch("normal", ["-open", "1004"])
        wait(app.buttons["Play"], 20)
        XCUIRemote.shared.press(.down)         // from the tab bar into the page
        sleep(1)
        XCUIRemote.shared.press(.menu)
        wait(app.staticTexts["Season 1"], 20)
        wait(app.buttons.matching(NSPredicate(format: "label CONTAINS 'First Light'")).firstMatch)
    }

    func testMenuOnAMoviePageStillGoesBackOnePage() {
        let app = launch("normal", ["-open", "8217"])
        wait(app.buttons["Play"], 20)
        XCUIRemote.shared.press(.down)         // from the tab bar into the page
        sleep(1)
        XCUIRemote.shared.press(.menu)
        wait(app.staticTexts["Continue Watching"], 10, "Menu on a movie page should go back to Home")
    }

    func testMenuOnAnEpisodeOpenedFromItsSeasonListGoesBackToTheList() {
        let app = launch("normal", ["-open", "1003", "-autoepisode", "1"])
        wait(app.buttons["Play"], 20)
        XCUIRemote.shared.press(.down)         // from the tab bar into the page
        sleep(1)
        XCUIRemote.shared.press(.menu)
        wait(app.staticTexts["Season 1"], 20)
    }

    func testInfoPanelCanScrollBackUpToTheDescription() {
        let app = launch("normal", ["-open", "8217", "-autoplay", "1", "-showpanel", "1"])
        wait(app.staticTexts["Cast"], 20)
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'A quiet town discovers'")).firstMatch
        wait(summary)
        let person = app.buttons.matching(NSPredicate(format: "label CONTAINS ','")).firstMatch
        XCUIRemote.shared.press(.down)                       // description -> cast
        sleep(1)
        XCTAssertTrue(person.hasFocus || app.buttons.matching(NSPredicate(format: "hasFocus == true")).count >= 1, "focus reaches the cast")
        XCUIRemote.shared.press(.up)                         // back up
        sleep(1)
        XCTAssertTrue(summary.hasFocus, "the description is reachable again")
    }

    func testSelectingAPersonInTheInfoPanelOpensTheirPage() {
        let app = launch("normal", ["-open", "8217", "-autoplay", "1", "-showpanel", "1"])
        wait(app.staticTexts["Cast"], 20)
        sleep(1)
        XCUIRemote.shared.press(.down)           // from the description to the first person
        sleep(1)
        XCUIRemote.shared.press(.select)
        wait(text(app, containing: "Known For"), 20, "their page opens over the video")
    }

    // MARK: TV picture mode

    private func openPicturePanel(_ fixture: String = "normal", key: String? = "fixture-key") -> XCUIApplication {
        launch(fixture, ["-open", "8217", "-autoplay", "1", "-showpanel", "picture", "-tv", "on"] + (key.map { ["-tvkey", $0] } ?? []))
    }

    func testPictureTabListsTheTVsModesAndMarksTheCurrentOne() {
        let app = openPicturePanel()
        wait(text(app, containing: "TV picture mode: Dolby Vision Bright"), 20)
        wait(item(app, "Dolby Vision Dark"))
        wait(item(app, "Dolby Vision Bright"))
    }

    func testChoosingDolbyVisionDarkChangesTheTV() {
        let app = openPicturePanel()
        wait(item(app, "Dolby Vision Dark"), 20)
        XCUIRemote.shared.press(.down)         // first row is Dark
        sleep(1)
        XCUIRemote.shared.press(.select)
        wait(text(app, containing: "TV picture mode: Dolby Vision Dark"), 20, "the panel shows what the TV reports after the change")
    }

    func testPictureTabSaysWhenTheTVIsOff() {
        let app = openPicturePanel("tvoff")
        wait(text(app, containing: "Could not reach the TV"), 20)
    }

    func testPictureTabSaysWhenTheTVIsAsleep() {
        let app = openPicturePanel("tvasleep")
        wait(text(app, containing: "off or asleep"), 20)
    }

    func testPictureTabWithoutAKeyPointsToSettings() {
        let app = openPicturePanel(key: nil)
        wait(text(app, containing: "add the TV's key in Settings"), 20)
    }

    func testTVControlIsOffByDefaultAndHidesItsFields() {
        let app = launch("normal", ["-tab", "settings"])
        wait(item(app, "Control a Sony TV's picture mode"), 20)
        for _ in 0..<2 { XCUIRemote.shared.press(.down); usleep(500_000) }      // scroll the TV section into view
        wait(item(app, "Control a Sony TV's picture mode"), 10)
        XCTAssertFalse(app.buttons["Save and Test"].exists, "address and key are hidden while TV control is off")
    }

    func testTurningTVControlOnShowsItsFields() {
        let app = launch("normal", ["-tab", "settings"])
        wait(item(app, "Control a Sony TV's picture mode"), 20)
        for _ in 0..<2 { XCUIRemote.shared.press(.down); usleep(500_000) }     // subtitle picker, then the TV switch
        XCUIRemote.shared.press(.select)
        wait(app.buttons["Save and Test"], 10)
    }

    func testPictureTabIsHiddenWhenTVControlIsOff() {
        let app = launch("normal", ["-open", "8217", "-autoplay", "1", "-showpanel", "1"])
        wait(app.staticTexts["Cast"], 20)
        XCTAssertTrue(app.buttons["Subtitles"].exists || item(app, "Subtitles").exists)
        XCTAssertFalse(item(app, "Picture").exists, "no Picture tab unless TV control is on")
    }

    func testSearchShowsResultShelves() {
        let app = launch("normal", ["-tab", "search", "-query", "the"])
        let any = app.staticTexts["Movies"].exists || app.staticTexts["TV Shows"].waitForExistence(timeout: 15)
        XCTAssertTrue(any || app.staticTexts["Movies"].waitForExistence(timeout: 15))
    }

    // MARK: Settings and sign out

    func testSettingsShowsServerAndSignOutReturnsToSignIn() {
        let app = launch("normal", ["-tab", "settings"])
        wait(app.staticTexts["Name, Fixture NAS"])
        wait(app.buttons["Sign Out"])
        // From the tab bar: subtitle picker, TV switch (off by default), then Sign Out.
        for _ in 0..<3 { XCUIRemote.shared.press(.down); usleep(500_000) }
        XCUIRemote.shared.press(.select)            // opens the "Sign out of this server?" dialog
        sleep(2)                                    // the dialog appears
        XCUIRemote.shared.press(.right)             // Cancel has focus first; Sign Out is to its right
        XCUIRemote.shared.press(.select)
        wait(app.buttons["Sign In with a Code"], 15, "signing out returns to the sign-in screen")
    }
}
