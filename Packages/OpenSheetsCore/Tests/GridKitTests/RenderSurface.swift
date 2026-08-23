import AppKit
import CoreGraphics
import Foundation
import SheetModel
@testable import GridKit

/// An offscreen, flipped bitmap the renderer can draw into, plus enough pixel inspection to make
/// real assertions about what came out.
///
/// Rendering to a bitmap rather than to a window is what lets these run in `swift test` with no
/// window server, and what makes them deterministic: same input, same pixels, every time.
@MainActor
final class RenderSurface {
    let pointSize: CGSize
    let scale: Double
    let context: CGContext
    let renderer: GridRenderer

    init(width: Double = 600, height: Double = 300, scale: Double = 2, theme: GridTheme = .light) {
        pointSize = CGSize(width: width, height: height)
        self.scale = scale
        let pixelWidth = Int(width * scale)
        let pixelHeight = Int(height * scale)
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            preconditionFailure("could not create a \(pixelWidth)×\(pixelHeight) bitmap")
        }
        self.context = context
        renderer = GridRenderer(theme: theme)
        renderer.backingScale = scale

        // Flip: the renderer draws in a document-view space with the origin at the top left.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
    }

    /// Draws one pane over the whole surface.
    func render(_ model: GridRenderModel, pane: GridPane = .body, sheetOrigin: CGPoint? = nil) {
        let origin = sheetOrigin ?? CGPoint(
            x: pane == .corner || pane == .left ? 0 : model.geometry.frozenWidth,
            y: pane == .corner || pane == .top ? 0 : model.geometry.frozenHeight
        )
        renderer.draw(
            pane,
            into: context,
            viewRect: CGRect(origin: .zero, size: pointSize),
            sheetOrigin: origin,
            model: model
        )
    }

    /// Draws the column header strip across the top of the surface.
    func renderColumnHeader(_ model: GridRenderModel, height: Double = 22, scrollOrigin: CGPoint = .zero) {
        let headers = GridHeaderRenderer(theme: model.theme)
        headers.backingScale = scale
        headers.drawColumnHeader(
            into: context,
            viewRect: CGRect(x: 0, y: 0, width: pointSize.width, height: height),
            scrollOrigin: scrollOrigin,
            model: model
        )
    }

    /// Draws the row header strip down the left of the surface.
    func renderRowHeader(_ model: GridRenderModel, width: Double = 46, scrollOrigin: CGPoint = .zero) {
        let headers = GridHeaderRenderer(theme: model.theme)
        headers.backingScale = scale
        headers.drawRowHeader(
            into: context,
            viewRect: CGRect(x: 0, y: 0, width: width, height: pointSize.height),
            scrollOrigin: scrollOrigin,
            model: model
        )
    }

    // MARK: - Reading

    /// The colour at a point, in the surface's own point coordinates.
    func colour(atX x: Double, y: Double) -> RGBAColor {
        guard let data = context.data else { return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0) }
        let column = Int(x * scale)
        let row = Int(y * scale)
        guard column >= 0, column < context.width, row >= 0, row < context.height else {
            return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        let pointer = data.advanced(by: row * context.bytesPerRow + column * 4)
            .assumingMemoryBound(to: UInt8.self)
        return RGBAColor(red: pointer[0], green: pointer[1], blue: pointer[2], alpha: pointer[3])
    }

    /// How many pixels inside `rect` differ from `background` by more than a hair.
    func inkCount(in rect: CGRect, background: RGBAColor, tolerance: Int = 12) -> Int {
        var count = 0
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                if differs(colour(atX: x, y: y), background, tolerance: tolerance) { count += 1 }
                x += 1 / scale
            }
            y += 1 / scale
        }
        return count
    }

    /// Whether anything was painted in `rect` that is not the background.
    func hasInk(in rect: CGRect, background: RGBAColor, tolerance: Int = 12) -> Bool {
        inkCount(in: rect, background: background, tolerance: tolerance) > 0
    }

    private func differs(_ lhs: RGBAColor, _ rhs: RGBAColor, tolerance: Int) -> Bool {
        abs(Int(lhs.red) - Int(rhs.red)) > tolerance
            || abs(Int(lhs.green) - Int(rhs.green)) > tolerance
            || abs(Int(lhs.blue) - Int(rhs.blue)) > tolerance
    }

    /// A cheap content fingerprint, for "these two renders differ" assertions.
    func fingerprint() -> UInt64 {
        guard let data = context.data else { return 0 }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let total = context.bytesPerRow * context.height
        var index = 0
        while index < total {
            hash = (hash ^ UInt64(bytes[index])) &* 0x0000_0100_0000_01B3
            index += 7
        }
        return hash
    }
}
