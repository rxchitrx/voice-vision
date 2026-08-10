import Foundation
import Vision
import AVFoundation
import Combine

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
    private let minConfidence: Float = 0.4
    private let minBoundingBoxArea: CGFloat = 0.0008
    
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
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false
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
                    let boundingBox = observation.boundingBox
                    let area = boundingBox.width * boundingBox.height
                    
                    // Filter out very small or noise text
                    guard text.count >= 2 else { continue }
                    guard area >= self.minBoundingBoxArea else { continue }
                    
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
