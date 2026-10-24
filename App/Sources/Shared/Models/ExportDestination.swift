import Foundation

/// Where an export went (product spec §4.7), in the words the user knows the
/// place by. On iOS the export check reads a staged copy inside the app and
/// only then are the files handed on, so this says where they were handed,
/// never which file the check read.
enum ExportDestination: Equatable, Sendable {
    /// macOS: the file the save panel chose, which is the file the check read.
    case savedFile
    /// The Files exporter saved them into this folder, outermost first, as
    /// Files names it: ["我的iPhone", "字型"], under the names it gave them
    /// (nil when it did not report one); the license text's too, when one went.
    case files(folder: [String], font: String?, recipe: String?, license: String?)
    /// The share sheet handed them to an activity: a UIActivity.ActivityType
    /// raw value, nil when the sheet did not say which. Where they end up is
    /// up to the receiver and is never reported back.
    case shared(activity: String?)

    // MARK: Files

    /// The Files exporter's folder for `file`, one of the URLs it returns.
    ///
    /// Files' own name for the top of the path cannot be read: for On My
    /// iPhone the URL is `…/AppGroup/<UUID>/File Provider Storage/…`, whose
    /// localized name is "File Provider Storage", and the file provider APIs
    /// answer nothing for it (simulator, iOS 27). So that container path is
    /// mapped to the name Files shows, 我的iPhone/我的iPad (`device` is
    /// UIDevice's model). iCloud Drive has a system name,
    /// `ubiquitousItemContainerDisplayName`, passed as `iCloudContainer`.
    /// The folders below come from `localizedName`, read while the security
    /// scope is open (iCloud shows a Mac's Desktop as 桌面), else the path.
    static func filesFolder(
        of file: URL, device: String, iCloudContainer: String?, localizedName: (URL) -> String?
    ) -> [String] {
        let folder = file.deletingLastPathComponent()
        let components = folder.pathComponents
        // The folders from components[start...] down, by their shown names.
        func names(from start: Int) -> [String] {
            (start..<components.count).map { index in
                let url = URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])))
                return localizedName(url) ?? components[index]
            }
        }
        if let iCloudContainer, let base = components.lastIndex(of: "Mobile Documents"), base + 1 < components.count {
            // An app's iCloud container shows its Documents folder under the
            // container's name; iCloud Drive itself is com~apple~CloudDocs.
            var start = base + 2
            if components[base + 1].hasPrefix("iCloud~"), start < components.count, components[start] == "Documents" {
                start += 1
            }
            return [iCloudContainer] + names(from: start)
        }
        if let storage = components.firstIndex(of: "File Provider Storage"), storage >= 2,
            components[storage - 2] == "AppGroup"
        {
            return ["我的\(device)"] + names(from: storage + 1)
        }
        // A provider this does not know: the folder's own name is all there is.
        return [localizedName(folder) ?? folder.lastPathComponent]
    }

    /// The font's and the recipe's names among the URLs the Files exporter
    /// returns, in any order. Not the names the app offered: Files on iOS 26
    /// saves over an existing file as "EbookKai-Medium 2.ttf" without asking.
    static func savedNames(_ urls: [URL]) -> (font: String?, recipe: String?, license: String?) {
        func name(_ ext: String) -> String? {
            urls.first { $0.pathExtension.lowercased() == ext }?.lastPathComponent
        }
        return (name("ttf"), name("json"), name("txt"))
    }

    /// A Files folder on one line.
    static func path(_ folder: [String]) -> String {
        folder.joined(separator: " › ")
    }

    // MARK: Share sheet

    /// The share sheet's name for the activity the files went to. The sheet
    /// reports only an activity type: for a share extension that is the
    /// extension's bundle ID, which iOS does not let an app turn into a name.
    static func activityName(_ activity: String?) -> String {
        activity.flatMap { activityNames[$0] } ?? "其他 App"
    }

    /// Raw values of UIKit's UIActivity.ActivityType constants (checked
    /// against UIKit in the iOS tests), and Save to Files as the share sheet
    /// reported it in the iOS flows. Named as iOS 27's sheet labels them.
    static let activityNames: [String: String] = [
        "com.apple.UIKit.activity.AirDrop": "AirDrop",
        "com.apple.UIKit.activity.Mail": "郵件",
        "com.apple.UIKit.activity.Message": "訊息",
        "com.apple.UIKit.activity.CopyToPasteboard": "拷貝",
        "com.apple.DocumentManagerUICore.SaveToFiles": "儲存到檔案",
    ]
}
