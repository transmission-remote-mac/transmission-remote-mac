// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class AddTorrentDestinationRuleTests: XCTestCase {
    func testLargestMatchingByteTotalWinsAndDeclarationOrderBreaksTies() throws {
        let general = try rule(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            label: "Video",
            destination: "/downloads/video",
            extensions: ["avi"]
        )
        let highDefinition = try rule(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            label: "High definition",
            destination: "/downloads/hd",
            extensions: ["mkv"],
            nameTokens: ["1080p"]
        )
        let tiedHighDefinition = try rule(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003")),
            label: "Tied high definition",
            destination: "/downloads/other-hd",
            extensions: ["mkv"],
            nameTokens: ["1080p"]
        )
        let files = [
            AddTorrentDestinationCandidateFile(path: "show.720p.avi", sizeBytes: 100),
            AddTorrentDestinationCandidateFile(path: "show.1080p.mkv", sizeBytes: 900)
        ]

        let recommendation = try XCTUnwrap(
            AddTorrentDestinationRuleResolver.recommendation(
                rules: [general, highDefinition, tiedHighDefinition],
                defaultDestination: "/downloads/default",
                files: files
            )
        )

        XCTAssertEqual(recommendation.destination, "/downloads/hd")
        XCTAssertEqual(
            recommendation.provenance,
            .matchingRule(
                id: highDefinition.id,
                label: "High definition",
                declarationIndex: 1,
                matchedFileCount: 1,
                matchedBytes: 900
            )
        )

        let tieRecommendation = try XCTUnwrap(
            AddTorrentDestinationRuleResolver.recommendation(
                rules: [highDefinition, tiedHighDefinition],
                defaultDestination: nil,
                files: files
            )
        )
        XCTAssertEqual(tieRecommendation.destination, "/downloads/hd")
        XCTAssertEqual(
            tieRecommendation.provenance,
            .matchingRule(
                id: highDefinition.id,
                label: "High definition",
                declarationIndex: 0,
                matchedFileCount: 1,
                matchedBytes: 900
            )
        )
    }

    func testDisabledRulesNeverParticipateInPrecedence() throws {
        let disabled = try rule(
            label: "Disabled",
            isEnabled: false,
            destination: "/downloads/disabled",
            extensions: ["mkv"]
        )
        let enabled = try rule(
            label: "Enabled",
            destination: "/downloads/enabled",
            extensions: ["mp4"]
        )

        let recommendation = try XCTUnwrap(
            AddTorrentDestinationRuleResolver.recommendation(
                rules: [disabled, enabled],
                defaultDestination: "/downloads/default",
                files: [
                    AddTorrentDestinationCandidateFile(path: "large.mkv", sizeBytes: 10_000),
                    AddTorrentDestinationCandidateFile(path: "small.mp4", sizeBytes: 1)
                ]
            )
        )

        XCTAssertEqual(recommendation.destination, "/downloads/enabled")
        guard case .matchingRule(let id, _, let declarationIndex, _, _) = recommendation.provenance else {
            return XCTFail("Expected an enabled matching-rule recommendation")
        }
        XCTAssertEqual(id, enabled.id)
        XCTAssertEqual(declarationIndex, 1)
    }

    func testExtensionsAndOrderedNameTokensAreNormalizedAndMatchedAgainstBasename() throws {
        let destinationRule = try rule(
            label: "  High Definition Video  ",
            destination: "/srv/Video Library/keep ",
            extensions: [" .MKV ", "mkv", ".Tar.GZ"],
            nameTokens: [" 1080P ", "X265"]
        )

        XCTAssertEqual(destinationRule.label, "High Definition Video")
        XCTAssertEqual(destinationRule.destination, "/srv/Video Library/keep ")
        XCTAssertEqual(destinationRule.extensions, ["mkv", "tar.gz"])
        XCTAssertEqual(destinationRule.nameTokens, ["1080p", "x265"])

        let recommendation = try XCTUnwrap(
            AddTorrentDestinationRuleResolver.recommendation(
                rules: [destinationRule],
                defaultDestination: nil,
                files: [
                    AddTorrentDestinationCandidateFile(
                        path: "folder/SHOW.1080P.PROPER.X265.MKV",
                        sizeBytes: 42
                    ),
                    AddTorrentDestinationCandidateFile(
                        path: "1080p/folder/show.x265.mkv",
                        sizeBytes: 10_000
                    ),
                    AddTorrentDestinationCandidateFile(
                        path: "folder/show.x265.1080p.mkv",
                        sizeBytes: 10_000
                    )
                ]
            )
        )

        XCTAssertEqual(recommendation.destination, "/srv/Video Library/keep ")
        XCTAssertEqual(
            recommendation.provenance,
            .matchingRule(
                id: destinationRule.id,
                label: "High Definition Video",
                declarationIndex: 0,
                matchedFileCount: 1,
                matchedBytes: 42
            )
        )
    }

    func testRepeatedOrderedNameTokensRequireRepeatedOccurrences() throws {
        let destinationRule = try rule(
            label: "Multipart",
            destination: "/downloads/multipart",
            extensions: ["mkv"],
            nameTokens: ["part", "part"]
        )

        XCTAssertEqual(destinationRule.nameTokens, ["part", "part"])
        let recommendation = try XCTUnwrap(
            AddTorrentDestinationRuleResolver.recommendation(
                rules: [destinationRule],
                defaultDestination: nil,
                files: [
                    AddTorrentDestinationCandidateFile(
                        path: "only-one-part.mkv",
                        sizeBytes: 10_000
                    ),
                    AddTorrentDestinationCandidateFile(
                        path: "part-one-part-two.mkv",
                        sizeBytes: 42
                    )
                ]
            )
        )

        XCTAssertEqual(recommendation.destination, "/downloads/multipart")
        guard case .matchingRule(_, _, _, let count, let bytes) = recommendation.provenance else {
            return XCTFail("Expected the repeated-token rule to match")
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(bytes, 42)
    }

    func testInvalidRulesAndSnapshotsAreRejectedWithoutPathMangling() throws {
        XCTAssertThrowsError(
            try rule(label: "Relative", destination: "srv/video", extensions: ["mkv"])
        ) { error in
            XCTAssertEqual(
                error as? AddTorrentDestinationRuleValidationError,
                .invalidDestination(.notAbsolute)
            )
        }
        XCTAssertThrowsError(
            try rule(label: "No matcher", destination: "/srv/video")
        ) { error in
            XCTAssertEqual(
                error as? AddTorrentDestinationRuleValidationError,
                .matcherRequired
            )
        }
        XCTAssertThrowsError(
            try rule(label: "Bad extension", destination: "/srv/video", extensions: ["m*kv"])
        ) { error in
            XCTAssertEqual(
                error as? AddTorrentDestinationRuleValidationError,
                .invalidExtension("m*kv")
            )
        }
        XCTAssertThrowsError(
            try rule(label: "Empty token", destination: "/srv/video", nameTokens: [" "])
        ) { error in
            XCTAssertEqual(
                error as? AddTorrentDestinationRuleValidationError,
                .emptyNameToken
            )
        }

        let duplicateID = UUID()
        let first = try rule(
            id: duplicateID,
            label: "First",
            destination: "/first",
            extensions: ["mkv"]
        )
        let second = try rule(
            id: duplicateID,
            label: "Second",
            destination: "/second",
            extensions: ["mp4"]
        )
        XCTAssertThrowsError(
            try AddTorrentDestinationRulesSnapshot(
                defaultDestination: "/default",
                rules: [first, second]
            )
        ) { error in
            XCTAssertEqual(
                error as? AddTorrentDestinationRuleValidationError,
                .duplicateRuleIdentifier(duplicateID)
            )
        }

        let malformedRule = Data(
            #"{"id":"00000000-0000-0000-0000-000000000001","label":"Bad","isEnabled":true,"destination":"relative","extensions":["mkv"],"nameTokens":[]}"#.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(AddTorrentDestinationRule.self, from: malformedRule)
        )
    }

    func testNoPositiveMatchFallsBackExplicitlyOrReturnsNil() throws {
        let destinationRule = try rule(
            label: "Video",
            destination: "/downloads/video",
            extensions: ["mkv"]
        )
        let unmatchedFiles = [
            AddTorrentDestinationCandidateFile(path: "readme.txt", sizeBytes: 500),
            AddTorrentDestinationCandidateFile(path: "empty.mkv", sizeBytes: 0),
            AddTorrentDestinationCandidateFile(path: "invalid.mkv", sizeBytes: -1)
        ]

        XCTAssertNil(
            try AddTorrentDestinationRuleResolver.recommendation(
                rules: [destinationRule],
                defaultDestination: nil,
                files: unmatchedFiles
            )
        )

        let recommendation = try XCTUnwrap(
            AddTorrentDestinationRuleResolver.recommendation(
                rules: [destinationRule],
                defaultDestination: "/downloads/exact path ",
                files: unmatchedFiles
            )
        )
        XCTAssertEqual(recommendation.destination, "/downloads/exact path ")
        XCTAssertEqual(recommendation.provenance, .profileDefault)
    }

    func testDraftResetIsStagedCancelRestoresAndApplyAdvancesBaseline() throws {
        let savedRule = try rule(
            label: "Saved",
            destination: "/saved",
            extensions: ["mkv"]
        )
        let saved = try AddTorrentDestinationRulesSnapshot(
            defaultDestination: "/default",
            rules: [savedRule]
        )
        var draft = AddTorrentDestinationRulesDraft(snapshot: saved)

        draft.reset()
        XCTAssertTrue(draft.hasChanges)
        XCTAssertEqual(draft.defaultDestination, "")
        XCTAssertTrue(draft.rules.isEmpty)

        draft.cancel()
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(draft.defaultDestination, "/default")
        XCTAssertEqual(draft.rules, [savedRule])

        var editedRuleDraft = AddTorrentDestinationRuleDraft(rule: savedRule)
        editedRuleDraft.label = "  Applied  "
        editedRuleDraft.extensionsText = " .MKV, mp4, MKV "
        let editedRule = try editedRuleDraft.validatedRule()
        draft.defaultDestination = "/new default"
        draft.rules[0] = editedRule
        let applied = try draft.apply()

        XCTAssertEqual(applied.defaultDestination, "/new default")
        XCTAssertEqual(applied.rules[0].label, "Applied")
        XCTAssertEqual(applied.rules[0].extensions, ["mkv", "mp4"])
        XCTAssertFalse(draft.hasChanges)

        draft.defaultDestination = "relative"
        XCTAssertThrowsError(try draft.apply())
        draft.cancel()
        XCTAssertEqual(draft.defaultDestination, "/new default")
        XCTAssertEqual(draft.rules[0].label, "Applied")
    }

    func testMaximumRulesRemainPracticalForTenThousandFiles() throws {
        let rules = try (0 ..< AddTorrentDestinationRulesSnapshot.maximumRuleCount).map { index in
            try rule(
                label: "Video \(index)",
                destination: "/downloads/video-\(index)",
                extensions: [index == 0 ? "mkv" : "unused\(index)"]
            )
        }
        let files = (0 ..< 10_000).map { index in
            AddTorrentDestinationCandidateFile(
                path: "season/episode-\(index).mkv",
                sizeBytes: 1
            )
        }

        let recommendation = try XCTUnwrap(
            AddTorrentDestinationRuleResolver.recommendation(
                rules: rules,
                defaultDestination: "/downloads/default",
                files: files
            )
        )

        XCTAssertEqual(recommendation.destination, "/downloads/video-0")
        guard case .matchingRule(_, _, let index, let count, let bytes) = recommendation.provenance else {
            return XCTFail("Expected the indexed extension rule to match")
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(count, 10_000)
        XCTAssertEqual(bytes, 10_000)
    }

    private func rule(
        id: UUID = UUID(),
        label: String,
        isEnabled: Bool = true,
        destination: String,
        extensions: [String] = [],
        nameTokens: [String] = []
    ) throws -> AddTorrentDestinationRule {
        try AddTorrentDestinationRule(
            id: id,
            label: label,
            isEnabled: isEnabled,
            destination: destination,
            extensions: extensions,
            nameTokens: nameTokens
        )
    }
}
