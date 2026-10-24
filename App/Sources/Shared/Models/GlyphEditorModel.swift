import CoreGraphics
import FontsMakerKit
import Foundation
import Observation

/// The glyph editor (Phase 4f, technical design §5.8): Latin letters,
/// figures and punctuation of one font, redrawn by hand. Each change lands in
/// the draft's outlines step, so the page, the build and the export follow it
/// like any effect. Platform-neutral, so the macOS and iPad views share it and
/// it runs in unit tests.
@MainActor @Observable
final class GlyphEditorModel: Identifiable {
    struct CharacterGroup: Identifiable {
        let title: String
        let characters: [Character]
        var id: String { title }
    }

    /// What a press on the canvas does.
    enum Tool: String, CaseIterable, Identifiable {
        case select, addPoint, pen
        var id: String { rawValue }
    }

    /// A node, or one of its handles.
    struct Target: Equatable {
        enum Part: Equatable { case node, handleIn, handleOut }
        var contour: Int
        var index: Int
        var part: Part
    }

    /// The order the grid shows them in; only those the font has are listed.
    static let candidateGroups: [(String, [Character])] = [
        ("大寫字母", Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")),
        ("小寫字母", Array("abcdefghijklmnopqrstuvwxyz")),
        ("數字", Array("0123456789")),
        ("標點與符號", Array("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~“”‘’–—…•·«»¡¿§¶©®°")),
        (
            "重音字母",
            (0xC0...0x17F).compactMap { Unicode.Scalar($0).map(Character.init) }.filter { $0.isLetter }
        ),
    ]

    /// Whether the font has anything the editor offers: the ② card shows for
    /// Latin fonts and for CJK fonts with half-width letters or figures.
    nonisolated static func applies(to font: Font) -> Bool {
        let basics = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".unicodeScalars
        return basics.contains { font.characterMap.mappings[$0.value] != nil }
    }

    /// The running text under the canvas: the classic test word, then the
    /// character between straight and round letters.
    static func previewText(for character: Character?) -> String {
        guard let character else { return "Hamburgefonstiv" }
        return "Hamburgefonstiv  n\(character)n o\(character)o H\(character)H"
    }

    let id = UUID()
    let editor: EditorModel
    let groups: [CharacterGroup]
    let font: Font
    /// Source glyph paths for the grid and the 原字 overlay, by character.
    private(set) var sourcePaths: [Character: CGPath] = [:]

    private(set) var selected: Character?
    /// The glyph on the canvas: the draft's, or the source's made editable.
    /// During a drag it runs ahead of the draft, which is written on release.
    private(set) var working: EditedGlyph?
    /// The source glyph as the editor first showed it; a glyph equal to it
    /// is not an edit and stays out of the recipe.
    private(set) var original: EditedGlyph?
    /// How far simplification moved the source curve (design §5.8), for the info line.
    private(set) var simplificationError = 0.0
    var tool = Tool.select {
        didSet { if tool != .pen { finishPen() } }
    }
    var selection: Target?
    var showsOriginal = true
    /// The contour the pen is drawing; it joins the glyph when closed.
    private(set) var pendingContour: [OutlineNode] = []
    /// The live strip under the canvas.
    private(set) var preview: GlyphPreview?

    private struct Snapshot: Equatable {
        var outlines: [String: EditedGlyph]
        var selected: Character?
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// Taken when a drag starts; pushed only if the drag changed something.
    private var dragStart: Snapshot?
    private var previewTask: Task<Void, Never>?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// Characters the draft has redrawn.
    var editedCount: Int { editor.draft.outlines.count }

    init?(editor: EditorModel) {
        guard let font = editor.sourceFont?.font else { return nil }
        self.editor = editor
        self.font = font
        groups = GlyphEditorModel.candidateGroups.compactMap { title, characters in
            let present = characters.filter { font.characterMap.mappings[$0.unicodeScalars.first!.value] != nil }
            return present.isEmpty ? nil : CharacterGroup(title: title, characters: present)
        }
        for character in groups.flatMap(\.characters) {
            if let glyphID = font.characterMap.mappings[character.unicodeScalars.first!.value] {
                sourcePaths[character] = try? font.path(ofGlyph: Int(glyphID))
            }
        }
        select(groups.first?.characters.first)
    }

    static func key(_ character: Character) -> String { String(character) }

    func isEdited(_ character: Character) -> Bool { editor.draft.outlines[GlyphEditorModel.key(character)] != nil }

    /// The path the grid shows: the draft's redrawn glyph, or the source's.
    func gridPath(_ character: Character) -> CGPath? {
        editor.draft.outlines[GlyphEditorModel.key(character)]?.path ?? sourcePaths[character]
    }

    // MARK: Choosing a glyph

    func select(_ character: Character?) {
        finishPen()
        selected = character
        selection = nil
        guard let character, let scalar = character.unicodeScalars.first,
            let source = try? font.editableGlyph(for: scalar.value)
        else {
            working = nil
            original = nil
            schedulePreview()
            return
        }
        original = source.glyph
        simplificationError = source.maxError
        working = editor.draft.outlines[GlyphEditorModel.key(character)] ?? source.glyph
        schedulePreview()
    }

    // MARK: Changes and undo

    private var snapshot: Snapshot { Snapshot(outlines: editor.draft.outlines, selected: selected) }

    /// One undoable change: `change` edits a copy of the working glyph.
    func apply(_ change: (inout EditedGlyph) -> Void) {
        guard var glyph = working else { return }
        change(&glyph)
        guard glyph != working else { return }
        undoStack.append(snapshot)
        redoStack.removeAll()
        working = glyph
        store()
    }

    /// Writes the working glyph to the draft; one equal to the source's is
    /// removed instead, so undoing every change leaves no outlines step.
    private func store() {
        guard let selected, let working else { return }
        let key = GlyphEditorModel.key(selected)
        if working == original {
            editor.draft.outlines[key] = nil
        } else {
            editor.draft.outlines[key] = working
        }
        schedulePreview()
    }

    /// A step remembers the character it changed, so undo and redo both go
    /// back to it, whatever is selected now.
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(Snapshot(outlines: editor.draft.outlines, selected: previous.selected))
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(outlines: editor.draft.outlines, selected: next.selected))
        restore(next)
    }

    private func restore(_ state: Snapshot) {
        editor.draft.outlines = state.outlines
        if state.selected != selected {
            select(state.selected)
        } else if let selected {
            finishPen()
            selection = nil
            working = state.outlines[GlyphEditorModel.key(selected)] ?? original
            schedulePreview()
        }
    }

    /// Back to the source's glyph (undoable).
    func revert() {
        guard let original, working != original else { return }
        apply { $0 = original }
        selection = nil
    }

    // MARK: Canvas: hit testing and dragging

    /// The handle or node within `radius` font units of the point; handles
    /// first, as they sit on top and are smaller.
    func target(atX x: Double, y: Double, radius: Double) -> Target? {
        guard let working else { return nil }
        func near(_ p: OutlinePoint) -> Double { hypot(Double(p.x) - x, Double(p.y) - y) }
        var best: (Target, Double)?
        func consider(_ target: Target, _ point: OutlinePoint?) {
            guard let point else { return }
            let distance = near(point)
            if distance <= radius && (best == nil || distance < best!.1) { best = (target, distance) }
        }
        for (c, contour) in working.contours.enumerated() {
            for (n, node) in contour.enumerated() {
                consider(Target(contour: c, index: n, part: .handleIn), node.handleIn)
                consider(Target(contour: c, index: n, part: .handleOut), node.handleOut)
            }
        }
        if let best { return best.0 }
        for (c, contour) in working.contours.enumerated() {
            for (n, node) in contour.enumerated() { consider(Target(contour: c, index: n, part: .node), node.point) }
        }
        return best?.0
    }

    func beginDrag(_ target: Target) {
        selection = target
        dragStart = snapshot
        grabbed = working.flatMap { glyph -> OutlinePoint? in
            guard glyph.contours.indices.contains(target.contour),
                glyph.contours[target.contour].indices.contains(target.index)
            else { return nil }
            let node = glyph.contours[target.contour][target.index]
            switch target.part {
            case .node: return node.point
            case .handleIn: return node.handleIn
            case .handleOut: return node.handleOut
            }
        }
    }

    /// Where the dragged point was when the drag began.
    private var grabbed: OutlinePoint?

    /// Moves the dragged point by the pointer's travel since the press, not
    /// to the pointer: a press a few pixels off the node must not make it
    /// jump there, and a click that does not move leaves the glyph as it was.
    func drag(by dx: Int, _ dy: Int, breakingSmooth: Bool = false) {
        guard let grabbed else { return }
        drag(to: OutlinePoint(x: grabbed.x + dx, y: grabbed.y + dy), breakingSmooth: breakingSmooth)
    }

    /// Moves the dragged node (with its handles) or handle to a point. A
    /// smooth node's other handle turns to stay in line, keeping its length,
    /// unless `breakingSmooth` (⌥-drag), which makes the node a corner.
    func drag(to point: OutlinePoint, breakingSmooth: Bool = false) {
        guard let target = selection, var glyph = working, dragStart != nil,
            glyph.contours.indices.contains(target.contour),
            glyph.contours[target.contour].indices.contains(target.index)
        else { return }
        var node = glyph.contours[target.contour][target.index]
        switch target.part {
        case .node:
            let dx = point.x - node.x
            let dy = point.y - node.y
            node.point = point
            node.handleIn = node.handleIn.map { OutlinePoint(x: $0.x + dx, y: $0.y + dy) }
            node.handleOut = node.handleOut.map { OutlinePoint(x: $0.x + dx, y: $0.y + dy) }
        case .handleIn, .handleOut:
            let isIn = target.part == .handleIn
            if isIn { node.handleIn = point } else { node.handleOut = point }
            if breakingSmooth {
                node.smooth = false
            } else if node.smooth, let other = isIn ? node.handleOut : node.handleIn {
                let length = hypot(Double(other.x - node.x), Double(other.y - node.y))
                let dx = Double(point.x - node.x)
                let dy = Double(point.y - node.y)
                let arm = hypot(dx, dy)
                if arm > 0 {
                    let mirrored = OutlinePoint(
                        x: node.x - Int((dx / arm * length).rounded()), y: node.y - Int((dy / arm * length).rounded()))
                    if isIn { node.handleOut = mirrored } else { node.handleIn = mirrored }
                }
            }
            // A handle dragged back onto its node is a retracted one.
            if node.handleIn == node.point { node.handleIn = nil }
            if node.handleOut == node.point { node.handleOut = nil }
        }
        glyph.contours[target.contour][target.index] = node
        working = glyph
        schedulePreview()
    }

    /// The drag is over: one undo step, if it moved anything.
    func endDrag() {
        guard let start = dragStart else { return }
        dragStart = nil
        guard let selected, working != (start.outlines[GlyphEditorModel.key(selected)] ?? original) else { return }
        undoStack.append(start)
        redoStack.removeAll()
        store()
    }

    /// 加點: a node on the segment nearest the point, if one is within `radius`.
    func addPoint(atX x: Double, y: Double, radius: Double) {
        guard let hit = working?.nearestSegment(toX: x, y: y), hit.distance <= radius else { return }
        var index = 0
        apply { index = $0.insertNode(contour: hit.contour, segment: hit.segment, t: hit.t) }
        selection = Target(contour: hit.contour, index: index, part: .node)
    }

    func deleteSelection() {
        guard let target = selection else { return }
        apply { $0.removeNode(contour: target.contour, index: target.index) }
        selection = nil
    }

    var selectedNode: OutlineNode? {
        guard let target = selection, let working, working.contours.indices.contains(target.contour),
            working.contours[target.contour].indices.contains(target.index)
        else { return nil }
        return working.contours[target.contour][target.index]
    }

    func toggleSmooth() {
        guard let target = selection, let node = selectedNode else { return }
        apply { $0.setSmooth(!node.smooth, contour: target.contour, index: target.index) }
        selection = Target(contour: target.contour, index: target.index, part: .node)
    }

    // MARK: Pen

    /// One press of the pen: a corner node, or with `handle` (where the
    /// press was dragged to) a smooth node with mirrored handles. A press on
    /// the first node, `radius` font units or closer, closes the contour.
    func penPress(at point: OutlinePoint, handle: OutlinePoint? = nil, radius: Double) {
        if pendingContour.count >= 2, let first = pendingContour.first,
            hypot(Double(point.x - first.x), Double(point.y - first.y)) <= radius
        {
            closePen()
            return
        }
        var node = OutlineNode(x: point.x, y: point.y)
        if let handle, handle != point {
            node.handleOut = handle
            node.handleIn = OutlinePoint(x: 2 * point.x - handle.x, y: 2 * point.y - handle.y)
            node.smooth = true
        }
        pendingContour.append(node)
    }

    /// Adds the pen's contour to the glyph, turned the way the fill needs.
    func closePen() {
        let contour = pendingContour
        pendingContour = []
        guard contour.count >= 2 else { return }
        apply { glyph in
            glyph.contours.append(contour)
            glyph.orientForFill(contour: glyph.contours.count - 1)
        }
    }

    /// Leaving the pen: a contour of three nodes or more is closed and kept,
    /// fewer are dropped.
    func finishPen() {
        if pendingContour.count >= 3 { closePen() } else { pendingContour = [] }
    }

    // MARK: Side bearings

    /// The ink's left edge to the origin, as font editors show it.
    var leftSideBearing: Int? { working?.inkBounds.map { Int($0.minX.rounded()) } }
    var rightSideBearing: Int? {
        guard let working, let bounds = working.inkBounds else { return nil }
        return working.advance - Int(bounds.maxX.rounded())
    }

    /// Moves the outline; the right side bearing stays, so the advance
    /// changes by the same amount (as Glyphs and FontLab do).
    func setLeftSideBearing(_ value: Int) {
        guard let current = leftSideBearing, value != current else { return }
        let dx = value - current
        apply { glyph in
            glyph.translate(dx: dx, dy: 0)
            glyph.advance = max(0, glyph.advance + dx)
        }
    }

    func setRightSideBearing(_ value: Int) {
        guard let current = rightSideBearing, value != current else { return }
        apply { $0.advance = max(0, $0.advance + value - current) }
    }

    func setAdvance(_ value: Int) {
        apply { $0.advance = min(Int(UInt16.max), max(0, value)) }
    }

    /// The three number fields, as bindable properties (0 without a glyph).
    var leftSideBearingField: Int {
        get { leftSideBearing ?? 0 }
        set { setLeftSideBearing(newValue) }
    }
    var rightSideBearingField: Int {
        get { rightSideBearing ?? 0 }
        set { setRightSideBearing(newValue) }
    }
    var advanceField: Int {
        get { working?.advance ?? 0 }
        set { setAdvance(newValue) }
    }

    // MARK: Preview strip

    /// The strip under the canvas, through the draft's whole recipe (so
    /// 加粗 shows) with the glyph as it is on the canvas, even mid-drag.
    private func schedulePreview() {
        previewTask?.cancel()
        var draft = editor.draft
        if let selected, let working {
            draft.outlines[GlyphEditorModel.key(selected)] = working == original ? nil : working
        }
        let steps = draft.steps
        let text = GlyphEditorModel.previewText(for: selected)
        let font = font
        // The draft's replace steps read these; without them the strip
        // would fail for a CJK font that borrows letters or glyphs.
        let replacements = editor.secondFonts.mapValues(\.font)
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(40))
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .userInitiated) {
                try? font.preview(of: text.unicodeScalars.map(\.value), steps: steps, replacements: replacements)
            }.value
            if Task.isCancelled { return }
            preview = result
        }
    }

    /// Waits for the strip, for tests.
    func previewSettled() async {
        await previewTask?.value
    }
}
