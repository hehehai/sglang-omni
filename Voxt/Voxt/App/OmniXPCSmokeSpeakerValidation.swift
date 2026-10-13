#if os(macOS) && VOXT_OMNI_XPC_VALIDATION
import Foundation
import OmniXPCContracts

@MainActor
enum OmniXPCSmokeSpeakerValidation {
    private static var retainedOwner: OmniXPCSpeakerModelOwner?
    private static var retainedSession: OmniXPCSpeakerStreamingSession?
    static var hasRetainedOwner: Bool { retainedOwner != nil || retainedSession != nil }

    nonisolated static func kind(environment: [String: String]) throws -> OmniXPCSpeakerKind? {
        let fields = ["VOXT_OMNI_XPC_SMOKE_SPEAKER_KIND", "VOXT_OMNI_XPC_SMOKE_SPEAKER_MODEL_SOURCE",
                      "VOXT_OMNI_XPC_SMOKE_SPEAKER_EXPECTED_SOURCE"]
        let supplied = fields.compactMap { environment[$0] }
        if supplied.isEmpty { return nil }
        guard supplied.count == fields.count, supplied.allSatisfy({ !$0.isEmpty }),
              let number = Int32(supplied[0]), String(number) == supplied[0],
              let kind = OmniXPCSpeakerKind(rawValue: number) else {
            throw OmniXPCFailure.error(.invalidRequest, "Speaker smoke requires kind 1...2, model source and expected source.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: supplied[1], isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker model source must be an existing directory.")
        }
        _ = try OmniXPCSmokeBatchValidation.expectedText(at: URL(fileURLWithPath: supplied[2]))
        return kind
    }

    static func run(client: OmniXPCClient, kind: OmniXPCSpeakerKind?, container: URL, identifier: UUID,
                    samples: [Float], timeout: Duration) async throws {
        guard let kind else { return }
        guard !hasRetainedOwner else {
            throw OmniXPCFailure.error(.busy, "The previous speaker consumer still requires checked retirement.")
        }
        let directory = try OmniXPCRequestValidation.modelDirectory(
            relativePath: "Models/OmniXPCSpeakerSmoke/\(identifier.uuidString)", container: container
        )
        let root = container.resolvingSymlinksInPath().standardizedFileURL
        let expectedFile = root.appendingPathComponent("OmniXPCSmoke/\(identifier.uuidString)/speaker-expected.txt")
            .resolvingSymlinksInPath().standardizedFileURL
        guard expectedFile.path.hasPrefix(root.path + "/") else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker fixture escapes its shared container.")
        }
        let expected = try OmniXPCSmokeBatchValidation.expectedText(at: expectedFile)
        guard !samples.isEmpty, samples.count <= OmniXPCSpeakerLimits.maximumSessionSampleCount,
              samples.allSatisfy(\.isFinite) else {
            throw OmniXPCFailure.error(.invalidRequest, "Speaker smoke accepts finite mono16k input up to thirty seconds.")
        }
        let owner = OmniXPCSpeakerModelOwner(client: client, kind: kind, modelDirectory: directory)
        retainedOwner = owner
        do {
            try await owner.prepare(timeout: timeout)
            let stream = try await OmniXPCSpeakerStreamingSession.open(
                owner: owner, settings: .defaults(for: kind), requestTimeout: timeout, cleanupTimeout: timeout
            )
            retainedSession = stream
            let session: any ASRStreamingSession = stream
            let feeding = Task {
                do {
                    for offset in stride(from: 0, to: samples.count, by: OmniXPCProtocolLimits.sampleRate) {
                        try Task.checkCancellation()
                        let end = min(offset + OmniXPCProtocolLimits.sampleRate, samples.count)
                        session.feedAudio(samples: Array(samples[offset..<end]))
                        try await Task.sleep(for: .seconds(1))
                    }
                    session.stop()
                } catch { session.cancel() }
            }
            let deadline = Task {
                do { try await Task.sleep(for: timeout + .seconds(OmniXPCProtocolLimits.maximumAudioSeconds)) }
                catch { return }
                session.cancel()
            }
            defer { feeding.cancel(); deadline.cancel(); session.cancel() }
            let lastEvent = try await stream.consumeEvents { event in
                switch event {
                case .displayUpdate: return true
                case .ended(let result):
                    guard result.text.trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
                        throw OmniXPCFailure.error(.nativeFailure, "The speaker streaming transcript did not match its explicit fixture.")
                    }
                    return false
                case .failed(let failure): throw failure
                }
            }
            guard case .ended = lastEvent, owner.isClosed else {
                throw OmniXPCFailure.error(.nativeFailure, "The speaker consumer did not produce a checked closed result.")
            }
        } catch {
            try await retainedSession?.closeAndWait()
            try await owner.close(timeout: timeout)
            retainedSession = nil
            retainedOwner = nil
            throw error
        }
        retainedSession = nil
        retainedOwner = nil
    }
}
#endif
