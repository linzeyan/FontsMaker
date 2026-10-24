import CoreGraphics
import CoreText
import Foundation
import ImageIO

public enum RiskSheetError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case renderingFailed(String)

    public var description: String {
        switch self {
        case .renderingFailed(let detail): return "Cannot render the risk sheet: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

extension EmboldenReport {
    /// PNG pages for human review: each glyph of the given grades (A and B by
    /// default) drawn as source | emboldened, worst first.
    ///
    /// - Parameters:
    ///   - source: the font before emboldening (decomposed).
    ///   - emboldened: the same font after `embolden`.
    public func riskSheet(
        source: Font, emboldened: Font, grades: Set<EmboldenGrade> = [.a, .b], title: String, perPage: Int = 120
    ) throws -> [Data] {
        let selected = glyphs.filter { grades.contains($0.grade) }.sorted {
            ($0.grade, $0.minHoleRatio ?? .infinity, $0.glyphID) < ($1.grade, $1.minHoleRatio ?? .infinity, $1.glyphID)
        }
        return try RiskSheet.render(
            selected, source: source, emboldened: emboldened, title: title, perPage: max(1, perPage))
    }
}

enum RiskSheet {
    static let groupsPerRow = 6
    static let cell: CGFloat = 96
    static let gap: CGFloat = 2
    static let groupGap: CGFloat = 18
    static let margin: CGFloat = 20
    static let labelHeight: CGFloat = 30
    static let header: CGFloat = 56

    static func render(
        _ entries: [EmboldenGlyphReport], source: Font, emboldened: Font, title: String, perPage: Int
    ) throws -> [Data] {
        let pages = stride(from: 0, to: entries.count, by: perPage).map {
            Array(entries[$0..<min(entries.count, $0 + perPage)])
        }
        return try pages.enumerated().map { number, page in
            let pageTitle = pages.count > 1 ? "\(title)  (page \(number + 1)/\(pages.count))" : title
            return try renderPage(page, source: source, emboldened: emboldened, title: pageTitle)
        }
    }

    private static func renderPage(
        _ entries: [EmboldenGlyphReport], source: Font, emboldened: Font, title: String
    ) throws -> Data {
        let groupWidth = 2 * cell + gap
        let rows = max(1, (entries.count + groupsPerRow - 1) / groupsPerRow)
        let width = Int(2 * margin + CGFloat(groupsPerRow) * groupWidth + CGFloat(groupsPerRow - 1) * groupGap)
        let height = Int(2 * margin + header + CGFloat(rows) * (cell + labelHeight))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RiskSheetError.renderingFailed("cannot create a \(width)×\(height) bitmap") }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let top = CGFloat(height) - margin
        drawText(context, title, at: CGPoint(x: margin, y: top - 18), size: 16, bold: true)
        drawText(
            context, "per glyph: source | emboldened · label: character #glyph grade, min counter ratio",
            at: CGPoint(x: margin, y: top - 40), size: 12)

        for (index, entry) in entries.enumerated() {
            let x = margin + CGFloat(index % groupsPerRow) * (groupWidth + groupGap)
            let cellTop = top - header - CGFloat(index / groupsPerRow) * (cell + labelHeight)
            for (column, font) in [source, emboldened].enumerated() {
                let rect = CGRect(x: x + CGFloat(column) * (cell + gap), y: cellTop - cell, width: cell, height: cell)
                context.setFillColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1))
                context.fill(rect)
                try drawGlyph(entry.glyphID, of: font, in: rect, context: context)
            }
            let ratio = entry.minHoleRatio.map { String(format: " %.2f", $0) } ?? ""
            drawText(
                context, "\(entry.text) #\(entry.glyphID) \(entry.grade.rawValue)\(ratio)",
                at: CGPoint(x: x, y: cellTop - cell - 15), size: 11)
        }

        guard let image = context.makeImage() else {
            throw RiskSheetError.renderingFailed("cannot snapshot the bitmap")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw RiskSheetError.renderingFailed("PNG encoding is unavailable")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RiskSheetError.renderingFailed("PNG encoding failed")
        }
        return data as Data
    }

    /// The em box spans 1.2 em from (-0.1 em, descender - 0.1 em), the frame
    /// the Phase 0 sheets used, so glyphs of every font sit alike.
    private static func drawGlyph(_ glyphID: Int, of font: Font, in rect: CGRect, context: CGContext) throws {
        let em = CGFloat(font.unitsPerEm)
        let descender = CGFloat(font.os2?.typoDescender ?? Int16(-0.12 * em))
        let frame = CGRect(x: -0.1 * em, y: descender - 0.1 * em, width: 1.2 * em, height: 1.2 * em)
        let scale = rect.width / frame.width
        let outline: SimpleOutline
        switch font.glyphs[glyphID].outline {
        case .simple(let simple): outline = simple
        case .composite: outline = try font.flattenedOutline(of: glyphID).rounded()
        }
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX - frame.minX * scale, y: rect.minY - frame.minY * scale)
        context.scaleBy(x: scale, y: scale)
        context.setStrokeColor(CGColor(srgbRed: 0.8, green: 0.8, blue: 0.85, alpha: 1))
        context.setLineWidth(1 / scale)
        let advance = CGFloat(font.horizontalMetrics[glyphID].advanceWidth)
        context.stroke(CGRect(x: 0, y: descender, width: advance, height: em))
        context.addPath(outline.cgPath)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fillPath(using: .winding)
        context.restoreGState()
    }

    private static func drawText(
        _ context: CGContext, _ text: String, at point: CGPoint, size: CGFloat, bold: Bool = false
    ) {
        guard let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                srgbRed: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
