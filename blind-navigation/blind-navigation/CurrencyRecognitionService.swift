import Vision
import AVFoundation
import Combine
import CoreImage
import TensorFlowLite

struct DetectedCurrency: Identifiable, Equatable {
    let id = UUID()
    let value: Int
    let name: String
    
    static func == (lhs: DetectedCurrency, rhs: DetectedCurrency) -> Bool {
        return lhs.value == rhs.value && lhs.name == rhs.name
    }
}

final class CurrencyRecognitionService: ObservableObject {
    @Published var detectedCurrency: DetectedCurrency? = nil
    @Published var isPaused: Bool = false
    @Published var isActive: Bool = false // Currency detection mode active
    
    private let queue = DispatchQueue(label: "CurrencyRecognitionQueue")
    private var lastProcessedTime: Date = .distantPast
    private let processingInterval: TimeInterval = 0.2 // Faster processing in currency mode

    // Debug toggles
    private let logTopPredictions: Bool = true
    
    // Valid Indian currency denominations (in Rupees)
    private let validDenominations: Set<Int> = [10, 20, 50, 100, 200, 500, 2000]
    
    // Trained Android classifier, run directly through TensorFlow Lite on iOS.
    private var currencyInterpreter: Interpreter?
    private var currencyLabels: [String] = []
    private let modelInputSize = 224
    private let modelConfidenceThreshold: Float = 0.85
    private let modelConfidenceMargin: Float = 0.25
    
    // Presence checks prevent the closed-set classifier from labeling empty scenes.
    private let textRequest: VNRecognizeTextRequest
    private let noteRectangleRequest: VNDetectRectanglesRequest
    
    private let ciContext = CIContext(options: nil)
    private let minLuminance: CGFloat = 0.08
    
    // Consensus tracking
    private var recentCurrencyDetections: [(value: Int, timestamp: Date)] = []
    private let consensusWindow: TimeInterval = 0.8
    private let requiredMatches: Int = 2
    
    // Indian currency note colors (approximate RGB ranges)
    private let currencyColorRanges: [(name: String, rRange: ClosedRange<CGFloat>, gRange: ClosedRange<CGFloat>, bRange: ClosedRange<CGFloat>)] = [
        ("10", 0.4...0.7, 0.3...0.6, 0.2...0.5),   // Brown/Orange
        ("20", 0.5...0.8, 0.2...0.5, 0.2...0.5),   // Red/Pink
        ("50", 0.2...0.5, 0.4...0.7, 0.2...0.5),   // Green
        ("100", 0.2...0.5, 0.2...0.5, 0.4...0.7),  // Blue/Purple
        ("200", 0.6...0.9, 0.5...0.8, 0.2...0.5),  // Yellow/Orange
        ("500", 0.5...0.8, 0.4...0.7, 0.2...0.5),  // Orange/Brown
        ("2000", 0.6...0.9, 0.3...0.6, 0.5...0.8)  // Magenta/Pink
    ]
    
    init() {
        do {
            guard let modelPath = Bundle.main.path(forResource: "IndianCurrency", ofType: "tflite"),
                  let labelsURL = Bundle.main.url(forResource: "currency_labels", withExtension: "txt") else {
                throw CurrencyModelError.missingResources
            }

            currencyLabels = try String(contentsOf: labelsURL, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .map(String.init)

            var options = Interpreter.Options()
            options.threadCount = 2
            let interpreter = try Interpreter(modelPath: modelPath, options: options)
            try interpreter.allocateTensors()

            let input = try interpreter.input(at: 0)
            let output = try interpreter.output(at: 0)
            guard input.shape.dimensions == [1, modelInputSize, modelInputSize, 3],
                  input.dataType == .float32,
                  output.shape.dimensions == [1, currencyLabels.count] else {
                throw CurrencyModelError.unexpectedTensorShape
            }

            currencyInterpreter = interpreter
            print("DEBUG: Currency TFLite model loaded with \(currencyLabels.count) labels")
        } catch {
            currencyInterpreter = nil
            print("ERROR: Failed to load currency TFLite model: \(error)")
        }
        
        // Configure text recognition for ₹ symbol detection
        textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false
        textRequest.recognitionLanguages = ["en-US"]

        noteRectangleRequest = VNDetectRectanglesRequest()
        noteRectangleRequest.maximumObservations = 3
        noteRectangleRequest.minimumAspectRatio = 0.30
        noteRectangleRequest.maximumAspectRatio = 0.75
        noteRectangleRequest.minimumSize = 0.15
        noteRectangleRequest.minimumConfidence = 0.60
        noteRectangleRequest.quadratureTolerance = 25
        
        print("DEBUG: Currency recognition service initialized")
    }
    
    /// Activate currency detection mode
    func activate() {
        DispatchQueue.main.async {
            self.isActive = true
            self.isPaused = false
            self.reset()
            print("DEBUG: Currency detection mode activated")
        }
    }
    
    /// Deactivate currency detection mode
    func deactivate() {
        DispatchQueue.main.async {
            self.isActive = false
            self.reset()
            print("DEBUG: Currency detection mode deactivated")
        }
    }
    
    func process(pixelBuffer: CVPixelBuffer) {
        // Only process when active
        guard isActive && !isPaused else { return }
        guard currencyInterpreter != nil else {
            // This is the most common failure mode when the model isn't correctly included/compiled.
            // Keep it low-noise by logging once per activation window.
            #if DEBUG
            print("DEBUG: CurrencyRecognitionService skipping frame: TFLite model is not loaded")
            #endif
            return
        }
        
        let now = Date()
        guard now.timeIntervalSince(lastProcessedTime) >= processingInterval else { return }
        lastProcessedTime = now
        
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.isActive && !self.isPaused else { return }
            
            // Check brightness
            if !self.passesBrightnessGate(pixelBuffer: pixelBuffer) {
                self.recentCurrencyDetections.removeAll()
                self.updateDetectedCurrency(nil)
                return
            }
            
            // Get dominant color for color matching
            let dominantColor = self.getDominantColor(pixelBuffer: pixelBuffer)
            
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            
            do {
                // Run both ML model and text recognition in parallel
                var mlResult: (label: String, confidence: Float, margin: Float)?
                var textResults: [VNRecognizedTextObservation] = []

                // Establish that a note-like object is present before asking the classifier for a denomination.
                try handler.perform([self.textRequest, self.noteRectangleRequest])
                if let results = self.textRequest.results {
                    textResults = results
                }
                let hasNoteRectangle = !(self.noteRectangleRequest.results?.isEmpty ?? true)

                if hasNoteRectangle, let result = try self.classifyCurrency(pixelBuffer: pixelBuffer) {
                    if self.logTopPredictions {
                        print("DEBUG: Currency TFLite top: \(result.label)=\(String(format: "%.2f", result.confidence)), margin=\(String(format: "%.2f", result.margin))")
                    }
                    if result.confidence >= self.modelConfidenceThreshold,
                       result.margin >= self.modelConfidenceMargin {
                        mlResult = result
                        print("DEBUG: Currency ML candidate: '\(result.label)' (conf: \(String(format: "%.2f", result.confidence)))")
                    }
                }
                
                // Find ₹ symbol and nearby numbers
                var rupeeSymbols: [VNRecognizedTextObservation] = []
                var numberObservations: [(value: Int, observation: VNRecognizedTextObservation)] = []
                
                for observation in textResults {
                    guard let candidate = observation.topCandidates(1).first,
                          candidate.confidence >= 0.5 else { continue }
                    
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // Check for ₹ symbol
                    if text.contains("₹") || text.contains("Rs") || text.contains("RS") {
                        rupeeSymbols.append(observation)
                        print("DEBUG: Found ₹ symbol: '\(text)'")
                    }
                    
                    // Extract numbers
                    let numbers = text.components(separatedBy: CharacterSet.decimalDigits.inverted)
                        .joined()
                    if !numbers.isEmpty, let value = Int(numbers), self.validDenominations.contains(value) {
                        numberObservations.append((value: value, observation: observation))
                        print("DEBUG: Found number: \(value) in text '\(text)'")
                    }
                }
                
                // Determine currency value using multiple methods
                var detectedValue: Int? = nil
                
                // Method 1: Find number near ₹ symbol
                if !rupeeSymbols.isEmpty && !numberObservations.isEmpty {
                    for rupeeObs in rupeeSymbols {
                        let rupeeBox = rupeeObs.boundingBox
                        var closestNumber: (value: Int, distance: CGFloat)? = nil
                        
                        for (value, numberObs) in numberObservations {
                            let numberBox = numberObs.boundingBox
                            let horizontalDistance = abs(rupeeBox.midX - numberBox.midX)
                            let verticalDistance = abs(rupeeBox.midY - numberBox.midY)
                            
                            // Numbers should be near the symbol
                            if horizontalDistance < 0.3 && verticalDistance < 0.2 {
                                let totalDistance = sqrt(horizontalDistance * horizontalDistance + verticalDistance * verticalDistance)
                                if closestNumber == nil || totalDistance < closestNumber!.distance {
                                    closestNumber = (value: value, distance: totalDistance)
                                }
                            }
                        }
                        
                        if let closest = closestNumber {
                            detectedValue = closest.value
                            print("DEBUG: Currency detected via ₹ symbol: \(closest.value) Rupees")
                            break
                        }
                    }
                }
                
                // Method 2: Use ML model result if available
                if detectedValue == nil, let mlResult = mlResult {
                    if let mlValue = self.extractValueFromMLLabel(mlResult.label) {
                        // Color matching is a nice extra signal, but it's brittle across lighting/cameras.
                        // Prefer the ML output directly once the label parses.
                        detectedValue = mlValue
                        print("DEBUG: Currency detected via ML model: \(mlValue) Rupees")
                    }
                }
                
                // Method 3: Match numbers by color if no ₹ symbol
                if detectedValue == nil && hasNoteRectangle && !numberObservations.isEmpty {
                    for (value, _) in numberObservations {
                        // If OCR found a known denomination, accept it (color match is optional).
                        detectedValue = value
                        print("DEBUG: Currency detected via OCR number: \(value) Rupees")
                        break
                    }
                }
                
                // Process detected currency
                if let value = detectedValue {
                    let detectionTime = Date()
                    if recentCurrencyDetections.last?.value != value {
                        recentCurrencyDetections.removeAll()
                    }
                    self.recentCurrencyDetections.append((value: value, timestamp: detectionTime))
                    self.pruneOldDetections(now: detectionTime)
                    
                    // Check consensus
                    let matchingDetections = self.recentCurrencyDetections.filter { $0.value == value }
                    
                    if matchingDetections.count >= self.requiredMatches {
                        let currency = DetectedCurrency(value: value, name: "\(value) Rupees")
                        self.updateDetectedCurrency(currency)
                        print("DEBUG: ✅ Currency confirmed: \(currency.name)")
                    } else {
                        self.updateDetectedCurrency(nil)
                    }
                } else {
                    self.recentCurrencyDetections.removeAll()
                    self.updateDetectedCurrency(nil)
                }
            } catch {
                print("Currency recognition error:", error)
            }
        }
    }

    private func classifyCurrency(pixelBuffer: CVPixelBuffer) throws -> (label: String, confidence: Float, margin: Float)? {
        guard let interpreter = currencyInterpreter else { return nil }

        let source = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let translated = source.transformed(by: CGAffineTransform(
            translationX: -source.extent.minX,
            y: -source.extent.minY
        ))
        let resized = translated.transformed(by: CGAffineTransform(
            scaleX: CGFloat(modelInputSize) / source.extent.width,
            y: CGFloat(modelInputSize) / source.extent.height
        ))

        var rgba = [UInt8](repeating: 0, count: modelInputSize * modelInputSize * 4)
        ciContext.render(
            resized,
            toBitmap: &rgba,
            rowBytes: modelInputSize * 4,
            bounds: CGRect(x: 0, y: 0, width: modelInputSize, height: modelInputSize),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        var rgb = [Float32]()
        rgb.reserveCapacity(modelInputSize * modelInputSize * 3)
        for index in stride(from: 0, to: rgba.count, by: 4) {
            rgb.append(Float32(rgba[index]))
            rgb.append(Float32(rgba[index + 1]))
            rgb.append(Float32(rgba[index + 2]))
        }

        let inputData = rgb.withUnsafeBufferPointer(Data.init(buffer:))
        try interpreter.copy(inputData, toInputAt: 0)
        try interpreter.invoke()

        let output = try interpreter.output(at: 0)
        let confidences = output.data.withUnsafeBytes {
            Array($0.bindMemory(to: Float32.self))
        }
        let ranked = confidences.enumerated().sorted { $0.element > $1.element }
        guard ranked.count >= 2,
              let best = ranked.first,
              currencyLabels.indices.contains(best.offset) else {
            return nil
        }
        return (currencyLabels[best.offset], best.element, best.element - ranked[1].element)
    }
    
    /// Extract currency value from ML model label
    private func extractValueFromMLLabel(_ label: String) -> Int? {
        let cleaned = label
            .lowercased()
            .replacingOccurrences(of: "rs", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "rupees", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "rupee", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "note", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "inr", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "₹", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        let digits = cleaned.filter { $0.isNumber }
        guard !digits.isEmpty, let value = Int(digits) else { return nil }
        
        return validDenominations.contains(value) ? value : nil
    }
    
    private func pruneOldDetections(now: Date) {
        let expiration: TimeInterval = consensusWindow
        recentCurrencyDetections = recentCurrencyDetections.filter { now.timeIntervalSince($0.timestamp) <= expiration }
    }
    
    private func updateDetectedCurrency(_ currency: DetectedCurrency?) {
        DispatchQueue.main.async {
            if self.detectedCurrency != currency {
                self.detectedCurrency = currency
            }
        }
    }
    
    /// Reset currency detection state
    func reset() {
        DispatchQueue.main.async {
            self.detectedCurrency = nil
            self.recentCurrencyDetections.removeAll()
        }
    }
    
    private func passesBrightnessGate(pixelBuffer: CVPixelBuffer) -> Bool {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        
        guard let averageFilter = CIFilter(name: "CIAreaAverage") else {
            return true
        }
        averageFilter.setValue(ciImage, forKey: kCIInputImageKey)
        averageFilter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        
        let outputImage = averageFilter.outputImage ?? ciImage
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(outputImage,
                         toBitmap: &pixel,
                         rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8,
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        let r = CGFloat(pixel[0]) / 255.0
        let g = CGFloat(pixel[1]) / 255.0
        let b = CGFloat(pixel[2]) / 255.0
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance >= minLuminance
    }
    
    /// Get dominant color from image (for currency color matching)
    private func getDominantColor(pixelBuffer: CVPixelBuffer) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        
        guard let averageFilter = CIFilter(name: "CIAreaAverage") else {
            return (0.5, 0.5, 0.5)
        }
        averageFilter.setValue(ciImage, forKey: kCIInputImageKey)
        averageFilter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        
        let outputImage = averageFilter.outputImage ?? ciImage
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(outputImage,
                         toBitmap: &pixel,
                         rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8,
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        
        return (
            r: CGFloat(pixel[0]) / 255.0,
            g: CGFloat(pixel[1]) / 255.0,
            b: CGFloat(pixel[2]) / 255.0
        )
    }
    
    /// Check if detected color matches expected currency color
    private func matchesCurrencyColor(value: Int, color: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Bool {
        guard let colorRange = currencyColorRanges.first(where: { Int($0.name) == value }) else {
            return false
        }
        
        let matchesR = colorRange.rRange.contains(color.r)
        let matchesG = colorRange.gRange.contains(color.g)
        let matchesB = colorRange.bRange.contains(color.b)
        
        // At least 2 out of 3 color channels should match
        let matchCount = [matchesR, matchesG, matchesB].filter { $0 }.count
        return matchCount >= 2
    }
}

private enum CurrencyModelError: Error {
    case missingResources
    case unexpectedTensorShape
}
