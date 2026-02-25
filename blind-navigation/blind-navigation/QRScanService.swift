import Foundation
import Vision
import AVFoundation
import Combine
import CryptoKit

/// QR payload for wallet transfer (amount is entered by the user, not encoded in the QR).
struct QRTransferPayload: Equatable {
    let raw: String
    let fingerprint: String
}

final class QRScanService: ObservableObject {
    @Published var lastPayload: QRTransferPayload? = nil
    @Published var isPaused: Bool = false
    @Published var isActive: Bool = false

    /// Optional allowlist. If non-empty, ONLY these exact QR payload strings are accepted.
    /// Useful for "Option A" where only your provided QR should trigger transfers.
    var allowedRawValues: Set<String> = []
    /// Fingerprint allowlist used by backend-configured trusted merchant mode.
    var allowedFingerprints: Set<String> = []

    private let queue = DispatchQueue(label: "QRScanQueue")
    private var lastProcessedTime: Date = .distantPast
    private let processingInterval: TimeInterval = 0.15

    // Debounce repeated re-reads of the same QR
    private var lastRawValue: String? = nil
    private var lastEmitTime: Date = .distantPast
    private let emitCooldown: TimeInterval = 2.0

    private lazy var request: VNDetectBarcodesRequest = {
        let req = VNDetectBarcodesRequest { [weak self] request, error in
            guard let self else { return }
            if let error {
                #if DEBUG
                print("DEBUG: QRScanService barcode request error: \(error)")
                #endif
                return
            }
            guard let results = request.results as? [VNBarcodeObservation], !results.isEmpty else { return }

            // Prefer QR first.
            let qr = results.first(where: { $0.symbology == .qr }) ?? results[0]
            guard let raw = qr.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return }

            self.handleRawValue(raw)
        }
        req.symbologies = [.qr]
        return req
    }()

    func activate() {
        DispatchQueue.main.async {
            self.isActive = true
            self.isPaused = false
            self.reset()
            #if DEBUG
            print("DEBUG: QR scan mode activated")
            #endif
        }
    }

    func deactivate() {
        DispatchQueue.main.async {
            self.isActive = false
            self.reset()
            #if DEBUG
            print("DEBUG: QR scan mode deactivated")
            #endif
        }
    }

    func reset() {
        DispatchQueue.main.async {
            self.lastPayload = nil
        }
        lastRawValue = nil
        lastEmitTime = .distantPast
        lastProcessedTime = .distantPast
    }

    func process(pixelBuffer: CVPixelBuffer) {
        guard isActive && !isPaused else { return }

        let now = Date()
        guard now.timeIntervalSince(lastProcessedTime) >= processingInterval else { return }
        lastProcessedTime = now

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        queue.async {
            do {
                try handler.perform([self.request])
            } catch {
                #if DEBUG
                print("DEBUG: QRScanService Vision perform error: \(error)")
                #endif
            }
        }
    }

    private func handleRawValue(_ raw: String) {
        let normalized = normalize(raw)
        let fingerprint = sha256(normalized)

        if !allowedFingerprints.isEmpty && !allowedFingerprints.contains(fingerprint) {
            return
        }

        // Option A: if an allowlist is provided, reject anything not in it.
        if !allowedRawValues.isEmpty {
            // Be forgiving about whitespace/newlines.
            let normalizedAllowlist = Set(allowedRawValues.map { normalize($0) })
            if !normalizedAllowlist.contains(normalized) {
                return
            }
        }

        let now = Date()
        if raw == lastRawValue, now.timeIntervalSince(lastEmitTime) < emitCooldown {
            return
        }

        let payload = QRTransferPayload(raw: raw, fingerprint: fingerprint)

        lastRawValue = raw
        lastEmitTime = now
        DispatchQueue.main.async {
            self.lastPayload = payload
        }
    }

    private func normalize(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("https://") {
            normalized = String(normalized.dropFirst("https://".count))
        } else if normalized.hasPrefix("http://") {
            normalized = String(normalized.dropFirst("http://".count))
        }
        if normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        return normalized
    }

    private func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
