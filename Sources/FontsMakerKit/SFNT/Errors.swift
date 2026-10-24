import Foundation

/// Why a font file cannot be opened. Unsupported formats get their own cases
/// so the app and CLI can explain the reason instead of reporting "corrupt file".
public enum FontLoadError: Error, Equatable, Sendable {
    case woff
    case woff2
    case notAFont
    case missingTable(String)
    case unsupported(String)
    case malformed(String)
    /// The requested font of a collection (`faceIndex`) is not in the file.
    case faceIndexOutOfRange(index: Int, faceCount: Int)
    /// Axis values were given for a font without variation axes.
    case notVariable
    case unknownAxis(tag: String, available: [String])
    case axisValueOutOfRange(tag: String, value: Double, minimum: Double, maximum: Double)
    /// CoreText could not load the font, or did not give the outlines asked for.
    case outlineConversion(String)
}

extension FontLoadError: LocalizedError, CustomStringConvertible {
    public var description: String {
        switch self {
        case .woff:
            return "WOFF web fonts are not supported. Convert the file to a .ttf or .otf font first."
        case .woff2:
            return "WOFF2 web fonts are not supported. Convert the file to a .ttf or .otf font first."
        case .notAFont:
            return "The file is not a TrueType or OpenType font."
        case .missingTable(let tag):
            return "The font is missing the required '\(tag)' table."
        case .unsupported(let detail):
            return "Unsupported font feature: \(detail)"
        case .malformed(let detail):
            return "The font file is damaged: \(detail)"
        case .faceIndexOutOfRange(let index, let faceCount):
            return faceCount == 1
                ? "The file holds a single font, so faceIndex must be 0, not \(index)."
                : "The file holds \(faceCount) fonts (faceIndex 0–\(faceCount - 1)); there is no faceIndex \(index)."
        case .notVariable:
            return "Axis values (variation) were given, but the font is not a variable font."
        case .unknownAxis(let tag, let available):
            return "The font has no variation axis '\(tag)'; its axes are "
                + available.map { "'\($0)'" }.joined(separator: ", ") + "."
        case .axisValueOutOfRange(let tag, let value, let minimum, let maximum):
            return "Axis '\(tag)' value \(formatNumber(value)) is outside the font's range "
                + "\(formatNumber(minimum))–\(formatNumber(maximum))."
        case .outlineConversion(let detail):
            return "The font's outlines could not be converted to TrueType: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

/// The model holds something the binary format cannot represent.
public enum FontWriteError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case unencodable(String)

    public var description: String {
        switch self {
        case .unencodable(let detail): return "Cannot write font: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}
