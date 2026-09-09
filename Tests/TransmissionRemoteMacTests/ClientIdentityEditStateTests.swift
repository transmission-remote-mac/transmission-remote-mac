// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class ClientIdentityEditStateTests: XCTestCase {
    func testSharedAcknowledgmentDoesNotMutateEarlierSnapshots() {
        let pending = PendingClientIdentityImport(sourceFileName: "identity.p12", pkcs12Data: Data([1]))
        let state = ClientIdentityEditState(pendingImport: pending)
        let profile = ConnectionProfile(name: "Server", scheme: "https", host: "server.example", clientIdentityEditState: state)
        let copiedProfile = profile
        let before = state.snapshot
        let metadata = makeMetadata()

        state.markApplied(metadata: metadata)

        XCTAssertEqual(before.pendingImport, pending)
        XCTAssertFalse(before.didApply)
        XCTAssertNil(before.appliedMetadata)
        XCTAssertNil(state.snapshot.pendingImport)
        XCTAssertTrue(state.snapshot.didApply)
        XCTAssertEqual(profile.effectiveClientIdentityMetadata, metadata)
        XCTAssertEqual(copiedProfile.clientIdentityMetadataForTransport, metadata)
        let draft = ConnectionProfileDraft(profile: copiedProfile)
        XCTAssertNil(draft.pendingClientIdentityImport)
        XCTAssertEqual(draft.clientIdentityMetadata, metadata)
    }

    func testConcurrentAcknowledgmentsPublishCompleteSnapshots() {
        let pending = PendingClientIdentityImport(sourceFileName: "identity.p12", pkcs12Data: Data([1]))
        let state = ClientIdentityEditState(pendingImport: pending)
        let metadata = makeMetadata()

        DispatchQueue.concurrentPerform(iterations: 1_000) { iteration in
            if iteration.isMultiple(of: 3) {
                state.markApplied(metadata: iteration.isMultiple(of: 2) ? metadata : nil)
            }
            let snapshot = state.snapshot
            XCTAssertFalse(snapshot.removeOnApply)
            if snapshot.didApply {
                XCTAssertNil(snapshot.pendingImport)
                XCTAssertTrue(snapshot.appliedMetadata == nil || snapshot.appliedMetadata == metadata)
            } else {
                XCTAssertEqual(snapshot.pendingImport, pending)
                XCTAssertNil(snapshot.appliedMetadata)
            }
        }
    }

    private func makeMetadata() -> ClientIdentityMetadata {
        ClientIdentityMetadata(
            displayName: "Test identity",
            sha256Fingerprint: String(repeating: "a", count: 64),
            subject: "Test subject",
            issuer: "Test issuer",
            notBefore: Date(timeIntervalSince1970: 0),
            notAfter: Date(timeIntervalSince1970: 1_000)
        )
    }
}
