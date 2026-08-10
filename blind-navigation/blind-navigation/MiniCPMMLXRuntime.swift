#if canImport(CoreImage) && canImport(MLX) && canImport(MLXLMCommon) && canImport(MLXNN) && canImport(MLXVLM)
import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXNN
import MLXVLM

enum MiniCPMMLXRuntime {
    private static let registrationQueue = DispatchQueue(label: "MiniCPMMLXRuntime.registration")
    private static var isRegistered = false

    static let defaultRepositoryID = "mlx-community/MiniCPM-o-4_5-4bit"

    static func ensureRegistered() async {
        if registrationQueue.sync(execute: { isRegistered }) {
            return
        }

        await VLMTypeRegistry.shared.registerModelType("minicpmo") { data in
            let configuration = try JSONDecoder.json5().decode(MiniCPMOVLMConfiguration.self, from: data)
            return MiniCPMOVLM(configuration)
        }

        await VLMProcessorTypeRegistry.shared.registerProcessorType("MiniCPMOProcessor") { data, tokenizer in
            let configuration = try JSONDecoder.json5().decode(MiniCPMOProcessorConfiguration.self, from: data)
            return MiniCPMOProcessor(configuration, tokenizer: tokenizer)
        }

        registrationQueue.sync {
            isRegistered = true
        }
    }
}

private struct MiniCPMOProcessorConfiguration: Codable, Sendable {
    let patchSize: Int
    let scaleResolution: Int
    let imageFeatureSize: Int
    let imStart: String
    let imEnd: String
    let unk: String
    let sliceStart: String?
    let sliceEnd: String?
    let normMean: [CGFloat]
    let normStd: [CGFloat]

    var imageMeanTuple: (CGFloat, CGFloat, CGFloat) {
        (
            normMean[safe: 0] ?? 0.5,
            normMean[safe: 1] ?? 0.5,
            normMean[safe: 2] ?? 0.5
        )
    }

    var imageStdTuple: (CGFloat, CGFloat, CGFloat) {
        (
            normStd[safe: 0] ?? 0.5,
            normStd[safe: 1] ?? 0.5,
            normStd[safe: 2] ?? 0.5
        )
    }

    var placeholderText: String {
        imStart + String(repeating: unk, count: imageFeatureSize) + imEnd
    }

    enum CodingKeys: String, CodingKey {
        case patchSize = "patch_size"
        case scaleResolution = "scale_resolution"
        case imageFeatureSize = "image_feature_size"
        case imStart = "im_start"
        case imEnd = "im_end"
        case unk
        case sliceStart = "slice_start"
        case sliceEnd = "slice_end"
        case normMean = "norm_mean"
        case normStd = "norm_std"
    }
}

private struct MiniCPMOProcessor: UserInputProcessor {
    private let config: MiniCPMOProcessorConfiguration
    private let tokenizer: any Tokenizer

    init(_ config: MiniCPMOProcessorConfiguration, tokenizer: any Tokenizer) {
        self.config = config
        self.tokenizer = tokenizer
    }

    func prepare(input: UserInput) async throws -> LMInput {
        if input.images.count > 1 || !input.videos.isEmpty {
            throw VLMError.singleImageAllowed
        }

        let basePrompt = input.prompt.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = input.images.isEmpty ? basePrompt : injectImagePlaceholder(into: basePrompt)

        let promptTokens: [Int]
        let messages: [[String: any Sendable]] = [["role": "user", "content": prompt]]
        if let templated = try? tokenizer.applyChatTemplate(messages: messages, tools: input.tools, additionalContext: input.additionalContext) {
            promptTokens = templated
        } else {
            promptTokens = tokenizer.encode(text: prompt, addSpecialTokens: true)
        }

        let tokenArray = MLXArray(promptTokens).expandedDimensions(axis: 0)
        let mask = ones(like: tokenArray).asType(.int8)

        guard let image = input.images.first else {
            return LMInput(text: .init(tokens: tokenArray, mask: mask))
        }

        let bounds = try imageBounds(in: promptTokens)
        let processed = try preprocess(image: image, processing: input.processing, startIndex: bounds.lowerBound)
        return LMInput(
            text: .init(tokens: tokenArray, mask: mask),
            image: .init(pixels: processed.pixels, frames: [processed.frame])
        )
    }

    private func injectImagePlaceholder(into prompt: String) -> String {
        if prompt.contains(config.imStart) {
            return prompt
        }
        if prompt.isEmpty {
            return config.placeholderText
        }
        return "\(config.placeholderText)\n\(prompt)"
    }

    private func preprocess(image: UserInput.Image, processing: UserInput.Processing, startIndex: Int) throws -> (pixels: MLXArray, frame: THW) {
        let ciImage = try image.asCIImage()
        let processed = MediaProcessing.apply(ciImage, processing: processing)
        let size = processed.extent.size
        let target = bestResize(
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            scaleResolution: config.scaleResolution,
            patchSize: config.patchSize
        )
        let normalized = MediaProcessing.normalize(
            MediaProcessing.resampleBicubic(processed.toSRGB(), to: CGSize(width: target.width, height: target.height)),
            mean: config.imageMeanTuple,
            std: config.imageStdTuple
        )
        let pixels = MediaProcessing.asMLXArray(normalized)[0]
        let frame = THW(startIndex, target.height / config.patchSize, target.width / config.patchSize)
        return (pixels, frame)
    }

    private func imageBounds(in tokens: [Int]) throws -> Range<Int> {
        guard let startToken = tokenizer.convertTokenToId(config.imStart),
              let endToken = tokenizer.convertTokenToId(config.imEnd),
              let startIndex = tokens.firstIndex(of: startToken),
              let endIndex = tokens[startIndex...].firstIndex(of: endToken),
              endIndex > startIndex + 1 else {
            throw MiniCPMRuntimeError.processing("Unable to locate MiniCPM image placeholder tokens in the prompt.")
        }
        return (startIndex + 1)..<endIndex
    }

    private func bestResize(width: Int, height: Int, scaleResolution: Int, patchSize: Int) -> (width: Int, height: Int) {
        var targetWidth = width
        var targetHeight = height

        if width * height > scaleResolution * scaleResolution || width < scaleResolution || height < scaleResolution {
            let ratio = Double(width) / Double(max(height, 1))
            targetHeight = Int(Double(scaleResolution) / sqrt(max(ratio, 1e-6)))
            targetWidth = Int(Double(targetHeight) * ratio)
        }

        func rounded(_ value: Int) -> Int {
            max(Int((Double(value) / Double(patchSize)).rounded()) * patchSize, patchSize)
        }

        return (rounded(targetWidth), rounded(targetHeight))
    }
}

private struct MiniCPMOVLMConfiguration: Codable, Sendable {
    struct VisionConfiguration: Codable, Sendable {
        let modelType: String
        let hiddenSize: Int
        let intermediateSize: Int
        let numHiddenLayers: Int
        let numAttentionHeads: Int
        let imageSize: Int
        let patchSize: Int
        let layerNormEps: Float?

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case hiddenSize = "hidden_size"
            case intermediateSize = "intermediate_size"
            case numHiddenLayers = "num_hidden_layers"
            case numAttentionHeads = "num_attention_heads"
            case imageSize = "image_size"
            case patchSize = "patch_size"
            case layerNormEps = "layer_norm_eps"
        }
    }

    let modelType: String
    let hiddenSize: Int
    let intermediateSize: Int
    let numHiddenLayers: Int
    let numAttentionHeads: Int
    let numKeyValueHeads: Int
    let rmsNormEps: Float
    let vocabSize: Int
    let ropeTheta: Float
    let maxPositionEmbeddings: Int
    let tieWordEmbeddings: Bool
    let queryNum: Int
    let patchSize: Int
    let imageSize: Int
    let visionConfig: VisionConfiguration

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case numKeyValueHeads = "num_key_value_heads"
        case rmsNormEps = "rms_norm_eps"
        case vocabSize = "vocab_size"
        case ropeTheta = "rope_theta"
        case maxPositionEmbeddings = "max_position_embeddings"
        case tieWordEmbeddings = "tie_word_embeddings"
        case queryNum = "query_num"
        case patchSize = "patch_size"
        case imageSize = "image_size"
        case visionConfig = "vision_config"
    }
}

nonisolated private final class MiniCPMOVLM: Module, VLMModel, KVCacheDimensionProvider {
    @ModuleInfo(key: "vision_tower") private var visionTower: MiniCPMOVisionTower
    @ModuleInfo(key: "resampler") private var resampler: MiniCPMResampler
    @ModuleInfo(key: "language_model") private var languageModel: MiniCPMLanguageModel

    private let config: MiniCPMOVLMConfiguration

    var vocabularySize: Int { config.vocabSize }
    var kvHeads: [Int] { languageModel.kvHeads }

    var loraLayers: [Module] { languageModel.model.layers }

    nonisolated init(_ config: MiniCPMOVLMConfiguration) {
        self.config = config
        _visionTower.wrappedValue = MiniCPMOVisionTower(config.visionConfig)
        _resampler.wrappedValue = MiniCPMResampler(
            numQueries: config.queryNum,
            embedDim: config.hiddenSize,
            numHeads: max(1, config.hiddenSize / 128),
            kvDim: config.visionConfig.hiddenSize
        )
        _languageModel.wrappedValue = MiniCPMLanguageModel(config)
        super.init()
    }

    func prepare(_ input: LMInput, cache: [KVCache], windowSize _: Int?) throws -> PrepareResult {
        let inputIds = input.text.tokens
        guard let image = input.image, let frame = image.frames?.first else {
            let logits = languageModel(inputIds, cache: cache, inputEmbedding: nil)
            return .logits(logits)
        }

        let textEmbeds = languageModel.model.embedTokens(inputIds)
        let visionHidden = visionTower(image.pixels.asType(visionTower.inputDType), targetSize: frame)
        let imageFeatures = resampler(
            visionHidden,
            targetSizes: MLXArray([Int32(frame.h), Int32(frame.w)]).reshaped(1, 2)
        )
        let mergedEmbeddings = try merge(startIndex: frame.t, inputEmbeddings: textEmbeds, imageFeatures: imageFeatures)
        let logits = languageModel(nil, cache: cache, inputEmbedding: mergedEmbeddings)
        return .logits(logits)
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        languageModel(inputs, cache: cache, inputEmbedding: nil).logits
    }

    func sanitize(weights: [String: MLXArray], metadata: [String: String]) -> [String: MLXArray] {
        sanitize(weights: weights)
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized: [String: MLXArray] = [:]
        var inProjWeight: MLXArray?
        var inProjBias: MLXArray?

        for (originalKey, originalValue) in weights {
            if originalKey.hasPrefix("tts.") || originalKey.hasPrefix("audio_") || originalKey.hasPrefix("apm.") {
                continue
            }

            var key = originalKey
            var value = originalValue

            if key.hasPrefix("llm.") {
                key = key.replacingOccurrences(of: "llm.", with: "language_model.", options: [], range: key.startIndex..<key.endIndex)
            } else if key.hasPrefix("vpm.") {
                key = key.replacingOccurrences(of: "vpm.", with: "vision_tower.", options: [], range: key.startIndex..<key.endIndex)
            } else if key.hasPrefix("resampler.") {
                // keep as-is
            } else {
                continue
            }

            if key == "resampler.attn.in_proj_weight" {
                inProjWeight = value
                continue
            }
            if key == "resampler.attn.in_proj_bias" {
                inProjBias = value
                continue
            }
            if key.contains("position_ids") {
                continue
            }
            if key.hasSuffix("patch_embedding.weight") && !checkArrayShape(value) {
                value = value.transposed(0, 2, 3, 1)
            }
            sanitized[key] = value
        }

        if let inProjWeight {
            let splitWeights = split(inProjWeight, parts: 3, axis: 0)
            sanitized["resampler.attn.q_proj.weight"] = splitWeights[0]
            sanitized["resampler.attn.k_proj.weight"] = splitWeights[1]
            sanitized["resampler.attn.v_proj.weight"] = splitWeights[2]
        }
        if let inProjBias {
            let splitBiases = split(inProjBias, parts: 3, axis: 0)
            sanitized["resampler.attn.q_proj.bias"] = splitBiases[0]
            sanitized["resampler.attn.k_proj.bias"] = splitBiases[1]
            sanitized["resampler.attn.v_proj.bias"] = splitBiases[2]
        }
        if config.tieWordEmbeddings {
            sanitized["language_model.lm_head.weight"] = nil
        }
        return sanitized
    }

    private func merge(startIndex: Int, inputEmbeddings: MLXArray, imageFeatures: MLXArray) throws -> MLXArray {
        let flattenedFeatures = imageFeatures.reshaped(-1, imageFeatures.dim(-1))
        let replacementIndices = Array(startIndex..<(startIndex + flattenedFeatures.dim(0)))
        guard inputEmbeddings.dim(1) >= replacementIndices.endIndex else {
            throw MiniCPMRuntimeError.processing(
                "MiniCPM placeholder span exceeds the tokenized prompt length."
            )
        }

        var merged = inputEmbeddings
        merged[0..., MLXArray(replacementIndices), 0...] = flattenedFeatures[.newAxis, 0..., 0...]
        return merged
    }
}

private enum MiniCPMRuntimeError: LocalizedError {
    case processing(String)

    var errorDescription: String? {
        switch self {
        case .processing(let message):
            return message
        }
    }
}

nonisolated private final class MiniCPMLanguageAttention: Module {
    let config: MiniCPMOVLMConfiguration
    let scale: Float

    @ModuleInfo(key: "q_proj") var wq: Linear
    @ModuleInfo(key: "k_proj") var wk: Linear
    @ModuleInfo(key: "v_proj") var wv: Linear
    @ModuleInfo(key: "o_proj") var wo: Linear

    let rope: RoPELayer

    nonisolated init(_ config: MiniCPMOVLMConfiguration) {
        self.config = config
        let headDim = config.hiddenSize / config.numAttentionHeads
        self.scale = pow(Float(headDim), -0.5)

        _wq.wrappedValue = Linear(config.hiddenSize, config.numAttentionHeads * headDim, bias: false)
        _wk.wrappedValue = Linear(config.hiddenSize, config.numKeyValueHeads * headDim, bias: false)
        _wv.wrappedValue = Linear(config.hiddenSize, config.numKeyValueHeads * headDim, bias: false)
        _wo.wrappedValue = Linear(config.numAttentionHeads * headDim, config.hiddenSize, bias: false)
        rope = initializeRope(
            dims: headDim,
            base: config.ropeTheta,
            traditional: false,
            scalingConfig: nil,
            maxPositionEmbeddings: config.maxPositionEmbeddings
        )

        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?) -> MLXArray {
        let (batch, length) = (x.dim(0), x.dim(1))
        let headDim = config.hiddenSize / config.numAttentionHeads

        var queries = wq(x).reshaped(batch, length, config.numAttentionHeads, headDim).transposed(0, 2, 1, 3)
        var keys = wk(x).reshaped(batch, length, config.numKeyValueHeads, headDim).transposed(0, 2, 1, 3)
        var values = wv(x).reshaped(batch, length, config.numKeyValueHeads, headDim).transposed(0, 2, 1, 3)

        queries = applyRotaryPosition(rope, to: queries, cache: cache)
        keys = applyRotaryPosition(rope, to: keys, cache: cache)

        let output = attentionWithCacheUpdate(
            queries: queries,
            keys: keys,
            values: values,
            cache: cache,
            scale: scale,
            mask: mask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(batch, length, -1)

        return wo(output)
    }
}

nonisolated private final class MiniCPMLanguageMLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "down_proj") var down: Linear
    @ModuleInfo(key: "up_proj") var up: Linear

    nonisolated init(dimensions: Int, hiddenDimensions: Int) {
        _gate.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
        _down.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
        _up.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        down(silu(gate(x)) * up(x))
    }
}

nonisolated private final class MiniCPMLanguageDecoderLayer: Module {
    @ModuleInfo(key: "self_attn") var attention: MiniCPMLanguageAttention
    let mlp: MiniCPMLanguageMLP
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    nonisolated init(_ config: MiniCPMOVLMConfiguration) {
        _attention.wrappedValue = MiniCPMLanguageAttention(config)
        mlp = MiniCPMLanguageMLP(dimensions: config.hiddenSize, hiddenDimensions: config.intermediateSize)
        _inputLayerNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _postAttentionLayerNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?) -> MLXArray {
        let h = x + attention(inputLayerNorm(x), mask: mask, cache: cache)
        return h + mlp(postAttentionLayerNorm(h))
    }
}

nonisolated private final class MiniCPMLanguageInner: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    let layers: [MiniCPMLanguageDecoderLayer]
    let norm: RMSNorm

    nonisolated init(_ config: MiniCPMOVLMConfiguration) {
        _embedTokens.wrappedValue = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize)
        layers = (0..<config.numHiddenLayers).map { _ in MiniCPMLanguageDecoderLayer(config) }
        norm = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ inputs: MLXArray?, cache: [KVCache]? = nil, inputEmbedding: MLXArray? = nil) -> MLXArray {
        let hiddenStates: MLXArray
        if let inputEmbedding {
            hiddenStates = inputEmbedding
        } else if let inputs {
            hiddenStates = embedTokens(inputs)
        } else {
            fatalError("MiniCPM requires either input tokens or input embeddings.")
        }

        var h = hiddenStates
        let mask = createAttentionMask(h: h, cache: cache?.first)
        for (index, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: cache?[index])
        }
        return norm(h)
    }
}

nonisolated private final class MiniCPMLanguageModel: Module, KVCacheDimensionProvider {
    let configuration: MiniCPMOVLMConfiguration
    let model: MiniCPMLanguageInner
    let kvHeads: [Int]
    @ModuleInfo(key: "lm_head") var lmHead: Linear?
    nonisolated init(_ configuration: MiniCPMOVLMConfiguration) {
        self.configuration = configuration
        self.model = MiniCPMLanguageInner(configuration)
        self.kvHeads = (0..<configuration.numHiddenLayers).map { _ in configuration.numKeyValueHeads }
        if !configuration.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(configuration.hiddenSize, configuration.vocabSize, bias: false)
        }
        super.init()
    }

    func callAsFunction(_ inputs: MLXArray?, cache: [KVCache]?, inputEmbedding: MLXArray?) -> LMOutput {
        var out = model(inputs, cache: cache, inputEmbedding: inputEmbedding)
        if let lmHead {
            out = lmHead(out)
        } else {
            out = model.embedTokens.asLinear(out)
        }
        return LMOutput(logits: out)
    }
}

nonisolated private final class MiniCPMOVisionAttention: Module {
    let embedDim: Int
    let numHeads: Int
    let headDim: Int
    let scale: Float

    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    nonisolated init(_ config: MiniCPMOVLMConfiguration.VisionConfiguration) {
        self.embedDim = config.hiddenSize
        self.numHeads = config.numAttentionHeads
        self.headDim = config.hiddenSize / config.numAttentionHeads
        self.scale = pow(Float(headDim), -0.5)

        _kProj.wrappedValue = Linear(embedDim, embedDim, bias: true)
        _vProj.wrappedValue = Linear(embedDim, embedDim, bias: true)
        _qProj.wrappedValue = Linear(embedDim, embedDim, bias: true)
        _outProj.wrappedValue = Linear(embedDim, embedDim, bias: true)
        super.init()
    }

    func callAsFunction(_ hiddenStates: MLXArray) -> MLXArray {
        let batch = hiddenStates.dim(0)
        let length = hiddenStates.dim(1)

        let queries = qProj(hiddenStates).reshaped(batch, length, numHeads, headDim).transposed(0, 2, 1, 3)
        let keys = kProj(hiddenStates).reshaped(batch, length, numHeads, headDim).transposed(0, 2, 1, 3)
        let values = vProj(hiddenStates).reshaped(batch, length, numHeads, headDim).transposed(0, 2, 1, 3)

        let attended = MLXFast.scaledDotProductAttention(
            queries: queries,
            keys: keys,
            values: values,
            scale: scale,
            mask: .none
        )
        .transposed(0, 2, 1, 3)
        .reshaped(batch, length, embedDim)

        return outProj(attended)
    }
}

nonisolated private final class MiniCPMOVisionMLP: Module, UnaryLayer {
    @ModuleInfo var fc1: Linear
    @ModuleInfo var fc2: Linear
    @ModuleInfo var activation: GELU

    nonisolated init(_ config: MiniCPMOVLMConfiguration.VisionConfiguration) {
        fc1 = Linear(config.hiddenSize, config.intermediateSize, bias: true)
        fc2 = Linear(config.intermediateSize, config.hiddenSize, bias: true)
        activation = GELU(approximation: .precise)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        fc2(activation(fc1(x)))
    }
}

nonisolated private final class MiniCPMOVisionEncoderLayer: Module {
    @ModuleInfo var layerNorm1: LayerNorm
    @ModuleInfo var layerNorm2: LayerNorm
    @ModuleInfo(key: "self_attn") var selfAttention: MiniCPMOVisionAttention
    @ModuleInfo var mlp: MiniCPMOVisionMLP

    nonisolated init(_ config: MiniCPMOVLMConfiguration.VisionConfiguration) {
        layerNorm1 = LayerNorm(dimensions: config.hiddenSize, eps: config.layerNormEps ?? 1e-6)
        layerNorm2 = LayerNorm(dimensions: config.hiddenSize, eps: config.layerNormEps ?? 1e-6)
        _selfAttention.wrappedValue = MiniCPMOVisionAttention(config)
        mlp = MiniCPMOVisionMLP(config)
        super.init()
    }

    func callAsFunction(_ hiddenStates: MLXArray) -> MLXArray {
        let attended = hiddenStates + selfAttention(layerNorm1(hiddenStates))
        return attended + mlp(layerNorm2(attended))
    }
}

nonisolated private final class MiniCPMOVisionEmbeddings: Module {
    @ModuleInfo(key: "patch_embedding") var patchEmbedding: Conv2d
    @ModuleInfo(key: "position_embedding") var positionEmbedding: Embedding

    let hiddenSize: Int
    let patchSize: Int
    let patchesPerSide: Int
    let inputDType: DType = .float32

    nonisolated init(_ config: MiniCPMOVLMConfiguration.VisionConfiguration) {
        self.hiddenSize = config.hiddenSize
        self.patchSize = config.patchSize
        self.patchesPerSide = config.imageSize / config.patchSize
        _patchEmbedding.wrappedValue = Conv2d(
            inputChannels: 3,
            outputChannels: config.hiddenSize,
            kernelSize: IntOrPair(config.patchSize),
            stride: IntOrPair(config.patchSize),
            bias: true
        )
        _positionEmbedding.wrappedValue = Embedding(
            embeddingCount: patchesPerSide * patchesPerSide,
            dimensions: config.hiddenSize
        )
        super.init()
    }

    func callAsFunction(_ pixelValues: MLXArray, targetSize: THW) -> MLXArray {
        let batch = pixelValues.dim(0)
        let embedded = patchEmbedding(pixelValues.movedAxis(source: 1, destination: 3))
        var tokens = embedded.reshaped(batch, embedded.dim(1) * embedded.dim(2), embedded.dim(3))

        let positionIds = MLXArray(0..<(targetSize.h * targetSize.w)).asType(.int32)
        let embeddings = positionEmbedding(positionIds.asType(.int32))

        if tokens.ndim == 2 {
            tokens = tokens[.newAxis, 0..., 0...]
        }
        let broadcastEmbeddings = broadcast(embeddings[.newAxis, 0..., 0...], to: [batch, embeddings.dim(0), embeddings.dim(1)])
        return tokens + broadcastEmbeddings
    }
}

nonisolated private final class MiniCPMOVisionTower: Module {
    @ModuleInfo(key: "embeddings") var embeddings: MiniCPMOVisionEmbeddings
    @ModuleInfo(key: "encoder") var encoder: [MiniCPMOVisionEncoderLayer]
    @ModuleInfo(key: "post_layernorm") var postLayerNorm: LayerNorm

    let inputDType: DType = .float32

    nonisolated init(_ config: MiniCPMOVLMConfiguration.VisionConfiguration) {
        _embeddings.wrappedValue = MiniCPMOVisionEmbeddings(config)
        _encoder.wrappedValue = (0..<config.numHiddenLayers).map { _ in MiniCPMOVisionEncoderLayer(config) }
        _postLayerNorm.wrappedValue = LayerNorm(dimensions: config.hiddenSize, eps: config.layerNormEps ?? 1e-6)
        super.init()
    }

    func callAsFunction(_ pixelValues: MLXArray, targetSize: THW) -> MLXArray {
        var hiddenStates = embeddings(pixelValues, targetSize: targetSize)
        for layer in encoder {
            hiddenStates = layer(hiddenStates)
        }
        return postLayerNorm(hiddenStates)
    }
}

nonisolated private final class MiniCPMCrossAttention: Module {
    let numHeads: Int
    let headDim: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    nonisolated init(dim: Int, numHeads: Int) {
        self.numHeads = numHeads
        self.headDim = dim / numHeads
        self.scale = pow(Float(headDim), -0.5)
        _qProj.wrappedValue = Linear(dim, dim, bias: true)
        _kProj.wrappedValue = Linear(dim, dim, bias: true)
        _vProj.wrappedValue = Linear(dim, dim, bias: true)
        _outProj.wrappedValue = Linear(dim, dim, bias: true)
        super.init()
    }

    func callAsFunction(_ queries: MLXArray, keys: MLXArray, values: MLXArray) -> MLXArray {
        let batch = queries.dim(0)
        let queryLength = queries.dim(1)
        let keyLength = keys.dim(1)
        let dim = queries.dim(2)

        let q = qProj(queries).reshaped(batch, queryLength, numHeads, headDim).transposed(0, 2, 1, 3)
        let k = kProj(keys).reshaped(batch, keyLength, numHeads, headDim).transposed(0, 2, 1, 3)
        let v = vProj(values).reshaped(batch, keyLength, numHeads, headDim).transposed(0, 2, 1, 3)

        let attended = MLXFast.scaledDotProductAttention(
            queries: q,
            keys: k,
            values: v,
            scale: scale,
            mask: .none
        )
        .transposed(0, 2, 1, 3)
        .reshaped(batch, queryLength, dim)

        return outProj(attended)
    }
}

nonisolated private final class MiniCPMResampler: Module {
    let numQueries: Int
    let embedDim: Int
    let maxSize: (Int, Int)
    let posCache: MLXArray

    @ModuleInfo(key: "kv_proj") var kvProj: Linear?
    @ModuleInfo(key: "attn") var attn: MiniCPMCrossAttention
    @ModuleInfo(key: "ln_q") var lnQ: LayerNorm
    @ModuleInfo(key: "ln_kv") var lnKV: LayerNorm
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm

    @ParameterInfo(key: "query") var query: MLXArray
    @ParameterInfo(key: "proj") var proj: MLXArray

    nonisolated init(numQueries: Int, embedDim: Int, numHeads: Int, kvDim: Int?) {
        self.numQueries = numQueries
        self.embedDim = embedDim
        self.maxSize = (70, 70)
        self.posCache = MiniCPMResampler.makePositionalCache(size: maxSize, embedDim: embedDim)

        if let kvDim, kvDim != embedDim {
            _kvProj.wrappedValue = Linear(kvDim, embedDim, bias: false)
        } else {
            _kvProj.wrappedValue = nil
        }
        _attn.wrappedValue = MiniCPMCrossAttention(dim: embedDim, numHeads: numHeads)
        _lnQ.wrappedValue = LayerNorm(dimensions: embedDim, eps: 1e-6)
        _lnKV.wrappedValue = LayerNorm(dimensions: embedDim, eps: 1e-6)
        _lnPost.wrappedValue = LayerNorm(dimensions: embedDim, eps: 1e-6)
        _query.wrappedValue = zeros([numQueries, embedDim])
        _proj.wrappedValue = MLXRandom.normal([embedDim, embedDim]) * pow(Float(embedDim), -0.5)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, targetSizes: MLXArray) -> MLXArray {
        let batch = x.dim(0)
        let normalizedKeys = lnKV((kvProj?(x) ?? x))
        let normalizedQueries = broadcast(lnQ(query)[.newAxis, 0..., 0...], to: [batch, numQueries, embedDim])

        let targetHeight = Int(targetSizes[0, 0].item(Int32.self))
        let targetWidth = Int(targetSizes[0, 1].item(Int32.self))
        let patchCount = max(targetHeight * targetWidth, 1)
        let position = posCache[0..<targetHeight, 0..<targetWidth, 0...].reshaped(patchCount, embedDim)
        let positionedKeys = normalizedKeys + position[.newAxis, 0..., 0...]
        let attended = attn(normalizedQueries, keys: positionedKeys, values: normalizedKeys)
        return matmul(lnPost(attended), proj)
    }

    private static func makePositionalCache(size: (Int, Int), embedDim: Int) -> MLXArray {
        let height = size.0
        let width = size.1
        let half = embedDim / 2
        let quarter = half / 2

        let gridH = MLXArray(0..<height).asType(.float32)
        let gridW = MLXArray(0..<width).asType(.float32)
        let omega = pow(10_000, -(MLXArray(0..<quarter).asType(.float32) / Float(max(quarter, 1))))

        let gridHExpanded = broadcast(gridH[0..., .newAxis], to: [height, quarter])
        let gridWExpanded = broadcast(gridW[0..., .newAxis], to: [width, quarter])
        let hFreq = expandedDimensions(gridHExpanded * omega[.newAxis, 0...], axis: 1)
        let wFreq = expandedDimensions(gridWExpanded * omega[.newAxis, 0...], axis: 0)
        let tiledH = broadcast(hFreq, to: [height, width, quarter])
        let tiledW = broadcast(wFreq, to: [height, width, quarter])

        let hEmbedding = concatenated([sin(tiledH), cos(tiledH)], axis: -1)
        let wEmbedding = concatenated([sin(tiledW), cos(tiledW)], axis: -1)
        return concatenated([hEmbedding, wEmbedding], axis: -1).asType(.float32)
    }
}

private func checkArrayShape(_ array: MLXArray) -> Bool {
    let shape = array.shape
    guard shape.count == 4 else { return false }
    let outChannels = shape[0]
    let kernelHeight = shape[1]
    let kernelWidth = shape[2]
    return outChannels >= kernelHeight && outChannels >= kernelWidth && kernelHeight == kernelWidth
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
#endif
