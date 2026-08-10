import Vision
import AVFoundation
import Combine

struct Detection: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect
}

final class DetectionService: ObservableObject {
    @Published var detections: [Detection] = []
    @Published var isPaused: Bool = false
    @Published var isAvailable: Bool = false

    private let model: VNCoreMLModel?
    private let request: VNCoreMLRequest?
    private let queue = DispatchQueue(label: "DetectionQueue")
    private var lastProcessedTime = Date.distantPast
    private var isProcessing = false
    private let processingInterval: TimeInterval = 0.15

    private let minConfidence: Float = 0.5 // tune 0.4–0.6
    private let personAlpha: CGFloat = 0.4
    private let defaultAlpha: CGFloat = 0.6
    private let personIou: CGFloat = 0.7 // Increased from 0.6 to reduce person clustering
    private let defaultIou: CGFloat = 0.5
    private let minNormalizedAreaForPerson: CGFloat = 0.01 // Increased from 0.003 to filter small detections
    private var smoothedBoxes: [String: CGRect] = [:]

    // Intersection over Union for NMS
    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    // Class-wise Non-Maximum Suppression with per-class IoU
    private func nonMaxSuppression(_ boxes: [Detection], iouProvider: (String) -> CGFloat) -> [Detection] {
        var result: [Detection] = []
        var candidates = boxes.sorted { $0.confidence > $1.confidence }

        while let best = candidates.first {
            result.append(best)
            candidates.removeFirst()
            let bestIoU = iouProvider(best.label)
            candidates.removeAll { cand in
                cand.label == best.label && iou(cand.boundingBox, best.boundingBox) > bestIoU
            }
        }
        return result
    }

    // Temporal smoothing for bounding boxes (per label)
    private func smooth(box: CGRect, for label: String, alpha: CGFloat = 0.6) -> CGRect {
        if let prev = smoothedBoxes[label] {
            let nx = prev.origin.x * (1 - alpha) + box.origin.x * alpha
            let ny = prev.origin.y * (1 - alpha) + box.origin.y * alpha
            let nw = prev.size.width * (1 - alpha) + box.size.width * alpha
            let nh = prev.size.height * (1 - alpha) + box.size.height * alpha
            let smoothed = CGRect(x: nx, y: ny, width: nw, height: nh)
            smoothedBoxes[label] = smoothed
            return smoothed
        } else {
            smoothedBoxes[label] = box
            return box
        }
    }
    
    private func limitMotion(previous: CGRect?, next: CGRect, maxFraction: CGFloat = 0.25) -> CGRect {
        guard let prev = previous else { return next }
        let maxDx = prev.width * maxFraction
        let maxDy = prev.height * maxFraction
        let dx = max(min(next.midX - prev.midX, maxDx), -maxDx)
        let dy = max(min(next.midY - prev.midY, maxDy), -maxDy)
        let newMid = CGPoint(x: prev.midX + dx, y: prev.midY + dy)
        return CGRect(x: newMid.x - next.width/2,
                      y: newMid.y - next.height/2,
                      width: next.width, height: next.height)
    }

    init() {
        guard let mlModel = try? yolo11n(configuration: MLModelConfiguration()).model,
              let visionModel = try? VNCoreMLModel(for: mlModel) else {
            self.model = nil
            self.request = nil
            self.isAvailable = false
            print("ERROR: DetectionService unavailable - yolo11n model could not be loaded")
            return
        }

        self.model = visionModel
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
        self.request = request
        self.isAvailable = true
    }

    func process(pixelBuffer: CVPixelBuffer) {
        guard !isPaused, let request = self.request else { return }
        let now = Date()
        guard !isProcessing, now.timeIntervalSince(lastProcessedTime) >= processingInterval else { return }
        isProcessing = true
        lastProcessedTime = now
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        queue.async {
            defer {
                DispatchQueue.main.async { self.isProcessing = false }
            }
            do {
                try handler.perform([request])
                guard let results = request.results as? [VNRecognizedObjectObservation] else { return }

                // Build detections with class-specific smoothing
                let mapped: [Detection] = results
                    .filter { $0.confidence >= self.minConfidence }
                    .compactMap { obs -> Detection? in
                        let topLabel = obs.labels.first?.identifier ?? "Object"
                        let alpha = (topLabel == "person") ? self.personAlpha : self.defaultAlpha
                        let smoothed = self.smooth(box: obs.boundingBox, for: topLabel, alpha: alpha)
                        let stabilized = self.limitMotion(previous: self.smoothedBoxes[topLabel], next: smoothed, maxFraction: 0.25)

                        // Minimum area filter for person
                        if topLabel == "person" {
                            let area = stabilized.width * stabilized.height
                            if area < self.minNormalizedAreaForPerson { return nil }
                        }

                        return Detection(label: topLabel,
                                         confidence: obs.confidence,
                                         boundingBox: stabilized)
                    }

                // Class-specific IoU for NMS
                let finalDetections = self.nonMaxSuppression(mapped) { label in
                    return (label == "person") ? self.personIou : self.defaultIou
                }
                DispatchQueue.main.async { self.detections = finalDetections }
            } catch {
                print("Vision error:", error)
            }
        }
    }
}
