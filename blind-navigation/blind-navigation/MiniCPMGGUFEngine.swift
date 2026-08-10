import Foundation
import UIKit

final class MiniCPMGGUFEngine: MiniCPMEngine {
    static let runtimeCompiledIn: Bool = false

    let runtime: MiniCPMRuntime = .gguf
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
        let error: MiniCPMEngineError
        if !Self.runtimeCompiledIn {
            error = .runtimeUnavailable(runtime, "Link a GGUF-compatible iOS runtime before enabling GGUF fallback.")
        } else if !availability.isAvailable {
            error = .modelUnavailable(runtime, availability.detail)
        } else {
            error = .inferenceFailed(runtime, "GGUF inference adapter is scaffolded but not implemented for MiniCPM yet.")
        }
        completion(.failure(error))
    }
}
