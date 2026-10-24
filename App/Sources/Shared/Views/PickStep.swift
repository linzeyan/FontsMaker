import FontsMakerKit
import SwiftUI

/// ①: the catalog of fonts to download, in a 中文 and an English tab (plan,
/// Phase 4b), each card drawn in the font itself once it is in the library;
/// then the user's own fonts, a card for adding a file (also dropped
/// anywhere on the window) and one for a link.
struct PickStep: View {
    @Bindable var app: AppModel
    @CompactWidth private var isCompact
    @AppStorage(AppModel.Key.catalogScript) private var script = CatalogFont.Script.chinese
    @State private var showsLink = false
    #if os(iOS)
        @State private var showsSettings = false
    #endif

    /// Fonts in the library that are not catalog fonts: added from a file or a link.
    private var ownEntries: [LibraryEntry] {
        let catalog = Set(CatalogFont.all.map(\.fontSHA256))
        return app.library.entries.filter { !catalog.contains($0.id) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if script == .latin {
                        // Headings rather than a second picker: fifteen
                        // fonts scroll by in one go, and a filter would
                        // hide the groups from each other.
                        ForEach(CatalogFont.LatinGroup.allCases, id: \.self) { group in
                            Text(group.title).font(.title3.weight(.semibold))
                            catalogGrid(CatalogFont.all.filter { $0.latinGroup == group })
                        }
                    } else {
                        catalogGrid(CatalogFont.all.filter { $0.script == script })
                    }
                    Text("你自己的字型").font(.title2.weight(.bold)).padding(.top, 12)
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(ownEntries) { entry in
                            FontCard(app: app, entry: entry)
                        }
                        ownFileCard
                        linkCard
                    }
                    #if os(macOS)
                        InstalledFontsSection(installed: app.installed).id("installed")
                    #endif
                }
                .padding(isCompact ? 16 : 28)
            }
            .accessibilityIdentifier("controls")
            #if os(macOS)
                .onChange(of: app.showsInstalledRequested, initial: true) { _, requested in
                    guard requested else { return }
                    app.showsInstalledRequested = false
                    withAnimation { proxy.scrollTo("installed", anchor: .top) }
                }
            #endif
        }
        .overlay(alignment: .bottom) {
            if app.library.isImporting {
                ProgressView("匯入中…").padding().background(.regularMaterial, in: Capsule()).padding()
            }
        }
        .sheet(isPresented: $showsLink) { LinkSheet(downloads: app.downloads) }
        #if os(iOS)
            .sheet(isPresented: $showsSettings) { SettingsSheet() }
        #endif
    }

    private var columns: [GridItem] {
        // Top-aligned: a card that grows a progress bar must not push its row neighbours down.
        [GridItem(.adaptive(minimum: isCompact ? 280 : 260), spacing: 14, alignment: .top)]
    }

    private func catalogGrid(_ fonts: [CatalogFont]) -> some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(fonts) { font in
                CatalogCard(app: app, font: font)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("想改哪一套字？").font(isCompact ? .title.weight(.bold) : .largeTitle.weight(.bold))
                    Text("下面都是授權允許修改、再散布的字型（OFL），下載一次之後離線也能用。").foregroundStyle(.secondary)
                }
                Spacer()
                if !isCompact { scriptPicker }
                #if os(iOS)
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "gearshape").imageScale(.large).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("設定")
                #endif
            }
            if isCompact { scriptPicker }
            if app.catalogReturn != nil, let entry = app.currentEntry {
                Button("回到「\(entry.displayName)」", systemImage: "arrow.uturn.backward") { app.returnFromCatalog() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var scriptPicker: some View {
        Picker("文字", selection: $script) {
            ForEach(CatalogFont.Script.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    private var linkCard: some View {
        Button {
            showsLink = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "link.circle").font(.largeTitle)
                Text("從網址加入").font(.headline)
                Text("貼上 GitHub release 或字型檔的網址").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("從網址加入")
    }

    private var ownFileCard: some View {
        Button {
            app.importRequested = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle").font(.largeTitle)
                Text("用我自己的字型檔").font(.headline)
                #if os(macOS)
                    Text("或把檔案拖進這個視窗（⌘O）").font(.caption).foregroundStyle(.secondary)
                #else
                    Text("從「檔案」選 .ttf、.otf 或 .ttc").font(.caption).foregroundStyle(.secondary)
                #endif
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("用我自己的字型檔")
    }
}

/// A library font as a specimen in the font itself. A font whose license
/// forbids changes (product spec §4.2) is marked and cannot be opened, only
/// renamed or deleted (`LibraryFontMenu`).
private struct FontCard: View {
    @Bindable var app: AppModel
    let entry: LibraryEntry

    var body: some View {
        let restricted = entry.license == .restricted
        let font = Specimen.font(app.library.fontURL(for: entry), size: 30)
        Button {
            app.open(entry.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(font.map(Specimen.text(for:)) ?? Specimen.chinese)
                    .font(font.map { SwiftUI.Font($0) } ?? .system(size: 30))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    // Clear of the ⋯ button.
                    .padding(.trailing, LibraryFontMenu.buttonSize)
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.displayName).font(.headline).lineLimit(1)
                    Spacer()
                    LicenseBadge(license: entry.license)
                }
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if restricted {
                    Text("授權禁止修改，FontsMaker 不會處理這套字。").font(.caption).foregroundStyle(.red)
                }
            }
            .padding(14)
            .opacity(restricted ? 0.6 : 1)
            .contentShape(Rectangle())
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if app.currentFontID == entry.id {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(restricted)
        .accessibilityLabel(entry.displayName)
        .accessibilityIdentifier("fontCard")
        .modifier(LibraryFontMenu(app: app, entry: entry, title: entry.displayName, isCatalog: false))
    }

    /// A renamed font says what it is: its own name joins the counts.
    private var details: String {
        let counts = "\(entry.glyphCount.formatted()) 字形 · \(entry.characterCount.formatted()) 字元"
        if entry.customName != nil { return "\(entry.fontName) · \(counts)" }
        return entry.localizedFamilyName == nil ? counts : "\(entry.familyName) · \(counts)"
    }
}

/// Solid fills with white text: legible on any card or selection colour
/// (a green label on the selected row's blue was not).
struct LicenseBadge: View {
    let license: LicenseStatus

    var body: some View {
        let (text, color): (String, Color) =
            switch license {
            case .openFontLicense: ("OFL", Color(red: 0.12, green: 0.48, blue: 0.22))
            case .unknown: ("授權未知", Color(red: 0.72, green: 0.38, blue: 0.0))
            case .restricted: ("禁止修改", Color(red: 0.75, green: 0.1, blue: 0.1))
            }
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(color, in: Capsule())
    }
}

/// The app-wide settings: macOS's Settings window, iOS's sheet from ①.
struct ThreeStepsToggle: View {
    @AppStorage(AppModel.Key.threeSteps) private var threeSteps = true

    var body: some View {
        Toggle("每次都分三步走", isOn: $threeSteps)
        Text("關掉後，調整和匯出合成一個畫面，打開 App 直接回到上次那套字；「換字型」回到挑字型。")
            .font(.caption).foregroundStyle(.secondary)
    }
}

#if os(iOS)
    private struct SettingsSheet: View {
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                Form {
                    Section { ThreeStepsToggle() }
                    Section {
                        NavigationLink("第三方授權") { LicensesView() }
                    }
                }
                .navigationTitle("設定")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
            }
        }
    }
#endif
