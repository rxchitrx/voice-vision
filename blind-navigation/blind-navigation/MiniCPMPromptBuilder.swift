import Foundation

enum MiniCPMPromptBuilder {
    static func prompt(for mode: MiniCPMMode) -> String {
        switch mode {
        case .scene:
            return "Briefly describe the most important navigation-relevant scene details for a blind user."
        case .read:
            return "Read and explain the most relevant visible text clearly and briefly."
        case .document:
            return "Parse visible document text into concise key fields and summarize."
        }
    }
}
