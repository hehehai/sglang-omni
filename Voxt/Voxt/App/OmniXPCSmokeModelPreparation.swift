#if os(macOS) && VOXT_OMNI_XPC_VALIDATION
import Foundation
import OmniXPCContracts

extension AppDelegate {
    @MainActor
    static func prepareOmniSmokeModels(container: URL, identifier: UUID, environment: [String: String]) async throws {
        let batchKind = try OmniXPCSmokeBatchValidation.kind(environment: environment)
        let speakerKind = try OmniXPCSmokeSpeakerValidation.kind(environment: environment)
        var fixtures = [
            ("VOXT_OMNI_XPC_SMOKE_MODEL_SOURCE", "OmniXPCSmoke"),
            ("VOXT_OMNI_XPC_SMOKE_SILERO_SOURCE", "OmniXPCSileroSmoke"),
            ("VOXT_OMNI_XPC_SMOKE_SORTFORMER_SOURCE", "OmniXPCSortformerSmoke")
        ]
        if batchKind != nil {
            fixtures.append(("VOXT_OMNI_XPC_SMOKE_BATCH_MODEL_SOURCE", "OmniXPCBatchSmoke"))
        } else {}
        if speakerKind != nil {
            fixtures.append(("VOXT_OMNI_XPC_SMOKE_SPEAKER_MODEL_SOURCE", "OmniXPCSpeakerSmoke"))
        } else {}
        guard environment[fixtures[0].0] != nil else {
            throw OmniXPCFailure.error(.invalidRequest, "Model preparation requires an explicitly supplied source.")
        }
        let container = container.resolvingSymlinksInPath().standardizedFileURL
        let modelsRoot = container.appendingPathComponent("Models").resolvingSymlinksInPath().standardizedFileURL
        guard modelsRoot.path.hasPrefix(container.path + "/") else {
            throw OmniXPCFailure.error(.invalidRequest, "The shared Models root escapes its container.")
        }
        for (sourceKey, collection) in fixtures {
            guard let sourcePath = environment[sourceKey], !sourcePath.isEmpty else { continue }
            let destination = container.appendingPathComponent("Models/" + collection)
                .appendingPathComponent(identifier.uuidString)
            guard destination.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(modelsRoot.path + "/") else {
                throw OmniXPCFailure.error(.invalidRequest, "The preparation destination escapes shared Models.")
            }
            let outcome = try await ModelDiskOperations.prepareModelCopy(
                from: URL(fileURLWithPath: sourcePath), to: destination,
                validate: { staged in
                    let relativePath = "Models/" + collection + "/" + staged.lastPathComponent
                    _ = try OmniXPCRequestValidation.modelDirectory(relativePath: relativePath, container: container)
                }
            )
            _ = try OmniXPCRequestValidation.modelDirectory(
                relativePath: "Models/" + collection + "/" + outcome.directory.lastPathComponent, container: container
            )
        }
    }
}
#endif
