import ARKit
import Combine
import simd


final class ARCameraService: NSObject, ObservableObject {
    @Published var latestBuffer: CVPixelBuffer?
    @Published var wallDetections: [Detection] = []
    @Published var doorwayDetections: [Detection] = []
    @Published var windowDetections: [Detection] = []
    @Published var userPosition: simd_float3?
    @Published var obstacles3D: [Obstacle3D] = []
    @Published private(set) var isCameraReady = false
    @Published private(set) var isCameraStable = false
    
    private let arSession = ARSession()
    private var trackedPlanes: [UUID: ARPlaneAnchor] = [:]
    private var lastPlaneUpdate: [UUID: Date] = [:]
    private let queue = DispatchQueue(label: "ARCameraQueue")
    private let planeTimeout: TimeInterval = 2.0 // Remove planes not updated in 2 seconds
    private var trackedObjects: [UUID: (position: simd_float3, size: simd_float3, type: Obstacle3D.ObstacleType, label: String)] = [:]
    private let meshObstacleDistanceThreshold: Float = 1.2
    private var lastObstacleUpdate = Date.distantPast
    private var lastPlaneDetectionUpdate = Date.distantPast
    private var cameraMotionSamples: [(date: Date, transform: simd_float4x4)] = []
    private let meshSamplePoints: [CGPoint] = [
        CGPoint(x: 0.35, y: 0.35), CGPoint(x: 0.5, y: 0.35), CGPoint(x: 0.65, y: 0.35),
        CGPoint(x: 0.35, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.65, y: 0.5),
        CGPoint(x: 0.35, y: 0.65), CGPoint(x: 0.5, y: 0.65), CGPoint(x: 0.65, y: 0.65)
    ]
    
    // Doorway detection parameters
    private let minDoorwayWidth: Float = 0.6  // 60cm minimum
    private let maxDoorwayWidth: Float = 1.5  // 150cm maximum
    private let minDoorwayHeight: Float = 1.7 // 170cm minimum
    
    // Window detection parameters
    private let minWindowWidth: Float = 0.4   // 40cm minimum
    private let maxWindowWidth: Float = 2.0   // 200cm maximum
    private let minWindowHeight: Float = 0.5  // 50cm minimum
    private let maxWindowHeight: Float = 1.5  // 150cm maximum
    private let minWindowElevation: Float = 0.5 // Windows should be elevated (not at floor level)
    
    override init() {
        super.init()
        arSession.delegate = self
        arSession.delegateQueue = queue
    }
    
    func start() {
        print("DEBUG: ARCameraService.start() called")
        
        guard ARWorldTrackingConfiguration.isSupported else {
            print("ERROR: ARKit not supported on this device")
            DispatchQueue.main.async {
                // Could show an error message to user here
            }
            return
        }
        
        print("DEBUG: ARKit is supported, setting up configuration...")
        
        // Run AR session setup on main thread (required for ARKit)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                print("ERROR: ARCameraService deallocated before start completed")
                return
            }
            
            print("DEBUG: Creating ARWorldTrackingConfiguration...")
            let configuration = ARWorldTrackingConfiguration()
            configuration.planeDetection = [.vertical] // Detect walls (vertical planes)
            configuration.environmentTexturing = .none
            
            // Enable LiDAR depth sensing if available (iPhone 12 Pro and later)
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
                configuration.sceneReconstruction = .meshWithClassification
                print("DEBUG: LiDAR scene reconstruction enabled")
            } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                configuration.sceneReconstruction = .mesh
                print("DEBUG: LiDAR mesh reconstruction enabled")
            }
            
            // Enable LiDAR depth frame semantics for accurate depth data
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
                print("DEBUG: LiDAR scene depth enabled")
            }
            
            // High quality video format for better YOLO detection
            if let videoFormat = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: { format in
                format.imageResolution.width >= 1920 && format.imageResolution.height >= 1440
            }) {
                configuration.videoFormat = videoFormat
                print("DEBUG: Using high quality video format: \(videoFormat.imageResolution)")
            }
            
            // Run configuration
            print("DEBUG: Running AR session...")
            self.arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            print("DEBUG: AR session started successfully")
        }
    }
    
    func stop() {
        arSession.pause()
        clearTrackingState()
    }
    
    /// Clear all tracking state (used during relocalization)
    func clearTrackingState() {
        queue.async { [weak self] in
            self?.trackedPlanes.removeAll()
            self?.lastPlaneUpdate.removeAll()
            self?.cameraMotionSamples.removeAll()
            self?.lastObstacleUpdate = .distantPast
            self?.lastPlaneDetectionUpdate = .distantPast
        }
        DispatchQueue.main.async {
            self.wallDetections = []
            self.doorwayDetections = []
            self.windowDetections = []
            self.latestBuffer = nil
            self.obstacles3D = []
            self.isCameraReady = false
            self.isCameraStable = false
        }
    }

    /// Resolves depth for a group of Vision detections without retaining an ARFrame
    /// beyond this queue operation. Visual fallback remains explicitly qualitative.
    func perceptionCandidates(for detections: [Detection], source: PerceptionSource,
                              completion: @escaping ([PerceptionCandidate]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let frame = self.arSession.currentFrame
            let now = Date()
            let candidates = detections.map { detection in
                let position = HorizontalPosition(centerX: detection.boundingBox.midX)
                let distance = frame.flatMap { self.measuredDistance(for: detection.boundingBox, frame: $0) }
                    .map(DistanceEstimate.measured) ?? self.qualitativeDistance(for: detection.boundingBox)
                let identity = "\(source)-\(detection.label.lowercased())-\(position.rawValue)"
                return PerceptionCandidate(
                    identity: identity,
                    label: detection.label.lowercased(),
                    source: source,
                    confidence: detection.confidence,
                    horizontalPosition: position,
                    distance: distance,
                    boundingBox: detection.boundingBox,
                    timestamp: now
                )
            }
            DispatchQueue.main.async { completion(candidates) }
        }
    }
    
    // Get the AR session for rendering
    func getSession() -> ARSession {
        return arSession
    }
    
    
    // MARK: - 3D Obstacle Tracking
    
    /// Get current user position in world coordinates
    func getCurrentUserPosition() -> simd_float3? {
        return userPosition
    }
    
    /// Get all 3D obstacles for navigation
    func getObstacles3D() -> [Obstacle3D] {
        return obstacles3D
    }
    
    /// Update obstacles from YOLO detections and ARKit planes
    func updateObstacles3D(yoloDetections: [Detection], frame: ARFrame) {
        // NOTE: Avoid writing debug logs to absolute filesystem paths.
        // On iOS devices this can cause sandbox violations and the process may be killed.
        var obstacles: [Obstacle3D] = []
        let cameraTransform = frame.camera.transform
        let cameraPosition = simd_float3(cameraTransform.columns.3.x,
                                        cameraTransform.columns.3.y,
                                        cameraTransform.columns.3.z)
        
        // Add walls from ARKit planes
        for (_, plane) in trackedPlanes {
            let planePos = simd_float3(plane.transform.columns.3.x,
                                     plane.transform.columns.3.y,
                                     plane.transform.columns.3.z)
            let extent = plane.planeExtent
            
            // Only add if plane is reasonably sized
            guard extent.width > 0.3 && extent.height > 0.3 else { continue }
            
            let obstacle = Obstacle3D(
                type: .wall,
                position: planePos,
                size: simd_float3(extent.width, extent.height, 0.1),
                boundingBox: nil,
                confidence: 0.9
            )
            obstacles.append(obstacle)
        }
        
        // Add doorways (use actual 3D positions from detection)
        // Note: Doorway positions are calculated in detectDoorways, but we need them here
        // For now, estimate from doorway detections
        for doorway in doorwayDetections {
            // Estimate distance from bounding box size
            let area = doorway.boundingBox.width * doorway.boundingBox.height
            let distance: Float
            if area > 0.1 {
                distance = 1.5  // Close doorway
            } else if area > 0.05 {
                distance = 2.5  // Medium distance
            } else {
                distance = 3.5  // Far doorway
            }
            let direction = simd_float3(0, 0, -1) // Forward
            let pos = cameraPosition + direction * distance
            
            let obstacle = Obstacle3D(
                type: .doorway,
                position: pos,
                size: simd_float3(0.8, 2.0, 0.1),
                boundingBox: doorway.boundingBox,
                confidence: doorway.confidence
            )
            obstacles.append(obstacle)
        }
        
        // Add YOLO objects (furniture, etc.)
        for detection in yoloDetections {
            // Only process speakable objects that are obstacles
            let label = detection.label.lowercased()
            guard speakableLabels.contains(label) || label == "wall" || label == "doorway" else { continue }
            
            // Use LiDAR depth if available, otherwise estimate from bounding box
            let distance: Float = estimateDistanceFromBoundingBox(detection.boundingBox, frame: frame)
            let screenCenter = CGPoint(x: detection.boundingBox.midX, y: detection.boundingBox.midY)
            let direction = screenToWorldDirection(screenCenter, frame: frame)
            let pos = cameraPosition + direction * distance
            
            let obstacleType: Obstacle3D.ObstacleType
            switch label {
            case "person":
                obstacleType = .person
            case "car", "motorcycle", "bus", "train", "truck", "boat":
                obstacleType = .vehicle
            case "wall":
                obstacleType = .wall
            case "doorway":
                obstacleType = .doorway
            default:
                obstacleType = .furniture
            }
            
            let size = estimateObjectSize(type: obstacleType, distance: distance)
            
            let obstacle = Obstacle3D(
                type: obstacleType,
                position: pos,
                size: size,
                boundingBox: detection.boundingBox,
                confidence: detection.confidence
            )
            obstacles.append(obstacle)
        }
        
        // Add generic mesh-based obstacles (LiDAR)
        if let meshObstacle = detectNearestMeshObstacle(frame: frame, cameraTransform: cameraTransform, cameraPosition: cameraPosition) {
            obstacles.append(meshObstacle)
        }
        
        DispatchQueue.main.async {
            self.obstacles3D = obstacles
            
            #if DEBUG
            if obstacles.count > 0 {
                print("DEBUG: Updated \(obstacles.count) obstacles for navigation")
            }
            #endif
        }
    }
    
    // Helper to check if label is speakable (for obstacle filtering)
    private let speakableLabels: Set<String> = [
        "person", "chair", "couch", "bed", "dining table", "refrigerator",
        "wall", "doorway", "car", "motorcycle", "bus", "train", "truck", "boat"
    ]
    
    /// Extract LiDAR depth at screen point from ARFrame
    private func getDepthAt(screenPoint: CGPoint, frame: ARFrame) -> Float? {
        // Try smoothed scene depth first (more accurate)
        if let smoothedDepth = frame.smoothedSceneDepth {
            return getDepthFromMap(smoothedDepth.depthMap, at: screenPoint, frame: frame)
        }
        
        // Fall back to regular scene depth
        if let sceneDepth = frame.sceneDepth {
            return getDepthFromMap(sceneDepth.depthMap, at: screenPoint, frame: frame)
        }
        
        return nil
    }
    
    /// Extract depth value from CVPixelBuffer depth map at screen coordinates
    private func getDepthFromMap(_ depthMap: CVPixelBuffer, at screenPoint: CGPoint, frame: ARFrame) -> Float? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        // Get actual resolutions
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        
        // Account for potential orientation differences between camera and depth map
        // ARKit depth maps are typically in landscape orientation
        // Normalized screen coordinates are in portrait (0,0 = top-left)
        // We need to account for the actual orientation of the depth map
        
        // For now, assume depth map matches camera orientation
        // Scale normalized screen coordinates to depth map resolution
        // Note: screenPoint is in normalized coordinates (0-1) where (0,0) is top-left
        let normalizedX = screenPoint.x
        let normalizedY = screenPoint.y
        
        // Convert to depth map pixel coordinates
        // Account for potential aspect ratio differences
        let x = Int(normalizedX * CGFloat(depthWidth))
        let y = Int(normalizedY * CGFloat(depthHeight))
        
        // Clamp to valid range
        guard x >= 0 && x < depthWidth && y >= 0 && y < depthHeight else {
            return nil
        }
        
        // Get base address
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let buffer = baseAddress.assumingMemoryBound(to: Float32.self)
        
        // Read depth value (in meters)
        let depth = buffer[y * (bytesPerRow / MemoryLayout<Float32>.size) + x]
        
        // Filter out invalid depth values (0 or infinity)
        guard depth.isFinite && depth > 0 && depth < 10.0 else {
            return nil
        }
        
        return depth
    }
    
    /// Estimate distance from bounding box, using LiDAR depth if available
    private func estimateDistanceFromBoundingBox(_ box: CGRect, frame: ARFrame?) -> Float {
        // Try to use LiDAR depth sampling inside the box
        if let frame = frame {
            let samplePoints = depthSamplePoints(for: box, gridSize: 3)
            var depths: [Float] = []
            for point in samplePoints {
                if let lidarDepth = getDepthAt(screenPoint: point, frame: frame) {
                    depths.append(lidarDepth)
                }
            }
            if depths.count >= 4 {
                return depths.sorted()[depths.count / 2]
            }
        }
        
        // Fall back to bounding box estimation
        let area = box.width * box.height
        if area > 0.5 {
            return 0.5  // Very close
        } else if area > 0.3 {
            return 1.0
        } else if area > 0.15 {
            return 2.0
        } else if area > 0.08 {
            return 3.0
        } else {
            return 5.0  // Far
        }
    }
    
    /// Convert screen point to world direction vector
    private func screenToWorldDirection(_ screenPoint: CGPoint, frame: ARFrame) -> simd_float3 {
        // Convert normalized screen coordinates to camera ray direction
        let x = (Float(screenPoint.x) * 2.0 - 1.0)
        let y = (1.0 - Float(screenPoint.y) * 2.0)
        
        let camera = frame.camera
        let intrinsics = camera.intrinsics
        
        // Unproject to get direction in camera space
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]
        
        let direction = simd_float3((x - cx) / fx, (y - cy) / fy, -1.0)
        let normalized = simd_normalize(direction)
        
        // Transform to world space
        let cameraTransform = frame.camera.transform
        let worldDirection = simd_float3(
            cameraTransform.columns.0.x * normalized.x + cameraTransform.columns.1.x * normalized.y + cameraTransform.columns.2.x * normalized.z,
            cameraTransform.columns.0.y * normalized.x + cameraTransform.columns.1.y * normalized.y + cameraTransform.columns.2.y * normalized.z,
            cameraTransform.columns.0.z * normalized.x + cameraTransform.columns.1.z * normalized.y + cameraTransform.columns.2.z * normalized.z
        )
        
        return simd_normalize(worldDirection)
    }

    private func detectNearestMeshObstacle(frame: ARFrame,
                                          cameraTransform: simd_float4x4,
                                          cameraPosition: simd_float3) -> Obstacle3D? {
        let samplePoints = meshSamplePoints
        guard !samplePoints.isEmpty else { return nil }

        let depths = samplePoints.compactMap { getDepthAt(screenPoint: $0, frame: frame) }.sorted()
        guard depths.count >= 4 else { return nil }
        let closestDistance = depths[depths.count / 2]
        guard closestDistance <= meshObstacleDistanceThreshold else { return nil }

        let worldDirection = screenToWorldDirection(CGPoint(x: 0.5, y: 0.5), frame: frame)
        let position = cameraPosition + worldDirection * closestDistance

        return Obstacle3D(
            type: .unknown,
            position: position,
            size: simd_float3(0.4, 0.6, 0.4),
            boundingBox: nil,
            confidence: 0.7
        )
    }
    
    /// Estimate object size based on type and distance
    private func estimateObjectSize(type: Obstacle3D.ObstacleType, distance: Float) -> simd_float3 {
        switch type {
        case .person:
            return simd_float3(0.5, 1.7, 0.3) // Average person
        case .furniture:
            return simd_float3(0.8, 0.8, 0.8) // Typical furniture
        case .vehicle:
            return simd_float3(2.0, 1.5, 4.0) // Car size
        case .wall:
            return simd_float3(0.1, 2.5, 2.0) // Wall thickness
        case .doorway:
            return simd_float3(0.8, 2.0, 0.1)
        case .window:
            return simd_float3(1.0, 1.0, 0.1)
        case .unknown:
            return simd_float3(0.5, 0.5, 0.5)
        }
    }

    private func depthSamplePoints(for box: CGRect, gridSize: Int) -> [CGPoint] {
        guard gridSize > 1 else {
            return [CGPoint(x: box.midX, y: box.midY)]
        }
        let insetBox = box.insetBy(dx: box.width * 0.2, dy: box.height * 0.2)
        let stepX = insetBox.width / CGFloat(gridSize - 1)
        let stepY = insetBox.height / CGFloat(gridSize - 1)
        var points: [CGPoint] = []
        for row in 0..<gridSize {
            for col in 0..<gridSize {
                let visionX = insetBox.minX + CGFloat(col) * stepX
                let visionY = insetBox.minY + CGFloat(row) * stepY
                // Vision is lower-left in the portrait-oriented image. AR depth is
                // top-left in the landscape camera image used with orientation .right.
                points.append(CGPoint(x: 1.0 - visionY, y: 1.0 - visionX))
            }
        }
        return points
    }

    private func measuredDistance(for box: CGRect, frame: ARFrame) -> Float? {
        let depths = depthSamplePoints(for: box, gridSize: 3)
            .compactMap { getDepthAt(screenPoint: $0, frame: frame) }
            .filter { $0.isFinite && $0 > 0 && $0 < 10 }
            .sorted()
        guard depths.count >= 4 else { return nil }
        return depths[depths.count / 2]
    }

    private func qualitativeDistance(for box: CGRect) -> DistanceEstimate {
        let area = box.width * box.height
        if box.height > 0.7 || area > 0.5 { return .qualitative(.veryClose) }
        if box.height > 0.5 || area > 0.3 { return .qualitative(.close) }
        if box.height > 0.3 || area > 0.12 { return .qualitative(.nearby) }
        return .qualitative(.fartherAhead)
    }

    
    // Convert AR plane anchor to Detection format with screen coordinates
    private func planeToDetection(_ anchor: ARPlaneAnchor, 
                                   cameraTransform: simd_float4x4,
                                   cameraPosition: simd_float3,
                                   projectionMatrix: simd_float4x4) -> Detection? {
        // Get plane center in world space (transform anchor center to world space)
        let anchorTransform = anchor.transform
        let planeWorldPos = simd_float3(anchorTransform.columns.3.x,
                                       anchorTransform.columns.3.y,
                                       anchorTransform.columns.3.z)
        
        // Transform to camera space
        let planeInCameraSpace = simd_mul(cameraTransform.inverse, simd_float4(planeWorldPos.x, planeWorldPos.y, planeWorldPos.z, 1.0))
        
        // Check if plane is in front of camera (negative Z in camera space means in front)
        guard planeInCameraSpace.z < -0.5 else { return nil }
        
        // Distance to plane
        let distance = simd_length(planeWorldPos - cameraPosition)
        guard distance > 0.5 && distance < 6.0 else { return nil }
        
        // Project to screen space using camera projection
        let projected = simd_mul(projectionMatrix, planeInCameraSpace)
        
        // Check if valid projection
        guard projected.w > 0.001 else { return nil }
        
        // Normalize to NDC (-1 to 1), then to screen space (0 to 1)
        let ndcX = projected.x / projected.w
        let ndcY = projected.y / projected.w
        
        // Convert to 0-1 range (flip Y for UIKit coordinates)
        let screenX = (ndcX + 1.0) / 2.0
        let screenY = (1.0 - ndcY) / 2.0
        
        // Only show if reasonably on screen
        guard screenX > -0.2 && screenX < 1.2 && 
              screenY > -0.2 && screenY < 1.2 else { return nil }
        
        let extent = anchor.planeExtent
        let widthScale = CGFloat(extent.width / Float(distance) * 0.4)
        let heightScale = CGFloat(extent.height / Float(distance) * 0.4)
        
        let width = min(0.5, max(0.1, widthScale))
        let height = min(0.6, max(0.15, heightScale))
        
        // Clamp to screen bounds
        let clampedX = CGFloat(max(0.0, min(1.0, screenX)))
        let clampedY = CGFloat(max(0.0, min(1.0, screenY)))
        
        let boundingBox = CGRect(
            x: max(0, min(1 - width, clampedX - width / 2)),
            y: max(0, min(1 - height, clampedY - height / 2)),
            width: width,
            height: height
        )
        
        return Detection(
            label: "wall",
            confidence: 0.9,
            boundingBox: boundingBox
        )
    }

    // Clean up stale plane and mesh detections
    private func cleanupStalePlanes() {
        let now = Date()
        let staleIDs = lastPlaneUpdate.filter { now.timeIntervalSince($0.value) > planeTimeout }.map { $0.key }
        for id in staleIDs {
            trackedPlanes.removeValue(forKey: id)
            lastPlaneUpdate.removeValue(forKey: id)
        }
        
    }
    
    // Detect doorways by finding gaps between parallel vertical planes
    private func detectDoorways(cameraTransform: simd_float4x4, cameraPosition: simd_float3, projectionMatrix: simd_float4x4) -> [Detection] {
        var doorways: [Detection] = []
        
        // Get all vertical planes
        let planes = Array(trackedPlanes.values)
        
        // Check pairs of planes for doorway-like gaps
        for i in 0..<planes.count {
            for j in (i+1)..<planes.count {
                let plane1 = planes[i]
                let plane2 = planes[j]
                
                // Get plane positions and normals
                let pos1 = simd_float3(plane1.transform.columns.3.x,
                                      plane1.transform.columns.3.y,
                                      plane1.transform.columns.3.z)
                let pos2 = simd_float3(plane2.transform.columns.3.x,
                                      plane2.transform.columns.3.y,
                                      plane2.transform.columns.3.z)
                
                let normal1 = simd_float3(plane1.transform.columns.2.x,
                                         plane1.transform.columns.2.y,
                                         plane1.transform.columns.2.z)
                let normal2 = simd_float3(plane2.transform.columns.2.x,
                                         plane2.transform.columns.2.y,
                                         plane2.transform.columns.2.z)
                
                // Check if planes are roughly parallel (normals similar or opposite)
                let normalDot = abs(simd_dot(simd_normalize(normal1), simd_normalize(normal2)))
                guard normalDot > 0.85 else { continue } // ~30° tolerance
                
                // Calculate gap between planes
                let gapCenter = (pos1 + pos2) / 2.0
                let gapWidth = simd_length(pos1 - pos2)
                
                // Check if gap width matches doorway size
                guard gapWidth >= minDoorwayWidth && gapWidth <= maxDoorwayWidth else { continue }
                
                // Check if gap is at reasonable distance
                let distanceToGap = simd_length(gapCenter - cameraPosition)
                guard distanceToGap > 0.5 && distanceToGap < 5.0 else { continue }
                
                let height1 = plane1.planeExtent.height
                let height2 = plane2.planeExtent.height
                guard height1 >= minDoorwayHeight && height2 >= minDoorwayHeight else { continue }
                
                // Check vertical position - doorways should be at ground level
                let groundLevel = cameraPosition.y - 1.5 // Assume camera ~1.5m above ground
                let gapElevation = gapCenter.y - groundLevel
                guard abs(gapElevation) < 0.3 else { continue } // Must be near floor level
                
                // Check if gap is in front of camera
                let toGap = gapCenter - cameraPosition
                let cameraForward = simd_float3(-cameraTransform.columns.2.x,
                                               -cameraTransform.columns.2.y,
                                               -cameraTransform.columns.2.z)
                let dotProduct = simd_dot(simd_normalize(toGap), cameraForward)
                guard dotProduct > 0.6 else { continue }
                
                // Project doorway to screen space
                if let doorwayDetection = projectOpening(gapCenter: gapCenter, 
                                                         width: gapWidth,
                                                         height: min(height1, height2),
                                                         distance: distanceToGap,
                                                         cameraTransform: cameraTransform,
                                                         projectionMatrix: projectionMatrix,
                                                         label: "doorway") {
                    doorways.append(doorwayDetection)
                }
            }
        }
        
        return doorways
    }
    
    // Detect windows by finding elevated gaps between parallel vertical planes
    private func detectWindows(cameraTransform: simd_float4x4, cameraPosition: simd_float3, projectionMatrix: simd_float4x4) -> [Detection] {
        var windows: [Detection] = []
        
        let planes = Array(trackedPlanes.values)
        
        // Check pairs of planes for window-like gaps
        for i in 0..<planes.count {
            for j in (i+1)..<planes.count {
                let plane1 = planes[i]
                let plane2 = planes[j]
                
                // Get plane positions and normals
                let pos1 = simd_float3(plane1.transform.columns.3.x,
                                      plane1.transform.columns.3.y,
                                      plane1.transform.columns.3.z)
                let pos2 = simd_float3(plane2.transform.columns.3.x,
                                      plane2.transform.columns.3.y,
                                      plane2.transform.columns.3.z)
                
                let normal1 = simd_float3(plane1.transform.columns.2.x,
                                         plane1.transform.columns.2.y,
                                         plane1.transform.columns.2.z)
                let normal2 = simd_float3(plane2.transform.columns.2.x,
                                         plane2.transform.columns.2.y,
                                         plane2.transform.columns.2.z)
                
                // Check if planes are roughly parallel
                let normalDot = abs(simd_dot(simd_normalize(normal1), simd_normalize(normal2)))
                guard normalDot > 0.85 else { continue }
                
                // Calculate gap between planes
                let gapCenter = (pos1 + pos2) / 2.0
                let gapWidth = simd_length(pos1 - pos2)
                
                // Check if gap width matches window size
                guard gapWidth >= minWindowWidth && gapWidth <= maxWindowWidth else { continue }
                
                // Check distance
                let distanceToGap = simd_length(gapCenter - cameraPosition)
                guard distanceToGap > 0.5 && distanceToGap < 5.0 else { continue }
                
                // Check height range (windows are typically smaller than doorways)
                let height1 = plane1.planeExtent.height
                let height2 = plane2.planeExtent.height
                let avgHeight = (height1 + height2) / 2.0
                guard avgHeight >= minWindowHeight && avgHeight <= maxWindowHeight else { continue }
                
                // Check elevation - windows should be above ground level
                let groundLevel = cameraPosition.y - 1.5
                let gapElevation = gapCenter.y - groundLevel
                guard gapElevation > minWindowElevation else { continue } // Must be elevated
                
                // Check if gap is in front of camera
                let toGap = gapCenter - cameraPosition
                let cameraForward = simd_float3(-cameraTransform.columns.2.x,
                                               -cameraTransform.columns.2.y,
                                               -cameraTransform.columns.2.z)
                let dotProduct = simd_dot(simd_normalize(toGap), cameraForward)
                guard dotProduct > 0.6 else { continue }
                
                // Project window to screen space
                if let windowDetection = projectOpening(gapCenter: gapCenter,
                                                        width: gapWidth,
                                                        height: min(height1, height2),
                                                        distance: distanceToGap,
                                                        cameraTransform: cameraTransform,
                                                        projectionMatrix: projectionMatrix,
                                                        label: "window") {
                    windows.append(windowDetection)
                }
            }
        }
        
        return windows
    }
    
    // Project opening (doorway or window) gap to screen coordinates
    private func projectOpening(gapCenter: simd_float3, width: Float, height: Float, distance: Float, 
                                cameraTransform: simd_float4x4, projectionMatrix: simd_float4x4, label: String) -> Detection? {
        // Transform to camera space
        let gapInCameraSpace = simd_mul(cameraTransform.inverse, simd_float4(gapCenter.x, gapCenter.y, gapCenter.z, 1.0))
        
        // Check if in front of camera
        guard gapInCameraSpace.z < -0.5 else { return nil }
        
        // Project to screen space
        let projected = simd_mul(projectionMatrix, gapInCameraSpace)
        
        guard projected.w > 0.001 else { return nil }
        
        // Convert to screen coordinates (0 to 1)
        let screenX = CGFloat((projected.x / projected.w + 1.0) / 2.0)
        let screenY = CGFloat((1.0 - (projected.y / projected.w)) / 2.0)
        
        // Only show if on screen
        guard screenX > -0.1 && screenX < 1.1 && screenY > -0.1 && screenY < 1.1 else { return nil }
        
        // Estimate bounding box size based on doorway dimensions and distance
        let boxWidth = CGFloat(width / distance * 0.6)
        let boxHeight = CGFloat(height / distance * 0.6)
        
        let finalWidth = min(0.4, max(0.08, boxWidth))
        let finalHeight = min(0.6, max(0.15, boxHeight))
        
        let clampedX = max(0.0, min(1.0, screenX))
        let clampedY = max(0.0, min(1.0, screenY))
        
        let boundingBox = CGRect(
            x: max(0, min(1 - finalWidth, clampedX - finalWidth / 2)),
            y: max(0, min(1 - finalHeight, clampedY - finalHeight / 2)),
            width: finalWidth,
            height: finalHeight
        )
        
        let confidence: Float = label == "doorway" ? 0.85 : 0.80
        
        return Detection(
            label: label,
            confidence: confidence,
            boundingBox: boundingBox
        )
    }
}

extension ARCameraService: ARSessionDelegate {
    func session(_ session: ARSession, didFailWithError error: Error) {
        print("ERROR: ARSession failed with error: \(error.localizedDescription)")
        if let arError = error as? ARError {
            print("ERROR: ARError code: \(arError.errorCode), description: \(arError.localizedDescription)")
            // Check error code using ARError.Code enum
            switch arError.errorCode {
            case ARError.Code.cameraUnauthorized.rawValue:
                print("ERROR: Camera permission denied")
            case ARError.Code.unsupportedConfiguration.rawValue:
                print("ERROR: AR configuration not supported")
            case ARError.Code.sensorUnavailable.rawValue:
                print("ERROR: AR sensor unavailable")
            default:
                print("ERROR: Other AR error (code: \(arError.errorCode))")
            }
        }
        
        NotificationCenter.default.post(name: NSNotification.Name("ARSessionError"), object: error)
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        print("WARNING: ARSession was interrupted")
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        print("INFO: ARSession interruption ended")
        // Optionally restart the session
        start()
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // CRITICAL: Extract all data from frame immediately to avoid retaining the frame object
        // The frame parameter must be released before async blocks to prevent memory issues
        
        // Extract pixel buffer for YOLO detection (CVPixelBuffer is retained separately)
        let pixelBuffer = frame.capturedImage
        updateCameraMotion(with: frame)
        DispatchQueue.main.async { [weak self] in
            self?.latestBuffer = pixelBuffer
            self?.isCameraReady = true
        }
        
        // Extract camera transform data (copy values, not reference)
        let cameraTransform = frame.camera.transform
        let cameraPosition = simd_float3(cameraTransform.columns.3.x,
                                        cameraTransform.columns.3.y,
                                        cameraTransform.columns.3.z)
        let cameraProjection = frame.camera.projectionMatrix
        let cameraIntrinsics = frame.camera.intrinsics
        
        DispatchQueue.main.async { [weak self] in
            self?.userPosition = cameraPosition
        }
        
        // Extract frame data needed for processing (copy all values)
        let frameData = (
            cameraTransform: cameraTransform,
            cameraPosition: cameraPosition,
            projectionMatrix: cameraProjection,
            intrinsics: cameraIntrinsics
        )

        if Date().timeIntervalSince(lastObstacleUpdate) >= 0.5 {
            lastObstacleUpdate = Date()
            updateMeshObstacle(using: frame, cameraTransform: cameraTransform, cameraPosition: cameraPosition)
        }

        guard Date().timeIntervalSince(lastPlaneDetectionUpdate) >= 0.3 else { return }
        lastPlaneDetectionUpdate = Date()
        
        // Process wall detections on background queue
        // Use extracted data instead of frame to avoid retention
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Clean up stale planes first
            self.cleanupStalePlanes()
            
            var newDetections: [Detection] = []
            
            // Limit to top 3 closest planes to reduce clutter
            let sortedPlanes = self.trackedPlanes.sorted { plane1, plane2 in
                let pos1 = simd_float3(plane1.value.transform.columns.3.x,
                                      plane1.value.transform.columns.3.y,
                                      plane1.value.transform.columns.3.z)
                let pos2 = simd_float3(plane2.value.transform.columns.3.x,
                                      plane2.value.transform.columns.3.y,
                                      plane2.value.transform.columns.3.z)
                let dist1 = simd_length(pos1 - frameData.cameraPosition)
                let dist2 = simd_length(pos2 - frameData.cameraPosition)
                return dist1 < dist2
            }
            
            // Process only the closest planes
            for (id, anchor) in sortedPlanes.prefix(3) {
                // Update timestamp for processed planes
                self.lastPlaneUpdate[id] = Date()
                
                let extent = anchor.planeExtent
                guard extent.width > 0.5 && extent.height > 0.5 else { continue }
                
                // Use extracted frame data instead of frame object
                if let detection = self.planeToDetection(anchor, 
                                                         cameraTransform: frameData.cameraTransform,
                                                         cameraPosition: frameData.cameraPosition,
                                                         projectionMatrix: frameData.projectionMatrix) {
                    newDetections.append(detection)
                }
            }
            
            // Detect doorways and windows from gaps between walls
            // Pass extracted data instead of frame
            let doorways = self.detectDoorways(cameraTransform: frameData.cameraTransform,
                                               cameraPosition: frameData.cameraPosition,
                                               projectionMatrix: frameData.projectionMatrix)
            let windows = self.detectWindows(cameraTransform: frameData.cameraTransform,
                                             cameraPosition: frameData.cameraPosition,
                                             projectionMatrix: frameData.projectionMatrix)
            
            DispatchQueue.main.async {
                self.wallDetections = newDetections
                self.doorwayDetections = doorways
                self.windowDetections = windows
            }
        }
        
        // Frame is now released - all data has been extracted
    }

    private func updateMeshObstacle(using frame: ARFrame,
                                    cameraTransform: simd_float4x4,
                                    cameraPosition: simd_float3) {
        let obstacle = detectNearestMeshObstacle(
            frame: frame,
            cameraTransform: cameraTransform,
            cameraPosition: cameraPosition
        )
        DispatchQueue.main.async { [weak self] in
            self?.obstacles3D = obstacle.map { [$0] } ?? []
        }
    }

    private func updateCameraMotion(with frame: ARFrame) {
        let now = Date()
        cameraMotionSamples.append((now, frame.camera.transform))
        cameraMotionSamples.removeAll { now.timeIntervalSince($0.date) > 0.5 }
        guard let first = cameraMotionSamples.first, let last = cameraMotionSamples.last,
              now.timeIntervalSince(first.date) >= 0.4 else {
            DispatchQueue.main.async { self.isCameraStable = false }
            return
        }
        let firstPosition = simd_float3(first.transform.columns.3.x, first.transform.columns.3.y, first.transform.columns.3.z)
        let lastPosition = simd_float3(last.transform.columns.3.x, last.transform.columns.3.y, last.transform.columns.3.z)
        let translation = simd_distance(firstPosition, lastPosition)
        let relative = simd_mul(first.transform.inverse, last.transform)
        let trace = relative.columns.0.x + relative.columns.1.y + relative.columns.2.z
        let rotation = acos(max(-1, min(1, (trace - 1) / 2)))
        let trackingNormal: Bool
        if case .normal = frame.camera.trackingState { trackingNormal = true } else { trackingNormal = false }
        let stable = trackingNormal && translation < 0.04 && rotation < (.pi * 4 / 180)
        DispatchQueue.main.async { self.isCameraStable = stable }
    }
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor, planeAnchor.alignment == .vertical {
                trackedPlanes[anchor.identifier] = planeAnchor
                lastPlaneUpdate[anchor.identifier] = Date()
            }
        }
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor, planeAnchor.alignment == .vertical {
                trackedPlanes[anchor.identifier] = planeAnchor
                lastPlaneUpdate[anchor.identifier] = Date()
            }
        }
    }
    
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            trackedPlanes.removeValue(forKey: anchor.identifier)
            lastPlaneUpdate.removeValue(forKey: anchor.identifier)
        }
    }
}
