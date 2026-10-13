import Foundation
import OmniXPCContracts

#if os(macOS)
@MainActor
final class OmniXPCSileroLoadOwnership {
    enum Phase: Equatable {
        case notSubmitted
        case submitted(connectionID: UUID)
        case drained
    }

    let operationID: UUID
    private weak var originalClient: OmniXPCClient?
    private(set) var phase: Phase = .notSubmitted

    init(client: OmniXPCClient, operationID: UUID = UUID()) {
        originalClient = client
        self.operationID = operationID
    }

    func requireClient(_ client: OmniXPCClient) throws {
        guard originalClient === client else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero load ticket belongs to another client.")
        }
    }

    func markSubmitted(client: OmniXPCClient, connectionID: UUID) throws {
        try requireClient(client)
        guard phase == .notSubmitted else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero load ticket has already been submitted.")
        }
        phase = .submitted(connectionID: connectionID)
    }

    func markDrained(client: OmniXPCClient, connectionID: UUID) throws {
        try requireClient(client)
        guard phase == .submitted(connectionID: connectionID) else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero drain does not match the original load connection.")
        }
        phase = .drained
    }
}

nonisolated struct OmniXPCSileroModelDirectory: Sendable {
    let directory: URL
    let relativePath: String
    let container: URL
}

extension OmniXPCClient {
    func authorizedSileroModelDirectory(_ modelDirectory: URL) throws -> OmniXPCSileroModelDirectory {
        guard modelDirectory.isFileURL,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier
              ) else {
            throw OmniXPCFailure.error(.configuration, "Silero requires a model in the configured shared container.")
        }
        let containerPath = container.resolvingSymlinksInPath().standardizedFileURL.path
        let directoryPath = modelDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard directoryPath.hasPrefix(containerPath + "/") else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero model is outside the shared container.")
        }
        let relativePath = String(directoryPath.dropFirst(containerPath.count + 1))
        let directory = try OmniXPCRequestValidation.modelDirectory(relativePath: relativePath, container: container)
        return OmniXPCSileroModelDirectory(directory: directory, relativePath: relativePath, container: container)
    }

    func retireSileroLoad(_ ticket: OmniXPCSileroLoadOwnership, timeout: Duration) async throws {
        try ticket.requireClient(self)
        switch ticket.phase {
        case .notSubmitted, .drained:
            return
        case .submitted(let connectionID):
            guard connectionIdentifier == connectionID else {
                throw OmniXPCFailure.error(.disconnected, "The originating Silero connection is unavailable; cleanup is not confirmed.")
            }
            if let state = sileroModel, state.loadOwnership === ticket {
                try await closeSileroModel(state.reference, timeout: timeout)
            } else if let pending = pendingSileroLoad, pending.ownership === ticket {
                try await closePendingSileroLoad(timeout: timeout, requiredOperationID: ticket.operationID)
            } else {
                throw OmniXPCFailure.error(.invalidRequest, "The submitted Silero load has no matching retirement scope.")
            }
            guard ticket.phase == .drained else {
                throw OmniXPCFailure.error(.nativeFailure, "The Silero original load has no confirmed retirement.")
            }
        }
    }
}
#endif
