import Foundation
import OmniXPCContracts

#if VOXT_OMNI_XPC_VALIDATION
@MainActor
enum OmniXPCSmokeSileroValidation {
    private static var retainedOwner: OmniXPCSileroModelOwner?
    private static var retainedConsumer: OmniXPCASRVoiceActivityConsumer?
    static var hasRetainedOwner: Bool { retainedOwner != nil }

    static func run(client: OmniXPCClient, relativeModelDirectory: String, samples: [Float], timeout: Duration) async throws {
        guard retainedOwner == nil else {
            throw OmniXPCFailure.error(.busy, "The original Silero smoke scope still requires checked cleanup.")
        }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: client.configuration.appGroupIdentifier
        ) else {
            throw OmniXPCFailure.error(.configuration, "Silero smoke requires the configured shared container.")
        }
        let directory = try OmniXPCRequestValidation.modelDirectory(relativePath: relativeModelDirectory, container: container)
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory)
        var consumer: OmniXPCASRVoiceActivityConsumer?
        do {
            _ = try await owner.prepare(timeout: timeout, cleanupTimeout: timeout)
            let preparedConsumer = try OmniXPCASRVoiceActivityConsumer(owner: owner)
            consumer = preparedConsumer
            let settings = OmniXPCSileroSettings(
                threshold: 0.5, minimumSpeechMilliseconds: 250,
                minimumSilenceMilliseconds: 100, speechPaddingMilliseconds: 30
            )
            let first = try await preparedConsumer.speechTimestamps(samples16k: samples, settings: settings, timeout: timeout)
            let reused = try await preparedConsumer.speechTimestamps(samples16k: samples, settings: settings, timeout: timeout)
            guard first == reused else {
                throw OmniXPCFailure.error(.nativeFailure, "Silero same-model reuse returned inconsistent sample ranges.")
            }
            let stream = try await preparedConsumer.openStream(timeout: timeout)
            _ = try await preparedConsumer.probability(samples16k: samples, to: stream, timeout: timeout)
            _ = try await preparedConsumer.finishStream(stream, timeout: timeout)
            try await preparedConsumer.close(timeout: timeout)
        } catch {
            let cleanup = Task { @MainActor in
                if let consumer {
                    try await consumer.close(timeout: timeout)
                } else {
                    try await owner.close(timeout: timeout)
                }
            }
            do {
                try await cleanup.value
            } catch {
                retainedOwner = owner
                retainedConsumer = consumer
                throw error
            }
            throw error
        }
    }
}
#endif
