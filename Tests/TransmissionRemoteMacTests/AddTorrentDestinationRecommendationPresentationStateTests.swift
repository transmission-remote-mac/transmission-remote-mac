// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class AddTorrentDestinationRecommendationPresentationStateTests: XCTestCase {
    func testRequestSuggestionHasPrecedenceAndCanOnlyBeReappliedExplicitly() {
        var state = AddTorrentDestinationRecommendationPresentationState(
            requestSuggestedDestination: "/watch/incoming"
        )

        XCTAssertFalse(state.beginEvaluation(id: UUID()))
        XCTAssertEqual(
            state.status,
            .presenting(.requestSuggested(destination: "/watch/incoming"))
        )

        let userEnteredDestination = "/user/typed"
        XCTAssertEqual(
            state.destinationAfterExplicitApply(currentDestination: userEnteredDestination),
            "/watch/incoming"
        )
        XCTAssertEqual(state.destinationAfterResetToDaemonDefault(), "")
    }

    func testStaleEvaluationCannotReplaceCurrentPresentation() {
        var state = AddTorrentDestinationRecommendationPresentationState(
            requestSuggestedDestination: nil
        )
        let staleID = UUID()
        let currentID = UUID()
        XCTAssertTrue(state.beginEvaluation(id: staleID))
        XCTAssertTrue(state.beginEvaluation(id: currentID))

        let recommendation = AddTorrentDestinationRecommendation(
            destination: "/video",
            provenance: .profileDefault
        )
        XCTAssertFalse(
            state.completeEvaluation(
                id: staleID,
                result: .recommendation(recommendation)
            )
        )
        XCTAssertEqual(state.status, .resolving)

        XCTAssertTrue(
            state.completeEvaluation(
                id: currentID,
                result: .recommendation(recommendation)
            )
        )
        XCTAssertEqual(state.status, .presenting(.resolved(recommendation)))
    }

    func testCancellationClearsResolvedRecommendationAndPreservesExplicitDraftResult() {
        var state = AddTorrentDestinationRecommendationPresentationState(
            requestSuggestedDestination: nil
        )
        let evaluationID = UUID()
        let userEnteredDestination = "/user/typed"
        XCTAssertTrue(state.beginEvaluation(id: evaluationID))
        XCTAssertTrue(
            state.completeEvaluation(
                id: evaluationID,
                result: .recommendation(
                    AddTorrentDestinationRecommendation(
                        destination: "/recommended",
                        provenance: .profileDefault
                    )
                )
            )
        )

        state.cancelEvaluation()
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(
            state.destinationAfterExplicitApply(currentDestination: userEnteredDestination),
            userEnteredDestination
        )
    }
}
