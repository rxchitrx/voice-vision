import Foundation

enum ModelAvailabilityState: String {
    case available
    case missingAssets
    case runtimeUnavailable
}

struct ModelAvailability {
    let runtime: MiniCPMRuntime
    let state: ModelAvailabilityState
    let modelDirectory: URL?
    let repositoryID: String?
    let detail: String

    var isAvailable: Bool {
        state == .available
    }

    var canInstallLocally: Bool {
        runtime != .backendFallback && repositoryID != nil
    }
}
