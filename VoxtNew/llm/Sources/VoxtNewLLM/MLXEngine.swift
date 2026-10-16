import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import VoxtNewLLMKit

/// Shared prefixes kept per model: compose's system prompts differ by
/// feature, scene and language, so a few cover one person's use.
private let promptCacheEntries = 4
/// A Qwen3.5-4B snapshot of a 500-token prefix is about 65 MB (mostly the
/// fixed linear-attention state), so this bound is rarely what evicts.
private let promptCacheBytes = 768 << 20
private let promptCacheMinimumTokens = 64
/// The shared prefix is evaluated in chunks of this many tokens, whatever
/// the request's prefillStepSize (which follows the input's length), so
/// that a snapshot is the state a cold chat of any length reaches.
private let promptCachePrefixStepSize = 512
private let promptCacheOn = ProcessInfo.processInfo.environment["VOXTNEW_LLM_PROMPT_CACHE"] != "0"

/// An MLX text model (mlx-swift-lm): loaded with Voxt's loader, run with
/// the token loop of MLXLMCommon, streamed through a detokenizer. The
/// Runtime calls it one request at a time.
///
/// It keeps the model's caches after the shared part of each prompt
/// (PromptCache): a chat whose system prompt was seen before evaluates
/// only the rest. VOXTNEW_LLM_PROMPT_CACHE=0 keeps nothing (tests: the
/// prompts are still split at the same place, so the answers must be the
/// same token for token).
final class MLXEngine: @unchecked Sendable {
    private var container: ModelContainer?
    /// Used inside container.perform and in unload, which the Runtime
    /// never runs at once.
    private var prompts = PromptCache<[KVCache]>(
        maximumEntries: promptCacheOn ? promptCacheEntries : 0, maximumBytes: promptCacheBytes, minimumTokens: promptCacheMinimumTokens)

    var isLoaded: Bool { container != nil }

    func load(_ model: ModelSpec, cacheLimitMB: Int?) async throws {
        let dir = URL(fileURLWithPath: model.path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) else {
            throw RPCError(Code.loadFailed, "No config.json in \(model.path)")
        }
        if let mb = cacheLimitMB, mb > 0 {
            Memory.cacheLimit = mb << 20
        }
        do {
            container = try await ModelLoader.load(from: dir, using: LocalTokenizerLoader())
        } catch {
            throw RPCError(Code.loadFailed, "Could not load \(model.id): \(errorMessage(error))")
        }
    }

    func unload() {
        container = nil
        prompts.removeAll()
        Memory.clearCache()
    }

    func chat(_ p: ChatParams, onDelta: @escaping @Sendable (String) -> Void) async throws -> ChatOutcome {
        guard let container else { throw RPCError(Code.internal, "No MLX model is loaded") }
        let additional = p.template?.mapValues(\.sendable)
        let parameters = Self.parameters(p)
        let started = monotonicMs()
        let run = try await container.perform { context -> Run in
            let chat: [Chat.Message] = p.messages.map { m in
                switch m.role {
                case "system": .system(m.content)
                case "assistant": .assistant(m.content)
                default: .user(m.content)
                }
            }
            let input = try await context.processor.prepare(input: UserInput(chat: chat, additionalContext: additional))
            let promptTokens = input.text.tokens.asArray(Int.self)
            var shared = 0
            if chat.count > 1 {
                shared = sharedPrefixLength(promptTokens, try await Self.probeTokens(chat, additional, context))
            }
            let plan = self.prompts.plan(tokens: promptTokens, sharedPrefix: shared)
            let cache = try plan.entry.map { $0.snapshot.map { $0.copy() } } ?? context.model.newCache(parameters: parameters)
            var start = plan.reusedTokens
            var prefixMs = 0.0
            if let end = plan.storeAt {
                let t0 = monotonicMs()
                try Self.evaluate(input.text[start ..< end], model: context.model, cache: cache, stepSize: promptCachePrefixStepSize)
                if promptCacheOn {
                    let snapshot = cache.map { $0.copy() }
                    eval(snapshot)
                    let bytes = snapshot.reduce(0) { $0 + $1.state.reduce(0) { $0 + $1.nbytes } }
                    self.prompts.insert(tokens: Array(promptTokens[..<end]), snapshot: snapshot, bytes: bytes)
                    logLine("prompt cache: kept \(end) tokens (\(bytes >> 20) MB; \(self.prompts.entries.count) kept, \(self.prompts.bytes >> 20) MB)")
                }
                start = end
                prefixMs = monotonicMs() - t0
            }
            let use: CacheUse? = promptCacheOn ? CacheUse(hit: plan.entry != nil, prefixTokens: start) : nil
            guard p.maxTokens > 0 else {
                return Run(collector: TextCollector(), firstMs: nil, info: nil, prefixMs: prefixMs, promptTokens: promptTokens.count, cache: use)
            }
            // The repetition penalty still sees the whole prompt's last tokens.
            let processor: LogitProcessor? = parameters.processor().map { WholePromptProcessor(inner: $0, prompt: input.text.tokens) }
            let suffix = LMInput(text: input.text[start...])
            let iterator = try TokenIterator(
                input: suffix, model: context.model, cache: cache, processor: processor,
                sampler: parameters.sampler(), prefill: parameters.prefill, maxTokens: parameters.maxTokens)
            var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
            var collector = TextCollector()
            var firstMs: Double?
            let info = MLXLMCommon.generate(input: suffix, context: context, iterator: iterator) { token in
                if Task.isCancelled { return .stop }
                detokenizer.append(token: token)
                guard let piece = detokenizer.next(), !piece.isEmpty else { return .more }
                if firstMs == nil { firstMs = monotonicMs() - started }
                let more = collector.add(piece)
                if more { onDelta(piece) }
                return more ? .more : .stop
            }
            Memory.clearCache()
            return Run(collector: collector, firstMs: firstMs, info: info, prefixMs: prefixMs, promptTokens: promptTokens.count, cache: use)
        }
        try Task.checkCancellation()
        guard let info = run.info else {
            let ms = monotonicMs() - started
            return ChatOutcome(text: "", finish: Finish.length, usage: Usage(promptTokens: run.promptTokens, completionTokens: 0),
                               promptMs: ms, firstTokenMs: ms, tokensPerSecond: 0, cache: run.cache)
        }
        let finish = info.stopReason == .length && !run.collector.looped ? Finish.length : Finish.stop
        return ChatOutcome(
            text: run.collector.text, finish: finish,
            usage: Usage(promptTokens: run.promptTokens, completionTokens: info.generationTokenCount),
            promptMs: run.prefixMs + info.promptTime * 1000, firstTokenMs: run.firstMs ?? monotonicMs() - started,
            tokensPerSecond: info.generateTime > 0 ? Double(max(0, info.generationTokenCount - 1)) / info.generateTime : 0,
            cache: run.cache
        )
    }

    /// What one chat produced inside the model's context (info nil: it
    /// only evaluated the prompt's prefix).
    private struct Run: Sendable {
        var collector: TextCollector
        var firstMs: Double?
        var info: GenerateCompletionInfo?
        var prefixMs: Double
        var promptTokens: Int
        var cache: CacheUse?
    }

    /// The tokens of chat with its last message's text replaced: where they
    /// part from the real prompt's is where that message starts, whatever
    /// the chat template puts around it.
    private static func probeTokens(_ chat: [Chat.Message], _ additional: [String: any Sendable]?, _ context: ModelContext) async throws -> [Int] {
        var probe = chat
        let last = probe[probe.count - 1].content
        probe[probe.count - 1].content = last.hasPrefix("A") ? "B" : "A"
        return try await context.processor.prepare(input: UserInput(chat: probe, additionalContext: additional)).text.tokens.asArray(Int.self)
    }

    /// Evaluates tokens into cache, in chunks of stepSize (as the model's
    /// own prefill does), and waits for it.
    private static func evaluate(_ tokens: LMInput.Text, model: any LanguageModel, cache: [KVCache], stepSize: Int) throws {
        let count = tokens.tokens.dim(0)
        for chunk in stride(from: 0, to: count, by: stepSize) {
            try Task.checkCancellation()
            autoreleasepool {
                _ = model(tokens[.newAxis, chunk ..< min(chunk + stepSize, count)], cache: cache, state: nil)
                asyncEval(cache)
            }
        }
        eval(cache)
    }

    /// The request's sampling as MLXLMCommon's parameters.
    static func parameters(_ p: ChatParams) -> GenerateParameters {
        let s = p.sampling
        var prefill = PrefillParameters()
        prefill.stepSize = p.prefillStepSize
        prefill.chunking = .remainder
        return GenerateParameters(
            maxTokens: p.maxTokens,
            temperature: Float(s.temperature),
            topP: Float(s.topP ?? 1),
            topK: s.topK ?? 0,
            minP: Float(s.minP ?? 0),
            repetitionPenalty: s.repetitionPenalty.map(Float.init),
            repetitionContextSize: s.repetitionContextSize ?? 20,
            prefill: prefill,
            seed: s.seed
        )
    }

    /// MLX's memory counters.
    static func counters() -> (active: Int64, cache: Int64, peak: Int64) {
        (Int64(Memory.activeMemory), Int64(Memory.cacheMemory), Int64(Memory.peakMemory))
    }
}

/// A logit processor fed the whole prompt when the token iterator only
/// sees the part after a cached prefix.
private struct WholePromptProcessor: LogitProcessor {
    var inner: any LogitProcessor
    let prompt: MLXArray

    mutating func prompt(_ suffix: MLXArray) {
        inner.prompt(prompt)
    }

    func process(logits: MLXArray) -> MLXArray {
        inner.process(logits: logits)
    }

    mutating func didSample(token: MLXArray) {
        inner.didSample(token: token)
    }
}
