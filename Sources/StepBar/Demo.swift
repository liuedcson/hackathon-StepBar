import AppKit

// Demo mode, for recording screenshots without showing anyone's real data: `STEPBAR_DEMO=<dir> StepBar`.
// Data lives in <dir>; history comes only from a Chrome started with `--user-data-dir=<dir>/chrome`, and web pages
// open in that Chrome.
enum Demo {
    static let folder: URL? = ProcessInfo.processInfo.environment["STEPBAR_DEMO"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static var on: Bool { folder != nil }
    static var chrome: URL? { folder?.appendingPathComponent("chrome") }
}

// Every web address StepBar opens goes through here.
@discardableResult func openWeb(_ url: URL) -> Bool {
    if let chrome = Demo.chrome, ["http", "https"].contains(url.scheme ?? "") {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        process.arguments = ["--user-data-dir=\(chrome.path)", url.absoluteString]
        return (try? process.run()) != nil
    }
    return NSWorkspace.shared.open(url)
}
