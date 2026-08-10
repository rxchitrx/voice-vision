import CoreGraphics
import Combine
import Foundation

enum PerceptionSource: Hashable {
    case yolo
    case wall
    case doorway
    case meshObstacle
}

enum HorizontalPosition: String, Hashable {
    case left
    case ahead
    case right

    init(centerX: CGFloat) {
        if centerX < 0.33 { self = .left }
        else if centerX > 0.67 { self = .right }
        else { self = .ahead }
    }

    var spokenPhrase: String {
        switch self {
        case .left: return "on your left"
        case .ahead: return "directly ahead"
        case .right: return "on your right"
        }
    }
}

enum QualitativeDistance: Int, Comparable {
    case veryClose = 0
    case close = 1
    case nearby = 2
    case fartherAhead = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var spokenPhrase: String {
        switch self {
        case .veryClose: return "very close"
        case .close: return "close"
        case .nearby: return "nearby"
        case .fartherAhead: return "farther ahead"
        }
    }
}

enum DistanceEstimate: Equatable {
    case measured(meters: Float)
    case qualitative(QualitativeDistance)
    case unknown

    var urgencyBand: QualitativeDistance? {
        switch self {
        case .measured(let meters):
            if meters < 0.75 { return .veryClose }
            if meters < 1.5 { return .close }
            if meters < 2.5 { return .nearby }
            return .fartherAhead
        case .qualitative(let distance): return distance
        case .unknown: return nil
        }
    }

    var spokenPhrase: String? {
        switch self {
        case .measured(let meters):
            if meters < 0.75 { return "very close" }
            if meters < 1.5 { return "about one meter away" }
            if meters < 2.5 { return "about two meters away" }
            return "farther ahead"
        case .qualitative(let distance): return distance.spokenPhrase
        case .unknown: return nil
        }
    }
}

struct PerceptionCandidate {
    let identity: String
    let label: String
    let source: PerceptionSource
    let confidence: Float
    let horizontalPosition: HorizontalPosition
    let distance: DistanceEstimate
    let boundingBox: CGRect?
    let timestamp: Date
}

@MainActor
final class PerceptionAnnouncementCoordinator: ObservableObject {
    private struct Presence {
        var consecutiveSnapshots = 0
        var lastSeen = Date.distantPast
        var lastAnnounced: Date?
        var lastAnnouncedDistance: QualitativeDistance?
        var returnedAfterAbsence = false
    }

    private var pending: [String: PerceptionCandidate] = [:]
    private var presence: [String: Presence] = [:]
    private var aggregationTask: Task<Void, Never>?
    private let aggregationDelay: UInt64 = 350_000_000
    var onAnnouncement: ((SpeechRequest) -> Void)?
    var isEnabled = true

    func submitSnapshot(_ candidates: [PerceptionCandidate], source: PerceptionSource) {
        guard isEnabled else { return }
        let now = Date()
        let identities = Set(candidates.map(\.identity))

        for key in presence.keys where key.hasPrefix("\(source)-") && !identities.contains(key) {
            presence[key]?.consecutiveSnapshots = 0
        }

        for candidate in candidates {
            var state = presence[candidate.identity] ?? Presence()
            if now.timeIntervalSince(state.lastSeen) >= 1.0 {
                state.consecutiveSnapshots = 0
                state.returnedAfterAbsence = state.lastAnnounced != nil
            }
            state.consecutiveSnapshots += 1
            state.lastSeen = now
            presence[candidate.identity] = state
            pending[candidate.identity] = candidate
        }

        scheduleSelectionIfNeeded()
    }

    func clear() {
        aggregationTask?.cancel()
        aggregationTask = nil
        pending.removeAll()
        presence.removeAll()
    }

    private func scheduleSelectionIfNeeded() {
        guard aggregationTask == nil else { return }
        aggregationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.aggregationDelay ?? 350_000_000)
            guard !Task.isCancelled else { return }
            self?.selectAndAnnounce()
        }
    }

    private func selectAndAnnounce() {
        aggregationTask = nil
        let now = Date()
        let fresh = pending.values.filter { now.timeIntervalSince($0.timestamp) < 0.8 }
        pending.removeAll()

        let eligible = fresh.filter { candidate in
            let immediateDepthHazard = candidate.source == .meshObstacle &&
                candidate.horizontalPosition == .ahead &&
                candidate.distance.urgencyBand == .veryClose
            if candidate.source == .yolo && !immediateDepthHazard {
                return (presence[candidate.identity]?.consecutiveSnapshots ?? 0) >= 2
            }
            return true
        }.filter(shouldReannounce)

        guard let winner = eligible.max(by: { rank($0) < rank($1) }) else { return }
        let critical = isImmediateHazard(winner)
        let phrase = spokenPhrase(for: winner, critical: critical)
        var state = presence[winner.identity] ?? Presence()
        state.lastAnnounced = now
        state.lastAnnouncedDistance = winner.distance.urgencyBand
        state.returnedAfterAbsence = false
        presence[winner.identity] = state

        onAnnouncement?(SpeechRequest(
            label: winner.identity,
            phrase: phrase,
            priority: critical ? .safetyCritical : .ambient,
            category: critical ? .safetyWarning : .ambientObject
        ))
    }

    private func shouldReannounce(_ candidate: PerceptionCandidate) -> Bool {
        guard let state = presence[candidate.identity], let last = state.lastAnnounced else { return true }
        if state.returnedAfterAbsence { return true }
        if Date().timeIntervalSince(last) >= 6.0 { return rank(candidate).0 >= 400 }
        if let old = state.lastAnnouncedDistance, let new = candidate.distance.urgencyBand, new < old { return true }
        return false
    }

    private func isImmediateHazard(_ candidate: PerceptionCandidate) -> Bool {
        guard candidate.source == .meshObstacle, candidate.horizontalPosition == .ahead,
              case .measured(let meters) = candidate.distance else { return false }
        return meters <= 1.2
    }

    private func rank(_ candidate: PerceptionCandidate) -> (Int, Float, CGFloat) {
        let label = candidate.label.lowercased()
        let close = (candidate.distance.urgencyBand?.rawValue ?? 99) <= QualitativeDistance.close.rawValue
        let ahead = candidate.horizontalPosition == .ahead
        let tier: Int
        if isImmediateHazard(candidate) { tier = 600 }
        else if ahead && close && (["person", "car", "motorcycle", "bus", "train", "truck", "boat"].contains(label)) { tier = 500 }
        else if ahead && close && (["chair", "couch", "bed", "dining table", "refrigerator"].contains(label)) { tier = 400 }
        else if candidate.source == .doorway { tier = 300 }
        else if !ahead { tier = 200 }
        else { tier = 100 }
        return (tier, candidate.confidence, candidate.boundingBox?.width ?? 0)
    }

    private func spokenPhrase(for candidate: PerceptionCandidate, critical: Bool) -> String {
        let label = candidate.label.prefix(1).uppercased() + candidate.label.dropFirst()
        var phrase = "\(label) \(candidate.horizontalPosition.spokenPhrase)"
        if let distance = candidate.distance.spokenPhrase { phrase += ", \(distance)" }
        phrase += "."
        if critical { phrase += " Be careful." }
        return phrase
    }
}
