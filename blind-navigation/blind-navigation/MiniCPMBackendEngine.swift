import Foundation
import UIKit

final class MiniCPMBackendEngine: MiniCPMEngine {
    let runtime: MiniCPMRuntime = .backendFallback
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var statusDescription: String {
        "Using the backend perception API as a compatibility fallback."
    }

    var isReady: Bool {
        true
    }

    func analyze(
        mode: MiniCPMMode,
        prompt: String,
        ocrText: String,
        image: UIImage?,
        completion: @escaping (Result<MiniCPMAnalyzeResult, Error>) -> Void
    ) {
        var request = URLRequest(url: BackendConfig.baseURL.appendingPathComponent("perception/analyze"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 18

        let payload = MiniCPMAnalyzeRequest(
            mode: mode.rawValue,
            prompt: prompt,
            ocrText: ocrText,
            imageBase64: image.flatMap(Self.encodeImageBase64(from:))
        )

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let data else {
                completion(.failure(MiniCPMEngineError.inferenceFailed(self.runtime, "Backend returned an invalid response.")))
                return
            }

            do {
                let decoded = try JSONDecoder().decode(MiniCPMAnalyzeResponse.self, from: data)
                completion(.success(MiniCPMAnalyzeResult(
                    runtime: .backendFallback,
                    summary: decoded.summary,
                    structuredFields: decoded.structuredFields ?? [:],
                    warning: decoded.warning
                )))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func encodeImageBase64(from image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.32) else {
            return nil
        }
        return data.base64EncodedString()
    }
}
