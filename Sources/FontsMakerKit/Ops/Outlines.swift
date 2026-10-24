import Foundation

public struct OutlinesReport: Equatable, Sendable {
    /// The characters whose glyphs were replaced, sorted by code point.
    public var characters: [String]
    /// Composite glyphs that use a replaced glyph, directly or through
    /// another composite (é uses e): they follow the new outline.
    public var composites: Int
    /// Glyphs whose advance changed: replaced ones, and composites that take
    /// their metrics from a replaced component (USE_MY_METRICS).
    public var advances: Int
}

public enum OutlinesError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case charactersNotInFont([String])
    /// Two characters show one glyph, and the recipe draws them differently.
    case sharedGlyph(characters: [String], glyphID: Int)
    /// cu2qu found no quadratic spline of up to 100 pieces (a degenerate loop).
    case curveNotConvertible(character: String)

    public var description: String {
        switch self {
        case .charactersNotInFont(let characters):
            return "Characters in the outlines step that the source font does not contain: "
                + characters.joined(separator: ", ")
        case .sharedGlyph(let characters, let glyphID):
            return "\(characters.joined(separator: " and ")) show the same glyph (\(glyphID)) in the source font, "
                + "but the outlines step draws them differently; a glyph has one outline, so give them the same one"
        case .curveNotConvertible(let character):
            return "A curve of '\(character)' in the outlines step cannot be converted to TrueType curves"
        }
    }

    public var errorDescription: String? { description }
}

extension [Recipe.Step] {
    /// The outlines step, which runs before every other step and so must come
    /// first. Decoding already refuses it elsewhere; a recipe put together in
    /// code is checked here, so the step is never silently skipped.
    func leadingOutlines() throws -> OutlinesStep? {
        for (index, step) in enumerated() {
            guard case .outlines(let outlines) = step else { continue }
            guard index == 0 else {
                throw RecipeError.invalidValue(
                    path: "steps[\(index)].op",
                    reason: "outlines must be the first step: it replaces source glyphs before every other step")
            }
            return outlines
        }
        return nil
    }
}

extension Font {
    /// Replaces the glyphs of the step's characters with their edited
    /// outlines (design §5.8). Runs before composites are flattened, so a
    /// composite that uses a replaced glyph shows the new outline, and before
    /// every other step, which then works on the new outline.
    public mutating func applyOutlines(_ step: OutlinesStep) throws -> OutlinesReport {
        var byGlyph: [Int: (character: String, glyph: EditedGlyph)] = [:]
        var missing: [String] = []
        for (character, glyph) in step.glyphs.sorted(by: {
            $0.key.unicodeScalars.first!.value < $1.key.unicodeScalars.first!.value
        }) {
            guard let scalar = singleScalar(character), let glyphID = characterMap.mappings[scalar.value] else {
                missing.append(character)
                continue
            }
            if let earlier = byGlyph[Int(glyphID)] {
                guard earlier.glyph == glyph else {
                    throw OutlinesError.sharedGlyph(characters: [earlier.character, character], glyphID: Int(glyphID))
                }
            } else {
                byGlyph[Int(glyphID)] = (character, glyph)
            }
        }
        guard missing.isEmpty else { throw OutlinesError.charactersNotInFont(missing) }

        var replaced = glyphs
        var metrics = horizontalMetrics
        var vertical = verticalMetrics
        var advances = 0
        for (glyphID, entry) in byGlyph.sorted(by: { $0.key < $1.key }) {
            let source = glyphs[glyphID]
            let overlapping: Bool
            if case .simple(let simple) = source.outline {
                overlapping = simple.overlapping
            } else {
                overlapping = false
            }
            let outline: SimpleOutline
            do {
                outline = try entry.glyph.trueTypeOutline(overlapping: overlapping)
            } catch is EmboldenGeometry.CurveApproximationFailed {
                throw OutlinesError.curveNotConvertible(character: entry.character)
            }
            // The top side bearing hangs from the vertical origin, which the
            // outline does not determine: keep the origin where it was.
            if vertical != nil, let before = BoundingBox(try flattenedOutline(of: glyphID).rounded().points),
                let after = BoundingBox(outline.points)
            {
                let tsb = Int(vertical![glyphID].topSideBearing) + Int(before.yMax) - Int(after.yMax)
                vertical![glyphID].topSideBearing = Int16(clamping: tsb)
            }
            replaced[glyphID] = Glyph(outline: .simple(outline))
            if Int(metrics[glyphID].advanceWidth) != entry.glyph.advance {
                metrics[glyphID].advanceWidth = UInt16(entry.glyph.advance)
                advances += 1
            }
        }

        // Composites keep their components, so they show the new outlines by
        // themselves; one whose metrics are a component's follows its advance.
        var composites = 0
        var uses: [Int: Bool] = [:]
        func usesReplaced(_ glyphID: Int, depth: Int = 0) -> Bool {
            if let known = uses[glyphID] { return known }
            guard depth < 64, case .composite(let components) = glyphs[glyphID].outline else {
                return byGlyph[glyphID] != nil
            }
            let result = components.contains {
                byGlyph[Int($0.glyphID)] != nil || usesReplaced(Int($0.glyphID), depth: depth + 1)
            }
            uses[glyphID] = result
            return result
        }
        for glyphID in glyphs.indices where byGlyph[glyphID] == nil {
            guard case .composite(let components) = glyphs[glyphID].outline, usesReplaced(glyphID) else { continue }
            composites += 1
            if let metricsSource = components.first(where: { $0.flags & GlyphComponent.useMyMetrics != 0 }),
                let edited = byGlyph[Int(metricsSource.glyphID)],
                Int(metrics[glyphID].advanceWidth) != edited.glyph.advance
            {
                metrics[glyphID].advanceWidth = UInt16(edited.glyph.advance)
                advances += 1
            }
        }

        glyphs = replaced
        horizontalMetrics = metrics
        verticalMetrics = vertical
        // Design §4.3: an operation that changes advances owns xAvgCharWidth.
        if advances > 0 {
            let average = averageAdvanceWidth()
            os2?.xAvgCharWidth = average
        }
        return OutlinesReport(
            characters: byGlyph.values.map(\.character).sorted {
                $0.unicodeScalars.first!.value < $1.unicodeScalars.first!.value
            },
            composites: composites, advances: advances)
    }

    /// A glyph's TrueType outline with composites flattened, as it is drawn.
    public func flattenedSimpleOutline(ofGlyph glyphID: Int) throws -> SimpleOutline {
        try flattenedOutline(of: glyphID).rounded()
    }

    /// The glyph `codePoint` shows, as editable cubic contours (composites
    /// flattened), with its advance; nil when the font has no such character.
    /// `maxError` is how far simplification strayed from the source curve.
    public func editableGlyph(
        for codePoint: UInt32, tolerance: Double? = nil
    ) throws -> (glyph: EditedGlyph, maxError: Double)? {
        guard let glyphID = characterMap.mappings[codePoint].map(Int.init) else { return nil }
        let outline = try flattenedOutline(of: glyphID).rounded()
        return EditedGlyph.editable(
            outline, advance: Int(horizontalMetrics[glyphID].advanceWidth),
            tolerance: tolerance ?? EditedGlyph.defaultTolerance(unitsPerEm: Int(unitsPerEm)))
    }
}
