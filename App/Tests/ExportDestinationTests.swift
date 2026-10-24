import Foundation
import Testing

#if canImport(UIKit)
    import UIKit
#endif

/// Where an export went, as the export pane and the form say it. On iOS the
/// files are checked as staged copies and then copied out, so the only clue
/// to where they went is what Files or the share sheet reports.
@MainActor
struct ExportDestinationTests {
    /// What the system names nothing: every folder keeps its path name.
    private func pathNames(_ url: URL) -> String? { nil }

    /// URLs the Files exporter returned on the iOS 27 simulator (iPhone 17
    /// Pro, zh-Hant): On My iPhone is an app group container whose top folder
    /// is literally "File Provider Storage", and Files calls it 我的iPhone.
    @Test func onMyIPhoneAsFilesNamesIt() {
        let root = URL(
            fileURLWithPath:
                "/Users/ricky/Library/Developer/CoreSimulator/Devices/AA020DDF-7620-42B4-A8F2-972353B41D90/data/Containers/Shared/AppGroup/30C83424-7149-461D-ACB6-EEAEE845DEAE/File Provider Storage/ProbeKai-Regular.ttf"
        )
        let subfolder = URL(
            fileURLWithPath:
                "/Users/ricky/Library/Developer/CoreSimulator/Devices/AA020DDF-7620-42B4-A8F2-972353B41D90/data/Containers/Shared/AppGroup/30C83424-7149-461D-ACB6-EEAEE845DEAE/File Provider Storage/字型/ProbeKai-Regular.json"
        )
        #expect(
            ExportDestination.filesFolder(of: root, device: "iPhone", iCloudContainer: nil, localizedName: pathNames)
                == ["我的iPhone"])
        #expect(
            ExportDestination.filesFolder(
                of: subfolder, device: "iPhone", iCloudContainer: nil, localizedName: pathNames) == ["我的iPhone", "字型"])
        // The same container on a device (not captured: no device run), and on an iPad.
        let device = URL(
            fileURLWithPath:
                "/private/var/mobile/Containers/Shared/AppGroup/30C83424-7149-461D-ACB6-EEAEE845DEAE/File Provider Storage/字型/電子書/EbookKai-Medium.ttf"
        )
        #expect(
            ExportDestination.filesFolder(of: device, device: "iPad", iCloudContainer: nil, localizedName: pathNames)
                == ["我的iPad", "字型", "電子書"])
    }

    /// iCloud Drive has a name of its own (ubiquitousItemContainerDisplayName),
    /// and its folders may be shown under other names than their paths: a
    /// Mac's Desktop is 桌面. Not captured: the simulator has no iCloud
    /// account, so these follow the documented container layout.
    @Test func iCloudDriveByItsContainerName() {
        let drive = URL(
            fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Desktop/字型/TradKai-Regular.ttf")
        let names = ExportDestination.filesFolder(of: drive, device: "iPhone", iCloudContainer: "iCloud雲碟") { url in
            url.lastPathComponent == "Desktop" ? "桌面" : nil
        }
        #expect(names == ["iCloud雲碟", "桌面", "字型"])
        // An app's container shows its Documents folder under the app's name.
        let pages = URL(
            fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/iCloud~com~apple~Pages/Documents/TradKai-Regular.ttf")
        #expect(
            ExportDestination.filesFolder(of: pages, device: "iPhone", iCloudContainer: "Pages", localizedName: pathNames)
                == ["Pages"])
    }

    /// A provider whose layout is not known is not given a made-up place:
    /// the folder's own name, as the system gives it, is all that is shown.
    @Test func unknownProviderShowsOnlyTheFolder() {
        let other = URL(fileURLWithPath: "/private/var/mobile/Library/SomeProvider/Domain/字型/TradKai-Regular.ttf")
        #expect(
            ExportDestination.filesFolder(of: other, device: "iPhone", iCloudContainer: nil, localizedName: pathNames)
                == ["字型"])
        #expect(
            ExportDestination.filesFolder(of: other, device: "iPhone", iCloudContainer: nil) { _ in "Fonts" } == ["Fonts"])
    }

    /// Files on iOS 26 keeps both files when the names are taken, as
    /// "EbookKai-Medium 2.ttf": the done view must name what was saved, not
    /// what was offered, whatever order the exporter returns the URLs in.
    @Test func savedNamesAreTheOnesFilesChose() {
        let folder = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/X/File Provider Storage")
        let names = ExportDestination.savedNames([
            folder.appendingPathComponent("EbookKai-Medium 2.json"),
            folder.appendingPathComponent("EbookKai-Medium 2.ttf"),
        ])
        #expect(names.font == "EbookKai-Medium 2.ttf" && names.recipe == "EbookKai-Medium 2.json")
        #expect(names.license == nil)
        #expect(ExportDestination.savedNames([]) == (nil, nil, nil))
        let licensed = ExportDestination.savedNames([
            folder.appendingPathComponent("LEbook-Medium-OFL 2.txt"), folder.appendingPathComponent("LEbook-Medium 2.ttf"),
        ])
        #expect(licensed.license == "LEbook-Medium-OFL 2.txt")
    }

    /// The share sheet reports an activity type only. Known ones are named
    /// as the sheet names them; anything else, a third-party extension's
    /// bundle ID included, is another app, never the raw identifier. Save to
    /// Files is the type the sheet reported in the iOS 27 simulator.
    @Test func shareActivityNames() {
        #expect(ExportDestination.activityName("com.apple.DocumentManagerUICore.SaveToFiles") == "儲存到檔案")
        #expect(ExportDestination.activityName("com.apple.UIKit.activity.AirDrop") == "AirDrop")
        #expect(ExportDestination.activityName("com.apple.UIKit.activity.Mail") == "郵件")
        #expect(ExportDestination.activityName("com.apple.UIKit.activity.Message") == "訊息")
        #expect(ExportDestination.activityName("com.apple.UIKit.activity.CopyToPasteboard") == "拷貝")
        #expect(ExportDestination.activityName("com.example.reader.ShareExtension") == "其他 App")
        #expect(ExportDestination.activityName(nil) == "其他 App")
    }

    #if os(iOS)
        /// The table's keys are UIKit's own raw values, not remembered ones.
        @Test func shareActivityTypesAreUIKits() {
            for type in [UIActivity.ActivityType.airDrop, .mail, .message, .copyToPasteboard] {
                #expect(ExportDestination.activityNames[type.rawValue] != nil, "\(type.rawValue)")
            }
        }
    #endif

    /// The destination is part of the export: kept with the check, and gone
    /// with it when a new build makes the export stale.
    @Test func editorKeepsTheDestinationWithTheExport() async throws {
        let (_, editor, root) = try await makeEditor([TestFonts.fixture("ops.ttf")])
        defer { try? FileManager.default.removeItem(at: root) }
        editor.draft.familyName = "Ebook Kai"
        editor.draft.emboldenWeight = 6
        editor.startBuild()
        await editor.buildSettled()
        let outcome = try #require(editor.outcome)
        let check = try #require(await editor.writeExport(to: root.appendingPathComponent(outcome.result.fileName)))
        #expect(editor.exportDestination == nil, "written and checked is not exported")
        let destination = ExportDestination.files(
            folder: ["我的iPhone", "字型"], font: "a.ttf", recipe: "a.json", license: nil)
        editor.markExported(check, to: destination)
        #expect(editor.exportDestination == destination)
        #expect(editor.exportCheck?.sha256 == outcome.sha256)

        editor.startBuild()
        #expect(editor.exportCheck == nil && editor.exportDestination == nil)
        await editor.buildSettled()
    }
}
