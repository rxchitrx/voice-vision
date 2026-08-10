import Foundation
import UIKit

protocol MiniCPMEngine {
    var runtime: MiniCPMRuntime { get }
    var statusDescription: String { get }
    var isReady: Bool { get }

    func analyze(
        mode: MiniCPMMode,
        prompt: String,
        ocrText: String,
        image: UIImage?,
        completion: @escaping (Result<MiniCPMAnalyzeResult, Error>) -> Void
    )
}
