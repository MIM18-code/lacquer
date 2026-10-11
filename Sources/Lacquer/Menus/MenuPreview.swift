import CoreGraphics
import Foundation

/// What a TV shows: the page background with every button's normal image
/// and the chosen one in its selected (or activated) state.
enum MenuPreview {
    enum Highlight { case none, selected(Int), activated(Int) }

    static func composite(_ page: MenuPage, highlight: Highlight, showSafeAreas: Bool = false) -> CGImage {
        let c = MenuCanvas(width: 1920, height: 1080, opaque: true)
        c.draw(page.background, in: MenuGeometry.frame, fit: .fill)
        for (i, b) in page.buttons.enumerated() {
            var image = b.normal
            switch highlight {
            case .selected(let k) where k == i: image = b.selected
            case .activated(let k) where k == i: image = b.activated
            default: break
            }
            c.draw(image, in: b.rect, fit: .fill)
        }
        if showSafeAreas {
            c.ctx.setLineWidth(2)
            c.ctx.setLineDash(phase: 0, lengths: [10, 8])
            c.ctx.setStrokeColor(MenuColor(1, 0.3, 0.3, 0.9).cgColor)
            c.ctx.stroke(MenuGeometry.titleSafe)
            c.ctx.setStrokeColor(MenuColor(1, 0.85, 0.2, 0.9).cgColor)
            c.ctx.stroke(MenuGeometry.actionSafe)
        }
        return c.makeImage()
    }
}
