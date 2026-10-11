import CoreGraphics
import Foundation

// The contract between the menu designer (which draws pages and buttons)
// and the menu author (which turns them into Blu-ray HDMV menus: an IGS
// stream, navigation commands, index.bdmv and MovieObject.bdmv). Neither
// side should need to know how the other works.
//
// Coordinates are pixels on the 1920×1080 frame, origin top-left.

/// A complete disc menu: one or more pages the viewer moves between.
struct DiscMenu: Sendable {
    var pages: [MenuPage]
    /// Page shown when the disc is inserted (after any first-play video).
    var firstPage: Int = 0
    /// Seconds of the menu background before it loops. A still menu uses a
    /// short loop of the same frame.
    var loopSeconds: Double = 30
}

struct MenuPage: Sendable {
    /// Full-frame background, 1920×1080, opaque. Becomes the menu clip's
    /// video, so it can be anything the encoder can draw.
    var background: CGImage
    var buttons: [MenuButton]
    /// Index into `buttons` selected when the page opens.
    var defaultButton: Int = 0
}

struct MenuButton: Sendable, Identifiable {
    var id: Int
    /// Where the button's images sit on the frame. Every state image has
    /// exactly this size.
    var rect: CGRect
    /// RGBA overlays drawn over the background. HDMV menus are palette
    /// based (256 colours per page, shared by every button), so keep each
    /// page's overlays to a modest number of colours with clean alpha.
    var normal: CGImage
    var selected: CGImage
    var activated: CGImage
    /// Remote-control navigation: index into the page's `buttons`, or nil
    /// to stay put.
    var up: Int?
    var down: Int?
    var left: Int?
    var right: Int?
    var action: MenuAction
}

enum MenuAction: Sendable, Equatable {
    /// Play the film from the start.
    case playFilm
    /// Play the film from a chapter (0-based, as in `ChaptersConfig`).
    case playChapter(Int)
    /// Open another menu page.
    case goToPage(Int)
    /// Turn subtitle track 1 on or off, then stay on this page.
    case setSubtitles(on: Bool)
}
