#if canImport(HuggingFace) && canImport(Tokenizers) && canImport(MLXLMCommon)
import Foundation
import HuggingFace
import MLXLMCommon
import Tokenizers

struct HuggingFaceSnapshotDownloader: Downloader {
    private let client: HubClient

    init(client: HubClient = HubClient()) {
        self.client = client
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: id) else {
            throw HuggingFaceBridgeError.invalidRepositoryID(id)
        }

        return try await client.downloadSnapshot(
            of: repoID,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
    }
}

struct HuggingFaceTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return HuggingFaceTokenizerBridge(upstream)
    }
}

struct HuggingFaceTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

enum HuggingFaceBridgeError: LocalizedError {
    case invalidRepositoryID(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            return "Invalid Hugging Face repository ID: \(id)"
        }
    }
}
#endif
