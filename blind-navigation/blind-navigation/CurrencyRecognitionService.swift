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

private struct CurrencyEvidenceAccumulator {
    private struct ModelEvidence {
        let value: Int
        let timestamp: Date
    }

    private struct OCREvidence {
        let value: Int
        let timestamp: Date
    }

    private var modelEvidence: [ModelEvidence] = []
    private var ocrEvidence: [OCREvidence] = []
    private let modelWindow: TimeInterval = 1.5
    private let ocrWindow: TimeInterval = 3.0
    private let requiredConsecutiveModelMatches = 3

    mutating func recordModel(value: Int, at timestamp: Date) {
        prune(at: timestamp)
        modelEvidence.append(ModelEvidence(value: value, timestamp: timestamp))
    }

    mutating func recordOCR(value: Int, at timestamp: Date) {
        prune(at: timestamp)
        ocrEvidence.append(OCREvidence(value: value, timestamp: timestamp))
    }

    mutating func confirmedValue(at timestamp: Date) -> Int? {
        prune(at: timestamp)
        guard let latestModelValue = modelEvidence.last?.value else { return nil }

        let consecutiveMatches = modelEvidence.reversed()
            .prefix { $0.value == latestModelValue }
            .count
        guard consecutiveMatches >= requiredConsecutiveModelMatches else { return nil }
        guard ocrEvidence.contains(where: { $0.value == latestModelValue }) else { return nil }
        return latestModelValue
    }

    mutating func reset() {
        modelEvidence.removeAll()
        ocrEvidence.removeAll()
    }

    #if DEBUG
    static func assertPolicyInvariants() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        var matching = CurrencyEvidenceAccumulator()
        matching.recordOCR(value: 20, at: start)
        assert(matching.confirmedValue(at: start) == nil, "OCR must never confirm currency by itself")
        matching.recordModel(value: 20, at: start.addingTimeInterval(0.2))
        matching.recordModel(value: 20, at: start.addingTimeInterval(0.4))
        matching.recordModel(value: 20, at: start.addingTimeInterval(0.6))
        assert(matching.confirmedValue(at: start.addingTimeInterval(0.6)) == 20,
               "Matching cross-frame ML and OCR evidence should confirm")

        var mismatching = CurrencyEvidenceAccumulator()
        mismatching.recordOCR(value: 200, at: start)
        mismatching.recordModel(value: 20, at: start.addingTimeInterval(0.2))
        mismatching.recordModel(value: 20, at: start.addingTimeInterval(0.4))
        mismatching.recordModel(value: 20, at: start.addingTimeInterval(0.6))
        assert(mismatching.confirmedValue(at: start.addingTimeInterval(0.6)) == nil,
               "Mismatched OCR must not confirm a model prediction")
    }
    #endif

    private mutating func prune(at timestamp: Date) {
        modelEvidence.removeAll { timestamp.timeIntervalSince($0.timestamp) > modelWindow }
        ocrEvidence.removeAll { timestamp.timeIntervalSince($0.timestamp) > ocrWindow }
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
    private let validDenominations: Set<Int> = [10, 20, 50, 100, 200, 500]
    
    // Trained Android classifier, run directly through TensorFlow Lite on iOS.
    private var currencyInterpreter: Interpreter?
    private var currencyLabels: [String] = []
    private let modelInputSize = 224
    private let modelConfidenceThreshold: Float = 0.70
    
    private let textRequest: VNRecognizeTextRequest
    private let noteRectangleRequest: VNDetectRectanglesRequest
    
    private let ciContext = CIContext(options: nil)
    private let minLuminance: CGFloat = 0.08
    
    // A denomination is announced only after stable model evidence and at least
    // one matching OCR observation, which may arrive on a different frame.
    private var evidenceAccumulator = CurrencyEvidenceAccumulator()
    
    init() {
        #if DEBUG
        CurrencyEvidenceAccumulator.assertPolicyInvariants()
        #endif

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

            // Invoke the bundled model once during startup. This catches runtime/operator
            // incompatibilities immediately instead of silently skipping every camera frame.
            let zeroInput = Data(count: modelInputSize * modelInputSize * 3 * MemoryLayout<Float32>.size)
            try interpreter.copy(zeroInput, toInputAt: 0)
            try interpreter.invoke()
            let smokeTestOutput = try interpreter.output(at: 0)
            guard smokeTestOutput.data.count == currencyLabels.count * MemoryLayout<Float32>.size else {
                throw CurrencyModelError.smokeTestFailed
            }

            currencyInterpreter = interpreter
            print("DEBUG: Initialized TensorFlow Lite runtime \(Runtime.version)")
            print("DEBUG: Currency TFLite model loaded with \(currencyLabels.count) labels; startup inference passed")
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
        noteRectangleRequest.minimumConfidence = 0.55
        noteRectangleRequest.quadratureTolerance = 30

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
                self.evidenceAccumulator.reset()
                self.updateDetectedCurrency(nil)
                return
            }
            
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            
            do {
                // Run both ML model and text recognition in parallel
                var mlResult: (label: String, confidence: Float, margin: Float)?
                var textResults: [VNRecognizedTextObservation] = []

                try handler.perform([self.textRequest, self.noteRectangleRequest])
                if let results = self.textRequest.results {
                    textResults = results
                }
                let noteRectangle = self.noteRectangleRequest.results?
                    .max { lhs, rhs in
                        lhs.boundingBox.width * lhs.boundingBox.height < rhs.boundingBox.width * rhs.boundingBox.height
                    }

                if let result = try self.classifyCurrency(
                    pixelBuffer: pixelBuffer,
                    noteRectangle: noteRectangle
                ) {
                    if self.logTopPredictions {
                        print("DEBUG: Currency TFLite top: \(result.label)=\(String(format: "%.2f", result.confidence)), margin=\(String(format: "%.2f", result.margin))")
                    }
                    if result.confidence >= self.modelConfidenceThreshold {
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
                
                // OCR is corroborating evidence only. It can never create a currency
                // detection without a stable, matching model prediction.
                var ocrValue: Int? = nil

                // Prefer a denomination printed near a rupee marker.
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
                            ocrValue = closest.value
                            print("DEBUG: Currency OCR evidence near ₹ symbol: \(closest.value) Rupees")
                            break
                        }
                    }
                }

                // Otherwise accept OCR evidence only when the frame contains one
                // unambiguous known denomination.
                if ocrValue == nil {
                    let ocrValues = Set(numberObservations.map(\.value))
                    if ocrValues.count == 1, let singleOCRValue = ocrValues.first {
                        ocrValue = singleOCRValue
                        print("DEBUG: Currency OCR evidence: \(singleOCRValue) Rupees")
                    }
                }

                let evidenceTime = Date()
                if let ocrValue {
                    self.evidenceAccumulator.recordOCR(value: ocrValue, at: evidenceTime)
                }

                if let mlResult,
                   let mlValue = self.extractValueFromMLLabel(mlResult.label) {
                    self.evidenceAccumulator.recordModel(value: mlValue, at: evidenceTime)
                    print("DEBUG: Currency ML evidence: \(mlValue) Rupees")
                }

                if let confirmedValue = self.evidenceAccumulator.confirmedValue(at: evidenceTime) {
                    let currency = DetectedCurrency(value: confirmedValue, name: "\(confirmedValue) Rupees")
                    self.updateDetectedCurrency(currency)
                    print("DEBUG: ✅ Currency confirmed by stable ML plus OCR: \(currency.name)")
                } else {
                    self.updateDetectedCurrency(nil)
                }
            } catch {
                print("Currency recognition error:", error)
            }
        }
    }

    private func classifyCurrency(
        pixelBuffer: CVPixelBuffer,
        noteRectangle: VNRectangleObservation?
    ) throws -> (label: String, confidence: Float, margin: Float)? {
        guard let interpreter = currencyInterpreter else { return nil }

        let source = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let cropRect = classificationCropRect(for: source.extent, noteRectangle: noteRectangle)
        let cropped = source.cropped(to: cropRect)
        let translated = cropped.transformed(by: CGAffineTransform(
            translationX: -cropRect.minX,
            y: -cropRect.minY
        ))
        let resized = translated.transformed(by: CGAffineTransform(
            scaleX: CGFloat(modelInputSize) / cropRect.width,
            y: CGFloat(modelInputSize) / cropRect.height
        ))

        #if DEBUG
        print("DEBUG: Currency classification crop: \(noteRectangle == nil ? "center square" : "detected rectangle")")
        #endif

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

    private func classificationCropRect(
        for extent: CGRect,
        noteRectangle: VNRectangleObservation?
    ) -> CGRect {
        if let normalizedBox = noteRectangle?.boundingBox {
            let detected = CGRect(
                x: extent.minX + normalizedBox.minX * extent.width,
                y: extent.minY + normalizedBox.minY * extent.height,
                width: normalizedBox.width * extent.width,
                height: normalizedBox.height * extent.height
            )
            let padded = detected.insetBy(
                dx: -detected.width * 0.08,
                dy: -detected.height * 0.08
            )
            let clipped = padded.intersection(extent)
            if !clipped.isNull, clipped.width > 1, clipped.height > 1 {
                return clipped
            }
        }

        // The model was trained on square images. Preserve camera-frame aspect ratio
        // by center-cropping instead of stretching a portrait frame into a square.
        let side = min(extent.width, extent.height)
        return CGRect(
            x: extent.midX - side / 2,
            y: extent.midY - side / 2,
            width: side,
            height: side
        )
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
        }
        queue.async {
            self.evidenceAccumulator.reset()
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
    
}

private enum CurrencyModelError: Error {
    case missingResources
    case unexpectedTensorShape
    case smokeTestFailed
}
