import SwiftUI
import AetherEngine

/// Draws the active subtitle cues over the video: text and rich text, and bitmap pictures (PGS, VobSub, DVB).
struct SubtitleOverlay: View {
    @ObservedObject var feed: SubtitleFeed
    /// Lifts text subtitles when the on-screen controls are showing, so they do not overlap.
    var liftForControls = false

    var body: some View {
        GeometryReader { geo in
            let cues = feed.active
            ZStack {
                ForEach(cues) { cue in
                    switch cue.body {
                    case .image(let image):
                        BitmapCue(image: image, video: videoRect(in: geo.size, canvas: image.canvasSize))
                    case .text, .richText:
                        TextCue(cue: cue, size: geo.size, lift: liftForControls)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Where the picture is on screen: the video's shape fitted inside the screen.
    private func videoRect(in screen: CGSize, canvas: CGSize) -> CGRect {
        let v = feed.videoSize.width > 0 ? feed.videoSize : (canvas.width > 0 ? canvas : screen)
        guard v.width > 0, v.height > 0 else { return CGRect(origin: .zero, size: screen) }
        let scale = min(screen.width / v.width, screen.height / v.height)
        let w = v.width * scale, h = v.height * scale
        return CGRect(x: (screen.width - w) / 2, y: (screen.height - h) / 2, width: w, height: h)
    }
}

/// Maps a bitmap cue's normalized position onto the picture, the way the engine's own compositor does.
enum BitmapPlacement {
    static func rect(position: CGRect, canvas: CGSize, video: CGRect) -> CGRect {
        let fw = video.width, fh = video.height
        let local: CGRect
        if canvas == .zero || canvas.width <= 0 {
            local = CGRect(x: position.minX * fw, y: position.minY * fh, width: position.width * fw, height: position.height * fh)
        } else {
            let scale = fw / canvas.width
            local = CGRect(
                x: position.minX * canvas.width * scale,
                y: fh / 2 + (position.minY * canvas.height - canvas.height / 2) * scale,
                width: position.width * canvas.width * scale,
                height: position.height * canvas.height * scale
            )
        }
        return local.offsetBy(dx: video.minX, dy: video.minY)
    }
}

private struct BitmapCue: View {
    let image: SubtitleImage
    let video: CGRect
    var body: some View {
        let r = BitmapPlacement.rect(position: image.position, canvas: image.canvasSize, video: video)
        Image(decorative: image.cgImage, scale: 1)
            .resizable()
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
    }
}

private struct TextCue: View {
    let cue: SubtitleCue
    let size: CGSize
    let lift: Bool

    var body: some View {
        let alignment = cue.placement?.alignment ?? 2
        styledText
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: size.width * 0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: vertical(alignment))
            .padding(.top, alignment >= 7 ? 90 : 0)
            .padding(.bottom, alignment < 4 ? (lift ? 190 : 90) : 0)
    }

    private func vertical(_ a: Int) -> Alignment { a >= 7 ? .top : (a >= 4 ? .center : .bottom) }

    private var styledText: Text {
        switch cue.body {
        case .text(let s):
            return base(Text(s))
        case .richText(let runs):
            return runs.reduce(Text("")) { acc, run in
                var t = Text(run.text)
                if let c = run.color { t = t.foregroundColor(Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)) }
                if run.isBold { t = t.bold() }
                if run.isItalic { t = t.italic() }
                if run.isUnderlined { t = t.underline() }
                if run.isStruckThrough { t = t.strikethrough() }
                return acc + t
            }
            .font(.system(size: 44, weight: .semibold))
        case .image:
            return Text("")
        }
    }

    private func base(_ t: Text) -> Text { t.font(.system(size: 44, weight: .semibold)).foregroundColor(.white) }
}
