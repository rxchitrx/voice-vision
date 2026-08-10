import AVFoundation
import Combine
import Foundation
import UIKit

enum SpeechPriority: Int, Comparable {
    case ambient = 0
    case status = 1
    case requested = 2
    case safetyCritical = 3
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum SpeechCategory: Hashable {
    case ambientObject, safetyWarning, modeStatus, ocrPrompt, textReading
    case miniCPMResult, paymentGuidance, error
}

struct SpeechRequest {
    let id: UUID
    let label: String
    let phrase: String
    let priority: SpeechPriority
    let category: SpeechCategory
    let createdAt: Date

    init(id: UUID = UUID(), label: String, phrase: String, priority: SpeechPriority,
         category: SpeechCategory, createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.phrase = phrase
        self.priority = priority
        self.category = category
        self.createdAt = createdAt
    }
}

@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    private var synthesizer = AVSpeechSynthesizer()
    private var currentRequest: SpeechRequest?
    private var queued: [SpeechRequest] = []
    private var utteranceRequests: [ObjectIdentifier: SpeechRequest] = [:]
    private var lastSpokenTime: [String: Date] = [:]
    private var deliveryTask: Task<Void, Never>?
    private var voiceOverCompletionTask: Task<Void, Never>?
    private var isInitialized = false
    private var isInterrupted = false
    private let cooldown: TimeInterval

    init(cooldown: TimeInterval = 3.0) {
        self.cooldown = cooldown
        super.init()
        synthesizer.delegate = self
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func initialize() {
        guard !isInitialized else { return }
        isInitialized = true
        configureAudioSession()
        observeSystemEvents()
    }

    func submit(_ request: SpeechRequest) {
        guard !request.phrase.isEmpty, !isInterrupted else {
            if request.priority >= .requested && !isStale(request) { enqueue(request) }
            return
        }
        if request.priority != .safetyCritical,
           Date().timeIntervalSince(lastSpokenTime[request.label.lowercased()] ?? .distantPast) < cooldown {
            return
        }

        guard let current = currentRequest else {
            begin(request)
            return
        }
        let perceptionCategories: Set<SpeechCategory> = [.ambientObject, .safetyWarning]
        if current.category == .textReading,
           perceptionCategories.contains(request.category) {
            return
        }
        if request.category == .ambientObject { return }
        if request.priority > current.priority {
            cancelCurrentForInterruption()
            begin(request)
        } else {
            enqueue(request)
        }
    }

    func speak(label: String, phrase: String) {
        let key = label.lowercased()
        let mapping: (SpeechPriority, SpeechCategory)
        if key == "textreading" { mapping = (.requested, .textReading) }
        else if key.contains("wallet") || key.contains("qr") { mapping = (.requested, .paymentGuidance) }
        else if key.contains("currency") { mapping = (.requested, .modeStatus) }
        else if key == "text" { mapping = (.status, .ocrPrompt) }
        else if key == "mode" || key == "test" { mapping = (.status, .modeStatus) }
        else if key.contains("error") { mapping = (.status, .error) }
        else { mapping = (.ambient, .ambientObject) }
        submit(SpeechRequest(label: label, phrase: phrase, priority: mapping.0, category: mapping.1))
    }

    func speakWithPriority(label: String, phrase: String, priority: Int) {
        let value = SpeechPriority(rawValue: max(0, min(3, priority))) ?? .ambient
        let category: SpeechCategory = label.lowercased().contains("minicpm") ? .miniCPMResult : .modeStatus
        submit(SpeechRequest(label: label, phrase: phrase, priority: value, category: category))
    }

    func readTextImmediately(label: String, phrase: String) {
        let perceptionCategories: Set<SpeechCategory> = [.ambientObject, .safetyWarning]
        deliveryTask?.cancel()
        deliveryTask = nil
        queued.removeAll { perceptionCategories.contains($0.category) }
        if let current = currentRequest, perceptionCategories.contains(current.category) {
            cancelCurrentForInterruption()
        }
        submit(SpeechRequest(label: label, phrase: phrase, priority: .requested, category: .textReading))
    }

    func stopAndClear() {
        deliveryTask?.cancel()
        voiceOverCompletionTask?.cancel()
        queued.removeAll()
        currentRequest = nil
        utteranceRequests.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        deactivateAudioSession()
        NotificationCenter.default.post(name: .speechTextReadingFinished, object: nil)
    }

    func discardAmbient() {
        queued.removeAll { $0.category == .ambientObject }
        if currentRequest?.category == .ambientObject { cancelCurrentForInterruption() }
    }

    func discardPerception() {
        let perceptionCategories: Set<SpeechCategory> = [.ambientObject, .safetyWarning]
        queued.removeAll { perceptionCategories.contains($0.category) }
        if let current = currentRequest, perceptionCategories.contains(current.category) {
            cancelCurrentForInterruption()
            scheduleNext()
        }
    }

    var currentPriorityLevel: Int { currentRequest?.priority.rawValue ?? 0 }

    private func enqueue(_ request: SpeechRequest) {
        guard !isStale(request), request.category != .ambientObject else { return }
        if request.priority == .status {
            queued.removeAll { $0.category == request.category || $0.label == request.label }
        }
        queued.append(request)
        queued.sort { $0.priority.rawValue > $1.priority.rawValue }
    }

    private func begin(_ request: SpeechRequest) {
        guard !isInterrupted, !isStale(request) else { return }
        currentRequest = request
        lastSpokenTime[request.label.lowercased()] = Date()
        isSpeaking = true
        if request.category == .textReading { NotificationCenter.default.post(name: .speechTextReadingStarted, object: nil) }

        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: request.phrase)
            let duration = min(12.0, 0.6 + Double(request.phrase.split(separator: " ").count) * 0.32)
            voiceOverCompletionTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(request)
            }
            return
        }

        activateAudioSession()
        let utterance = AVSpeechUtterance(string: request.phrase)
        utterance.rate = 0.5
        utterance.volume = 1.0
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utteranceRequests[ObjectIdentifier(utterance)] = request
        synthesizer.speak(utterance)
    }

    private func finish(_ request: SpeechRequest) {
        guard currentRequest?.id == request.id else { return }
        if request.category == .textReading { NotificationCenter.default.post(name: .speechTextReadingFinished, object: nil) }
        currentRequest = nil
        isSpeaking = false
        scheduleNext()
    }

    private func scheduleNext() {
        queued.removeAll(where: isStale)
        guard !isInterrupted, !queued.isEmpty else {
            deactivateAudioSession()
            return
        }
        let next = queued.removeFirst()
        let delay: UInt64 = next.priority == .safetyCritical ? 0 : 300_000_000
        deliveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.begin(next)
        }
    }

    private func cancelCurrentForInterruption() {
        guard let request = currentRequest else { return }
        voiceOverCompletionTask?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        utteranceRequests.removeAll()
        currentRequest = nil
        isSpeaking = false
        if request.category == .textReading { NotificationCenter.default.post(name: .speechTextReadingFinished, object: nil) }
    }

    private func isStale(_ request: SpeechRequest) -> Bool {
        let age = Date().timeIntervalSince(request.createdAt)
        if request.category == .ambientObject { return age > 0.8 }
        if request.priority == .status { return age > 8.0 }
        return age > 30.0
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        } catch {
            #if DEBUG
            print("Speech audio configuration failed: \(error)")
            #endif
        }
    }

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(voiceOverNotification), name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(audioInterruptionNotification(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(routeChangeNotification(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(mediaServicesResetNotification), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    @objc private func voiceOverNotification() { voiceOverChanged() }
    @objc private func audioInterruptionNotification(_ notification: Notification) { handleInterruption(notification) }
    @objc private func routeChangeNotification(_ notification: Notification) { handleRouteChange(notification) }
    @objc private func mediaServicesResetNotification() { configureAudioSession() }

    private func voiceOverChanged() {
        queued.removeAll()
        if currentRequest != nil { cancelCurrentForInterruption() }
        deactivateAudioSession()
    }

    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            isInterrupted = true
            queued.removeAll { $0.priority < .requested }
            cancelCurrentForInterruption()
            deactivateAudioSession()
        } else {
            isInterrupted = false
            scheduleNext()
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        let privateCategories: Set<SpeechCategory> = [.textReading, .paymentGuidance, .miniCPMResult]
        if let current = currentRequest, privateCategories.contains(current.category) { cancelCurrentForInterruption() }
        queued.removeAll { privateCategories.contains($0.category) }
        deactivateAudioSession()
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let request = self.utteranceRequests.removeValue(forKey: key) else { return }
            self.finish(request)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceRequests.removeValue(forKey: key) }
    }
}

extension Notification.Name {
    static let speechTextReadingStarted = Notification.Name("TextReadingStarted")
    static let speechTextReadingFinished = Notification.Name("TextReadingFinished")
}
