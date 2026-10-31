import AppKit
import ServiceManagement

enum KeeperState {
    case active    // stream running
    case paused    // user idle or Mac asleep; resumes on input/wake
    case waiting   // current output isn't selected
    case disabled
    case failed
}

@MainActor
final class Controller: NSObject, NSMenuDelegate {
    private let settings = Settings()
    private let keeper = SilenceKeeper()
    private var watcher: AudioDeviceWatcher?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private var state: KeeperState = .disabled
    private var currentOutput: OutputInfo?
    private var systemAsleep = false
    private var userIdle = false

    /// macOS display sleep timer ("Turn display off when inactive"), re-read periodically
    /// because it differs between battery and power adapter. 0 = never.
    private var displaySleepSeconds: Double = 0
    private var displaySleepReadAt = Date.distantPast

    /// Release the stream this long before the display timer fires. The stream itself keeps
    /// macOS from turning the display off, so it has to be gone before the timer runs out.
    private static let releaseMargin: Double = 2

    func start() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.image = Self.restGlyph()

        keeper.onUnexpectedStop = { [weak self] in self?.scheduleEvaluate(after: 0.5) }

        let watcher = AudioDeviceWatcher { [weak self] in self?.scheduleEvaluate() }
        watcher.start()
        self.watcher = watcher

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake),
                              name: NSWorkspace.didWakeNotification, object: nil)

        // Polls once a second so the stream is released within the 2 s margin.
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(checkIdle),
                          userInfo: nil, repeats: true)
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)

        evaluate()
    }

    // MARK: - Logic

    private func scheduleEvaluate(after delay: TimeInterval = 0.3) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(evaluateNow), object: nil)
        perform(#selector(evaluateNow), with: nil, afterDelay: delay, inModes: [.common])
    }

    @objc private func evaluateNow() { evaluate() }

    /// Whether this output was selected in the Outputs menu.
    private func isKept(_ output: OutputInfo) -> Bool {
        if output.isHeadphoneJack { return settings.keepJack }
        if output.isExternalWired { return settings.keptDevices[output.key] != nil }
        return false
    }

    /// Runs the stream only while the default output is selected in Outputs and the user is around;
    /// otherwise releases the output so the Mac can sleep.
    private func evaluate() {
        let output = AudioDevices.defaultOutput.map(AudioDevices.info)
        currentOutput = output

        let wanted: KeeperState
        if !settings.enabled {
            wanted = .disabled
        } else if output == nil || !isKept(output!) {
            wanted = .waiting
        } else if systemAsleep || userIdle {
            wanted = .paused
        } else {
            wanted = .active
        }

        if wanted == .active {
            keeper.start()
            state = keeper.isRunning ? .active : .failed
        } else {
            keeper.stop()
            state = wanted
        }
        if state == .failed {
            scheduleEvaluate(after: 5)
        }
        updateButton()
    }

    @objc private func willSleep() {
        systemAsleep = true
        evaluate()
    }

    @objc private func didWake() {
        systemAsleep = false
        // Audio devices take a moment to come back after wake.
        scheduleEvaluate(after: 2)
    }

    /// Pauses the stream shortly before the macOS display timer fires, so the display turns off
    /// and the Mac sleeps on its own schedule, as if Hush weren't running. Resumes on input.
    /// While another app plays audio the stream stays on: that app keeps the Mac awake anyway,
    /// and the output won't click when it stops.
    @objc private func checkIdle() {
        if Date().timeIntervalSince(displaySleepReadAt) > 60 {
            displaySleepSeconds = Self.readDisplaySleepSeconds()
            displaySleepReadAt = Date()
        }
        let idleNow = displaySleepSeconds > 0
            && Self.secondsSinceLastInput() >= displaySleepSeconds - Self.releaseMargin
            && !AudioDevices.othersPlaying
        if idleNow != userIdle {
            userIdle = idleNow
            evaluate()
        }
    }

    private static func secondsSinceLastInput() -> Double {
        let anyInput = CGEventType(rawValue: ~0) ?? .mouseMoved
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// Reads "displaysleep N" (minutes) from `pmset -g`, the settings for the current power source.
    private static func readDisplaySleepSeconds() -> Double {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return 0 }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0] == "displaysleep", let minutes = Double(fields[1]) {
                return minutes * 60
            }
        }
        return 0
    }

    // MARK: - UI

    /// One line: "Active · External Headphones". A pause only lasts while nobody is
    /// looking at the screen, so it's shown as active.
    private var statusText: String {
        guard let output = currentOutput else { return "No output" }
        let word: String
        switch state {
        case .active, .paused: word = "Active"
        case .disabled: word = "Disabled"
        case .waiting: word = "Inactive"
        case .failed: word = "Error"
        }
        return "\(word) · \(output.name)"
    }

    /// Menu bar glyph: a musical whole rest, a block hanging from a thin line, square corners.
    /// A template image, so macOS tints it for light/dark menu bars and the dimmed state.
    private static func restGlyph() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            NSRect(x: 1, y: 6, width: 18, height: 1.5).fill()
            NSRect(x: 4.5, y: 7.5, width: 11, height: 4.5).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Hush"
        return image
    }

    private func updateButton() {
        statusItem.button?.appearsDisabled = !(state == .active || state == .paused)
        statusItem.button?.toolTip = "Hush: " + statusText
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(label(statusText))
        menu.addItem(.separator())

        menu.addItem(item("Enabled", #selector(toggleEnabled), checked: settings.enabled))
        menu.addItem(submenu("Outputs", outputsMenu()))

        menu.addItem(.separator())
        menu.addItem(item("Open at Login", #selector(toggleLoginItem),
                          checked: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item("Quit Hush", #selector(quit), key: "q"))
    }

    /// The jack plus every wired DAC that is connected now or was selected before.
    private func outputsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Headphone Jack (3.5 mm)", #selector(toggleJack), checked: settings.keepJack))
        menu.addItem(.separator())

        let kept = settings.keptDevices
        var candidates: [String: (name: String, connected: Bool)] = [:]
        for (key, name) in kept {
            candidates[key] = (name, false)
        }
        for device in AudioDevices.allDevices where AudioDevices.hasOutput(device) {
            let info = AudioDevices.info(device)
            if info.isExternalWired {
                candidates[info.key] = (info.name, true)
            }
        }

        if candidates.isEmpty {
            menu.addItem(label("No USB DACs connected"))
        }
        let sorted = candidates.sorted {
            $0.value.name.localizedCaseInsensitiveCompare($1.value.name) == .orderedAscending
        }
        for (key, entry) in sorted {
            let title = entry.connected ? entry.name : "\(entry.name) (not connected)"
            let it = item(title, #selector(toggleDevice(_:)), checked: kept[key] != nil)
            it.representedObject = [key, entry.name]
            menu.addItem(it)
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector, checked: Bool = false, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        it.state = checked ? .on : .off
        return it
    }

    private func label(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = menu
        return it
    }

    // MARK: - Menu actions

    @objc private func toggleEnabled() { settings.enabled.toggle(); evaluate() }
    @objc private func toggleJack() { settings.keepJack.toggle(); evaluate() }

    @objc private func toggleDevice(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String] else { return }
        let (key, name) = (pair[0], pair[1])
        var kept = settings.keptDevices
        kept[key] = kept[key] == nil ? name : nil
        settings.keptDevices = kept
        evaluate()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription
                + "\n\nYou can add Hush manually in System Settings > General > Login Items."
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
