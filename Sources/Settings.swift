import Foundation

final class Settings {
    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            "enabled": true,
            "keepJack": true,
        ])
    }

    var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    /// Keep the built-in 3.5 mm headphone jack awake.
    var keepJack: Bool {
        get { defaults.bool(forKey: "keepJack") }
        set { defaults.set(newValue, forKey: "keepJack") }
    }

    /// External DACs selected in the Outputs menu: device key -> display name.
    var keptDevices: [String: String] {
        get { defaults.dictionary(forKey: "keptDevices") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "keptDevices") }
    }
}
