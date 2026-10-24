import XCTest

/// iOS end to end (product spec S1–S3, plus embolden with pseudoVertical) on
/// the simulator it runs on, iPhone or iPad, through the three steps: ① pick
/// or import a font, ② switch effects on and look at the page and its 原字,
/// ③ choose where it is read, name it, build and save it to Files or share
/// it, review risky glyphs; with a screenshot of each step.
///
/// `scripts/ios-flows.sh` runs it after putting GuanKiapTsingKhai.ttf,
/// CrimsonText-Regular.ttf and reject-woff.woff into the simulator's On My iPhone/iPad folder, and takes
/// the exported fonts and recipes from that folder afterwards. The system
/// language is Traditional Chinese (Taiwan), so system UI is matched by its
/// zh-Hant labels. Tests run in name order and build on each other: the
/// import comes first, the persistence check last.
@MainActor
final class FlowTests: XCTestCase {
    let app = XCUIApplication()

    // MARK: Flows

    /// Import through Files from ①: an unsupported format is refused with
    /// the reason in Chinese, a TrueType font is added and opened in ②.
    func test1Import() {
        launch()
        shot("01-pick-empty")
        // Below the catalog, in a lazy grid: not in the tree until scrolled to.
        let ownFile = app.buttons["用我自己的字型檔"]
        scroll(to: ownFile)
        tap(ownFile, "own font card")
        pickInFiles("reject-woff", shotName: "02-files-picker")
        let alert = app.alerts["有檔案無法匯入"]
        require(alert, "no import error for a WOFF font")
        XCTAssertTrue(
            alert.staticTexts.matching(NSPredicate(format: "label CONTAINS '網頁字型（WOFF）'")).count > 0,
            "the alert says why, in Chinese")
        shot("03-import-error")
        alert.buttons["好"].tap()

        scroll(to: ownFile)
        tap(ownFile, "own font card")
        pickInFiles("GuanKiapTsingKhai")
        require(effect("加粗"), "the imported font did not open in ②", timeout: 60)
        XCTAssertTrue(stepButton(2).isSelected, "an imported font goes straight to ②")
        shot("04-adjust-imported")
        tap(stepButton(1), "step 1")
        require(fontCard, "imported font not among the cards")
        shot("04-pick-imported")
    }

    /// S1: embolden, the suggested name, build and save to Files, review a
    /// risky glyph and export again over the first file.
    func test2Embolden() {
        launch()
        openFont()
        shot("05-s1-adjust")
        setSwitch(effect("加粗"), on: true)
        require(app.sliders["粗細"], "the weight slider shows once 加粗 is on")
        requireValue(previewCaption, containing: "加粗 12", "加粗 starts at 12")
        shot("06-s1-embolden")
        compare(shotName: "06-s1-compare-source")

        goToExport()
        shot("07-s1-export")
        chooseTarget("Kobo")
        // The suggestion: the source's initials, the effect, Medium for bold.
        require(nameDisclosure("GKTK Ebook Medium"), "the suggested name is not GKTK Ebook Medium")
        setNames("Ebook Kai", "電子書楷")
        require(nameDisclosure("Ebook Kai Medium"), "the names typed are not shown folded")
        shot("08-s1-named")
        exportToFiles(shotPrefix: "09-s1", progressShot: "09-s1-build-progress")
        // Imported from a file: the app has no license text to give with it, and says so.
        require(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '沒有附上授權全文'")).firstMatch,
            "the done view does not say the license text is missing")
        require(app.staticTexts["接下來：放進Kobo"], "no Kobo steps after the export")
        require(app.staticTexts["步驟待實機驗證"], "the Kobo steps are not marked unverified")
        scroll(to: app.staticTexts["步驟待實機驗證"])
        shot("10-s1-install-guide")

        let review = app.buttons["檢查這些字"]
        scroll(to: review)
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label MATCHES '有 \\\\d+ 個字加粗後筆畫可能黏在一起'")).count > 0,
            "the risk notice counts the glyphs")
        shot("11-s1-risk-notice")
        review.tap()
        let decide = app.buttons.matching(NSPredicate(format: "label == '接受' AND enabled == true")).firstMatch
        require(decide, "no decision menu in the review grid")
        shot("12-s1-risk-review")
        decide.tap()
        tap(app.buttons["不加粗"], "skip in the decision menu")
        tap(app.buttons["套用並重新匯出"], "apply and export again")
        // The sheet closes and the export runs again, into the same folder;
        // Files (iOS 26) keeps both files rather than asking to replace.
        saveInExporter(folder: nil, shotName: "13-s1-export-again-files")
        requireExported(place: localStorageName, shotName: "13-s1-exported-again")
        tap(app.buttons["檢查這些字"], "review again")
        require(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS '未加粗'")).firstMatch,
            "the skipped glyph is not shown as not emboldened", timeout: 60)
        shot("14-s1-review-after")
        tap(app.buttons["完成"].firstMatch, "done in the review sheet")
    }

    /// S2: pseudo-vertical, with the turned page. The destination is
    /// remembered and the style follows the effects; a share sheet closed
    /// without sharing exports nothing.
    func test3PseudoVertical() {
        launch()
        openFont()
        setSwitch(effect("加粗"), on: false)
        setSwitch(effect("直排閱讀"), on: true)
        require(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH '句讀標點' OR label == '置中（台灣慣例）'")).firstMatch,
            "the punctuation choice is in the card")
        requireLayout(rotatedLayout, "the page turns with pseudoVertical")
        shot("15-s2-adjust")
        // 原字 on the turned page: the source's CJK lies on its side.
        compare(shotName: "15-s2-compare-source")

        goToExport()
        XCTAssertTrue(app.buttons["Kobo"].isSelected, "the destination chosen last time is kept")
        // The name typed stays; the style was the suggestion, and follows.
        require(nameDisclosure("Ebook Kai Regular"), "the style did not follow the effects")
        setNames("Kai Vertical", "楷書直排")
        share(shotName: "16-s2-share-sheet")
        requireNotExported(shotName: "16-s2-share-dismissed")
        exportToFiles(shotPrefix: "17-s2")
        // Drawn by CoreText from the exported file, turned as the recipe says (the screenshot shows it).
        require(exportPage, "no page drawn from the exported font")
    }

    /// S3: simplified to traditional, with phrases (design §5.4): 后来 reads
    /// 後來 and 里程碑 stays 里程碑, where character by character it is
    /// 裡程碑. Also: a cancelled save to Files exports nothing.
    func test4SimplifiedToTraditional() {
        launch()
        openFont()
        setSwitch(effect("直排閱讀"), on: false)
        setSwitch(effect("簡體書顯示繁體"), on: true)
        requireLayout(app.buttons["橫排"], "the page follows the draft")
        requireValue(previewPage, containing: "為後來里程碑", "the preview applies the phrase rules")
        shot("18-s3-adjust")
        // 原字 is the text as typed, in the source font: simplified stays simplified.
        compare(shotName: "18-s3-compare-source") {
            self.requireValue(self.previewPage, containing: "为后来里程碑", "原字 shows the source font as is")
        }
        requireValue(previewPage, containing: "為後來里程碑", "成品 again after 原字")

        let more = app.buttons["更多選項"]
        scroll(to: more)
        more.tap()
        let phrases = app.switches["依詞彙轉換（里程碑不會變成裡程碑）"]
        scroll(to: phrases)
        XCTAssertEqual(phrases.value as? String, "1", "簡轉繁 converts by phrase when switched on")
        shot("19-s3-more-options")
        setSwitch(phrases, on: false)
        requireValue(previewPage, containing: "為後來裡程碑", "without phrases the preview converts per character")
        shot("19-s3-per-character")
        chooseOneToMany("不轉換")
        scroll(to: phrases)
        XCTAssertFalse(phrases.isEnabled, "phrases need the most common traditional form")
        XCTAssertEqual(phrases.value as? String, "0")
        shot("19-s3-phrases-disabled")
        chooseOneToMany("取最常用的繁體")
        setSwitch(phrases, on: true)
        requireValue(previewPage, containing: "為後來里程碑", "phrases on again")

        goToExport()
        setNames("Trad Kai", "繁體楷")
        tapExport()
        require(saveInFiles, "Files exporter did not open", timeout: 300)
        if !isPad {
            // On iPhone, cancel is on Browse, a level above On My iPhone.
            tap(app.navigationBars.buttons["瀏覽"], "Browse in the Files exporter")
        }
        // A fresh iPad's exporter has one in the sidebar's bar and one in the
        // folder's; either closes it.
        let cancel = app.buttons["取消"].firstMatch
        tap(cancel, "cancel in the Files exporter")
        if !cancel.waitForNonExistence(timeout: 15) { fail("the Files exporter did not close") }
        requireNotExported(shotName: "20-s3-export-cancelled")

        exportToFiles(shotPrefix: "21-s3")
        requireValue(exportPage, containing: "為後來里程碑", "CoreText applies the exported phrase rules")
        let details = app.buttons["檔案資訊"]
        scroll(to: details)
        details.tap()
        let check = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", ".*；(\\d+)/\\1 個字的字形與預覽相同")
        ).firstMatch
        require(check, "the export check found glyphs that differ from the preview")
        require(
            app.staticTexts["檢查的是 App 內交給「檔案」前的那一份，與存出的檔案位元組相同（sha256 同上）。"],
            "the details do not say the check read the app's copy")
        scroll(to: check)
        shot("22-s3-file-details")
        let phraseLine = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'OpenCC phrases'")).firstMatch
        scroll(to: phraseLine)
        shot("22-s3-step-report")
    }

    /// Embolden with pseudoVertical; the layouts an iPad meets; exports into
    /// a folder and shares through Save to Files; leaves page settings to
    /// check after a relaunch.
    func test5BoldPseudoVertical() {
        launch()
        openFont()
        setSwitch(effect("簡體書顯示繁體"), on: false)
        setSwitch(effect("加粗"), on: true)
        setSwitch(effect("直排閱讀"), on: true)
        requireLayout(rotatedLayout, "the page turns with pseudoVertical")
        shot("23-combined-adjust")
        compare(shotName: "23-combined-compare-source")
        portraitShot("23-combined-adjust")

        goToExport()
        require(nameDisclosure("Trad Kai Medium"), "the style did not follow the effects")
        setNames("Ebook Kai V", "電子書楷直排")
        exportToFiles(shotPrefix: "24-combined", progressShot: "24-combined-build-progress")
        portraitShot("24-combined-exported")
        // Folders that ios-flows.sh makes in On My iPhone/iPad.
        exportToFiles(shotPrefix: "25-combined-folder", folder: "字型")
        shareToFiles(shotPrefix: "25-combined-share", folder: "分享")

        // For test6: the smallest size and a word added to the preview text.
        // The thumb is dragged past the slider's start, where it stops at the
        // minimum; adjust(toNormalizedSliderPosition:) lands a few steps off
        // on a slider this short.
        tap(stepButton(2), "step 2")
        setPageSettings(shown: true)
        let size = app.sliders["字級"]
        require(size, "font size slider")
        size.coordinate(withNormalizedOffset: CGVector(dx: size.normalizedSliderPosition, dy: 0.5))
            .press(forDuration: 0.3, thenDragTo: size.coordinate(withNormalizedOffset: CGVector(dx: -1, dy: 0.5)))
        require(app.staticTexts["12"], "font size did not go to 12")
        shot("26-page-settings")
        setPageSettings(shown: false)
        // The text is edited on the page itself, which takes no room otherwise.
        tap(app.buttons["編輯預覽文字"], "edit the preview text")
        let text = app.textViews["sampleText"]
        tap(text, "preview text")
        text.typeText("永和")
        XCTAssertTrue((text.value as? String)?.contains("永和") == true)
        shot("26-edit-text")
        tap(app.buttons["完成"], "done editing the preview text")
        requireValue(previewPage, containing: "永和", "the page shows the edited text")
    }

    /// Font size, preview text and the draft survive a relaunch, and the
    /// layout follows the restored draft; so does a change made right before
    /// the app goes to the background and is ended there. With 「每次都分三步走」
    /// off, the app opens on the last font, ② and ③ on one screen.
    func test6SettingsPersist() {
        launch()
        openFont()
        setPageSettings(shown: true)
        require(rotatedLayout, "orientation picker")
        XCTAssertTrue(rotatedLayout.isSelected, "the restored draft (test5's) has pseudoVertical")
        XCTAssertTrue(app.staticTexts["12"].exists, "the font size set before the relaunch (12) is kept")
        requireValue(previewPage, containing: "永和", "the preview text edited before the relaunch is kept")
        shot("27-relaunch-adjust")
        setPageSettings(shown: false)
        goToExport()
        XCTAssertTrue(app.buttons["Kobo"].isSelected, "the destination is kept")
        require(nameDisclosure("Ebook Kai V Medium"), "the draft's names are not restored")
        shot("28-relaunch-export")
        tap(stepButton(2), "step 2")

        // From the change straight to the background, and ended there as iOS
        // may end a suspended app. XCUITest takes about 1.6 s from the tap to
        // the background, past the draft's 1 s debounce, so this checks the
        // whole path rather than which write kept the change; the app logs
        // "saved ahead of its debounce" when it was the write on leaving the
        // foreground.
        let pseudoVertical = effect("直排閱讀")
        scroll(to: pseudoVertical)
        XCTAssertEqual(pseudoVertical.value as? String, "1")
        flip(pseudoVertical)
        XCUIDevice.shared.press(.home)
        app.terminate()
        launch()
        openFont()
        scroll(to: pseudoVertical)
        XCTAssertEqual(pseudoVertical.value as? String, "0", "the change made just before the background is kept")
        requireLayout(app.buttons["橫排"], "the page follows the restored draft")
        shot("28-relaunch-after-background")

        // Three steps off: straight back to this font on the next launch.
        tap(stepButton(1), "step 1")
        tap(app.buttons["設定"], "settings in ①")
        let threeSteps = app.switches["每次都分三步走"]
        require(threeSteps, "the three-steps switch is not in the settings")
        XCTAssertEqual(threeSteps.value as? String, "1", "the three steps are on by default")
        setSwitch(threeSteps, on: false, scrolling: false)
        shot("29-settings-three-steps-off")
        tap(app.buttons["完成"].firstMatch, "done in the settings")
        app.terminate()
        launch()
        require(app.buttons["換字型"], "without the steps the app does not reopen the last font", timeout: 30)
        XCTAssertFalse(stepButton(1).exists, "the step bar shows with the steps off")
        require(effect("加粗"), "the combined screen has no effect cards")
        scroll(to: app.buttons["做出字型並存檔"])
        shot("30-combined-screen")
        tap(app.buttons["換字型"], "change font")
        require(fontCard, "換字型 does not go back to ①")

        // The licenses credit the phrase dictionaries 簡轉繁 uses.
        tap(app.buttons["設定"], "settings in ①")
        tap(app.buttons["第三方授權"].firstMatch, "licenses in the settings")
        let generated = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'STPhrases_GeneratedFromRegionalPhrases'")
        ).firstMatch
        let licenses = app.collectionViews.containing(
            NSPredicate(format: "label BEGINSWITH 'FontsMaker 內含以下第三方'")
        ).firstMatch
        scroll(to: generated, in: licenses)
        shot("31-licenses-opencc")
    }

    /// English reading (Phase 4c): a Latin font gets 字寬, 字距 and 行高 and
    /// not the CJK cards, its page is English, and 加粗 with all three
    /// exports. The page before and after, and 原字 for the comparison.
    func test7EnglishReading() {
        launch()
        // test6 left the three steps off: back on, from ①.
        tap(app.buttons["換字型"], "change font", timeout: 30)
        tap(app.buttons["設定"], "settings in ①")
        let threeSteps = app.switches["每次都分三步走"]
        require(threeSteps, "the three-steps switch is not in the settings")
        setSwitch(threeSteps, on: true, scrolling: false)
        tap(app.buttons["完成"].firstMatch, "done in the settings")

        // Below the catalog, in a lazy grid: not in the tree until scrolled to.
        let ownFile = app.buttons["用我自己的字型檔"]
        scroll(to: ownFile)
        tap(ownFile, "own font card")
        pickInFiles("CrimsonText-Regular")
        require(effect("加粗"), "the imported Latin font did not open in ②", timeout: 60)
        XCTAssertFalse(effect("直排閱讀").exists, "a Latin font has nothing to turn")
        XCTAssertFalse(effect("簡體書顯示繁體").exists, "a Latin font has nothing to convert")
        // The text test5 typed is for CJK fonts: a Latin font would draw it
        // as empty boxes, so it gets its own text, English by default.
        requireValue(previewPage, containing: "It was the best of times", "a Latin font previews English")
        XCTAssertFalse(
            (previewPage.value as? String)?.contains("永和") ?? true, "the text typed for CJK fonts stays with them")
        shot("32-latin-adjust")

        setSwitch(effect("加粗"), on: true)
        let widen = app.switches["字寬跟著加寬（字母不擠在一起）"]
        setSwitch(widen, on: true)
        setSwitch(effect("字距"), on: true)
        require(app.sliders["字距大小"], "the tracking slider shows once 字距 is on")
        setSwitch(effect("行高"), on: true)
        require(app.sliders["行高大小"], "the line height slider shows once 行高 is on")
        require(app.staticTexts["行高 1.50 em（原本 1.30 em）"], "行高 starts 0.2 em above the font's own line")
        requireValue(
            previewCaption, containing: "加粗 12（字寬加寬）、字距 +20、行高 1.50 em", "the caption lists what 成品 applies")
        shot("33-latin-tuned")
        compare(shotName: "33-latin-compare-source") {
            self.require(
                self.app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '原樣：未加粗、字距原樣、行高原樣'")).firstMatch,
                "原字 says what it leaves out")
        }

        goToExport()
        require(nameDisclosure("CT Ebook Medium"), "the suggested name is not CT Ebook Medium")
        exportToFiles(shotPrefix: "34-latin", progressShot: "34-latin-build-progress")
        require(exportPage, "no page drawn from the exported font")
        scroll(to: exportPage)
        shot("35-latin-export-page")
    }

    /// The catalog (plan, Phase 4b), over the network: ①'s English tab,
    /// kept across a relaunch; Literata downloaded, its Bold instance chosen
    /// in ②, emboldened and saved to Files; then 芫荽, which comes in a zip,
    /// from the 中文 tab, the same way. ios-flows.sh checks the recipes name
    /// the instance and rebuilds them with the CLI.
    func test8Catalog() {
        launch()
        // test6 left the three steps off: the app opened on the last font.
        let change = app.buttons["換字型"]
        if change.waitForExistence(timeout: 30) { change.tap() }
        tap(app.buttons["設定"], "settings in ①")
        setSwitch(app.switches["每次都分三步走"], on: true, scrolling: false)
        tap(app.buttons["完成"].firstMatch, "done in the settings")

        let english = app.segmentedControls.buttons["English"]
        tap(english, "the English tab")
        let getLiterata = app.buttons["下載「Literata」"]
        require(getLiterata, "Literata is not in the English tab")
        shot("40-catalog-english")
        app.terminate()
        launch()
        require(english, "no English tab after a relaunch")
        XCTAssertTrue(english.isSelected, "① opens on the tab it was left on")

        scroll(to: getLiterata)
        getLiterata.tap()
        let progress = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '下載中'")).firstMatch
        if progress.waitForExistence(timeout: 10) { shot("41-catalog-downloading") }
        let literata = app.buttons["Literata"]
        require(literata, "Literata did not download", timeout: 600)
        scroll(to: literata)
        shot("42-catalog-downloaded")
        literata.tap()
        require(effect("加粗"), "② did not open on Literata", timeout: 60)
        shot("43-literata-adjust")

        let style = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '樣式' OR label == 'Regular'")).firstMatch
        scroll(to: style)
        style.tap()
        tap(app.buttons["Bold"].firstMatch, "Bold in the 樣式 menu")
        require(app.staticTexts["700"], "the weight axis does not show 700")
        shot("44-literata-bold")
        setSwitch(effect("加粗"), on: true)
        shot("45-literata-bold-embolden")
        goToExport()
        chooseTarget("Kobo")
        // The Bold instance emboldened is one weight class heavier than Bold.
        require(nameDisclosure("L Ebook ExtraBold"), "the suggested name is not L Ebook ExtraBold")
        exportToFiles(shotPrefix: "46-literata")
        // A download came with its license, and the OFL wants it passed on with the font.
        let licensed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '已附上來源字型的授權全文'")).firstMatch
        require(licensed, "the done view does not say the license went with the font")
        // Named as Files reports it; Files sometimes leaves the text out of
        // the URLs it returns (seen on iOS 26.5), and then only 授權全文 is
        // said. ios-flows.sh checks the file itself is beside the font.
        require(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS '、授權全文'")).firstMatch,
            "the done view does not say the license file is beside the font")
        scroll(to: licensed)
        shot("46-literata-license")

        tap(stepButton(1), "step 1")
        tap(app.segmentedControls.buttons["中文"], "the 中文 tab")
        let getIansui = app.buttons["下載「芫荽」"]
        scroll(to: getIansui)
        getIansui.tap()
        let iansui = app.buttons["芫荽"]
        require(iansui, "芫荽 did not download", timeout: 600)
        scroll(to: iansui)
        shot("47-catalog-chinese-downloaded")
        iansui.tap()
        require(effect("加粗"), "② did not open on 芫荽", timeout: 60)
        setSwitch(effect("加粗"), on: true)
        shot("48-iansui-embolden")
        goToExport()
        require(nameDisclosure("I Ebook Medium"), "the suggested name is not I Ebook Medium")
        exportToFiles(shotPrefix: "49-iansui")
    }

    /// 英文字母換成另一套字型 (Phase 4d): 原俠正楷 takes its Latin letters
    /// from Literata, which test8 downloaded; the page shows them, 原字 the
    /// font's own, and the export carries the replace step before embolden.
    /// ios-flows.sh checks the recipe; verify-phase4d.sh rebuilds it.
    func test9MixedLatin() {
        launch()
        openFont()
        let card = effect("英文字母換成另一套字型")
        scroll(to: card)
        shot("50-mixed-card-off")
        setSwitch(card, on: true)
        // The library's OFL fonts by name: Crimson Text comes first.
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '英文字型' OR label == 'Crimson Text'"))
            .firstMatch
        scroll(to: picker)
        picker.tap()
        tap(app.buttons["Literata"].firstMatch, "Literata in the 英文字型 menu")
        require(app.sliders["英文字母大小"], "the size slider shows once a font is chosen")
        requireValue(previewCaption, containing: "英文換成 Literata", "the caption names the second font")
        shot("51-mixed-literata")
        compare(shotName: "51-mixed-compare-source") {
            self.require(
                self.app.staticTexts.matching(NSPredicate(format: "label CONTAINS '英文未換字型'")).firstMatch,
                "原字 says the letters are the font's own")
        }

        goToExport()
        setNames("Mixed Kai", "中英楷")
        exportToFiles(shotPrefix: "52-mixed")
        require(exportPage, "no page drawn from the exported font")
        scroll(to: exportPage)
        shot("53-mixed-export-page")
    }

    /// Regular／Italic／Bold／Bold Italic at once (technical design §5.6):
    /// Crimson Text's other three files, imported in one pick, join the
    /// Regular test7 imported. ③ finds the family and a file for each style,
    /// and one save puts the four fonts and their recipes in Files.
    /// ios-flows.sh checks the recipes' style names and weight classes, and
    /// the CLI rebuilds them.
    func test9bStyleSet() {
        launch()
        let ownFile = app.buttons["用我自己的字型檔"]
        scroll(to: ownFile)
        tap(ownFile, "own font card", timeout: 30)
        browseLocalStorage()
        for (name, predicate) in [
            ("Italic", "label CONTAINS 'CrimsonText-Italic'"),
            ("Bold", "label CONTAINS 'CrimsonText-Bold' AND NOT label CONTAINS 'BoldItalic'"),
            ("BoldItalic", "label CONTAINS 'CrimsonText-BoldItalic'"),
        ] {
            tap(app.cells.matching(NSPredicate(format: predicate)).firstMatch, "file CrimsonText-\(name)")
        }
        shot("54-set-import-three")
        tap(app.buttons.matching(NSPredicate(format: "label IN {'打開', '開啟', '完成'}")).firstMatch, "open in Files")
        require(effect("加粗"), "the imported files did not open in ②", timeout: 60)
        setSwitch(effect("加粗"), on: true)

        goToExport()
        let together = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Regular／Italic／Bold／Bold Italic'"))
            .firstMatch
        require(together, "③ does not offer the four styles of the family", timeout: 30)
        setSwitch(together, on: true)
        for role in ["Regular", "Italic", "Bold", "Bold Italic"] {
            require(
                app.descendants(matching: .any).matching(identifier: "styleSource.\(role)").firstMatch,
                "no source menu for \(role)")
        }
        // The name line says the family and the four files, not the one font's style.
        require(nameDisclosure("CT Ebook（Regular／Italic／Bold／Bold Italic）"), "the name line is not the set's")
        scroll(to: together)
        shot("55-set-styles")
        exportToFiles(shotPrefix: "56-set", progressShot: "56-set-build-progress")
        require(app.staticTexts["已存好 4 個字型與配方"], "③ does not say the four fonts were saved")
        let coreText = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'CTEbook-BoldItalic.ttf：CoreText'"))
            .firstMatch
        scroll(to: coreText)
        shot("57-set-exported")
    }

    /// Glyph editing (Phase 4f), from ②'s 逐字修改造型 card on Crimson Text.
    /// Last, so its edits reach no export that a later flow checks.
    /// On iPad: the pen draws a new contour on a, one of its nodes is
    /// dragged, 0's right side bearing is typed, undo and redo walk it back
    /// and forth, and ② says two characters are redrawn. iPhone shows the
    /// glyphs without the tools.
    func test9cGlyphEditor() {
        launch()
        // The app opens on ② when the three steps are off.
        let change = app.buttons["換字型"]
        if change.waitForExistence(timeout: 30) { change.tap() }
        let ownFile = app.buttons["用我自己的字型檔"]
        scroll(to: ownFile)
        tap(ownFile, "own font card")
        pickInFiles("CrimsonText")
        require(effect("加粗"), "Crimson Text did not open in ②", timeout: 60)
        let open = app.buttons.matching(NSPredicate(format: "label IN {'編輯字形…', '繼續編輯…'}")).firstMatch
        scroll(to: open)
        open.tap()
        let canvas = app.descendants(matching: .any)["glyphCanvas"]
        require(canvas, "the glyph editor did not open")
        func glyph(_ character: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "字形 \(character)")).firstMatch
        }
        tap(glyph("a"), "a in the glyph grid")
        shot("58-glyph-editor")
        guard isPad else {
            XCTAssertFalse(app.segmentedControls["tools"].exists, "iPhone shows the glyphs without the tools")
            tap(app.buttons["完成"].firstMatch, "done in the editor")
            return
        }

        // 'N 個點・…' under the canvas counts the working glyph's nodes.
        let nodes = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '個點・'")).firstMatch
        func nodeCount() -> Int { Int(nodes.label.prefix { $0.isNumber }) ?? -1 }
        require(nodes, "no node count under the canvas")
        let before = nodeCount()
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        }
        tap(app.segmentedControls["tools"].buttons["鋼筆"], "the pen tool")
        point(0.08, 0.12).tap()
        point(0.2, 0.12).tap()
        point(0.14, 0.26).tap()
        point(0.08, 0.12).tap()
        XCTAssertEqual(nodeCount(), before + 3, "the pen closed a three-node contour on its first node")
        XCTAssertTrue(glyph("a").label.hasSuffix("已修改"), "a is marked as redrawn in the grid")
        shot("59-glyph-pen")

        tap(app.segmentedControls["tools"].buttons["選取"], "the select tool")
        point(0.2, 0.12).press(forDuration: 0.2, thenDragTo: point(0.27, 0.2))
        XCTAssertEqual(nodeCount(), before + 3, "a drag moves a node, it adds none")
        shot("60-glyph-node-moved")

        tap(glyph("0"), "0 in the glyph grid")
        let right = app.textFields["右側邊距"]
        require(right, "no right side bearing field")
        let source = right.value as? String ?? ""
        // The tap that focuses this right-aligned field leaves the cursor
        // before the number, where deletes take nothing away; a second tap
        // in the focused field puts it at the end.
        let end = right.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5))
        end.tap()
        end.tap()
        right.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: source.count) + "90\n")
        XCTAssertEqual(right.value as? String, "90", "the right side bearing is what was typed")
        XCTAssertTrue(glyph("0").label.hasSuffix("已修改"), "0 is marked as redrawn in the grid")
        shot("61-glyph-side-bearing")
        tap(app.buttons["復原"], "undo")
        requireValue(right, containing: source, "undo puts the source's side bearing back")
        shot("62-glyph-undo")
        tap(app.buttons["重做"], "redo")
        requireValue(right, containing: "90", "redo brings the typed side bearing back")
        shot("63-glyph-redo")

        tap(app.buttons["完成"].firstMatch, "done in the editor")
        requireValue(previewCaption, containing: "改了 2 個字的造型", "② says what the editor changed")
        shot("64-glyph-adjust")
    }

    /// Risk review's 從另一套字型取代 (technical design §5.7): 原俠正楷, as
    /// test9MixedLatin left it (Literata's letters, 加粗 12), exported, then
    /// 鑭, which crowds to grade A, taken from 芫荽 (test8 downloaded it) and
    /// exported again. ios-flows.sh checks the second recipe has the borrowed
    /// replace step after embolden; the CLI rebuilds it. Named to run last
    /// whether flows sort by case or not: it leaves a decision in the draft
    /// test9MixedLatin exports.
    func test9zRiskReplace() {
        launch()
        openFont()
        goToExport()
        setNames("Borrow Kai", "借字楷")
        exportToFiles(shotPrefix: "65-borrow")
        let review = app.buttons["檢查這些字"]
        scroll(to: review)
        review.tap()
        let menu = app.buttons["decision.鑭"]
        require(menu, "鑭 is not in the review", timeout: 30)
        scroll(to: menu, in: app.scrollViews["reviewGrid"])
        shot("66-borrow-review")
        // The library's fonts are read for the menu after the sheet opens; a
        // menu opened before that lists none yet, so it is opened again.
        let borrow = app.buttons["取自 芫荽"]
        for _ in 0..<4 {
            menu.tap()
            if borrow.waitForExistence(timeout: 10) { break }
            shot("67-borrow-menu-searching")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        }
        require(borrow, "the menu does not offer 芫荽's 鑭")
        shot("67-borrow-menu")
        borrow.tap()
        requireValue(menu, containing: "取自 芫荽", "the cell does not show the decision")
        shot("68-borrow-decided")
        tap(app.buttons["套用並重新匯出"], "apply and export again")
        saveInExporter(folder: nil, shotName: "69-borrow-export-again-files")
        requireExported(place: localStorageName, shotName: "69-borrow-exported-again")
        require(exportPage, "no page drawn from the exported font")
        scroll(to: exportPage)
        shot("70-borrow-export-page")
    }

    /// ①'s own fonts (plan, 4g): a card's ⋯ renames it (a blank name cannot
    /// be saved) and the name survives a relaunch; its long-press menu opens
    /// it in ②, titled with the new name; 刪除 asks first, takes the card
    /// away and closes ② and ③ on it. A downloaded catalog font (the
    /// smallest, from the English tab's Mono group) has 移除下載 and can be
    /// downloaded again. Imports and downloads its own fonts, so it runs
    /// alone too (FONTSMAKER_FLOWS_ONLY); named to run last, as it deletes.
    func test9eOwnFonts() {
        launch()
        // The app opens on ② when the three steps are off.
        let change = app.buttons["換字型"]
        if change.waitForExistence(timeout: 10) { change.tap() }
        let ownFile = app.buttons["用我自己的字型檔"]
        scroll(to: ownFile)
        tap(ownFile, "own font card")
        pickInFiles("CrimsonText-Regular")
        require(effect("加粗"), "Crimson Text did not open in ②", timeout: 60)
        tap(stepButton(1), "step 1")

        // Every Crimson Text file has a card of that name; the one renamed
        // is the one the rest of the flow follows.
        let more = moreButton("Crimson Text")
        scroll(to: more)
        more.tap()
        tap(app.buttons["重新命名…"], "重新命名 in the ⋯ menu")
        let alert = app.alerts["重新命名"]
        require(alert, "no rename alert")
        let field = alert.textFields.firstMatch
        require(field, "no name field in the rename alert")
        XCTAssertEqual(field.value as? String, "Crimson Text", "the field starts with the name shown")
        let save = alert.buttons["儲存"]
        clear(field)
        field.typeText("   ")
        XCTAssertFalse(save.isEnabled, "a blank name cannot be saved")
        shot("65-own-rename-blank")
        clear(field)
        field.typeText("我的英文書")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let renamed = app.buttons["我的英文書"]
        require(renamed, "the card does not show the new name")
        scroll(to: renamed)
        shot("66-own-renamed")

        app.terminate()
        launch()
        if change.waitForExistence(timeout: 10) { change.tap() }
        scroll(to: renamed)
        shot("67-own-renamed-relaunch")

        // Touch has no right click: the card's menu is a long press.
        renamed.press(forDuration: 1.2)
        tap(app.buttons["編輯"], "編輯 in the card's long-press menu")
        require(effect("加粗"), "編輯 did not open the font in ②", timeout: 60)
        require(app.staticTexts["我的英文書"], "② is not titled with the new name")
        shot("68-own-edit")
        tap(stepButton(1), "step 1")

        let renamedMore = moreButton("我的英文書")
        scroll(to: renamedMore)
        renamedMore.tap()
        tap(app.buttons["刪除…"], "刪除 in the ⋯ menu")
        let delete = app.buttons["刪除"]
        require(delete, "deleting does not ask first")
        require(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '字型檔、調整到一半的設定與授權全文'")).firstMatch,
            "the confirmation does not say what goes")
        shot("69-own-delete-confirm")
        delete.tap()
        if !renamed.waitForNonExistence(timeout: 15) { fail("the deleted font's card is still there") }
        XCTAssertFalse(stepButton(2).isEnabled, "② still offers the deleted font")
        scroll(to: ownFile)
        shot("70-own-deleted")

        // A catalog download goes the same way, and can come back.
        scroll(to: app.segmentedControls.buttons["English"])
        tap(app.segmentedControls.buttons["English"], "the English tab")
        let mono = app.staticTexts["等寬字型 Mono"]
        scroll(to: mono)
        shot("71-catalog-mono")
        let get = app.buttons["下載「Atkinson Hyperlegible Mono」"]
        scroll(to: get)
        get.tap()
        let downloaded = app.buttons["Atkinson Hyperlegible Mono"]
        require(downloaded, "Atkinson Hyperlegible Mono did not download", timeout: 300)
        scroll(to: downloaded)
        shot("72-catalog-mono-downloaded")
        let catalogMore = moreButton("Atkinson Hyperlegible Mono")
        tap(catalogMore, "⋯ on the downloaded catalog font")
        tap(app.buttons["移除下載…"], "移除下載 in the ⋯ menu")
        tap(app.buttons["移除下載"], "移除下載 in the confirmation")
        require(get, "the removed download is not offered again")
        XCTAssertFalse(downloaded.exists, "the removed font still opens")
        scroll(to: get)
        shot("73-catalog-download-removed")

        // ① remembers the tab; the flows after this one find 原俠正楷 below
        // the Chinese list, out of reach under the longer English one.
        scroll(to: app.segmentedControls.buttons["中文"])
        tap(app.segmentedControls.buttons["中文"], "the 中文 tab")
    }

    // MARK: Steps

    /// A library font's ⋯ button, by the name on its card.
    func moreButton(_ name: String) -> XCUIElement {
        app.buttons["「\(name)」的更多動作"].firstMatch
    }

    /// Deletes what a text field holds: a tap past its text puts the cursor
    /// at the end, where the deletes take it all.
    func clear(_ field: XCUIElement) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let held = field.value as? String ?? ""
        let count = held == field.placeholderValue ? 0 : held.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
    }

    func launch() {
        continueAfterFailure = false
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        app.launch()
    }

    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The step bar's button for step `number` (1–3).
    func stepButton(_ number: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第 \(number) 步")).firstMatch
    }

    var fontCard: XCUIElement {
        app.buttons["原俠正楷"].firstMatch
    }

    /// From ①, where the app opens with the three steps on.
    func openFont() {
        tap(fontCard, "font card in ①", timeout: 30)
        require(effect("加粗"), "② did not open", timeout: 30)
    }

    /// An effect card's switch, by the card's title.
    func effect(_ title: String) -> XCUIElement {
        app.switches[title].firstMatch
    }

    func goToExport() {
        tap(app.buttons["下一步：匯出"], "next to ③")
        require(app.staticTexts["要放到哪裡讀？"], "③ did not open")
    }

    func chooseTarget(_ title: String) {
        let tile = app.buttons[title]
        scroll(to: tile)
        tile.tap()
        XCTAssertTrue(tile.isSelected, "\(title) is not selected")
    }

    /// The folded names, by what their label shows.
    func nameDisclosure(_ shown: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "字型名稱：\(shown)")).firstMatch
    }

    var englishName: XCUIElement { field("英文名稱", placeholder: "例如 Ebook Kai") }

    /// Unfolds the names when folded, types both and folds them again.
    func setNames(_ english: String, _ chinese: String) {
        let disclosure = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '字型名稱：'")).firstMatch
        if !englishName.exists {
            scroll(to: disclosure)
            disclosure.tap()
        }
        type(english, into: englishName)
        type(chinese, into: field("中文名稱（選填）", placeholder: "例如 電子書楷"))
        require(app.staticTexts["若要散布，請確認名稱沒有用到原作者保留的名稱（RFN），他們常只寫在授權或說明檔裡。"], "no RFN note")
        scroll(to: disclosure)
        disclosure.tap()
        if !englishName.waitForNonExistence(timeout: 5) { fail("the names did not fold") }
    }

    func tapExport() {
        let button = app.buttons["做出字型並存檔"]
        scroll(to: button)
        button.tap()
    }

    /// 原字, with a screenshot and an optional check, then back to 成品.
    func compare(shotName: String, check: () -> Void = {}) {
        let source = app.segmentedControls.buttons["原字"]
        tap(source, "原字 in the page's toggle")
        XCTAssertTrue(source.isSelected)
        check()
        shot(shotName)
        tap(app.segmentedControls.buttons["成品"], "成品 in the page's toggle")
    }

    /// Shows or hides the page settings (size, spacing, layout) above the page.
    func setPageSettings(shown: Bool) {
        let toggle = app.buttons["字級與版面"].firstMatch
        require(toggle, "page settings toggle")
        let slider = app.sliders["字級"]
        if slider.exists != shown { toggle.tap() }
        if shown ? !slider.waitForExistence(timeout: 5) : !slider.waitForNonExistence(timeout: 5) {
            fail("the page settings did not \(shown ? "open" : "close")")
        }
    }

    /// Checks the page's layout segment, which sits in the page settings.
    func requireLayout(_ segment: XCUIElement, _ message: String) {
        setPageSettings(shown: true)
        require(segment, "layout segment")
        XCTAssertTrue(segment.isSelected, message)
        setPageSettings(shown: false)
    }

    /// On iPad, the step as it is in portrait too, then back to landscape.
    func portraitShot(_ name: String) {
        guard isPad else { return }
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        shot("\(name)-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
    }

    /// 做出字型並存檔, saved to On My iPhone/iPad or to `folder` in it.
    func exportToFiles(shotPrefix: String, folder: String? = nil, progressShot: String? = nil) {
        tapExport()
        if let progressShot, app.buttons["取消"].waitForExistence(timeout: 10) { shot(progressShot) }
        saveInExporter(folder: folder, shotName: "\(shotPrefix)-export-files")
        requireExported(place: ([localStorageName] + [folder].compactMap { $0 }).joined(separator: " › "), shotName: "\(shotPrefix)-exported")
    }

    /// The exporter opens, after the build, in the last folder used: On My
    /// iPhone/iPad on a fresh simulator, Browse on iPhone after a cancelled save,
    /// a folder in On My iPhone after a save into it.
    func saveInExporter(folder: String?, shotName: String) {
        if isPad {
            require(saveInFiles, "Files exporter did not open", timeout: 300)
            tap(localStorageInSidebar, "On My iPad in the Files sidebar")
        } else {
            var waited = 0
            while !saveInFiles.exists && !localStorageInSidebar.exists && waited < 300 {
                sleep(1)
                waited += 1
            }
            let inLocalStorage = app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '我的'"))
                .firstMatch
            if !saveInFiles.exists {
                tap(localStorageInSidebar, "On My iPhone in the Files exporter")
            } else if !inLocalStorage.waitForExistence(timeout: 3) {
                // Opened in a folder of it, the last one saved into (test5's 字型).
                goToLocalStorage()
            }
            require(inLocalStorage, "the exporter is not in On My iPhone", timeout: 5)
        }
        if let folder { openFolder(folder) }
        require(saveInFiles, "no save button in the Files exporter")
        shot(shotName)
        saveInFiles.tap()
        let replace = app.buttons["取代"]
        if replace.waitForExistence(timeout: 3) { replace.tap() }
    }

    /// ③ says the files were saved, where, and that they are current.
    func requireExported(place: String, shotName: String) {
        // "已存好 <the name Files gave the font>", or without the name when
        // Files did not report the font's URL (seen once on iOS 26).
        let saved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '已存好'")).firstMatch
        require(saved, "③ does not say the font was saved", timeout: 30)
        let destination = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "存到「\(place)」"))
            .firstMatch
        require(destination, "③ does not say the files went to \(place)")
        let stale = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '設定在匯出後改過了'")).firstMatch
        if !stale.waitForNonExistence(timeout: 10) { fail("the saved export is not the current settings") }
        scroll(to: saved)
        shot(shotName)
    }

    /// Shares through the share sheet's Save to Files into `folder` of On My
    /// iPhone/iPad, which must be empty: in the simulator, Save to Files over
    /// an existing file fails (OSStatus -8072) where the exporter offers to
    /// replace it. The sheet reports only the activity, so ③ names it and
    /// says the receiver decides where the files go.
    func shareToFiles(shotPrefix: String, folder: String) {
        tapShare()
        require(app.otherElements["ActivityListView"], "share sheet did not open", timeout: 300)
        tap(app.cells["儲存到檔案"].firstMatch, "儲存到檔案 in the share sheet")
        // Older runtimes name its save button; iOS 26's is only labelled.
        let save = app.buttons.matching(
            NSPredicate(format: "identifier == 'DOCPicker.actionButton' OR label IN {'儲存', '移動'}")
        ).firstMatch
        require(save, "Save to Files did not open", timeout: 30)
        goToLocalStorage()
        openFolder(folder)
        shot("\(shotPrefix)-files")
        save.tap()
        let said = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "分享給「儲存到檔案」；存到哪裡由接收的 App 決定，FontsMaker 無從得知。")
        ).firstMatch
        require(said, "③ does not say the receiver decides where shared files go", timeout: 30)
        scroll(to: said)
        shot("\(shotPrefix)-exported")
    }

    func tapShare() {
        let button = app.buttons["分享…"]
        scroll(to: button)
        button.tap()
    }

    /// What Files calls On My iPhone/iPad.
    var localStorageName: String {
        isPad ? "我的iPad" : "我的iPhone"
    }

    /// Takes a Files picker, open wherever it was last used, to On My
    /// iPhone/iPad: through the sidebar on iPad, back up to Browse on iPhone.
    func goToLocalStorage() {
        if isPad {
            tap(localStorageInSidebar, "On My iPad in the Files sidebar", timeout: 30)
            return
        }
        let bar = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        let here = bar.staticTexts[localStorageName]
        var steps = 0
        while !here.waitForExistence(timeout: 2) && steps < 4 {
            if localStorageInSidebar.exists {
                localStorageInSidebar.tap()
            } else if bar.buttons["BackButton"].exists {
                bar.buttons["BackButton"].tap()
            }
            steps += 1
        }
        require(here, "the Files picker did not reach \(localStorageName)")
    }

    /// Opens a folder of the one a Files picker shows; its cell reads
    /// "字型, 0個項目".
    func openFolder(_ name: String) {
        let cell = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
        tap(cell, "folder \(name) in Files")
        if !cell.waitForNonExistence(timeout: 10) { fail("Files did not open the folder \(name)") }
    }

    var saveInFiles: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN {'儲存', '移動'}")).firstMatch
    }

    /// Builds, opens the share sheet and closes it without sharing.
    func share(shotName: String) {
        tapShare()
        let sheet = app.otherElements["ActivityListView"]
        require(sheet, "share sheet did not open", timeout: 300)
        sleep(2)
        shot(shotName)
        if isPad {
            // A popover closes on a tap outside it, and the tap goes no
            // further; the window's left edge is the export panel's margin.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).tap()
        } else {
            // The sheet has no close button, and the page around it stays
            // live: it is dragged down by its header. XCUITest cannot swipe
            // the sheet itself (it reports no visible frame), so the drag
            // goes through the app's coordinates.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: sheet.frame.midX, dy: sheet.frame.minY + 50))
                .press(
                    forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: sheet.frame.midX, dy: app.frame.maxY)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        }
        if !sheet.waitForNonExistence(timeout: 15) {
            fail("the share sheet did not close")
        }
    }

    /// Nothing exported: ③ does not say a file was saved.
    func requireNotExported(shotName: String) {
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '已存好'")).count, 0,
            "an export that never left the app is shown as saved")
        shot(shotName)
    }

    var previewPage: XCUIElement {
        app.descendants(matching: .any)["previewPage"]
    }

    var exportPage: XCUIElement {
        app.descendants(matching: .any)["exportPage"]
    }

    /// The line under the page that says what 成品 applies.
    var previewCaption: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '套用：'")).firstMatch
    }

    var rotatedLayout: XCUIElement {
        app.buttons["偽直排（轉 90° 閱讀）"]
    }

    /// The s2t 一對多的字 menu, a button showing its current choice.
    func chooseOneToMany(_ title: String) {
        let picker = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH '一對多的字' OR label IN {'取最常用的繁體', '不轉換'}")
        ).firstMatch
        scroll(to: picker)
        picker.tap()
        tap(app.buttons[title].firstMatch, "\(title) in the 一對多的字 menu")
    }

    /// On iPad, Files lists its locations in a sidebar ("我的iPad"); on
    /// iPhone, Browse does.
    var localStorageInSidebar: XCUIElement {
        app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'DOC.sidebar.item.我的'")).firstMatch
    }

    /// Browse in the Files picker, then On My iPhone/iPad ("我的iPhone") unless Browse is already there.
    func browseLocalStorage() {
        if isPad {
            tap(localStorageInSidebar, "On My iPad in the Files sidebar", timeout: 30)
            return
        }
        require(app.tabBars.buttons["瀏覽"], "Files picker did not open", timeout: 30)
        app.tabBars.buttons["瀏覽"].tap()
        let here = app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '我的'")).firstMatch
        if !here.waitForExistence(timeout: 3) {
            tap(app.cells.matching(NSPredicate(format: "label BEGINSWITH '我的'")).firstMatch, "On My iPhone/iPad")
        }
    }

    /// Picks the file whose name contains `name` in On My iPhone/iPad.
    func pickInFiles(_ name: String, shotName: String? = nil) {
        browseLocalStorage()
        let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        // Not right after the tap that opens the picker: it is still sliding in.
        if let shotName {
            require(file, "file \(name) not in Files")
            shot(shotName)
        }
        tap(file, "file \(name)")
        // With multiple selection allowed, a tap only selects the file.
        let open = app.buttons.matching(NSPredicate(format: "label IN {'打開', '開啟', '完成'}")).firstMatch
        if open.waitForExistence(timeout: 3) {
            open.tap()
        } else {
            shot("pick-\(name)")
            dump("pick-\(name)")
        }
    }

    // MARK: Helpers

    func field(_ label: String, placeholder: String) -> XCUIElement {
        let byLabel = app.textFields[label]
        return byLabel.exists ? byLabel : app.textFields.matching(NSPredicate(format: "placeholderValue == %@", placeholder)).firstMatch
    }

    /// Types and returns: the keyboard goes away, so it covers nothing
    /// after. Replaces what the field holds: the draft, names included, is
    /// restored from the last flow.
    func type(_ text: String, into field: XCUIElement) {
        scroll(to: field)
        // Past the text, so the cursor lands after it.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let held = field.value as? String ?? ""
        let count = held == field.placeholderValue ? 0 : held.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + text + "\n")
        XCTAssertEqual(field.value as? String, text, "the field holds what was typed, and only that")
    }

    /// The scroll view of the step on screen: ②'s cards, ③'s panel, ①'s cards.
    var controls: XCUIElement {
        app.scrollViews["controls"].firstMatch
    }

    /// Drags a scroll view, the step's controls unless told otherwise, until
    /// `element` lies wholly inside it and can be tapped: toward it when it
    /// is in the tree, else down to the end, then back up to the top.
    func scroll(to element: XCUIElement, in list: XCUIElement? = nil) {
        let surface = list ?? controls
        require(surface, "no scroll view to find \(element) in")
        // At either edge an element still counts as hittable while a tap
        // there misses it, so it must be clear of them.
        func visible() -> CGRect { surface.frame.insetBy(dx: 0, dy: 16) }
        func inView() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let frame = element.frame
            let view = visible()
            return frame.minY >= view.minY && frame.maxY <= view.maxY
        }
        // What moves under a drag: unchanged after one, the view is at its end.
        func marker() -> CGRect {
            if element.exists { return element.frame }
            let text = surface.staticTexts.firstMatch
            return text.exists ? text.frame : .zero
        }
        // Held at its end so the view does not fling on, and started just
        // inside the leading edge: beside the controls, not on a slider or
        // a switch, which would take the touch.
        func drag(up: Bool) {
            let x = CGVector(dx: 0.03, dy: 0)
            let from = surface.coordinate(withNormalizedOffset: CGVector(dx: x.dx, dy: up ? 0.75 : 0.3))
            let to = surface.coordinate(withNormalizedOffset: CGVector(dx: x.dx, dy: up ? 0.35 : 0.7))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0.3)
        }
        // Once the element is in the tree, its row is dragged to the middle,
        // slowly: a fixed drag carries a list little taller than the view
        // from one end to the other, past an element that fits only between.
        // Kept off the view's edges: one reaching the bottom of the screen
        // puts the touch on the home indicator, which takes it.
        func center() {
            let height = surface.frame.height
            let from = min(0.8, max(0.2, (element.frame.midY - surface.frame.minY) / height))
            let to = min(0.8, max(0.2, from - (element.frame.midY - visible().midY) / height))
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: from)).press(
                forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: to)),
                withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        var up = true
        var turned = false
        var stuck = 0
        var drags = 0
        while !inView() && drags < 40 {
            if element.exists { up = element.frame.midY > visible().midY }
            let before = marker()
            if element.exists { center() } else { drag(up: up) }
            drags += 1
            stuck = marker() == before ? stuck + 1 : 0
            if stuck >= 2 {
                // Toward an element in the tree there is nowhere else to go.
                if turned || element.exists { break }
                up.toggle()
                turned = true
                stuck = 0
            }
        }
        if !inView() { fail("could not scroll to \(element)") }
    }

    func tap(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 15) {
        require(element, "\(what) not found", timeout: timeout)
        element.tap()
    }

    /// A switch, by its element; flips it unless it already is `on`.
    func setSwitch(_ toggle: XCUIElement, on: Bool, scrolling: Bool = true) {
        require(toggle, "\(toggle) not found")
        if scrolling { scroll(to: toggle) }
        let wanted = on ? "1" : "0"
        if toggle.value as? String == wanted { return }
        flip(toggle)
        let flipped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", wanted), object: toggle)
        if XCTWaiter().wait(for: [flipped], timeout: 5) != .completed {
            fail("\(toggle) did not turn \(on ? "on" : "off")")
        }
    }

    /// A tap on the switch itself: a form row's element is the whole row,
    /// where a tap on the label may not flip it.
    func flip(_ toggle: XCUIElement) {
        let control = toggle.switches.firstMatch
        (control.exists ? control : toggle).tap()
    }

    /// Waits for the accessibility value (what a page shows) or the label of
    /// `element` to contain `text`. The preview is redrawn off the main
    /// actor, after phrase rules are derived.
    func requireValue(_ element: XCUIElement, containing text: String, _ message: String) {
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text), object: element)
        if XCTWaiter().wait(for: [shown], timeout: 60) != .completed {
            fail("\(message): shows \(element.exists ? (element.value as? String ?? element.label) : "no element")")
        }
    }

    func require(_ element: XCUIElement, _ message: String, timeout: TimeInterval = 15) {
        if !element.waitForExistence(timeout: timeout) { fail(message) }
    }

    func fail(_ message: String) {
        shot("FAILED-\(name)")
        dump("FAILED-\(name)")
        XCTFail(message)
    }

    func shot(_ name: String) {
        let device = isPad ? "ipad" : "iphone"
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(device)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func dump(_ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "\(name)-tree"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
