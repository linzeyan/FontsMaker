import SwiftUI

struct PageSettings: Equatable {
    var fontSize: CGFloat = 20
    /// Baseline distance as a multiple of the font's own line height
    /// (hhea), so 1 shows the line, or for a pseudo-vertical font the
    /// column pitch, the built font has.
    var lineSpacing: CGFloat = 1
}

/// The page settings, kept across launches for the whole app; the live and
/// the exported preview share them. Not the orientation: that follows the
/// recipe on each page (`EditorModel`).
@propertyWrapper
struct StoredPageSettings: DynamicProperty {
    @AppStorage("page.fontSize") private var fontSize = 20.0
    @AppStorage("page.lineSpacing") private var lineSpacing = 1.0

    var wrappedValue: PageSettings {
        get { PageSettings(fontSize: CGFloat(fontSize), lineSpacing: CGFloat(lineSpacing)) }
        nonmutating set {
            fontSize = Double(newValue.fontSize)
            lineSpacing = Double(newValue.lineSpacing)
        }
    }

    var projectedValue: Binding<PageSettings> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

/// One e-reader page: warm grey paper, black text drawn from the given
/// glyph outlines. A 3:4 portrait screen, like most 6–7.8″ readers.
struct PageView: View {
    static let paper = Color(red: 0.90, green: 0.885, blue: 0.85)

    let page: PageText?
    let settings: PageSettings
    let orientation: PageOrientation

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(PageView.paper))
            guard let page else { return }
            let margin = (min(size.width, size.height) * 0.06).rounded()
            var sheet = context
            var area = CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin)
            if orientation == .readerRotated {
                sheet.concatenate(PageLayout.readerRotation(pageSize: size))
                area = CGSize(width: area.height, height: area.width)
            }
            sheet.translateBy(x: margin, y: margin)
            let placements = PageLayout.layout(
                page, fontSize: settings.fontSize, lineSpacing: settings.lineSpacing, lineLength: area.width,
                pageDepth: area.height)
            for placement in placements {
                guard let glyph = page.positions[placement.index].glyph else { continue }
                let transform = PageLayout.glyphTransform(
                    origin: placement.origin, fontSize: settings.fontSize, unitsPerEm: page.unitsPerEm)
                sheet.fill(Path(glyph.path).applying(transform), with: .color(.black))
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.25)))
        .accessibilityLabel("頁面預覽")
        // What the page shows, which with s2t is not the sample text as typed.
        .accessibilityValue(page?.text ?? "")
    }
}

/// Orientation, size and spacing controls shared by the live and the exported preview.
struct PageSettingsBar: View {
    @Binding var settings: PageSettings
    @Binding var orientation: PageOrientation

    var body: some View {
        // One row where it fits (macOS, iPad); stacked on an iPhone.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { orientationPicker; size; spacing }
            VStack(alignment: .leading, spacing: 8) {
                orientationPicker
                HStack(spacing: 16) { size; spacing }
            }
            VStack(alignment: .leading, spacing: 8) { orientationPicker; size; spacing }
        }
        .font(.callout)
    }

    private var orientationPicker: some View {
        Picker("版面", selection: $orientation) {
            ForEach(PageOrientation.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var size: some View {
        HStack {
            Text("字級")
            Slider(value: $settings.fontSize, in: 12...40, step: 1).frame(width: 110).accessibilityLabel("字級")
            Text("\(Int(settings.fontSize))").monospacedDigit().frame(width: 24)
        }
    }

    private var spacing: some View {
        HStack {
            Text("行距")
            Slider(value: $settings.lineSpacing, in: 0.8...2.0, step: 0.1).frame(width: 110).accessibilityLabel("行距")
            // A multiple of the font's own line height, not of the font size.
            Text(String(format: "%.1f×", Double(settings.lineSpacing))).monospacedDigit()
        }
    }
}
