#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
@testable import Voxt

nonisolated final class OmniXPCSpeakerTestPeer: OmniInferenceXPCProtocol {
    let base: OmniXPCBatchTestPeer
    var holdLoadReply = false, holdStartReply = false, holdPushReply = false
    var holdFinishReply = false, holdPollReply = false, holdDrain = false, holdClose = false
    var loadBytes: Data?, startBytes: Data?, pushBytes: Data?, pollBytes: Data?
    var drainFailure: NSError?, closeFailure: NSError?
    private(set) var model: OmniXPCSpeakerModelReference?
    private(set) var session: OmniXPCSpeakerSessionReference?
    private(set) var loadOperations: [String] = []
    private(set) var drainOperations: [String] = []
    private(set) var startSessions: [String] = []
    private(set) var settings: [OmniXPCSpeakerSettings] = []
    private(set) var audioSequences: [UInt64] = []
    private(set) var audioChunks: [Data] = []
    private(set) var pollAcknowledgements: [UInt64] = []
    private(set) var closedSessions: [OmniXPCSpeakerSessionReference] = []
    private(set) var cancellations: [(requestID: String, modelID: String?)] = []
    private(set) var commitCount = 0, finishCount = 0, acknowledgedDrains = 0, acknowledgedCloses = 0
    private(set) var controlledLoadActive = false, controlledStartActive = false, controlledWorkActive = false
    var events: [OmniXPCSpeakerEvent] = []
    var removesAcknowledgedEvents = false
    var completionText: String?
    var completionSegments: [OmniXPCBatchSegment] = []
    private var loadReply: (@Sendable (Data?, NSError?) -> Void)?
    private var startReply: (@Sendable (Data?, NSError?) -> Void)?
    private var pushReply: (@Sendable (Data?, NSError?) -> Void)?
    private var finishReply: (@Sendable (NSError?) -> Void)?
    private var pollReply: (@Sendable (Data?, NSError?) -> Void)?
    private var drainReplies: [@Sendable (NSError?) -> Void] = []
    private var closeReplies: [@Sendable (NSError?) -> Void] = []
    private var checkedClosedSession: OmniXPCSpeakerSessionReference?

    init(base: OmniXPCBatchTestPeer) { self.base = base }

    func loadSpeaker(operationID: String, kind: Int, modelDirectory: String, clientConnectionID: String,
                     withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        loadOperations.append(operationID)
        model = try! OmniXPCSpeakerModelReference(kind: OmniXPCSpeakerKind(rawValue: Int32(kind))!,
            modelID: UUID(), serviceInstanceID: base.serviceInstanceID,
            connectionID: UUID(uuidString: clientConnectionID)!, loadOperationID: UUID(uuidString: operationID)!)
        controlledLoadActive = holdLoadReply
        loadReply = reply
        if !holdLoadReply { completeLoad() }
    }

    func completeLoad() {
        controlledLoadActive = false
        let reply = loadReply
        loadReply = nil
        reply?(loadBytes ?? (try! model!.encoded()), nil)
        releaseBarriers()
    }

    func startSpeakerSession(sessionID: String, modelReference: Data, settings: Data,
                             withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        startSessions.append(sessionID)
        self.settings.append(try! OmniXPCSpeakerSettings.decode(settings))
        session = try! OmniXPCSpeakerSessionReference(sessionID: UUID(uuidString: sessionID)!,
            model: OmniXPCSpeakerModelReference.decode(modelReference))
        controlledStartActive = holdStartReply
        startReply = reply
        if !holdStartReply { completeStart() }
    }

    func completeStart() {
        controlledStartActive = false
        let reply = startReply
        startReply = nil
        reply?(startBytes ?? (try! session!.encoded()), nil)
        releaseBarriers()
    }

    func pushSpeakerAudio(sessionReference: Data, audioSequence: UInt64, audio: Data,
                          withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        let reference = try! OmniXPCSpeakerSessionReference.decode(sessionReference)
        precondition(reference == session)
        audioSequences.append(audioSequence)
        audioChunks.append(audio)
        controlledWorkActive = true
        pushReply = reply
        if !holdPushReply { acknowledgePush() }
    }

    func acknowledgePush() {
        let reply = pushReply
        pushReply = nil
        let acknowledgement = try! OmniXPCSpeakerAudioAcknowledgement(session: session!, audioSequence: audioSequences.last!)
        reply?(pushBytes ?? (try! acknowledgement.encoded()), nil)
    }

    func commitSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        precondition(try! OmniXPCSpeakerSessionReference.decode(sessionReference) == session)
        commitCount += 1
        reply(nil)
    }

    func finishSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        precondition(try! OmniXPCSpeakerSessionReference.decode(sessionReference) == session)
        finishCount += 1
        if let completionText {
            events.append(try! OmniXPCSpeakerEvent(session: session!,
                eventSequence: (events.last?.eventSequence ?? pollAcknowledgements.last ?? 0) + 1,
                kind: .completed, text: completionText, segments: completionSegments))
        }
        finishReply = reply
        if !holdFinishReply { acknowledgeFinish() }
    }

    func acknowledgeFinish() { let reply = finishReply; finishReply = nil; reply?(nil) }

    func pollSpeakerEvents(sessionReference: Data, acknowledgedEventSequence: UInt64, maximumEventCount: Int,
                           withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        precondition(try! OmniXPCSpeakerSessionReference.decode(sessionReference) == session)
        pollAcknowledgements.append(acknowledgedEventSequence)
        if removesAcknowledgedEvents { events.removeAll { $0.eventSequence <= acknowledgedEventSequence } }
        pollReply = reply
        if !holdPollReply { deliverPoll() }
    }

    func deliverPoll() {
        let reply = pollReply
        pollReply = nil
        let batch = try! OmniXPCSpeakerBatch(session: session!, events: events,
            isDrained: checkedClosedSession == session && events.isEmpty)
        reply?(pollBytes ?? (try! batch.encoded()), nil)
    }

    func closeSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        let reference = try! OmniXPCSpeakerSessionReference.decode(sessionReference)
        closedSessions.append(reference)
        if let closeFailure { reply(closeFailure) }
        else { closeReplies.append(reply); releaseBarriers() }
    }

    func drainSpeakerLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        drainOperations.append(operationID)
        guard operationID == model?.loadOperationID.uuidString else {
            return reply(OmniXPCFailure.error(.invalidRequest, "Drain must target the original load"))
        }
        if let drainFailure { reply(drainFailure) }
        else { drainReplies.append(reply); releaseBarriers() }
    }

    func unloadSpeaker(operationID: String, modelReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        precondition(try! OmniXPCSpeakerModelReference.decode(modelReference) == model)
        drainSpeakerLoad(operationID: model!.loadOperationID.uuidString, withReply: reply)
    }

    func cancelSpeakerRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        cancellations.append((requestID, modelID))
        reply(nil)
    }

    func completeControlledWork() {
        controlledWorkActive = false
        releaseBarriers()
    }

    func releaseBarriers() {
        // note (guanwei): Presentation and cancellation ACKs cannot retire controlled asynchronous work.
        guard !controlledLoadActive, !controlledStartActive, !controlledWorkActive else { return }
        if !holdClose {
            let replies = closeReplies
            closeReplies.removeAll()
            if !replies.isEmpty { checkedClosedSession = session }
            acknowledgedCloses += replies.count
            for reply in replies { reply(nil) }
        }
        if !holdDrain {
            let replies = drainReplies
            drainReplies.removeAll()
            acknowledgedDrains += replies.count
            for reply in replies { reply(nil) }
        }
    }
}
#endif
