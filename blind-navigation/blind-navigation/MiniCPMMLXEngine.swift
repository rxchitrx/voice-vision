#if canImport(CoreImage) && canImport(HuggingFace) && canImport(MLX) && canImport(MLXLMCommon) && canImport(MLXNN) && canImport(MLXVLM) && canImport(Tokenizers)
import CoreImage
import Foundation
import HuggingFace
import MLX
import MLXLMCommon
import MLXNN
import MLXVLM
import Tokenizers
import UIKit

final class MiniCPMMLXEngine: MiniCPMEngine {
    static let runtimeCompiledIn: Bool = true

    let runtime: MiniCPMRuntime = .mlx
    private let availability: ModelAvailability
    private let queue = DispatchQueue(label: "MiniCPMMLXEngine")
    private let downloader = HuggingFaceSnapshotDownloader()
    private let tokenizerLoader = HuggingFaceTokenizerLoader()
    private var modelContainerTask: Task<ModelContainer, Error>?

    init(availability: ModelAvailability) {
        self.availability = availability
    }

    var statusDescription: String {
        availability.detail
    }

    var isReady: Bool {
        availability.isAvailable && Self.runtimeCompiledIn
    }

    func analyze(
        mode: MiniCPMMode,
        prompt: String,
        ocrText: String,
        image: UIImage?,
        completion: @escaping (Result<MiniCPMAnalyzeResult, Error>) -> Void
    ) {
        Task {
            do {
                await MiniCPMMLXRuntime.ensureRegistered()
                let container = try await loadModelContainer()
                let session = ChatSession(
                    container,
                    generateParameters: .init(maxTokens: 220, temperature: 0.2),
                    processing: .init(resize: CGSize(width: 448, height: 448))
                )
                let response = try await session.respond(
                    to: buildPrompt(mode: mode, prompt: prompt, ocrText: ocrText),
                    image: image.flatMap(makeUserInputImage(from:))
                )
                completion(.success(MiniCPMAnalyzeResult(
                    runtime: .mlx,
                    summary: normalizedSummary(from: response),
                    structuredFields: parseStructuredFields(from: response),
                    warning: nil
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func loadModelContainer() async throws -> ModelContainer {
        if let task = queue.sync(execute: { modelContainerTask }) {
            return try await task.value
        }

        let task = Task<ModelContainer, Error> {
            if let repositoryID = availability.repositoryID {
                let configuration = ModelConfiguration(
                    id: repositoryID,
                    defaultPrompt: "Describe the image in English"
                )
                return try await VLMModelFactory.shared.loadContainer(
                    from: downloader,
                    using: tokenizerLoader,
                    configuration: configuration,
                    progressHandler: { progress in
                        print("MiniCPM MLX download progress:", progress.fractionCompleted)
                    }
                )
            }

            guard let directory = availability.modelDirectory else {
                throw MiniCPMEngineError.modelUnavailable(runtime, availability.detail)
            }
            _ = ModelConfiguration(
                directory: directory,
                defaultPrompt: "Describe the image in English"
            )
            return try await VLMModelFactory.shared.loadContainer(
                from: directory,
                using: tokenizerLoader
            )
        }

        queue.sync {
            modelContainerTask = task
        }

        do {
            return try await task.value
        } catch {
            queue.sync {
                modelContainerTask = nil
            }
            throw error
        }
    }

    private func buildPrompt(mode: MiniCPMMode, prompt: String, ocrText: String) -> String {
        var lines = [prompt.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("OCR context:\n\(ocrText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        switch mode {
        case .scene:
            lines.append("Reply in one or two concise sentences focused on navigation-relevant details.")
        case .read:
            lines.append("Read and explain the visible text briefly and clearly.")
        case .document:
            lines.append("Return a concise summary and key-value fields in plain text.")
        }

        return lines.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func makeUserInputImage(from image: UIImage) -> UserInput.Image? {
        guard let ciImage = CIImage(image: image) else {
            return nil
        }
        return .ciImage(ciImage)
    }

    private func normalizedSummary(from response: String) -> String {
        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = cleaned.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let summary = object["summary"] as? String,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return summary.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

}
#else
import Foundation
import UIKit

final class MiniCPMMLXEngine: MiniCPMEngine {
    static let runtimeCompiledIn: Bool = false

    let runtime: MiniCPMRuntime = .mlx
    private let availability: ModelAvailability

    init(availability: ModelAvailability) {
        self.availability = availability
    }

    var statusDescription: String {
        availability.detail
    }

    var isReady: Bool {
        availability.isAvailable && Self.runtimeCompiledIn
    }

    func analyze(
        mode: MiniCPMMode,
        prompt: String,
        ocrText: String,
        image: UIImage?,
        completion: @escaping (Result<MiniCPMAnalyzeResult, Error>) -> Void
    ) {
        completion(.failure(
            MiniCPMEngineError.runtimeUnavailable(
                runtime,
                "Add the MLX Swift, MLX VLM, HuggingFace, and Tokenizers packages to enable on-device MLX inference."
            )
        ))
    }
}
#endif
