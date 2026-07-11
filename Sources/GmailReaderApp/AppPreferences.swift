import Foundation

@MainActor
final class AppPreferences: ObservableObject {
    @Published var proxyEnabled: Bool { didSet { save() } }
    @Published var proxyHost: String { didSet { save() } }
    @Published var proxyPort: Int { didSet { save() } }

    private let defaults = UserDefaults.standard

    init() {
        if defaults.object(forKey: "proxyEnabled") == nil {
            proxyEnabled = true
            proxyHost = "127.0.0.1"
            proxyPort = 6153
        } else {
            proxyEnabled = defaults.bool(forKey: "proxyEnabled")
            proxyHost = defaults.string(forKey: "proxyHost") ?? "127.0.0.1"
            proxyPort = defaults.integer(forKey: "proxyPort")
            if proxyPort == 0 { proxyPort = 6153 }
        }
    }

    var proxy: ProxySettings {
        let validPort = (1...65535).contains(proxyPort) ? proxyPort : 6153
        return ProxySettings(enabled: proxyEnabled, host: proxyHost.trimmingCharacters(in: .whitespacesAndNewlines), port: validPort)
    }

    private func save() {
        defaults.set(proxyEnabled, forKey: "proxyEnabled")
        defaults.set(proxyHost, forKey: "proxyHost")
        defaults.set(proxyPort, forKey: "proxyPort")
    }
}
