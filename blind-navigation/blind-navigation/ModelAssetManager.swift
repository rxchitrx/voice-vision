import Foundation

final class ModelAssetManager {
    static let shared = ModelAssetManager()
    static let defaultMLXVLMRepositoryID = "mlx-community/MiniCPM-o-4_5-4bit"
    static let unsupportedMiniCPMRepositoryID = "mlx-community/MiniCPM-o-4_5-4bit"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func ensureBaseDirectories() throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeDirectory(for: .mlx), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeDirectory(for: .gguf), withIntermediateDirectories: true)
    }

    var baseDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("MiniCPM", isDirectory: true)
    }

    func runtimeDirectory(for runtime: MiniCPMRuntime) -> URL {
        baseDirectory.appendingPathComponent(runtime.rawValue, isDirectory: true)
    }

    func manifestURL(for runtime: MiniCPMRuntime) -> URL {
        runtimeDirectory(for: runtime).appendingPathComponent("manifest.json")
    }

    func configuredRepositoryID(for runtime: MiniCPMRuntime) -> String? {
        let key: String
        let fallback: String?
        switch runtime {
        case .mlx:
            key = "MLXVLMRepositoryID"
            fallback = Self.defaultMLXVLMRepositoryID
        case .gguf:
            key = "GGUFModelRepositoryID"
            fallback = nil
        case .backendFallback:
            return nil
        }

        if let override = UserDefaults.standard.string(forKey: key),
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        return fallback
    }

    func availability(for runtime: MiniCPMRuntime) -> ModelAvailability {
        let directory = runtimeDirectory(for: runtime)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ModelAvailability(
                runtime: runtime,
                state: .missingAssets,
                modelDirectory: directory,
                repositoryID: configuredRepositoryID(for: runtime),
                detail: "Model directory is missing at \(directory.path)."
            )
        }

        switch runtime {
        case .mlx:
            let requiredFiles = ["config.json", "tokenizer.json", "preprocessor_config.json"]
            let missing = requiredFiles.filter { !fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
            if missing.isEmpty {
                return ModelAvailability(
                    runtime: runtime,
                    state: .available,
                    modelDirectory: directory,
                    repositoryID: configuredRepositoryID(for: runtime),
                    detail: "MLX model assets found in \(directory.lastPathComponent)."
                )
            }
            if let repositoryID = configuredRepositoryID(for: runtime) {
                return ModelAvailability(
                    runtime: runtime,
                    state: .available,
                    modelDirectory: directory,
                    repositoryID: repositoryID,
                    detail: "MLX runtime will download `\(repositoryID)` on first use if local assets are missing."
                )
            }
            return ModelAvailability(
                runtime: runtime,
                state: .missingAssets,
                modelDirectory: directory,
                repositoryID: configuredRepositoryID(for: runtime),
                detail: "Missing MLX model files: \(missing.joined(separator: ", "))."
            )
        case .gguf:
            let entries = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            let hasGGUF = entries.contains(where: { $0.pathExtension.lowercased() == "gguf" })
            if hasGGUF {
                return ModelAvailability(
                    runtime: runtime,
                    state: .available,
                    modelDirectory: directory,
                    repositoryID: configuredRepositoryID(for: runtime),
                    detail: "GGUF model assets found in \(directory.lastPathComponent)."
                )
            }
            return ModelAvailability(
                runtime: runtime,
                state: .missingAssets,
                modelDirectory: directory,
                repositoryID: configuredRepositoryID(for: runtime),
                detail: "No `.gguf` model file found in \(directory.path)."
            )
        case .backendFallback:
            return ModelAvailability(
                runtime: runtime,
                state: .available,
                modelDirectory: nil,
                repositoryID: nil,
                detail: "Backend fallback is available whenever the API is reachable."
            )
        }
    }
}

private struct InstalledModelManifest: Codable {
    let runtime: String
    let repositoryID: String
    let revision: String
    let installedAt: Date
    let files: [String]
}

#if canImport(HuggingFace)
import HuggingFace

extension ModelAssetManager {
    static let mlxSnapshotPatterns = [
        "config.json",
        "generation_config.json",
        "preprocessor_config.json",
        "processor_config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "added_tokens.json",
        "chat_template.jinja",
        "vocab.json",
        "merges.txt",
        "model-*.safetensors",
        "model.safetensors.index.json"
    ]

    func installMLXModel(
        repositoryID: String,
        revision: String = "main",
        force: Bool = false,
        progressHandler: @MainActor @escaping (Progress) -> Void
    ) async throws -> URL {
        try ensureBaseDirectories()
        let destination = runtimeDirectory(for: .mlx)
        if force {
            try resetDirectory(destination)
        }

        guard let repo = Repo.ID(rawValue: repositoryID) else {
            throw HuggingFaceBridgeError.invalidRepositoryID(repositoryID)
        }

        let client = HubClient()
        let installedDirectory = try await client.downloadSnapshot(
            of: repo,
            to: destination,
            revision: revision,
            matching: Self.mlxSnapshotPatterns,
            progressHandler: progressHandler
        )

        let files = try installedFileNames(at: installedDirectory)
        let manifest = InstalledModelManifest(
            runtime: MiniCPMRuntime.mlx.rawValue,
            repositoryID: repositoryID,
            revision: revision,
            installedAt: Date(),
            files: files
        )
        try writeManifest(manifest, runtime: .mlx)
        return installedDirectory
    }

    private func resetDirectory(_ directory: URL) throws {
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func installedFileNames(at directory: URL) throws -> [String] {
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return entries.map(\.lastPathComponent).sorted()
    }

    private func writeManifest(_ manifest: InstalledModelManifest, runtime: MiniCPMRuntime) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(for: runtime), options: .atomic)
    }
}
#endif
