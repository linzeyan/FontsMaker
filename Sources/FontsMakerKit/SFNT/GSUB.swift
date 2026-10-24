/// Read-only GSUB access: the single substitutions of the vertical-forms
/// features, which pseudo-vertical layout swaps in (technical design §5.3).
enum GSUB {
    static let verticalFeatures: Set<String> = ["vert", "vrt2"]

    /// Merged glyph → vertical-form glyph map over every `vert`/`vrt2` lookup.
    /// Lookups are visited in lookup-list order (the order a shaper applies
    /// them) and the first substitution found for a glyph wins. Lookup types
    /// other than single substitution are ignored.
    static func verticalSubstitutions(_ table: [UInt8], numGlyphs: Int) throws -> [UInt16: UInt16] {
        var reader = ByteReader(table, context: "GSUB")
        _ = try reader.u32()  // version
        _ = try reader.u16()  // ScriptList: features are taken regardless of script
        let featureList = Int(try reader.u16())
        let lookupList = Int(try reader.u16())

        try reader.seek(featureList)
        let featureCount = Int(try reader.u16())
        var lookupIndices = Set<Int>()
        for index in 0..<featureCount {
            try reader.seek(featureList + 2 + 6 * index)
            let tag = try reader.tag()
            let offset = Int(try reader.u16())
            guard verticalFeatures.contains(tag) else { continue }
            try reader.seek(featureList + offset + 2)  // skip featureParamsOffset
            let count = Int(try reader.u16())
            for _ in 0..<count { lookupIndices.insert(Int(try reader.u16())) }
        }

        try reader.seek(lookupList)
        let lookupCount = Int(try reader.u16())
        var result: [UInt16: UInt16] = [:]
        for lookupIndex in lookupIndices.sorted() {
            guard lookupIndex < lookupCount else {
                throw FontLoadError.malformed("GSUB: feature references missing lookup \(lookupIndex)")
            }
            try reader.seek(lookupList + 2 + 2 * lookupIndex)
            let lookup = lookupList + Int(try reader.u16())
            try reader.seek(lookup)
            let lookupType = try reader.u16()
            _ = try reader.u16()  // lookupFlag
            let subtableCount = Int(try reader.u16())
            for subtableIndex in 0..<subtableCount {
                try reader.seek(lookup + 6 + 2 * subtableIndex)
                var subtable = lookup + Int(try reader.u16())
                var type = lookupType
                if type == 7 {
                    // Extension: the real subtable sits behind a 32-bit offset.
                    try reader.seek(subtable + 2)
                    type = try reader.u16()
                    subtable += Int(try reader.u32())
                }
                guard type == 1 else { continue }
                for (from, to) in try singleSubstitutions(table, at: subtable) where result[from] == nil {
                    guard Int(to) < numGlyphs else {
                        throw FontLoadError.malformed("GSUB: substitution to glyph \(to) beyond numGlyphs")
                    }
                    result[from] = to
                }
            }
        }
        return result
    }

    private static func singleSubstitutions(_ table: [UInt8], at start: Int) throws -> [(UInt16, UInt16)] {
        var reader = ByteReader(table, from: start, context: "GSUB single substitution")
        let format = try reader.u16()
        let covered = try coverage(table, at: start + Int(try reader.u16()))
        switch format {
        case 1:
            let delta = try reader.u16()
            return covered.map { ($0, $0 &+ delta) }
        case 2:
            let count = Int(try reader.u16())
            guard count == covered.count else {
                throw FontLoadError.malformed("GSUB: substitute count differs from coverage")
            }
            return try covered.map { ($0, try reader.u16()) }
        default:
            throw FontLoadError.malformed("GSUB: unknown single substitution format \(format)")
        }
    }

    /// Covered glyphs in coverage-index order.
    private static func coverage(_ table: [UInt8], at start: Int) throws -> [UInt16] {
        var reader = ByteReader(table, from: start, context: "GSUB coverage")
        let format = try reader.u16()
        let count = Int(try reader.u16())
        switch format {
        case 1:
            return try (0..<count).map { _ in try reader.u16() }
        case 2:
            var glyphs: [UInt16] = []
            for _ in 0..<count {
                let first = try reader.u16()
                let last = try reader.u16()
                _ = try reader.u16()  // startCoverageIndex: ranges are stored in index order
                guard first <= last else { throw FontLoadError.malformed("GSUB: inverted coverage range") }
                glyphs.append(contentsOf: first...last)
            }
            return glyphs
        default:
            throw FontLoadError.malformed("GSUB: unknown coverage format \(format)")
        }
    }
}
