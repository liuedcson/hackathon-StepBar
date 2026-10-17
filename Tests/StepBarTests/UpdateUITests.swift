import AppKit

// Uses only a temporary test window, never the installed StepBar or user data.
@main struct UpdateUITests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "StepBar isolated update confirmation test"
        window.makeKeyAndOrderFront(nil)
        var installs = 0
        UpdateConfirmation.present(window: window) { installs += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let sheet = window.attachedSheet else { fatalError("Update confirmation sheet did not appear") }
            window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                precondition(installs == 0, "Cancel must not install")
                UpdateConfirmation.present(window: window) { installs += 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let sheet = window.attachedSheet else { fatalError("Second confirmation sheet did not appear") }
                    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        precondition(installs == 1, "Confirm must invoke install exactly once")
                        window.orderOut(nil)
                        print("PASS: real AppKit sheet presentation, cancel and install callback")
                        exit(0)
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { fatalError("Update UI test timed out") }
        app.run()
    }
}
