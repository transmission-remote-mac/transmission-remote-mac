// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum AddTorrentDestinationRecommendationPresentation: Equatable, Sendable {
    case requestSuggested(destination: String)
    case resolved(AddTorrentDestinationRecommendation)

    var destination: String {
        switch self {
        case .requestSuggested(let destination):
            destination
        case .resolved(let recommendation):
            recommendation.destination
        }
    }
}

enum AddTorrentDestinationRecommendationEvaluation: Equatable, Sendable {
    case recommendation(AddTorrentDestinationRecommendation?)
    case failed(String)
}

enum AddTorrentDestinationRecommendationPresentationStatus: Equatable, Sendable {
    case idle
    case resolving
    case presenting(AddTorrentDestinationRecommendationPresentation)
    case failed(String)
}

/// Owns the async recommendation presentation lifecycle without owning or
/// mutating the Add sheet's destination draft.
struct AddTorrentDestinationRecommendationPresentationState: Equatable, Sendable {
    private(set) var status: AddTorrentDestinationRecommendationPresentationStatus

    private let requestSuggestedDestination: String?
    private var evaluationID: UUID?

    init(requestSuggestedDestination: String?) {
        self.requestSuggestedDestination = requestSuggestedDestination
        if let requestSuggestedDestination {
            status = .presenting(.requestSuggested(destination: requestSuggestedDestination))
        } else {
            status = .idle
        }
    }

    @discardableResult
    mutating func beginEvaluation(id: UUID) -> Bool {
        guard requestSuggestedDestination == nil else { return false }
        evaluationID = id
        status = .resolving
        return true
    }

    @discardableResult
    mutating func completeEvaluation(
        id: UUID,
        result: AddTorrentDestinationRecommendationEvaluation
    ) -> Bool {
        guard evaluationID == id, requestSuggestedDestination == nil else { return false }
        evaluationID = nil
        switch result {
        case .recommendation(let recommendation):
            status = recommendation.map {
                .presenting(.resolved($0))
            } ?? .idle
        case .failed(let message):
            status = .failed(message)
        }
        return true
    }

    mutating func cancelEvaluation() {
        evaluationID = nil
        if let requestSuggestedDestination {
            status = .presenting(.requestSuggested(destination: requestSuggestedDestination))
        } else {
            status = .idle
        }
    }

    func destinationAfterExplicitApply(currentDestination: String) -> String {
        guard case .presenting(let presentation) = status else {
            return currentDestination
        }
        return presentation.destination
    }

    func destinationAfterResetToDaemonDefault() -> String {
        ""
    }
}
