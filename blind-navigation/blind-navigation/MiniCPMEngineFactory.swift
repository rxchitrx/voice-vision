import Foundation

struct MiniCPMEngineSelection {
    let primary: MiniCPMEngine
    let fallbacks: [MiniCPMEngine]
    let diagnostics: [String]
}

enum MiniCPMEngineFactory {
    static func makeSelection(
        loader: MiniCPMModelLoader = MiniCPMModelLoader(),
        session: URLSession = .shared
    ) -> MiniCPMEngineSelection {
        loader.prepareDirectories()

        let mlxAvailability = loader.availability(for: .mlx)
        let ggufAvailability = loader.availability(for: .gguf)

        let mlxEngine = MiniCPMMLXEngine(availability: mlxAvailability)
        let ggufEngine = MiniCPMGGUFEngine(availability: ggufAvailability)
        let backendEngine = MiniCPMBackendEngine(session: session)

        let localEngines: [MiniCPMEngine] = [mlxEngine, ggufEngine]
        if let primary = localEngines.first(where: { $0.isReady }) {
            let fallbacks = localEngines.filter { $0.runtime != primary.runtime && $0.isReady } + [backendEngine]
            return MiniCPMEngineSelection(
                primary: primary,
                fallbacks: fallbacks,
                diagnostics: [mlxAvailability.detail, ggufAvailability.detail, backendEngine.statusDescription]
            )
        }

        return MiniCPMEngineSelection(
            primary: backendEngine,
            fallbacks: [],
            diagnostics: [mlxAvailability.detail, ggufAvailability.detail, backendEngine.statusDescription]
        )
    }
}
