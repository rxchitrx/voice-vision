import Foundation
import Combine
import AVFoundation

/// Lightweight speech helper that serializes announcements and throttles repeats.
final class SpeechService: NSObject, ObservableObject {
    @Published var isSpeaking: Bool = false
    
    private let synthesizer: AVSpeechSynthesizer
    private var lastSpokenTime: [String: Date] = [:]
    private let cooldown: TimeInterval
    private let accessQueue = DispatchQueue(label: "SpeechService.cooldown")
    private var isInitialized = false
    
    // Priority system
    private var currentPriority: Int = 0
    private let priorityQueue = DispatchQueue(label: "SpeechService.priority")
    
    // Track current speech label to detect text reading
    private var currentSpeechLabel: String = ""
    private let labelQueue = DispatchQueue(label: "SpeechService.label")

    init(cooldown: TimeInterval = 3.0) {
        self.cooldown = cooldown
        self.synthesizer = AVSpeechSynthesizer()
        super.init()
        synthesizer.delegate = self
    }

    /// Call once from SwiftUI lifecycle to warm up internal objects.
    func initialize() {
        guard !isInitialized else { return }
        isInitialized = true
        
        // Configure audio session for speech output
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: .mixWithOthers)
            try audioSession.setActive(true)
            print("DEBUG: SpeechService - Audio session configured for playback")
        } catch {
            print("DEBUG: SpeechService - Failed to configure audio session: \(error)")
        }
        #endif
        
        DispatchQueue.main.async { _ = self.synthesizer.isSpeaking }
    }

    func speak(label: String, phrase: String) {
        speakWithPriority(label: label, phrase: phrase, priority: 0)
    }
    
    /// Speak with priority (higher priority can interrupt lower)
    func speakWithPriority(label: String, phrase: String, priority: Int) {
        guard !phrase.isEmpty else { 
            print("DEBUG: SpeechService - empty phrase, skipping")
            return 
        }
        
        print("DEBUG: SpeechService - attempting to speak: '\(phrase)' (label: '\(label)')")
        
        let key = label.lowercased()
        let isTextReading = (key == "textreading")
        
        // Check if text reading is in progress - don't allow other speech to interrupt
        let currentLabel = labelQueue.sync { currentSpeechLabel }
        if currentLabel == "textreading" && !isTextReading {
            print("DEBUG: SpeechService - text reading in progress, skipping object announcement")
            return
        }

        let shouldSpeak: Bool = accessQueue.sync {
            let now = Date()
            // Skip cooldown check for text reading to allow immediate reads
            if isTextReading {
                lastSpokenTime[key] = now
                return true
            }
            if now.timeIntervalSince(lastSpokenTime[key] ?? .distantPast) >= cooldown {
                lastSpokenTime[key] = now
                return true
            }
            print("DEBUG: SpeechService - cooldown active for '\(label)', skipping")
            return false
        }

        guard shouldSpeak else { return }
        
        // Prevent lower-priority speech from interrupting more important speech.
        let shouldInterruptCurrent = priorityQueue.sync { () -> Bool in
            if synthesizer.isSpeaking && priority < currentPriority {
                return false
            }
            currentPriority = priority
            return true
        }

        guard shouldInterruptCurrent else {
            print("DEBUG: SpeechService - lower priority speech skipped for '\(label)'")
            return
        }

        // Store label for delegate to track text reading
        labelQueue.sync {
            currentSpeechLabel = key
        }
        
        if synthesizer.isSpeaking {
            DispatchQueue.main.async {
                self.synthesizer.stopSpeaking(at: .immediate)
            }
        }

        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = 0.5 // Slightly slower for clarity
        utterance.volume = 1.0 // Full volume
        
        // Label is already stored in currentSpeechLabel via labelQueue
        
        if let voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode()) {
            utterance.voice = voice
            print("DEBUG: SpeechService - using voice: \(voice.name)")
        } else {
            print("DEBUG: SpeechService - using default voice")
        }
        
        DispatchQueue.main.async {
            print("DEBUG: SpeechService - calling synthesizer.speak()")
            self.synthesizer.speak(utterance)
        }
    }
    
    /// Stop current speech and clear all queued announcements
    func stopAndClear() {
        // Clear the label first so other speech can proceed
        labelQueue.sync {
            currentSpeechLabel = ""
        }
        DispatchQueue.main.async {
            if self.synthesizer.isSpeaking {
                self.synthesizer.stopSpeaking(at: .immediate)
            }
            self.isSpeaking = false
        }
        priorityQueue.sync {
            currentPriority = 0
        }
    }
    
    /// Get current priority
    var currentPriorityLevel: Int {
        return priorityQueue.sync { currentPriority }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = true
            // Notify if this is text reading
            let label = self.labelQueue.sync { self.currentSpeechLabel }
            if label == "textreading" {
                NotificationCenter.default.post(name: NSNotification.Name("TextReadingStarted"), object: nil)
            }
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            if !synthesizer.isSpeaking {
                self.isSpeaking = false
                self.priorityQueue.sync { self.currentPriority = 0 }
                // Notify if text reading finished
                let label = self.labelQueue.sync { self.currentSpeechLabel }
                if label == "textreading" {
                    NotificationCenter.default.post(name: NSNotification.Name("TextReadingFinished"), object: nil)
                    self.labelQueue.sync { self.currentSpeechLabel = "" }
                }
            }
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            if !synthesizer.isSpeaking {
                self.isSpeaking = false
                self.priorityQueue.sync { self.currentPriority = 0 }
                // Notify if text reading was cancelled
                let label = self.labelQueue.sync { self.currentSpeechLabel }
                if label == "textreading" {
                    NotificationCenter.default.post(name: NSNotification.Name("TextReadingFinished"), object: nil)
                    self.labelQueue.sync { self.currentSpeechLabel = "" }
                }
            }
        }
    }
}
