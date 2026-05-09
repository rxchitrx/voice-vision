import SwiftUI
import Combine
import ARKit
import AVFoundation

struct ContentView: View {
    @StateObject private var arCamera = ARCameraService()
    @StateObject private var detector: DetectionService
    @StateObject private var currencyRecognition = CurrencyRecognitionService()
    @StateObject private var speechService = SpeechService()

    // Debug/diagnostics
    @State private var lastARSessionError: String? = nil
    @State private var cameraAuthStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    
    init() {
        // Initialize detector safely
        print("DEBUG: Initializing DetectionService...")
        if let detectionService = DetectionService() {
            _detector = StateObject(wrappedValue: detectionService)
            print("DEBUG: DetectionService initialized successfully")
        } else {
            print("ERROR: Failed to initialize DetectionService - ML model could not be loaded")
            // This will crash, but with a clear error message
            // In production, the model should always be available
            fatalError("Failed to initialize DetectionService - ML model could not be loaded. Please ensure yolo11n.mlpackage is included in the app bundle.")
        }
    }
    
    // Track objects that have been announced (only reset when they leave frame)
    @State private var announcedObjects: Set<String> = []
    // Track objects in the last few frames to detect when they truly leave
    @State private var recentlyDetectedObjects: [Set<String>] = []
    private let frameHistorySize = 5 // Number of frames to check before considering object "gone"
    // Global cooldown per label to prevent spam from micro-movements
    @State private var lastAnnouncementTimeByLabel: [String: Date] = [:]
    private let objectAnnouncementCooldown: TimeInterval = 4.0
    
    // Currency recognition state
    @State private var detectedCurrency: DetectedCurrency? = nil
    @State private var pendingCurrency: DetectedCurrency? = nil
    @State private var isCurrencyModeActive: Bool = false // Currency detection mode
    @State private var lastCurrencyPromptTime: Date = .distantPast
    private let currencyPromptCooldown: TimeInterval = 3.0
    
    // Whitelist of object labels that should be spoken aloud
    // Only large, important objects that blind users need to know about
    // Note: YOLO11n trained on COCO doesn't include "door" or "window" classes
    private let speakableLabels: Set<String> = [
        "person", // Added for navigation safety
        "chair",
        "couch",
        "bed",
        "dining table",
        "refrigerator", // Used as proxy for cupboards/cabinets
        "wall", // Detected via ARKit vertical planes
        "doorway", // Detected via ARKit gaps between planes (ANNOUNCE)
        "car",
        "motorcycle",
        "bus",
        "train",
        "truck",
        "boat"
    ]
    
    // Labels to detect but NOT announce (visual only)
    private let silentLabels: Set<String> = [
        "window" // Detected via ARKit but not announced
    ]
    // Vehicle labels that require stricter filtering to avoid false positives
    private let vehicleLabels: Set<String> = [
        "car",
        "motorcycle",
        "bus",
        "train",
        "truck",
        "boat"
    ]
    
    // Person detections need stricter filtering
    private let personLabels: Set<String> = [
        "person"
    ]
    
    // Error state
    @State private var initializationError: String? = nil
    @State private var arSessionStarted: Bool = false

    var body: some View {
        ZStack {
            // Background color to prevent black screen
            Color.black
                .ignoresSafeArea()
            
            // Show error message if initialization failed
            if let error = initializationError {
                VStack(spacing: 20) {
                    Text("Initialization Error")
                        .font(.title)
                        .foregroundColor(.white)
                    Text(error)
                        .font(.body)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                    Text("Please check Xcode console for details")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .padding()
                .background(Color.black)
            } else {
                // Show camera preview once AR session is ready
                if arSessionStarted {
                    CameraPreview(arCameraService: arCamera)
                        .ignoresSafeArea()
                } else {
                    // Show loading state
                    VStack(spacing: 20) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                        Text("Initializing AR Camera...")
                            .foregroundColor(.white)
                            .font(.headline)
                        Text("If this screen persists, check Xcode console")
                            .foregroundColor(.gray)
                            .font(.caption)
                            .padding(.top)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                }
            }

            // Lightweight always-on debug overlay (helps diagnose black screen on device)
            VStack(alignment: .leading, spacing: 6) {
                Text("Debug")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("Camera auth: \(debugCameraAuthString(cameraAuthStatus))")
                    .font(.caption2)
                Text("AR started: \(arSessionStarted ? "yes" : "no")")
                    .font(.caption2)
                Text("Has frames: \(arCamera.latestBuffer == nil ? "no" : "yes")")
                    .font(.caption2)
                if let last = lastARSessionError {
                    Text("AR error: \(last)")
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(3)
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.55))
            .foregroundColor(.white)
            .cornerRadius(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding([.top, .leading], 12)
            .zIndex(2000)
            ForEach(detector.detections) { detection in
                DetectionBox(detection: detection)
            }
            ForEach(arCamera.wallDetections) { detection in
                DetectionBox(detection: detection)
            }
            ForEach(arCamera.doorwayDetections) { detection in
                DetectionBox(detection: detection, color: .blue) // Blue for doorways
            }
            ForEach(arCamera.windowDetections) { detection in
                DetectionBox(detection: detection, color: .cyan) // Cyan for windows
            }
            
            // Currency mode indicator
            if isCurrencyModeActive {
                VStack {
                    HStack {
                        Spacer()
                        VStack {
                            Text("Currency Mode")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("Double tap to exit")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding()
                        .background(Color.blue.opacity(0.8))
                        .cornerRadius(10)
                        .padding()
                    }
                    Spacer()
                }
                .zIndex(1200)
            }
        }
        .onTapGesture {
            handlePrimaryConfirmationTap()
        }
        .highPriorityGesture(
            TapGesture(count: 2)
                .onEnded {
                    handleCurrencyModeToggleGesture()
                }
        )
        .onReceive(arCamera.$latestBuffer.compactMap { $0 }) { buffer in
            // Currency mode owns the camera pipeline while active.
            if !isCurrencyModeActive {
                detector.process(pixelBuffer: buffer)
            }
            // Always process currency recognition (it checks isActive internally)
            currencyRecognition.process(pixelBuffer: buffer)
        }
        .onReceive(detector.$detections) { detections in
            // Only handle detections when NOT in currency mode.
            if !isCurrencyModeActive {
                handleDetections(detections, announce: true)
            }
        }
        .onReceive(arCamera.$wallDetections) { walls in
            handleDetections(walls, announce: true)
        }
        .onReceive(arCamera.$doorwayDetections) { doorways in
            handleDetections(doorways, announce: true)
        }
        .onReceive(arCamera.$windowDetections) { windows in
            handleDetections(windows, announce: false) // Detect but don't announce
        }
        .onReceive(currencyRecognition.$detectedCurrency) { currency in
            handleCurrencyDetection(currency)
        }
        .onReceive(speechService.$isSpeaking) { isSpeaking in
            // Pause currency recognition when speech is active to avoid conflicts.
            currencyRecognition.isPaused = isSpeaking
        }
        .onAppear {
            print("DEBUG: ========== ContentView appeared - starting services... ==========")
            
            // Check for basic requirements first
            guard ARWorldTrackingConfiguration.isSupported else {
                let errorMsg = "ARKit is not supported on this device"
                print("ERROR: \(errorMsg)")
                initializationError = errorMsg
                return
            }
            
            // Start unified AR camera service (handles both camera feed and wall detection)
            // IMPORTANT: On first install, starting AR before camera permission is granted can lead to a black screen.
            requestCameraAccessAndStartAR()
            
            print("DEBUG: Initializing speech service...")
            speechService.initialize()
            
            // Test speech output to verify it works
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                print("DEBUG: Testing speech output...")
                speechService.speak(label: "Test", phrase: "VoiceVision app is ready")
            }
            
            print("DEBUG: ContentView initialization complete")
        }
        .onDisappear {
            TorchService.shared.setTorch(enabled: false)
            arCamera.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // If the app came back from background right after a permission prompt, ensure AR is running.
            cameraAuthStatus = AVCaptureDevice.authorizationStatus(for: .video)
            if initializationError == nil && !arSessionStarted {
                requestCameraAccessAndStartAR()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ARSessionError"))) { note in
            let message: String
            if let err = note.object as? Error {
                message = err.localizedDescription
            } else {
                message = "Unknown ARSession error"
            }
            DispatchQueue.main.async {
                self.lastARSessionError = message
                self.initializationError = "ARSession error: \(message)"
            }
        }
    }

    private func requestCameraAccessAndStartAR() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAuthStatus = status
        switch status {
        case .authorized:
            startARNow()
        case .notDetermined:
            print("DEBUG: Requesting camera permission...")
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.cameraAuthStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    if granted {
                        print("DEBUG: Camera permission granted")
                        self.startARNow()
                    } else {
                        let errorMsg = "Camera permission is required to show the camera feed. Enable it in Settings > Privacy & Security > Camera."
                        print("ERROR: \(errorMsg)")
                        self.initializationError = errorMsg
                    }
                }
            }
        case .denied, .restricted:
            let errorMsg = "Camera permission is not available. Enable it in Settings > Privacy & Security > Camera."
            print("ERROR: \(errorMsg)")
            initializationError = errorMsg
        @unknown default:
            let errorMsg = "Unknown camera permission state."
            print("ERROR: \(errorMsg)")
            initializationError = errorMsg
        }
    }

    private func startARNow() {
        print("DEBUG: Starting AR camera...")
        arCamera.start()
        // Mark AR session as started after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.arSessionStarted = true
            print("DEBUG: AR session marked as started")
        }
    }

    private func debugCameraAuthString(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }
    

    private func handleDetections(_ detections: [Detection], announce: Bool = true) {
        // Filter to valid detections (speakable or silent labels)
        let validDetections = detections.filter { detection in
            let label = detection.label.lowercased()
            
            // Check if in speakable whitelist or silent list
            let isInWhitelist = speakableLabels.contains(label) || silentLabels.contains(label)
            guard isInWhitelist else {
                return false
            }
            
            // ARKit detections (doorway, wall, window) have high confidence and should pass through
            if label == "doorway" || label == "wall" || label == "window" {
                return true // ARKit detections are already validated
            }
            
            // Very strict filtering for person detections to reduce clustering
            // Person need high confidence (0.60) and reasonable size (0.2 height)
            if personLabels.contains(label) {
                return detection.confidence > 0.60 && detection.boundingBox.height > 0.2
            }
            
            // Stricter filtering for vehicles to reduce false positives
            // Vehicles need higher confidence (0.65) and larger size (0.3 height)
            if vehicleLabels.contains(label) {
                return detection.confidence > 0.65 && detection.boundingBox.height > 0.3
            }
            
            // Base filters for other objects: confidence and size
            guard detection.confidence > 0.45 && detection.boundingBox.height > 0.25 else {
                return false
            }
            
            return true
        }
        
        // Create unique keys for currently detected objects (label + position)
        let currentObjectKeys = Set(validDetections.map { createObjectKey(for: $0) })
        
        // Add current frame to history
        recentlyDetectedObjects.append(currentObjectKeys)
        if recentlyDetectedObjects.count > frameHistorySize {
            recentlyDetectedObjects.removeFirst()
        }
        
        // Find objects that have truly left the frame (not in last N frames)
        let objectsStillPresent = recentlyDetectedObjects.reduce(Set<String>()) { $0.union($1) }
        
        // Remove objects from announced set if they've been gone for several frames
        announcedObjects = announcedObjects.intersection(objectsStillPresent)
        
        // Only announce if requested (for speakable objects)
        guard announce else { return }
        
        // Announce only objects that haven't been announced yet
        for detection in validDetections {
            let objectKey = createObjectKey(for: detection)
            let label = detection.label.lowercased()
            
            // Skip if already announced
            guard !announcedObjects.contains(objectKey) else { continue }
            
            // Skip silent labels (windows)
            guard !silentLabels.contains(label) else { continue }
            
            // Only announce if in speakable list
            guard speakableLabels.contains(label) else { continue }
            
            // Global cooldown per label to avoid spam from micro-movements
            let now = Date()
            if let lastTime = lastAnnouncementTimeByLabel[label],
               now.timeIntervalSince(lastTime) < objectAnnouncementCooldown {
                continue
            }
            lastAnnouncementTimeByLabel[label] = now
            
            let position = describePosition(for: detection)
            let distance = estimateDistance(for: detection.boundingBox)
            let labelCapitalized = detection.label.capitalized
            
            // Include distance for all large objects
            // Make announcements more concise and clear
            let phrase: String
            if distance.contains("half") || distance.contains("1 meter") {
                // Close objects - emphasize proximity
                phrase = "\(labelCapitalized) \(position), \(distance). Be careful."
            } else {
                phrase = "\(labelCapitalized) \(position), \(distance)"
            }

            DispatchQueue.main.async {
                self.speechService.speak(label: labelCapitalized, phrase: phrase)
            }
            
            // Mark as announced
            announcedObjects.insert(objectKey)
        }
        
        announceMeshObstacleIfNeeded()
    }
    
    /// Creates a unique key for an object based on label and position
    /// This allows tracking the same object type in different positions separately
    private func createObjectKey(for detection: Detection) -> String {
        let label = detection.label.lowercased()
        let position = describePosition(for: detection)
        return "\(label)_\(position)"
    }

    private func describePosition(for detection: Detection) -> String {
        let centerX = detection.boundingBox.midX
        if centerX < 0.33 { return "on your left" }
        if centerX > 0.66 { return "on your right" }
        return "in front of you"
    }

    private func describeProximity(for height: CGFloat) -> String? {
        if height > 0.6 { return "Very close" }
        if height > 0.4 { return "Close" }
        return nil
    }
    
    /// Estimates approximate distance to object based on bounding box size
    /// Uses normalized height (0.0 to 1.0) as proxy for distance
    /// Returns distance in meters as a string
    private func estimateDistance(for boundingBox: CGRect) -> String {
        // Use both height and area for better distance estimation
        let height = boundingBox.height
        let area = boundingBox.width * boundingBox.height
        
        // Calibration: larger objects appear larger in frame when closer
        // These thresholds are calibrated for typical indoor distances
        if height > 0.7 || area > 0.5 {
            return "half a meter away"
        } else if height > 0.5 || area > 0.3 {
            return "1 meter away"
        } else if height > 0.35 || area > 0.15 {
            return "2 meters away"
        } else if height > 0.25 || area > 0.08 {
            return "2 and a half meters away"
        } else {
            return "3 meters away"
        }
    }
    
    
    private func announceMeshObstacleIfNeeded() {
        guard let nearestObstacle = arCamera.obstacles3D.first(where: { $0.type == .unknown }) else {
            return
        }
        
        let label = "obstacle"
        let now = Date()
        if let lastTime = lastAnnouncementTimeByLabel[label],
           now.timeIntervalSince(lastTime) < objectAnnouncementCooldown {
            return
        }
        lastAnnouncementTimeByLabel[label] = now
        
        let distance = estimateDistanceFor3DObstacle(nearestObstacle)
        let phrase = "Obstacle ahead, \(distance)."
        DispatchQueue.main.async {
            self.speechService.speak(label: "Obstacle", phrase: phrase)
        }
    }

    private func estimateDistanceFor3DObstacle(_ obstacle: Obstacle3D) -> String {
        guard let userPosition = arCamera.userPosition else {
            return "nearby"
        }
            let distance = simd_length(obstacle.position - userPosition)
        if distance < 0.8 { return "very close" }
        if distance < 1.5 { return "1 meter away" }
        if distance < 2.5 { return "2 meters away" }
        return "more than 2 meters away"
    }

    // MARK: - Currency Handling
    
    /// Double-tap handler: enter/exit currency mode.
    private func handleCurrencyModeToggleGesture() {
        DispatchQueue.main.async {
            if self.isCurrencyModeActive {
                self.deactivateCurrencyMode(announce: true)
            } else {
                self.activateCurrencyMode()
            }
        }
    }

    private func activateCurrencyMode() {
        isCurrencyModeActive = true

        TorchService.shared.setTorch(enabled: true, level: 1.0)
        currencyRecognition.activate()

        detector.isPaused = true

        detectedCurrency = nil
        pendingCurrency = nil
        lastCurrencyPromptTime = .distantPast

        speechService.speak(label: "Mode", phrase: "Currency mode activated. Point camera at currency note.")
    }

    private func deactivateCurrencyMode(announce: Bool) {
        isCurrencyModeActive = false
        TorchService.shared.setTorch(enabled: false)
        currencyRecognition.deactivate()
        detector.isPaused = false
        detectedCurrency = nil
        pendingCurrency = nil
        lastCurrencyPromptTime = .distantPast
        if announce {
            speechService.speak(label: "Mode", phrase: "Currency mode deactivated")
        }
    }
    
    private func handleCurrencyDetection(_ currency: DetectedCurrency?) {
        // Only handle currency detection when in currency mode
        guard isCurrencyModeActive else { return }
        
        // If the model stops seeing currency, clear the pending state so a new note can be detected.
        // This prevents the "detects only once" behavior.
        if currency == nil {
            if pendingCurrency != nil {
                DispatchQueue.main.async {
                    self.pendingCurrency = nil
                    self.detectedCurrency = nil
                }
            }
            return
        }

        guard let currency = currency else { return }

        // If a different denomination appears, allow prompting again.
        if let pending = pendingCurrency, pending != currency {
            DispatchQueue.main.async {
                self.pendingCurrency = nil
                self.detectedCurrency = nil
                self.lastCurrencyPromptTime = .distantPast
            }
        }

        // If we already have a pending currency (same denomination) don't spam prompts.
        guard pendingCurrency == nil else { return }
        
        let now = Date()
        
        // Cooldown to avoid repeating announcement too frequently
        guard now.timeIntervalSince(lastCurrencyPromptTime) >= currencyPromptCooldown else {
            return
        }
        
        DispatchQueue.main.async {
            self.detectedCurrency = currency
            self.pendingCurrency = currency
            self.lastCurrencyPromptTime = now
            
            // Speak currency value (no deposit / wallet mutation)
            self.speechService.speak(label: "CurrencyPrompt", phrase: "Detected \(currency.name).")
        }
    }

    private func handleCurrencyConfirmationTap() {
        // Deposits are intentionally disabled. Single-tap confirmation does nothing in currency mode.
        // (Double-tap still exits currency mode.)
        return
    }

    // MARK: - Gesture routing

    private func handlePrimaryConfirmationTap() {
        if isCurrencyModeActive {
            handleCurrencyConfirmationTap()
            return
        }
        // Normal mode: no-op for now
    }
}

struct DetectionBox: View {
    let detection: Detection
    var color: Color = .green
    
    var body: some View {
        GeometryReader { geo in
            let box = detection.boundingBox
            let rect = CGRect(
                x: box.minX * geo.size.width,
                y: (1 - box.maxY) * geo.size.height,
                width: box.width * geo.size.width,
                height: box.height * geo.size.height
            )
            
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .path(in: rect)
                    .stroke(color, lineWidth: 2)
                Text("\(detection.label) \(Int(detection.confidence * 100))%")
                    .font(.caption2)
                    .padding(4)
                    .background(Color.black.opacity(0.6))
                    .foregroundColor(.white)
                    .offset(x: rect.minX, y: rect.minY - 18)
            }
        }
        .allowsHitTesting(false)
    }
}
