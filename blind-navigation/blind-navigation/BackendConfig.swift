import Foundation

enum BackendConfig {
    // Configure for local network access.
    // You can override at runtime via UserDefaults key "BackendBaseURL" (e.g., from a debug menu).
    static var baseURL: URL {
        if let override = UserDefaults.standard.string(forKey: "BackendBaseURL"),
           let url = URL(string: override) {
            return url
        }

        #if targetEnvironment(simulator)
        // Simulator can hit localhost directly.
        return URL(string: "http://localhost:5001/api")!
        #else
        // Device must use the Mac's LAN IP address.
        // Update this if your Mac's IP changes.
        return URL(string: "http://172.17.14.50:5001/api")!
        #endif
    }
}
