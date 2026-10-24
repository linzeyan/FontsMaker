extension EmboldenStep {
    /// Maps the character-keyed settings through the font's current cmap to
    /// the glyph-keyed options the engine takes (design §4.2). The miter limit
    /// is EmboldenOptions' default 4: fixed by design (§5.1), not by recipes.
    ///
    /// A glyph shared by several code points is processed once, so the
    /// characters that name it must agree: `skip` on one and a weight on
    /// another (or two different weights) is an error listing every clash.
    /// Code points that share a glyph but are not mentioned simply follow it.
    /// Glyphs without a code point (vertical alternates, ...) get `weight`.
    public func resolve(in font: Font) throws -> EmboldenOptions {
        enum Setting: Equatable {
            case skip
            case weight(Double)

            var label: String {
                switch self {
                case .skip: return "skip"
                case .weight(let value): return "weight \(formatNumber(value))"
                }
            }
        }

        var requests: [(glyph: Int, scalar: Unicode.Scalar, setting: Setting)] = []
        var missing: [String] = []
        func request(_ text: String, _ setting: Setting, field: String) {
            // Decoding guarantees one scalar per key.
            guard let scalar = singleScalar(text) else { return }
            guard let glyph = font.characterMap.mappings[scalar.value] else {
                missing.append("\(field) '\(text)' (U+\(hex(scalar.value)))")
                return
            }
            requests.append((Int(glyph), scalar, setting))
        }
        for text in skip { request(text, .skip, field: "skip") }
        for (text, override) in perCharacter.sorted(by: { $0.key < $1.key }) {
            request(text, .weight(override.weight), field: "perCharacter")
        }
        if !missing.isEmpty { throw BuildError.charactersNotInFont(missing) }

        var byGlyph: [Int: [(scalar: Unicode.Scalar, setting: Setting)]] = [:]
        for entry in requests { byGlyph[entry.glyph, default: []].append((entry.scalar, entry.setting)) }

        var options = EmboldenOptions(weight: weight, widen: widen)
        var conflicts: [String] = []
        for (glyph, entries) in byGlyph.sorted(by: { $0.key < $1.key }) {
            let settings = entries.map(\.setting)
            guard settings.allSatisfy({ $0 == settings[0] }) else {
                let parts = entries.sorted { $0.scalar.value < $1.scalar.value }.map {
                    "\(String($0.scalar)) (U+\(hex($0.scalar.value))): \($0.setting.label)"
                }
                conflicts.append("glyph \(glyph) is shared by " + parts.joined(separator: ", "))
                continue
            }
            switch settings[0] {
            case .skip: options.skip.insert(glyph)
            case .weight(let value): options.perGlyphWeight[glyph] = value
            }
        }
        if !conflicts.isEmpty { throw BuildError.conflictingCharacterSettings(conflicts) }
        return options
    }
}

/// 12 rather than 12.0 in messages and summaries.
func formatNumber(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
}
