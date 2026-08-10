import AVFoundation
import Combine
import CoreImage
import Foundation
import UIKit

final class MiniCPMService: ObservableObject {
    @Published var latestSceneSummary: String = ""
    @Published var latestReadSummary: String = ""
    @Published var latestDocumentSummary: String = ""
    @Published var latestStructuredFields: [String: String] = [:]
    @Published var lastError: String? = nil
    @Published var isProcessing: Bool = false
    @Published var activeRuntime: MiniCPMRuntime = .backendFallback
    @Published var runtimeStatus: String = ""
    @Published var engineDiagnostics: [String] = []
    @Published var isInstallingModel: Bool = false
    @Published var modelInstallProgress: Double = 0
    @Published var modelInstallStatus: String? = nil

    private let queue = DispatchQueue(label: "MiniCPMService.serial")
    private let ciContext = CIContext()
    private let loader: MiniCPMModelLoader
    private let session: URLSession
    private var primaryEngine: MiniCPMEngine
    private var fallbackEngines: [MiniCPMEngine] = []
    private var lastInvocationByMode: [MiniCPMMode: Date] = [:]
    private var isSubmitting = false
    private let cooldownByMode: [MiniCPMMode: TimeInterval] = [
        .scene: 7.0,
        .read: 3.0,
        .document: 2.5
    ]

    init(loader: MiniCPMModelLoader = MiniCPMModelLoader(), session: URLSession = .shared) {
        self.loader = loader
        self.session = session
        let selection = MiniCPMEngineFactory.makeSelection(loader: loader, session: session)
        self.primaryEngine = selection.primary
        self.fallbackEngines = selection.fallbacks
        self.engineDiagnostics = selection.diagnostics
        self.runtimeStatus = selection.primary.statusDescription
        self.activeRuntime = selection.primary.runtime
    }

    var canInstallPreferredLocalModel: Bool {
        loader.availability(for: .mlx).canInstallLocally && MiniCPMMLXEngine.runtimeCompiledIn
    }

    var shouldOfferModelInstall: Bool {
        guard canInstallPreferredLocalModel else { return false }
        let availability = loader.availability(for: .mlx)
        guard let directory = availability.modelDirectory else { return true }
        let requiredFiles = ["config.json", "tokenizer.json", "preprocessor_config.json", "model.safetensors.index.json"]
        return requiredFiles.contains { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    func refreshEngineSelection() {
        let selection = MiniCPMEngineFactory.makeSelection(loader: loader, session: session)
        primaryEngine = selection.primary
        fallbackEngines = selection.fallbacks

        DispatchQueue.main.async {
            self.activeRuntime = selection.primary.runtime
            self.runtimeStatus = selection.primary.statusDescription
            self.engineDiagnostics = selection.diagnostics
        }
    }

    func installPreferredLocalModel(force: Bool = false) {
        guard !isInstallingModel else { return }
        let availability = loader.availability(for: .mlx)
        guard availability.canInstallLocally else {
            DispatchQueue.main.async {
                self.modelInstallStatus = "No local MLX repository is configured."
            }
            return
        }

        DispatchQueue.main.async {
            self.isInstallingModel = true
            self.modelInstallProgress = 0
            self.modelInstallStatus = "Preparing MiniCPM download..."
            self.lastError = nil
        }

        Task {
            do {
                let updatedAvailability = try await loader.install(runtime: .mlx, force: force) { progress in
                    self.modelInstallProgress = progress.fractionCompleted
                    let percent = Int((progress.fractionCompleted * 100).rounded())
                    self.modelInstallStatus = "Downloading MiniCPM model: \(percent)%"
                }
                await MainActor.run {
                    self.isInstallingModel = false
                    self.modelInstallProgress = 1
                    self.modelInstallStatus = updatedAvailability.detail
                }
                refreshEngineSelection()
            } catch {
                await MainActor.run {
                    self.isInstallingModel = false
                    self.modelInstallStatus = "MiniCPM install failed."
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func maybeAnalyze(pixelBuffer: CVPixelBuffer, mode: MiniCPMMode, ocrText: String, prompt: String = "") {
        queue.async {
            let now = Date()
            let cooldown = self.cooldownByMode[mode] ?? 5.0
            let last = self.lastInvocationByMode[mode] ?? .distantPast
            guard now.timeIntervalSince(last) >= cooldown else { return }

            if mode != .scene, ocrText.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 {
                return
            }

            self.lastInvocationByMode[mode] = now
            let image = self.makeImage(from: pixelBuffer)
            self.submit(mode: mode, prompt: prompt, ocrText: ocrText, image: image)
        }
    }

    func analyzeText(mode: MiniCPMMode, ocrText: String, prompt: String = "") {
        queue.async {
            self.lastInvocationByMode[mode] = Date()
            self.submit(mode: mode, prompt: prompt, ocrText: ocrText, image: nil)
        }
    }

    private func submit(mode: MiniCPMMode, prompt: String, ocrText: String, image: UIImage?) {
        guard !isSubmitting else { return }
        isSubmitting = true

        DispatchQueue.main.async {
            self.isProcessing = true
            self.lastError = nil
        }

        let engines = [primaryEngine] + fallbackEngines
        attemptAnalyze(
            with: engines,
            at: 0,
            mode: mode,
            prompt: prompt,
            ocrText: ocrText,
            image: image,
            errors: []
        )
    }

    private func attemptAnalyze(
        with engines: [MiniCPMEngine],
        at index: Int,
        mode: MiniCPMMode,
        prompt: String,
        ocrText: String,
        image: UIImage?,
        errors: [String]
    ) {
        guard index < engines.count else {
            finishWithError(errors.joined(separator: " | "))
            return
        }

        let engine = engines[index]
        engine.analyze(mode: mode, prompt: prompt, ocrText: ocrText, image: image) { result in
            switch result {
            case .success(let result):
                self.finishWithResult(result, mode: mode, status: engine.statusDescription)
            case .failure(let error):
                let nextErrors = errors + ["\(engine.runtime.displayName): \(error.localizedDescription)"]
                self.attemptAnalyze(
                    with: engines,
                    at: index + 1,
                    mode: mode,
                    prompt: prompt,
                    ocrText: ocrText,
                    image: image,
                    errors: nextErrors
                )
            }
        }
    }

    private func finishWithResult(_ result: MiniCPMAnalyzeResult, mode: MiniCPMMode, status: String) {
        queue.async {
            self.isSubmitting = false
        }

        DispatchQueue.main.async {
            self.isProcessing = false
            self.activeRuntime = result.runtime
            self.runtimeStatus = status
            self.lastError = result.warning

            switch mode {
            case .scene:
                self.latestSceneSummary = result.summary
            case .read:
                self.latestReadSummary = result.summary
            case .document:
                self.latestDocumentSummary = result.summary
            }

            self.latestStructuredFields = result.structuredFields
        }
    }

    private func finishWithError(_ message: String) {
        queue.async {
            self.isSubmitting = false
        }

        DispatchQueue.main.async {
            self.isProcessing = false
            self.lastError = message.isEmpty ? "MiniCPM request failed." : message
        }
    }

    private func makeImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
