import MLXAudioVAD
import OmniModelArtifacts

nonisolated final class MeetingSortformerModelLease: @unchecked Sendable {
    private var ownedModel: SortformerModel?
    private var directoryLease: OmniModelDirectoryLease?

    var model: SortformerModel { ownedModel! }

    init(directoryLease: OmniModelDirectoryLease) throws {
        self.directoryLease = directoryLease
        ownedModel = try SortformerModel.fromModelDirectory(directoryLease.directory)
    }

    deinit {
        // Note (assistant): drop the model before releasing its cooperating directory reader.
        ownedModel = nil
        directoryLease = nil
    }
}
