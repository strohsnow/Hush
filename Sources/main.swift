import AppKit

// Top-level code in main.swift runs on the main thread, but in Swift 5 mode
// the compiler doesn't know that, so we state it explicitly.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = Controller()
    controller.start()
    withExtendedLifetime(controller) {
        app.run()
    }
}
