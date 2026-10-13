#if OMNI_XPC_PORTABLE_TESTS && os(Linux)
import Foundation
import OmniXPCContracts

@MainActor
public final class NSXPCInterface {
    public init(with protocolType: (any OmniInferenceXPCProtocol).Type) {}
}

@MainActor
public final class NSXPCConnection {
    public static var setup: ((NSXPCConnection) -> Void)?
    public var exportedObject: (any OmniInferenceXPCProtocol)?
    public var remoteObjectInterface: NSXPCInterface?
    public var interruptionHandler: (@Sendable () -> Void)?
    public var invalidationHandler: (@Sendable () -> Void)?
    public init(serviceName: String) { Self.setup?(self) }
    public func setCodeSigningRequirement(_ requirement: String) {}
    public func resume() {}
    public func invalidate() { invalidationHandler?() }
    public func remoteObjectProxyWithErrorHandler(_ errorHandler: @escaping @Sendable (Error) -> Void) -> (any OmniInferenceXPCProtocol)? {
        exportedObject
    }
}

extension FileManager {
    public func containerURL(forSecurityApplicationGroupIdentifier identifier: String) -> URL? {
        guard let root = ProcessInfo.processInfo.environment["SILERO_OWNER_TEST_ROOT"] else { return nil }
        let directory = URL(fileURLWithPath: root).appendingPathComponent("containers/" + identifier)
        do {
            try createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch { return nil }
    }
}

extension ProcessInfo {
    enum ThermalState: Int, Sendable { case nominal, fair, serious, critical }
    var thermalState: ThermalState { .nominal }
}

enum MeetingFileInferenceCache {
    static func trimIfNeeded(underPressure: Bool) {}
    static func beginWorkUnit() -> @Sendable () -> Void { {} }
}

enum MeetingMemoryPressureMonitor {
    static func currentFileConstraint() -> Bool? { nil }
}

enum VoxtLog {
    static func meeting(_ message: String) {}
    static func meetingWarning(_ message: String) {}
}

enum MeetingFileTaskContext {
    @TaskLocal static var taskID: UUID?
}

extension Notification.Name {
    static let voxtMeetingFileResourceWaitDidChange = Notification.Name("SileroOwnerFileResourceWait")
}

@MainActor final class OmniXPCRealtimeClientState {}
@MainActor final class OmniXPCSortformerStreamState {}
@MainActor final class OmniXPCSortformerModelState {}
struct OmniXPCSortformerLoadState: Sendable {}
struct OmniXPCSortformerLoadCleanup: Sendable {}
@MainActor final class OmniXPCBatchLoadState {}
@MainActor final class OmniXPCSpeakerLoadState {}
#endif
