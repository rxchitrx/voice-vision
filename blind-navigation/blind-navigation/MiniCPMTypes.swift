import Foundation

enum MiniCPMRuntime: String, Codable, CaseIterable {
    case mlx
    case gguf
    case backendFallback

    var displayName: String {
        switch self {
        case .mlx:
            return "MLX"
        case .gguf:
            return "GGUF"
        case .backendFallback:
            return "Backend"
        }
    }
}

struct MiniCPMAnalyzeRequest: Encodable {
    let mode: String
    let prompt: String
    let ocrText: String
    let imageBase64: String?
}

struct MiniCPMAnalyzeResponse: Decodable {
    let provider: String?
    let mode: String?
    let summary: String
    let structuredFields: [String: String]?
    let warning: String?
}

struct MiniCPMAnalyzeResult {
    let runtime: MiniCPMRuntime
    let summary: String
    let structuredFields: [String: String]
    let warning: String?
}

func parseStructuredFields(from text: String) -> [String: String] {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return [:] }

    if let jsonStart = cleaned.firstIndex(of: "{"),
       let jsonEnd = cleaned.lastIndex(of: "}") {
        let jsonCandidate = String(cleaned[jsonStart...jsonEnd])
        if let data = jsonCandidate.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let fields = object["structuredFields"] as? [String: String] {
                return fields
            }
            return object.reduce(into: [String: String]()) { result, item in
                if item.key != "summary", let value = item.value as? String {
                    result[item.key] = value
                }
            }
        }
    }

    var fields: [String: String] = [:]
    cleaned.split(separator: "\n").forEach { line in
        guard let colonIndex = line.firstIndex(of: ":") else { return }
        let key = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[-*\d.\s]+"#, with: "", options: .regularExpression)
        let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, !value.isEmpty, key.count <= 80 {
            fields[key] = value
        }
    }
    return fields
}

enum MiniCPMEngineError: LocalizedError {
    case modelUnavailable(MiniCPMRuntime, String)
    case runtimeUnavailable(MiniCPMRuntime, String)
    case inferenceFailed(MiniCPMRuntime, String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let runtime, let detail):
            return "\(runtime.displayName) model unavailable: \(detail)"
        case .runtimeUnavailable(let runtime, let detail):
            return "\(runtime.displayName) runtime unavailable: \(detail)"
        case .inferenceFailed(let runtime, let detail):
            return "\(runtime.displayName) inference failed: \(detail)"
        }
    }
}
