import CoreGraphics
import Foundation

/// The 1920×1080 frame and the TV safe areas inside it. Titles and
/// buttons stay in title-safe (10% in on every side); nothing important
/// goes outside action-safe (5%).
enum MenuGeometry {
    static let size = CGSize(width: 1920, height: 1080)
    static let frame = CGRect(origin: .zero, size: size)
    static let actionSafe = CGRect(x: 96, y: 54, width: 1728, height: 972)
    static let titleSafe = CGRect(x: 192, y: 108, width: 1536, height: 864)
}

/// How one preset looks: fonts, colours, how the selection is drawn and
/// which layout the main page uses. The drawing code reads this; the
/// per-preset art (scrims, the letterbox band, the faded panel) lives in
/// `MenuRenderer`.
struct MenuStyle: Sendable {
    /// How the focused button reads from the couch.
    enum Selection: Sendable {
        /// Full-strength text with a bar under it.
        case underline
        /// Outlined, softly filled capsule around the text.
        case capsule
        /// Accent square before the text.
        case marker
    }

    enum MainLayout: Sendable {
        case lowerLeftRow
        case centredCard
        case leftColumn
    }

    let preset: MenuStylePreset
    let selection: Selection
    let mainLayout: MainLayout

    /// Strong text and the accent used for selection.
    let text: MenuColor
    let accent: MenuColor
    /// Page colour where the preset has a flat one.
    let ground: MenuColor
    /// Opacity of unselected text. Multiples of 1/15 keep the palette small.
    let dimAlpha: Double

    let titleFont: MenuFont
    let titleTracking: CGFloat
    let titleUppercase: Bool
    let titleLineHeight: CGFloat
    let subtitleFont: MenuFont
    let subtitleTracking: CGFloat
    let subtitleUppercase: Bool
    let subtitleColor: MenuColor
    let buttonFont: MenuFont
    let buttonTracking: CGFloat
    let buttonUppercase: Bool
    /// Scene label under each thumbnail.
    let labelFont: MenuFont
    let headerFont: MenuFont
    let headerTracking: CGFloat
    let headerUppercase: Bool

    // MARK: Button geometry

    static let capsuleSidePad: CGFloat = 40
    static let markerWidth: CGFloat = 48
    static let underlineThickness: CGFloat = 6

    func buttonBlock(_ string: String) -> TypeBlock {
        TypeBlock.line(buttonUppercase ? string.uppercased() : string, font: buttonFont, tracking: buttonTracking)
    }

    /// Whole-pixel size of a text button for this style.
    func buttonSize(for block: TypeBlock) -> CGSize {
        let lineH = ceil(block.ascent + block.descent)
        switch selection {
        case .underline:
            return CGSize(width: ceil(block.width), height: lineH + 20)
        case .capsule:
            return CGSize(width: ceil(block.width) + 2 * Self.capsuleSidePad, height: lineH + 24)
        case .marker:
            return CGSize(width: ceil(block.width) + Self.markerWidth, height: lineH + 20)
        }
    }

    /// Where the text starts inside the button, and its top.
    func textOrigin(for block: TypeBlock, in size: CGSize) -> CGPoint {
        switch selection {
        case .underline: return CGPoint(x: 0, y: 0)
        case .capsule: return CGPoint(x: Self.capsuleSidePad, y: ((size.height - ceil(block.ascent + block.descent)) / 2).rounded())
        case .marker: return CGPoint(x: Self.markerWidth, y: 0)
        }
    }

    // MARK: Presets

    static func style(for preset: MenuStylePreset) -> MenuStyle {
        switch preset {
        case .fullFrame:
            return MenuStyle(
                preset: preset, selection: .underline, mainLayout: .lowerLeftRow,
                text: MenuColor(hex: 0xF5F1E8), accent: MenuColor(hex: 0xE6B45E),
                ground: MenuColor(hex: 0x0A0A0A), dimAlpha: 0.6,
                titleFont: MenuFont(face: .serif(.regular), size: 104), titleTracking: 0,
                titleUppercase: false, titleLineHeight: 1.04,
                subtitleFont: MenuFont(face: .named("AvenirNext-Medium"), size: 40), subtitleTracking: 3,
                subtitleUppercase: false, subtitleColor: MenuColor(hex: 0xF5F1E8, alpha: 0.8),
                buttonFont: MenuFont(face: .named("AvenirNext-Medium"), size: 44), buttonTracking: 1,
                buttonUppercase: false,
                labelFont: MenuFont(face: .named("AvenirNext-Medium"), size: 40),
                headerFont: MenuFont(face: .serif(.regular), size: 72), headerTracking: 0, headerUppercase: false)
        case .titleCard:
            return MenuStyle(
                preset: preset, selection: .capsule, mainLayout: .centredCard,
                text: MenuColor(hex: 0xF4F1EA), accent: MenuColor(hex: 0xD8C9A3),
                ground: MenuColor(hex: 0x050505), dimAlpha: 0.6,
                titleFont: MenuFont(face: .named("Didot"), size: 100), titleTracking: 10,
                titleUppercase: true, titleLineHeight: 1.12,
                subtitleFont: MenuFont(face: .named("GillSans"), size: 40), subtitleTracking: 9,
                subtitleUppercase: true, subtitleColor: MenuColor(hex: 0xF4F1EA, alpha: 0.8),
                buttonFont: MenuFont(face: .named("GillSans"), size: 42), buttonTracking: 5,
                buttonUppercase: true,
                labelFont: MenuFont(face: .named("GillSans"), size: 40),
                headerFont: MenuFont(face: .named("Didot"), size: 64), headerTracking: 12, headerUppercase: true)
        case .typographic:
            return MenuStyle(
                preset: preset, selection: .marker, mainLayout: .leftColumn,
                text: MenuColor(hex: 0xF5F5F5), accent: MenuColor(hex: 0xFF4B3A),
                ground: MenuColor(hex: 0x0B0B0D), dimAlpha: 0.6,
                titleFont: MenuFont(face: .named("HelveticaNeue-Bold"), size: 136), titleTracking: -2,
                titleUppercase: false, titleLineHeight: 0.98,
                subtitleFont: MenuFont(face: .named("HelveticaNeue-Medium"), size: 40), subtitleTracking: 5,
                subtitleUppercase: true, subtitleColor: MenuColor(hex: 0xFF4B3A),
                buttonFont: MenuFont(face: .named("HelveticaNeue-Medium"), size: 48), buttonTracking: 0,
                buttonUppercase: false,
                labelFont: MenuFont(face: .named("HelveticaNeue-Medium"), size: 40),
                headerFont: MenuFont(face: .named("HelveticaNeue-Bold"), size: 72), headerTracking: -1, headerUppercase: false)
        }
    }
}
