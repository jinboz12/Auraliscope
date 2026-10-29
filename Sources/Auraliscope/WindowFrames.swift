import CoreGraphics

/// Keeps a window reachable: a frame restored from an earlier launch, or left behind when a display was removed or
/// rearranged, is brought back onto a screen that exists now. A frame whose title bar can be grabbed on some screen
/// stays where it is (only shrunk to fit that screen); otherwise it moves, at the same size where that fits, to the
/// centre of the screen it overlaps most, or of the main screen.
enum WindowFrames {
    /// How much of the title bar has to be on a screen for the window to count as reachable.
    static let grabWidth: CGFloat = 120
    static let titleBarHeight: CGFloat = 28

    static func onScreen(_ frame: CGRect, visible screens: [CGRect], main: CGRect?) -> CGRect {
        guard !screens.isEmpty, frame.width > 0, frame.height > 0 else { return frame }
        let titleBar = CGRect(x: frame.minX, y: frame.maxY - titleBarHeight, width: frame.width, height: titleBarHeight)
        let best = screens.max { overlap(frame, $0) < overlap(frame, $1) }!
        let target = overlap(frame, best) > 0 ? best : (main ?? screens[0])
        let size = CGSize(width: min(frame.width, target.width), height: min(frame.height, target.height))
        if let grab = screens.first(where: { titleBar.intersection($0).width >= min(grabWidth, frame.width)
                                              && titleBar.intersection($0).height >= titleBarHeight / 2 }) {
            guard frame.width > grab.width || frame.height > grab.height else { return frame }
            // Shrunk to its screen, its top edge kept where it was, then nudged inside.
            var fitted = CGRect(x: frame.minX, y: frame.maxY - min(frame.height, grab.height),
                                width: min(frame.width, grab.width), height: min(frame.height, grab.height))
            fitted.origin.x = min(max(fitted.minX, grab.minX), grab.maxX - fitted.width)
            fitted.origin.y = min(max(fitted.minY, grab.minY), grab.maxY - fitted.height)
            return fitted
        }
        return CGRect(x: target.midX - size.width / 2, y: target.midY - size.height / 2, width: size.width, height: size.height)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }
}
