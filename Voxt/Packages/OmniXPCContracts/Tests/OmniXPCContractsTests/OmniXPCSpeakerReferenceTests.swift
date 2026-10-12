import Foundation
import OmniXPCContracts
import XCTest

nonisolated enum SpeakerTestValues {
    static func model(_ kind: OmniXPCSpeakerKind = .moss) throws -> OmniXPCSpeakerModelReference {
        try OmniXPCSpeakerModelReference(kind: kind, modelID: UUID(), serviceInstanceID: UUID(),
                                         connectionID: UUID(), loadOperationID: UUID())
    }

    static func session(_ kind: OmniXPCSpeakerKind = .moss) throws -> OmniXPCSpeakerSessionReference {
        try OmniXPCSpeakerSessionReference(sessionID: UUID(), model: model(kind))
    }

    static func segment(text: String = "", speaker: String? = nil, language: String? = nil,
                        emotion: String? = nil, event: String? = nil) throws -> OmniXPCBatchSegment {
        try OmniXPCBatchSegment(startSeconds: 0.123456789012345, endSeconds: 1.23456789012345,
                               text: text, speaker: speaker, language: language, emotion: emotion, event: event)
    }
}

final class OmniXPCSpeakerReferenceTests: XCTestCase {
    func testBothFamilyScopesAndAcknowledgementsRoundTrip() throws {
        for kind in OmniXPCSpeakerKind.allCases {
            let model = try SpeakerTestValues.model(kind)
            let session = try OmniXPCSpeakerSessionReference(sessionID: UUID(), model: model)
            XCTAssertEqual(try OmniXPCSpeakerModelReference.decode(model.encoded()), model)
            XCTAssertEqual(try OmniXPCSpeakerSessionReference.decode(session.encoded()), session)
            for audioSequence in [UInt64(1), UInt64(Int64.max) + 1, UInt64.max] {
                let acknowledgement = try OmniXPCSpeakerAudioAcknowledgement(session: session, audioSequence: audioSequence)
                XCTAssertEqual(try OmniXPCSpeakerAudioAcknowledgement.decode(acknowledgement.encoded()), acknowledgement)
            }
            XCTAssertThrowsError(try OmniXPCSpeakerAudioAcknowledgement(session: session, audioSequence: 0))
            let same = try OmniXPCSpeakerModelReference(kind: kind, modelID: model.modelID,
                                                       serviceInstanceID: model.serviceInstanceID,
                                                       connectionID: model.connectionID, loadOperationID: model.loadOperationID)
            XCTAssertEqual(same, model)
        }
    }

    func testEachOwnerFieldParticipatesInIdentityAndMustBeValidNonzeroUUID() throws {
        let model = try SpeakerTestValues.model()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: model.encoded()) as? [String: Any])
        for field in ["modelID", "serviceInstanceID", "connectionID", "loadOperationID"] {
            var changed = original
            changed[field] = UUID().uuidString
            XCTAssertNotEqual(try OmniXPCSpeakerModelReference.decode(JSONSerialization.data(withJSONObject: changed)), model)
            for invalid: Any in ["bad", "00000000-0000-0000-0000-000000000000", "1", 1, NSNull(), "\0"] {
                changed[field] = invalid
                XCTAssertThrowsError(try OmniXPCSpeakerModelReference.decode(JSONSerialization.data(withJSONObject: changed)), field)
            }
            changed.removeValue(forKey: field)
            XCTAssertThrowsError(try OmniXPCSpeakerModelReference.decode(JSONSerialization.data(withJSONObject: changed)), field)
        }
        var otherFamily = original
        otherFamily["kind"] = 2
        XCTAssertNotEqual(try OmniXPCSpeakerModelReference.decode(JSONSerialization.data(withJSONObject: otherFamily)), model)
        let zero = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        XCTAssertThrowsError(try OmniXPCSpeakerModelReference(kind: .moss, modelID: zero, serviceInstanceID: UUID(),
                                                            connectionID: UUID(), loadOperationID: UUID()))
        XCTAssertThrowsError(try OmniXPCSpeakerSessionReference(sessionID: zero, model: model))
        let session = try OmniXPCSpeakerSessionReference(sessionID: UUID(), model: model)
        let wire = String(decoding: try session.encoded(), as: UTF8.self)
        for invalid in ["not-a-uuid", zero.uuidString, "18446744073709551615"] {
            XCTAssertThrowsError(try OmniXPCSpeakerSessionReference.decode(Data(wire.replacingOccurrences(
                of: session.sessionID.uuidString, with: invalid).utf8)))
        }
    }

    func testStrictReferenceAndNativeUnsignedAcknowledgementFields() throws {
        let session = try SpeakerTestValues.session(.nemotron)
        let acknowledgement = try OmniXPCSpeakerAudioAcknowledgement(session: session, audioSequence: 1)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: acknowledgement.encoded()) as? [String: Any])
        for invalid: Any in [0, -1, true, 1.5, "1", NSNull()] {
            var changed = original
            changed["audioSequence"] = invalid
            XCTAssertThrowsError(try OmniXPCSpeakerAudioAcknowledgement.decode(JSONSerialization.data(withJSONObject: changed)))
        }
        let wire = "{\"session\":\(String(decoding: try session.encoded(), as: UTF8.self)),\"audioSequence\":18446744073709551616}"
        XCTAssertThrowsError(try OmniXPCSpeakerAudioAcknowledgement.decode(Data(wire.utf8)))
        for field in ["session", "audioSequence"] {
            var missing = original
            missing.removeValue(forKey: field)
            XCTAssertThrowsError(try OmniXPCSpeakerAudioAcknowledgement.decode(JSONSerialization.data(withJSONObject: missing)))
        }
        var unknown = original
        unknown["nativeSessionID"] = 1
        XCTAssertThrowsError(try OmniXPCSpeakerAudioAcknowledgement.decode(JSONSerialization.data(withJSONObject: unknown)))
        let model = try SpeakerTestValues.model()
        let modelWire = String(decoding: try model.encoded(), as: UTF8.self)
        for kind in ["0", "3", "2147483648", "true", "null", "\"moss\""] {
            XCTAssertThrowsError(try OmniXPCSpeakerModelReference.decode(Data(modelWire.replacingOccurrences(
                of: "\"kind\":1", with: "\"kind\":\(kind)").utf8)))
        }
        XCTAssertThrowsError(try OmniXPCSpeakerSessionReference.decode(Data("{\"sessionID\":\"\(UUID())\",\"model\":null}".utf8)))
    }

    func testReferenceAndAcknowledgementByteAdmissionAndMalformedJSON() throws {
        let session = try SpeakerTestValues.session()
        let acknowledgement = try OmniXPCSpeakerAudioAcknowledgement(session: session, audioSequence: 1)
        var modelBytes = try session.model.encoded()
        var sessionBytes = try session.encoded()
        var acknowledgementBytes = try acknowledgement.encoded()
        let limit = OmniXPCSpeakerLimits.maximumReferenceByteCount
        modelBytes.append(Data(repeating: 32, count: limit - modelBytes.count))
        sessionBytes.append(Data(repeating: 32, count: limit - sessionBytes.count))
        acknowledgementBytes.append(Data(repeating: 32, count: limit - acknowledgementBytes.count))
        XCTAssertEqual(try OmniXPCSpeakerModelReference.decode(modelBytes), session.model)
        XCTAssertEqual(try OmniXPCSpeakerSessionReference.decode(sessionBytes), session)
        XCTAssertEqual(try OmniXPCSpeakerAudioAcknowledgement.decode(acknowledgementBytes), acknowledgement)
        for invalid in [Data(), Data("null".utf8), Data("{}".utf8), Data("[]".utf8), Data([0xFF]),
                        Data(repeating: 32, count: limit + 1)] {
            XCTAssertThrowsError(try OmniXPCSpeakerModelReference.decode(invalid))
            XCTAssertThrowsError(try OmniXPCSpeakerSessionReference.decode(invalid))
            XCTAssertThrowsError(try OmniXPCSpeakerAudioAcknowledgement.decode(invalid))
        }
    }

    func testNativeClosedStatusAndKindNumbersAndAudioLimits() throws {
        XCTAssertEqual(OmniXPCSpeakerKind.allCases.map(\.rawValue), [1, 2])
        XCTAssertEqual(OmniXPCSpeakerStatus.allCases.map(\.rawValue), [0, 1, 2, 3, 4, 5, 6])
        for status in OmniXPCSpeakerStatus.allCases {
            XCTAssertEqual(try JSONDecoder().decode(OmniXPCSpeakerStatus.self, from: JSONEncoder().encode(status)), status)
        }
        for rawValue in [-1, 7, Int32.max] { XCTAssertNil(OmniXPCSpeakerStatus(rawValue: rawValue)) }
        XCTAssertEqual(OmniXPCSpeakerLimits.sampleRate, 16_000)
        XCTAssertEqual(OmniXPCSpeakerLimits.maximumChunkSampleCount, 32_000)
        XCTAssertEqual(OmniXPCSpeakerLimits.maximumSessionSampleCount, 480_000)
    }
}
