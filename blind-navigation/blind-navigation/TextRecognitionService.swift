import Foundation
import Vision
import AVFoundation
import Combine
import CoreImage
import UIKit

struct RecognizedText: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let confidence: Float
    let boundingBox: CGRect
    
    static func == (lhs: RecognizedText, rhs: RecognizedText) -> Bool {
        return lhs.text == rhs.text && 
               abs(lhs.boundingBox.midX - rhs.boundingBox.midX) < 0.1 &&
               abs(lhs.boundingBox.midY - rhs.boundingBox.midY) < 0.1
    }
}

final class TextRecognitionService: ObservableObject {
    @Published var recognizedTexts: [RecognizedText] = []
    @Published var fullTextContent: String = ""
    @Published var isPaused: Bool = false
    
    private let textRequest: VNRecognizeTextRequest
    private let queue = DispatchQueue(label: "TextRecognitionQueue")
    private var lastProcessedTime: Date = .distantPast
    private let processingInterval: TimeInterval = 0.3 // Faster cadence for responsive OCR
    
    // Minimum confidence for text recognition
    private let minConfidence: Float = 0.55
    private let minBoundingBoxArea: CGFloat = 0.0008
    private let spellChecker = UITextChecker()

    private let usefulShortWords: Set<String> = [
        "atm", "bus", "cab", "danger", "entry", "exit", "fire", "go", "help",
        "in", "lift", "no", "open", "out", "pay", "pull", "push", "stop",
        "toilet", "warning", "washroom", "yes"
    ]
    private let usefulAcronyms: Set<String> = ["ATM", "GST", "INR", "OTP", "PIN", "QR", "UPI"]
    
    // Stability filtering
    private var recentTextSnapshots: [String] = []
    private let stabilityWindow: Int = 1
    private let requiredStableMatches: Int = 1
    
    // Debounce to prevent re-announcing same text
    private var lastAnnouncedText: String = ""
    private var lastAnnouncementTime: Date = .distantPast
    private let announcementCooldown: TimeInterval = 5.0 // Don't re-announce same text within 5 seconds
    
    init() {
        textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.recognitionLanguages = ["en-US"]
    }
    
    func process(pixelBuffer: CVPixelBuffer) {
        // Skip processing if paused (e.g., when speech is active)
        guard !isPaused else { return }
        
        // Throttle processing to avoid overload
        let now = Date()
        guard now.timeIntervalSince(lastProcessedTime) >= processingInterval else { return }
        lastProcessedTime = now
        
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Double-check pause status in async context
            guard !self.isPaused else { return }
            
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            
            do {
                try handler.perform([self.textRequest])
                
                guard let results = self.textRequest.results else { return }
                
                var texts: [RecognizedText] = []
                var allText: [String] = []
                
                for observation in results {
                    guard let candidate = observation.topCandidates(1).first,
                          candidate.confidence >= self.minConfidence else { continue }
                    
                    let text = candidate.string
                        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let boundingBox = observation.boundingBox
                    let area = boundingBox.width * boundingBox.height
                    
                    // Filter out very small or noise text
                    guard text.count >= 2 else { continue }
                    guard area >= self.minBoundingBoxArea else { continue }
                    guard self.isMeaningfulText(text) else { continue }
                    
                    texts.append(RecognizedText(
                        text: text,
                        confidence: candidate.confidence,
                        boundingBox: boundingBox
                    ))
                    
                    allText.append(text)
                }
                
                let rawText = allText.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let stableText = self.applyStabilityFilter(rawText)
                
                DispatchQueue.main.async {
                    self.recognizedTexts = texts
                    self.fullTextContent = stableText
                }
            } catch {
                print("Text recognition error:", error)
            }
        }
    }

    func filteredAnnouncementText(_ text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2, isMeaningfulText(cleaned) else { return nil }
        return cleaned
    }

    private func isMeaningfulText(_ text: String) -> Bool {
        let tokens = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return false }

        let singleCharacterTokens = tokens.filter { $0.count == 1 }.count
        if tokens.count >= 4 && Double(singleCharacterTokens) / Double(tokens.count) >= 0.6 {
            return false
        }

        let compactLetters = text.lowercased().filter(\.isLetter)
        if looksLikeKeyboardSequence(compactLetters) {
            return false
        }

        let numericTokens = tokens.filter { $0.contains(where: \.isNumber) }
        let alphabeticTokens = tokens.filter { $0.contains(where: \.isLetter) }
        if alphabeticTokens.isEmpty {
            return !numericTokens.isEmpty && (text.contains("₹") || text.contains("$") || text.count >= 3)
        }

        let recognizableWords = alphabeticTokens.filter(isRecognizableWord)
        if alphabeticTokens.count == 1 {
            return recognizableWords.count == 1
        }

        let requiredWords = max(1, Int(ceil(Double(alphabeticTokens.count) * 0.5)))
        return recognizableWords.count >= requiredWords
    }

    private func looksLikeKeyboardSequence(_ letters: String) -> Bool {
        guard letters.count >= 4 else { return false }
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        return rows.contains { row in
            row.contains(letters) || String(row.reversed()).contains(letters)
        }
    }

    private func isRecognizableWord(_ token: String) -> Bool {
        let lowercased = token.lowercased()
        if usefulShortWords.contains(lowercased) {
            return true
        }

        if usefulAcronyms.contains(token.uppercased()) {
            return true
        }

        guard token.count >= 3 else { return false }
        let range = NSRange(location: 0, length: (token as NSString).length)
        return spellChecker.rangeOfMisspelledWord(
            in: token,
            range: range,
            startingAt: 0,
            wrap: false,
            language: "en_US"
        ).location == NSNotFound
    }
    
    private func applyStabilityFilter(_ text: String) -> String {
        guard !text.isEmpty else {
            recentTextSnapshots.removeAll()
            return ""
        }
        
        recentTextSnapshots.append(text)
        if recentTextSnapshots.count > stabilityWindow {
            recentTextSnapshots.removeFirst()
        }
        
        let normalized = text.lowercased()
        let matches = recentTextSnapshots.filter { $0.lowercased() == normalized }.count
        if matches >= requiredStableMatches {
            return text
        }
        
        return ""
    }
    
    // Get announcement-worthy text (significant text blocks)
    func getAnnouncementText() -> String? {
        // Group nearby text into sentences/blocks
        let significantText = fullTextContent.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Only announce if we have meaningful text (more than just a few characters)
        guard significantText.count >= 5 else { return nil }
        
        // Check if this text is different from what we last announced
        let now = Date()
        let isSameText = significantText.lowercased() == lastAnnouncedText.lowercased()
        let isInCooldown = now.timeIntervalSince(lastAnnouncementTime) < announcementCooldown
        
        if isSameText && isInCooldown {
            return nil // Don't re-announce
        }
        
        // Update tracking
        lastAnnouncedText = significantText
        lastAnnouncementTime = now
        
        return significantText
    }
}

enum MiniCPMMode: String, Codable, CaseIterable {
    case scene
    case read
    case document
}

private struct MiniCPMAnalyzeRequest: Encodable {
    let mode: String
    let prompt: String
    let ocrText: String
    let imageBase64: String?
}

private struct MiniCPMAnalyzeResponse: Decodable {
    let provider: String?
    let mode: String?
    let summary: String
    let structuredFields: [String: String]?
    let warning: String?
}

/// Lightweight client for backend-proxied MiniCPM analysis.
final class MiniCPMService: ObservableObject {
    @Published var latestSceneSummary: String = ""
    @Published var latestReadSummary: String = ""
    @Published var latestDocumentSummary: String = ""
    @Published var latestStructuredFields: [String: String] = [:]
    @Published var lastError: String? = nil
    @Published var isProcessing: Bool = false

    private let session: URLSession
    private let ciContext = CIContext()
    private var lastInvocationByMode: [MiniCPMMode: Date] = [:]
    private let queue = DispatchQueue(label: "MiniCPMService.serial")
    private var isSubmitting = false
    private let cooldownByMode: [MiniCPMMode: TimeInterval] = [
        .scene: 7.0,
        .read: 3.0,
        .document: 2.5
    ]

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Runs exactly one user-requested analysis of the current frame.
    func analyze(pixelBuffer: CVPixelBuffer, mode: MiniCPMMode, ocrText: String, prompt: String = "") {
        queue.async {
            guard !self.isSubmitting else { return }
            let imageBase64 = self.encodeImageBase64(from: pixelBuffer)
            self.submit(mode: mode, prompt: prompt, ocrText: ocrText, imageBase64: imageBase64)
        }
    }

    func maybeAnalyze(pixelBuffer: CVPixelBuffer, mode: MiniCPMMode, ocrText: String, prompt: String = "") {
        queue.async {
            let now = Date()
            let cooldown = self.cooldownByMode[mode] ?? 5.0
            let last = self.lastInvocationByMode[mode] ?? .distantPast
            guard now.timeIntervalSince(last) >= cooldown else { return }

            // For read/document understanding, wait for meaningful text.
            if mode != .scene, ocrText.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 {
                return
            }

            self.lastInvocationByMode[mode] = now
            let imageBase64 = self.encodeImageBase64(from: pixelBuffer)
            self.submit(mode: mode, prompt: prompt, ocrText: ocrText, imageBase64: imageBase64)
        }
    }

    func analyzeText(mode: MiniCPMMode, ocrText: String, prompt: String = "") {
        queue.async {
            let now = Date()
            self.lastInvocationByMode[mode] = now
            self.submit(mode: mode, prompt: prompt, ocrText: ocrText, imageBase64: nil)
        }
    }

    private func submit(mode: MiniCPMMode, prompt: String, ocrText: String, imageBase64: String?) {
        guard !isSubmitting else { return }
        isSubmitting = true

        DispatchQueue.main.async {
            self.isProcessing = true
            self.lastError = nil
        }

        var request = URLRequest(url: BackendConfig.baseURL.appendingPathComponent("perception/analyze"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 18

        let payload = MiniCPMAnalyzeRequest(
            mode: mode.rawValue,
            prompt: prompt,
            ocrText: ocrText,
            imageBase64: imageBase64
        )

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            DispatchQueue.main.async {
                self.isProcessing = false
                self.lastError = "Failed to encode MiniCPM payload: \(error.localizedDescription)"
            }
            queue.async {
                self.isSubmitting = false
            }
            return
        }

        session.dataTask(with: request) { data, response, error in
            defer {
                self.queue.async {
                    self.isSubmitting = false
                }
                DispatchQueue.main.async {
                    self.isProcessing = false
                }
            }

            if let error {
                DispatchQueue.main.async {
                    self.lastError = "MiniCPM request failed: \(error.localizedDescription)"
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let data else {
                DispatchQueue.main.async {
                    self.lastError = "MiniCPM request returned an invalid response."
                }
                return
            }

            do {
                let decoded = try JSONDecoder().decode(MiniCPMAnalyzeResponse.self, from: data)
                DispatchQueue.main.async {
                    self.apply(decoded, for: mode)
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = "MiniCPM decode failed: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    private func apply(_ response: MiniCPMAnalyzeResponse, for mode: MiniCPMMode) {
        if let warning = response.warning, !warning.isEmpty {
            lastError = warning
        }

        switch mode {
        case .scene:
            latestSceneSummary = response.summary
        case .read:
            latestReadSummary = response.summary
        case .document:
            latestDocumentSummary = response.summary
        }

        if let fields = response.structuredFields {
            latestStructuredFields = fields
        }
    }

    private func encodeImageBase64(from pixelBuffer: CVPixelBuffer) -> String? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            return nil
        }
        let uiImage = UIImage(cgImage: cgImage)
        guard let data = uiImage.jpegData(compressionQuality: 0.32) else {
            return nil
        }
        return data.base64EncodedString()
    }
}
