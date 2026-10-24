/// A GSUB table taken apart as far as adding lookups requires (technical
/// design §4.3): the ScriptList and FeatureList as values, and each lookup as
/// its type, flags and where its subtables sit in the source bytes. Subtables
/// are never parsed. The rebuilt table carries the source table verbatim and
/// reaches the old subtables through extension lookups (32-bit offsets), so
/// growing the lists can never overflow a 16-bit offset inside them.
///
/// GPOS has the same header, lists and extension mechanism (type 9 instead
/// of 7), so `tag` "GPOS" reuses all of it for kerning and moved anchors
/// (design §5.6, §5.7) rather than keeping a second copy of the list code.
struct GSUBLayout {
    struct LangSys {
        var requiredFeature: UInt16
        var features: [UInt16]
    }

    struct Script {
        var tag: String
        var defaultLangSys: LangSys?
        var languages: [(tag: String, langSys: LangSys)]
    }

    struct Feature {
        var tag: String
        /// FeatureParams copied out of the source; empty when the feature has none.
        var params: [UInt8]
        var lookups: [UInt16]
    }

    struct Lookup {
        /// The real type: an extension lookup's (type 7) is the type it wraps.
        var type: UInt16
        var flag: UInt16
        var markFilteringSet: UInt16?
        /// Subtable positions in `source`.
        var subtables: [Int]
    }

    /// A lookup to add, flag 0, with its encoded subtables.
    struct NewLookup {
        var type: UInt16
        var subtables: [[UInt8]]
    }

    /// One context rule: the whole input sequence, and (sequence index,
    /// lookup index) records that substitute inside it.
    struct ContextRule {
        var input: [UInt16]
        var records: [(UInt16, UInt16)]
    }

    var scripts: [Script]
    var features: [Feature]
    var lookups: [Lookup]
    var source: [UInt8]
    /// "GSUB" or "GPOS".
    var tag: String

    var extensionLookupType: UInt16 { tag == "GPOS" ? 9 : 7 }

    /// For a font without GSUB. Han text gets `hani` from a shaper that finds
    /// it, `DFLT` from one that does not; the spike found CoreText's vertical
    /// layout taking `latn`'s features, so all three are registered.
    static let withoutGSUB = GSUBLayout(
        scripts: ["DFLT", "hani", "latn"].map {
            Script(tag: $0, defaultLangSys: LangSys(requiredFeature: 0xFFFF, features: []), languages: [])
        },
        features: [], lookups: [], source: [])

    init(scripts: [Script], features: [Feature], lookups: [Lookup], source: [UInt8], tag: String = "GSUB") {
        self.scripts = scripts
        self.features = features
        self.lookups = lookups
        self.source = source
        self.tag = tag
    }

    init(parsing table: [UInt8], tag: String = "GSUB") throws {
        self.tag = tag
        var reader = ByteReader(table, context: tag)
        let major = try reader.u16()
        let minor = try reader.u16()
        guard major == 1, minor <= 1 else {
            throw FontLoadError.unsupported("\(tag) version \(major).\(minor)")
        }
        let scriptList = Int(try reader.u16())
        let featureList = Int(try reader.u16())
        let lookupList = Int(try reader.u16())
        if minor == 1, try reader.u32() != 0 {
            throw FontLoadError.unsupported(
                tag == "GSUB"
                    ? "GSUB FeatureVariations (OpenType 1.8), which s2t phrases cannot rebuild; build without 'phrases'"
                    : "\(tag) FeatureVariations (OpenType 1.8), which FontsMaker cannot rebuild to add kerning or "
                        + "move anchors")
        }
        source = table
        scripts = try GSUBLayout.readScripts(table, at: scriptList, tableTag: tag)
        features = try GSUBLayout.readFeatures(table, at: featureList, tableTag: tag)
        lookups = try GSUBLayout.readLookups(table, at: lookupList, tableTag: tag)
        let featureCount = features.count
        let lookupCount = lookups.count
        for script in scripts {
            for langSys in [script.defaultLangSys].compactMap({ $0 }) + script.languages.map(\.langSys) {
                for index in langSys.features + (langSys.requiredFeature == 0xFFFF ? [] : [langSys.requiredFeature])
                where Int(index) >= featureCount {
                    throw FontLoadError.malformed("\(tag): script '\(script.tag)' references missing feature \(index)")
                }
            }
        }
        for feature in features {
            for index in feature.lookups where Int(index) >= lookupCount {
                throw FontLoadError.malformed("\(tag): feature '\(feature.tag)' references missing lookup \(index)")
            }
        }
    }

    private static func readLangSys(_ table: [UInt8], at start: Int, tableTag: String) throws -> LangSys {
        var reader = ByteReader(table, from: start, context: "\(tableTag) LangSys")
        _ = try reader.u16()  // lookupOrderOffset: reserved, always 0
        let required = try reader.u16()
        let count = Int(try reader.u16())
        return LangSys(requiredFeature: required, features: try (0..<count).map { _ in try reader.u16() })
    }

    private static func readScripts(_ table: [UInt8], at start: Int, tableTag: String) throws -> [Script] {
        var reader = ByteReader(table, from: start, context: "\(tableTag) ScriptList")
        let count = Int(try reader.u16())
        var scripts: [Script] = []
        for _ in 0..<count {
            let tag = try reader.tag()
            let script = start + Int(try reader.u16())
            var scriptReader = ByteReader(table, from: script, context: "\(tableTag) Script '\(tag)'")
            let defaultOffset = Int(try scriptReader.u16())
            let languageCount = Int(try scriptReader.u16())
            var languages: [(tag: String, langSys: LangSys)] = []
            for _ in 0..<languageCount {
                let languageTag = try scriptReader.tag()
                languages.append(
                    (
                        languageTag,
                        try readLangSys(table, at: script + Int(try scriptReader.u16()), tableTag: tableTag)
                    ))
            }
            scripts.append(
                Script(
                    tag: tag,
                    defaultLangSys: defaultOffset == 0
                        ? nil : try readLangSys(table, at: script + defaultOffset, tableTag: tableTag),
                    languages: languages))
        }
        return scripts
    }

    private static func readFeatures(_ table: [UInt8], at start: Int, tableTag: String) throws -> [Feature] {
        var reader = ByteReader(table, from: start, context: "\(tableTag) FeatureList")
        let count = Int(try reader.u16())
        var features: [Feature] = []
        for _ in 0..<count {
            let tag = try reader.tag()
            let feature = start + Int(try reader.u16())
            var featureReader = ByteReader(table, from: feature, context: "\(tableTag) Feature '\(tag)'")
            let paramsOffset = Int(try featureReader.u16())
            let lookupCount = Int(try featureReader.u16())
            let lookups = try (0..<lookupCount).map { _ in try featureReader.u16() }
            var params: [UInt8] = []
            if paramsOffset != 0 {
                params = try readFeatureParams(table, at: feature + paramsOffset, tag: tag, tableTag: tableTag)
            }
            features.append(Feature(tag: tag, params: params, lookups: lookups))
        }
        return features
    }

    /// FeatureParams have no offsets inside, so they are copied as bytes;
    /// their length follows from the feature tag (OpenType feature registry).
    private static func readFeatureParams(_ table: [UInt8], at start: Int, tag: String, tableTag: String) throws
        -> [UInt8]
    {
        var reader = ByteReader(table, from: start, context: "\(tableTag) FeatureParams of '\(tag)'")
        let length: Int
        if tag == "size" {
            length = 10
        } else if tag.hasPrefix("ss"), let number = Int(tag.dropFirst(2)), (1...20).contains(number) {
            length = 4
        } else if tag.hasPrefix("cv"), let number = Int(tag.dropFirst(2)), (1...99).contains(number) {
            try reader.skip(12)
            length = 14 + 3 * Int(try reader.u16())
            try reader.seek(start)
        } else {
            throw FontLoadError.unsupported(
                tableTag == "GSUB"
                    ? "GSUB FeatureParams on feature '\(tag)', which s2t phrases cannot rebuild"
                    : "\(tableTag) FeatureParams on feature '\(tag)', which FontsMaker cannot rebuild")
        }
        return try reader.read(length)
    }

    private static func readLookups(_ table: [UInt8], at start: Int, tableTag: String) throws -> [Lookup] {
        let extensionLookupType: UInt16 = tableTag == "GPOS" ? 9 : 7
        var reader = ByteReader(table, from: start, context: "\(tableTag) LookupList")
        let count = Int(try reader.u16())
        var lookups: [Lookup] = []
        for index in 0..<count {
            let lookup = start + Int(try reader.u16())
            var lookupReader = ByteReader(table, from: lookup, context: "\(tableTag) lookup \(index)")
            var type = try lookupReader.u16()
            let flag = try lookupReader.u16()
            let subtableCount = Int(try lookupReader.u16())
            var subtables = try (0..<subtableCount).map { _ in lookup + Int(try lookupReader.u16()) }
            let markFilteringSet = flag & 0x0010 != 0 ? try lookupReader.u16() : nil
            if type == extensionLookupType {
                var wrapped: UInt16?
                subtables = try subtables.map { subtable in
                    var extensionReader = ByteReader(
                        table, from: subtable, context: "\(tableTag) lookup \(index) extension")
                    let format = try extensionReader.u16()
                    let extensionType = try extensionReader.u16()
                    let offset = Int(try extensionReader.u32())
                    guard format == 1, extensionType != extensionLookupType, wrapped == nil || wrapped == extensionType,
                        subtable + offset < table.count
                    else {
                        throw FontLoadError.malformed("\(tableTag): invalid extension subtable in lookup \(index)")
                    }
                    wrapped = extensionType
                    return subtable + offset
                }
                // An empty extension lookup has no type to wrap; type 1 with no subtables is equivalent.
                type = wrapped ?? 1
            }
            guard (1...8).contains(type) else {
                throw FontLoadError.malformed("\(tableTag): lookup \(index) has type \(type)")
            }
            lookups.append(Lookup(type: type, flag: flag, markFilteringSet: markFilteringSet, subtables: subtables))
        }
        return lookups
    }

    /// Adds `lookups` to the feature `tag` in every language system of every
    /// script: appended to the language system's own `tag` feature where it
    /// has one (HarfBuzz uses only the first feature of a tag per language
    /// system), otherwise through one new feature shared by the rest. The
    /// FeatureList stays sorted by tag; feature indices are remapped.
    mutating func register(feature tag: String, lookups added: [UInt16]) {
        var extended = Set<Int>()
        var newFeature: UInt16?
        func register(_ langSys: inout LangSys) {
            if let existing = langSys.features.first(where: { features[Int($0)].tag == tag }) {
                if extended.insert(Int(existing)).inserted { features[Int(existing)].lookups += added }
                return
            }
            if newFeature == nil {
                newFeature = UInt16(features.count)
                features.append(Feature(tag: tag, params: [], lookups: added))
            }
            langSys.features.append(newFeature!)
        }
        for scriptIndex in scripts.indices {
            if scripts[scriptIndex].defaultLangSys != nil { register(&scripts[scriptIndex].defaultLangSys!) }
            for languageIndex in scripts[scriptIndex].languages.indices {
                register(&scripts[scriptIndex].languages[languageIndex].langSys)
            }
        }
        // Stable by tag: features sharing a tag keep their order, so the
        // first one of a tag in each language system stays the first.
        let order = features.indices.sorted { lhs, rhs in
            tagPrecedes(features[lhs].tag, features[rhs].tag) || (features[lhs].tag == features[rhs].tag && lhs < rhs)
        }
        var remap = [UInt16](repeating: 0, count: features.count)
        for (new, old) in order.enumerated() { remap[old] = UInt16(new) }
        features = order.map { features[$0] }
        func remapped(_ langSys: LangSys) -> LangSys {
            LangSys(
                requiredFeature: langSys.requiredFeature == 0xFFFF ? 0xFFFF : remap[Int(langSys.requiredFeature)],
                features: langSys.features.map { remap[Int($0)] }.sorted())
        }
        for scriptIndex in scripts.indices {
            scripts[scriptIndex].defaultLangSys = scripts[scriptIndex].defaultLangSys.map(remapped)
            for languageIndex in scripts[scriptIndex].languages.indices {
                scripts[scriptIndex].languages[languageIndex].langSys =
                    remapped(scripts[scriptIndex].languages[languageIndex].langSys)
            }
        }
    }

    // MARK: Encoding

    /// GSUB 1.0: header, ScriptList, FeatureList, LookupList (each lookup
    /// followed by its extension subtables), the source table verbatim, then
    /// the new lookups' subtables. Every lookup, old and new, is an extension
    /// lookup, and existing lookups keep their indices, so lookup indices
    /// inside the source subtables (contextual lookups) stay valid.
    ///
    /// `replacing` maps a source subtable position (as in `Lookup.subtables`)
    /// to new bytes that take its place in every lookup that uses it: how
    /// mark subtables with moved anchors are swapped in (`GPOSAnchors`).
    func encoded(adding newLookups: [NewLookup], replacing: [Int: [UInt8]] = [:]) throws -> [UInt8] {
        let scriptList = try encodedScriptList()
        let featureList = try encodedFeatureList()
        let scriptListStart = 10
        let featureListStart = scriptListStart + scriptList.count
        let lookupListStart = featureListStart + featureList.count

        enum Target {
            case source(Int)
            case added(Int)
        }
        var addedSubtables: [[UInt8]] = []
        var replaced: [Int: Int] = [:]
        for position in replacing.keys.sorted() {
            replaced[position] = addedSubtables.count
            addedSubtables.append(replacing[position]!)
        }
        var all: [(type: UInt16, flag: UInt16, markFilteringSet: UInt16?, targets: [Target])] = lookups.map {
            ($0.type, $0.flag, $0.markFilteringSet, $0.subtables.map { replaced[$0].map(Target.added) ?? .source($0) })
        }
        for lookup in newLookups {
            all.append((lookup.type, 0, nil, lookup.subtables.indices.map { .added(addedSubtables.count + $0) }))
            addedSubtables += lookup.subtables
        }
        guard all.count <= Int(UInt16.max) else { throw FontWriteError.unencodable("\(tag): \(all.count) lookups") }

        var lookupTableSizes: [Int] = []
        for lookup in all {
            let header = 6 + 2 * lookup.targets.count + (lookup.markFilteringSet == nil ? 0 : 2)
            lookupTableSizes.append(header + 8 * lookup.targets.count)
        }
        let lookupListSize = 2 + 2 * all.count + lookupTableSizes.reduce(0, +)
        let sourceStart = (lookupListStart + lookupListSize + 3) / 4 * 4
        var addedStarts: [Int] = []
        var position = (sourceStart + source.count + 3) / 4 * 4
        for subtable in addedSubtables {
            addedStarts.append(position)
            position = (position + subtable.count + 3) / 4 * 4
        }

        var writer = ByteWriter()
        writer.u32(0x0001_0000)
        writer.u16(try offset16(scriptListStart, "ScriptList"))
        writer.u16(try offset16(featureListStart, "FeatureList"))
        writer.u16(try offset16(lookupListStart, "LookupList"))
        writer.append(scriptList)
        writer.append(featureList)

        writer.u16(UInt16(all.count))
        var lookupStart = 2 + 2 * all.count
        for size in lookupTableSizes {
            writer.u16(try offset16(lookupStart, "lookup"))
            lookupStart += size
        }
        for lookup in all {
            writer.u16(extensionLookupType)
            writer.u16(lookup.flag)
            writer.u16(UInt16(lookup.targets.count))
            let recordsStart = 6 + 2 * lookup.targets.count + (lookup.markFilteringSet == nil ? 0 : 2)
            for index in lookup.targets.indices {
                writer.u16(try offset16(recordsStart + 8 * index, "extension subtable"))
            }
            if let markFilteringSet = lookup.markFilteringSet { writer.u16(markFilteringSet) }
            for target in lookup.targets {
                let recordStart = writer.count
                let absolute: Int
                switch target {
                case .source(let offset): absolute = sourceStart + offset
                case .added(let index): absolute = addedStarts[index]
                }
                writer.u16(1)
                writer.u16(lookup.type)
                guard let distance = UInt32(exactly: absolute - recordStart) else {
                    throw FontWriteError.unencodable("\(tag): extension offset \(absolute - recordStart)")
                }
                writer.u32(distance)
            }
        }
        while writer.count < sourceStart { writer.u8(0) }
        writer.append(source)
        for (index, subtable) in addedSubtables.enumerated() {
            while writer.count < addedStarts[index] { writer.u8(0) }
            writer.append(subtable)
        }
        return writer.bytes
    }

    private func offset16(_ value: Int, _ what: String) throws -> UInt16 {
        guard let narrow = UInt16(exactly: value) else {
            throw FontWriteError.unencodable("\(tag): \(what) offset \(value) exceeds 65535")
        }
        return narrow
    }

    private func encodedLangSys(_ langSys: LangSys) -> [UInt8] {
        var writer = ByteWriter()
        writer.u16(0)
        writer.u16(langSys.requiredFeature)
        writer.u16(UInt16(langSys.features.count))
        for feature in langSys.features { writer.u16(feature) }
        return writer.bytes
    }

    private func encodedScriptList() throws -> [UInt8] {
        var tables: [[UInt8]] = []
        for script in scripts {
            let langSystems = script.languages.map { encodedLangSys($0.langSys) }
            let defaultLangSys = script.defaultLangSys.map(encodedLangSys)
            var writer = ByteWriter()
            var next = 4 + 6 * script.languages.count
            writer.u16(defaultLangSys == nil ? 0 : try offset16(next, "DefaultLangSys"))
            next += defaultLangSys?.count ?? 0
            writer.u16(UInt16(script.languages.count))
            for (language, bytes) in zip(script.languages, langSystems) {
                writer.append(Array(language.tag.utf8))
                writer.u16(try offset16(next, "LangSys"))
                next += bytes.count
            }
            if let defaultLangSys { writer.append(defaultLangSys) }
            for langSys in langSystems { writer.append(langSys) }
            tables.append(writer.bytes)
        }
        var writer = ByteWriter()
        writer.u16(UInt16(scripts.count))
        var next = 2 + 6 * scripts.count
        for (script, table) in zip(scripts, tables) {
            writer.append(Array(script.tag.utf8))
            writer.u16(try offset16(next, "Script"))
            next += table.count
        }
        for table in tables { writer.append(table) }
        return writer.bytes
    }

    private func encodedFeatureList() throws -> [UInt8] {
        var writer = ByteWriter()
        writer.u16(UInt16(features.count))
        var next = 2 + 6 * features.count
        for feature in features {
            writer.append(Array(feature.tag.utf8))
            writer.u16(try offset16(next, "Feature"))
            next += 4 + 2 * feature.lookups.count + feature.params.count
        }
        for feature in features {
            writer.u16(feature.params.isEmpty ? 0 : UInt16(4 + 2 * feature.lookups.count))
            writer.u16(UInt16(feature.lookups.count))
            for lookup in feature.lookups { writer.u16(lookup) }
            writer.append(feature.params)
        }
        return writer.bytes
    }

    // MARK: New subtables

    /// Context substitution format 1 (glyph sequences). Rules sharing a first
    /// glyph form one rule set and stay in the given order, which is the order
    /// a shaper tries them: the first match wins and consumes the whole input.
    ///
    /// A rule's bytes leave out its first glyph, so rules of different sets
    /// with the same rest are often identical (every two-glyph blocking rule
    /// ending in 的); each subtable stores those once, after all rule sets.
    /// A subtable takes whole rule sets until it would pass 65535 bytes, the
    /// reach of its 16-bit offsets.
    static func contextSubtables(_ rules: [ContextRule]) throws -> [[UInt8]] {
        var sets: [(first: UInt16, rules: [[UInt8]])] = []
        for rule in rules {
            var writer = ByteWriter()
            writer.u16(UInt16(rule.input.count))
            writer.u16(UInt16(rule.records.count))
            for glyph in rule.input.dropFirst() { writer.u16(glyph) }
            for (sequenceIndex, lookupIndex) in rule.records {
                writer.u16(sequenceIndex)
                writer.u16(lookupIndex)
            }
            if sets.last?.first == rule.input[0] {
                sets[sets.count - 1].rules.append(writer.bytes)
            } else {
                precondition(sets.last.map { $0.first < rule.input[0] } ?? true, "rules must be grouped by first glyph")
                sets.append((rule.input[0], [writer.bytes]))
            }
        }

        struct Chunk {
            var sets: [(first: UInt16, rules: [[UInt8]])] = []
            var pool: [[UInt8]] = []
            /// Rule bytes → position in the pool.
            var pooled: [[UInt8]: Int] = [:]
            var poolSize = 0
            /// Format, coverage offset, set count, coverage format and count.
            var size = 10
        }
        var chunks: [Chunk] = []
        for set in sets {
            // Per set: its offset, its coverage glyph, its header, rules not pooled yet.
            func cost(in chunk: Chunk) -> Int {
                var new = Set<[UInt8]>()
                var bytes = 2 + 2 + 2 + 2 * set.rules.count
                for rule in set.rules where chunk.pooled[rule] == nil && new.insert(rule).inserted {
                    bytes += rule.count
                }
                return bytes
            }
            if chunks.isEmpty || chunks[chunks.count - 1].size + cost(in: chunks[chunks.count - 1]) > Int(UInt16.max) {
                guard Chunk().size + cost(in: Chunk()) <= Int(UInt16.max) else {
                    throw FontWriteError.unencodable("GSUB: too many phrase rules start with glyph \(set.first)")
                }
                chunks.append(Chunk())
            }
            var chunk = chunks.removeLast()
            chunk.size += cost(in: chunk)
            chunk.sets.append(set)
            for rule in set.rules where chunk.pooled[rule] == nil {
                chunk.pooled[rule] = chunk.poolSize
                chunk.pool.append(rule)
                chunk.poolSize += rule.count
            }
            chunks.append(chunk)
        }
        return chunks.map { chunk in
            let count = chunk.sets.count
            let coverage = 6 + 2 * count
            var setStarts: [Int] = []
            var next = coverage + 4 + 2 * count
            for set in chunk.sets {
                setStarts.append(next)
                next += 2 + 2 * set.rules.count
            }
            let poolStart = next
            var writer = ByteWriter()
            writer.u16(1)
            writer.u16(UInt16(coverage))
            writer.u16(UInt16(count))
            for start in setStarts { writer.u16(UInt16(start)) }
            writer.u16(1)
            writer.u16(UInt16(count))
            for set in chunk.sets { writer.u16(set.first) }
            for (set, setStart) in zip(chunk.sets, setStarts) {
                writer.u16(UInt16(set.rules.count))
                for rule in set.rules { writer.u16(UInt16(poolStart + chunk.pooled[rule]! - setStart)) }
            }
            for rule in chunk.pool { writer.append(rule) }
            precondition(writer.count == chunk.size, "context subtable size estimate")
            return writer.bytes
        }
    }

    /// Single substitution format 2, split so every subtable's offsets fit 16 bits.
    static func singleSubstitutionSubtables(_ map: [UInt16: UInt16]) -> [[UInt8]] {
        let pairs = map.sorted { $0.key < $1.key }
        return stride(from: 0, to: pairs.count, by: 16_000).map { start in
            let chunk = pairs[start..<min(start + 16_000, pairs.count)]
            var writer = ByteWriter()
            writer.u16(2)
            writer.u16(UInt16(6 + 2 * chunk.count))
            writer.u16(UInt16(chunk.count))
            for pair in chunk { writer.u16(pair.value) }
            writer.u16(1)
            writer.u16(UInt16(chunk.count))
            for pair in chunk { writer.u16(pair.key) }
            return writer.bytes
        }
    }
}
