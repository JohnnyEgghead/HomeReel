import XCTest

/// Drives the real remote path (season list, then an episode) against the live server and saves a screenshot.
/// Developer check only: needs TEST_RUNNER_HR_LIVE_TOKEN and TEST_RUNNER_HR_LIVE_SERVER in the environment and a reachable server.
final class NavigationShotTests: XCTestCase {
    func testOpenEpisodeFromSeasonList() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["HR_LIVE_TOKEN"] == nil, "live check not requested")
        let app = XCUIApplication()
        app.launchEnvironment["HR_TOKEN"] = env["HR_LIVE_TOKEN"]
        app.launchEnvironment["HR_SERVER"] = env["HR_LIVE_SERVER"] ?? "http://192.168.1.10:32400"
        app.launchArguments = ["-open", env["HR_LIVE_SEASON"] ?? "1003", "-mute", "1"]
        app.launch()
        sleep(8)
        XCUIRemote.shared.press(.down)        // from the tab bar into the list
        sleep(2)
        XCUIRemote.shared.press(.select)      // first episode in the season list
        sleep(12)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: URL(fileURLWithPath: env["HR_SHOT_PATH"] ?? "/tmp/episode-from-list.png"))
    }

    /// Developer check: open a tab, move focus with the given presses (for example "down,right"), save a screenshot.
    func testFocusScreenshot() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["HR_FOCUS_TAB"] == nil, "focus shot not requested")
        let app = XCUIApplication()
        app.launchEnvironment["HR_TOKEN"] = env["HR_LIVE_TOKEN"]
        app.launchEnvironment["HR_SERVER"] = env["HR_LIVE_SERVER"] ?? "http://192.168.1.10:32400"
        app.launchArguments = ["-tab", env["HR_FOCUS_TAB"] ?? "movies", "-mute", "1"]
        if let open = env["HR_FOCUS_OPEN"] { app.launchArguments += ["-open", open] }
        if let extra = env["HR_FOCUS_EXTRA"] { app.launchArguments += extra.split(separator: " ").map(String.init) }
        if env["HR_FOCUS_AUTOEP"] != nil { app.launchArguments += ["-autoepisode", "1"] }
        if env["HR_FOCUS_AUTOPLAY"] != nil { app.launchArguments += ["-autoplay", "1"] }
        if let start = env["HR_FOCUS_STARTAT"] { app.launchArguments += ["-startat", start] }
        app.launch()
        sleep(9)
        for press in (env["HR_FOCUS_PRESSES"] ?? "down").split(separator: ",") {
            switch press {
            case "down": XCUIRemote.shared.press(.down)
            case "up": XCUIRemote.shared.press(.up)
            case "left": XCUIRemote.shared.press(.left)
            case "right": XCUIRemote.shared.press(.right)
            case "select": XCUIRemote.shared.press(.select)
            case "menu": XCUIRemote.shared.press(.menu)
            case "wait": sleep(6)
            default: break
            }
            sleep(1)
        }
        sleep(2)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: URL(fileURLWithPath: env["HR_SHOT_PATH"] ?? "/tmp/focus.png"))
    }
}
