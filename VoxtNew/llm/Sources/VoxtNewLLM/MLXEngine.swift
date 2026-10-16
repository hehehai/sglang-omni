import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import VoxtNewLLMKit

/// An MLX text model (mlx-swift-lm): loaded with Voxt's loader, run with
/// the token loop of MLXLMCommon, streamed through a detokenizer. The
/// Runtime calls it one request at a time.
final class MLXEngine: @unchecked Sendable {
    private var container: ModelContainer?

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
        Memory.clearCache()
    }

    func chat(_ p: ChatParams, onDelta: @escaping @Sendable (String) -> Void) async throws -> ChatOutcome {
        guard let container else { throw RPCError(Code.internal, "No MLX model is loaded") }
        let messages = p.messages
        let additional = p.template?.mapValues(\.sendable)
        let parameters = Self.parameters(p)
        let started = monotonicMs()
        let outcome = try await container.perform { context in
            let chat: [Chat.Message] = messages.map { m in
                switch m.role {
                case "system": .system(m.content)
                case "assistant": .assistant(m.content)
                default: .user(m.content)
                }
            }
            let input = try await context.processor.prepare(input: UserInput(chat: chat, additionalContext: additional))
            var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
            var collector = TextCollector()
            var firstMs: Double?
            let info = try MLXLMCommon.generate(input: input, parameters: parameters, context: context) { token in
                if Task.isCancelled { return .stop }
                detokenizer.append(token: token)
                guard let piece = detokenizer.next(), !piece.isEmpty else { return .more }
                if firstMs == nil { firstMs = monotonicMs() - started }
                let more = collector.add(piece)
                if more { onDelta(piece) }
                return more ? .more : .stop
            }
            Memory.clearCache()
            return (collector, firstMs, info)
        }
        try Task.checkCancellation()
        let (collector, firstMs, info) = outcome
        let finish = info.stopReason == .length && !collector.looped ? Finish.length : Finish.stop
        return ChatOutcome(
            text: collector.text, finish: finish,
            usage: Usage(promptTokens: info.promptTokenCount, completionTokens: info.generationTokenCount),
            promptMs: info.promptTime * 1000, firstTokenMs: firstMs ?? monotonicMs() - started,
            tokensPerSecond: info.generateTime > 0 ? Double(max(0, info.generationTokenCount - 1)) / info.generateTime : 0
        )
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
