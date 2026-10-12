/// Optional fixture validation through the explicit batch model owner.
#if os(macOS) && VOXT_OMNI_XPC_VALIDATION
import Foundation
import OmniXPCContracts

@MainActor
enum OmniXPCSmokeBatchValidation {
    private static var retainedOwner: OmniXPCBatchModelOwner?
    static var hasRetainedOwner: Bool { retainedOwner != nil }

    nonisolated static func kind(environment: [String: String]) throws -> OmniXPCBatchKind? {
        let fields = ["VOXT_OMNI_XPC_SMOKE_BATCH_KIND", "VOXT_OMNI_XPC_SMOKE_BATCH_MODEL_SOURCE",
                      "VOXT_OMNI_XPC_SMOKE_BATCH_EXPECTED_SOURCE"]
        let supplied = fields.compactMap { environment[$0] }
        if supplied.isEmpty {
            return nil
        } else {
            guard supplied.count == fields.count, supplied.allSatisfy({ !$0.isEmpty }),
                  let number = Int(supplied[0]), String(number) == supplied[0],
                  let kind = OmniXPCBatchKind(rawValue: number) else {
                throw OmniXPCFailure.error(.invalidRequest, "Batch smoke requires kind 1...6, model source and expected source.")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: supplied[1], isDirectory: &isDirectory), isDirectory.boolValue else {
                throw OmniXPCFailure.error(.invalidRequest, "The batch model source must be an existing directory.")
            }
            _ = try expectedText(at: URL(fileURLWithPath: supplied[2]))
            return kind
        }
    }

    nonisolated static func expectedText(at file: URL) throws -> String {
        let maximumByteCount = 65_536
        let values = try file.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw OmniXPCFailure.error(.invalidRequest, "The batch expected transcript must be a regular file.")
        }
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var bytes = Data()
        while bytes.count <= maximumByteCount {
            let chunk = try reader.read(upToCount: maximumByteCount + 1 - bytes.count) ?? Data()
            if chunk.isEmpty { break } else { bytes.append(chunk) }
        }
        guard bytes.count <= maximumByteCount, let text = String(data: bytes, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OmniXPCFailure.error(.invalidRequest, "The batch expected transcript must be nonempty UTF-8, at most 65536 bytes.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func run(
        client: OmniXPCClient, kind: OmniXPCBatchKind?, container: URL, identifier: UUID,
        audio: Data, timeout: Duration
    ) async throws {
        guard let kind else { return }
        guard retainedOwner == nil else {
            throw OmniXPCFailure.error(.invalidRequest, "The previous batch owner still requires checked retirement.")
        }
        let modelDirectory = try OmniXPCRequestValidation.modelDirectory(
            relativePath: "Models/OmniXPCBatchSmoke/\(identifier.uuidString)", container: container
        )
        let root = container.resolvingSymlinksInPath().standardizedFileURL
        let expectedFile = root.appendingPathComponent("OmniXPCSmoke/\(identifier.uuidString)/batch-expected.txt")
            .resolvingSymlinksInPath().standardizedFileURL
        guard expectedFile.path.hasPrefix(root.path + "/") else {
            throw OmniXPCFailure.error(.invalidRequest, "The batch expected transcript escapes the shared container.")
        }
        let expected = try expectedText(at: expectedFile)
        _ = try OmniXPCRequestValidation.audioSamples(audio: audio, maximumSampleCount: OmniXPCProtocolLimits.maximumSampleCount)
        let owner = OmniXPCBatchModelOwner(
            client: client, kind: kind, modelDirectory: modelDirectory, coordinator: .shared, workClass: .fileASR
        )
        retainedOwner = owner
        do {
            try await owner.prepare(timeout: timeout)
            for _ in 0..<2 {
                let result = try await owner.transcribe(audio: audio, settings: .defaults(for: kind), timeout: timeout)
                // note (assistant): Automatic decode budgets can exhaust too; a matching truncated fixture must not pass.
                guard result.text.trimmingCharacters(in: .whitespacesAndNewlines) == expected, result.finishReason == .stop else {
                    throw OmniXPCFailure.error(.nativeFailure, "The batch smoke transcript did not match its fixture or hit the token limit.")
                }
            }
        } catch {
            try await owner.close(timeout: timeout)
            retainedOwner = nil
            throw error
        }
        try await owner.close(timeout: timeout)
        retainedOwner = nil
    }
}
#endif
