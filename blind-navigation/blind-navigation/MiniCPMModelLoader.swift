import Foundation

final class MiniCPMModelLoader {
    private let assetManager: ModelAssetManager

    init(assetManager: ModelAssetManager = .shared) {
        self.assetManager = assetManager
    }

    func prepareDirectories() {
        do {
            try assetManager.ensureBaseDirectories()
        } catch {
            print("MiniCPM model directory setup failed:", error)
        }
    }

    func availability(for runtime: MiniCPMRuntime) -> ModelAvailability {
        switch runtime {
        case .mlx:
            guard MiniCPMMLXEngine.runtimeCompiledIn else {
                return ModelAvailability(
                    runtime: .mlx,
                    state: .runtimeUnavailable,
                    modelDirectory: assetManager.runtimeDirectory(for: .mlx),
                    repositoryID: assetManager.configuredRepositoryID(for: .mlx),
                    detail: "The MLX Swift runtime is not linked into this Xcode target yet."
                )
            }
            return assetManager.availability(for: .mlx)
        case .gguf:
            guard MiniCPMGGUFEngine.runtimeCompiledIn else {
                return ModelAvailability(
                    runtime: .gguf,
                    state: .runtimeUnavailable,
                    modelDirectory: assetManager.runtimeDirectory(for: .gguf),
                    repositoryID: assetManager.configuredRepositoryID(for: .gguf),
                    detail: "The GGUF runtime is not linked into this Xcode target yet."
                )
            }
            return assetManager.availability(for: .gguf)
        case .backendFallback:
            return assetManager.availability(for: .backendFallback)
        }
    }

    func install(
        runtime: MiniCPMRuntime,
        force: Bool = false,
        progressHandler: @MainActor @escaping (Progress) -> Void
    ) async throws -> ModelAvailability {
        switch runtime {
        case .mlx:
            guard MiniCPMMLXEngine.runtimeCompiledIn else {
                throw MiniCPMEngineError.runtimeUnavailable(.mlx, "The MLX runtime is not linked into this target.")
            }
            guard let repositoryID = assetManager.configuredRepositoryID(for: .mlx) else {
                throw MiniCPMEngineError.modelUnavailable(.mlx, "No Hugging Face repository is configured for MLX.")
            }
#if canImport(HuggingFace)
            _ = try await assetManager.installMLXModel(
                repositoryID: repositoryID,
                force: force,
                progressHandler: progressHandler
            )
            return availability(for: .mlx)
#else
            throw MiniCPMEngineError.runtimeUnavailable(.mlx, "Hugging Face download support is not linked into this target.")
#endif
        case .gguf:
            throw MiniCPMEngineError.runtimeUnavailable(.gguf, "GGUF model installation is not implemented yet.")
        case .backendFallback:
            throw MiniCPMEngineError.runtimeUnavailable(.backendFallback, "Backend fallback does not require installation.")
        }
    }
}
