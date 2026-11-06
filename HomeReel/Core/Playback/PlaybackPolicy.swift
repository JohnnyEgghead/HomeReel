import Foundation

/// Where to start and when something counts as watched. Plain rules, easy to test.
enum PlaybackPolicy {
    /// Resume only if the saved spot is meaningful: not the first 30 seconds, and not within the last 5% (the credits).
    static func resumePosition(for item: PlexItem) -> Double? {
        guard let duration = item.durationSeconds, duration > 0 else { return nil }
        let at = item.offsetSeconds
        guard at >= 30, at <= duration * 0.95 else { return nil }
        return at
    }

    /// Plex's own rule of thumb: 90% or more.
    static let watchedFraction = 0.9

    static func countsAsWatched(time: Double, duration: Double) -> Bool {
        duration > 0 && time / duration >= watchedFraction
    }

    /// Seconds a left or right press on the remote jumps.
    static let skipSeconds = 10.0

    /// Seconds between progress reports while playing.
    static let reportInterval: TimeInterval = 10

    // MARK: Swipe scrubbing

    /// How far one slow, full-width swipe on the remote's touch surface moves, as a share of the video.
    static let scrubFractionPerFullSwipe = 0.06
    /// Bounds on that distance in seconds: a short clip still moves a little, a long film is capped.
    static let scrubMinSpan = 45.0
    static let scrubMaxSpan = 420.0

    /// Seconds a slow full-width swipe covers for a video of this length.
    static func scrubSpan(duration: Double) -> Double {
        min(scrubMaxSpan, max(scrubMinSpan, duration * scrubFractionPerFullSwipe))
    }

    /// Extra reach for a quick flick. `speed` is in widths per second. Slow and medium swipes get no boost,
    /// so fine control stays easy; a hard flick gets up to 3x.
    static func scrubBoost(speed: Double) -> Double {
        1 + min(2, max(0, speed - 1) * 0.5)
    }

    /// One small step of a swipe: move `position` by this movement, scaled and clamped.
    /// Working in small steps (not from the start of the swipe) keeps the motion smooth when speed changes.
    static func scrubStep(position: Double, dx: Double, width: Double, boost: Double, duration: Double) -> Double {
        guard width > 0, duration > 0 else { return position }
        let next = position + dx / width * scrubSpan(duration: duration) * boost
        return min(max(0, next), max(0, duration - 1))
    }
}
