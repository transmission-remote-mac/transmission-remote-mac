// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum AddTorrentDestinationRuleValidator {
    static func normalizedLabel(_ label: String) throws -> String {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw AddTorrentDestinationRuleValidationError.labelRequired
        }
        guard normalized.count <= AddTorrentDestinationRule.maximumLabelLength else {
            throw AddTorrentDestinationRuleValidationError.labelTooLong
        }
        guard !containsControlCharacter(normalized) else {
            throw AddTorrentDestinationRuleValidationError.labelRequired
        }
        return normalized
    }

    static func validatedDestination(_ destination: String) throws -> String {
        do {
            return try RemotePOSIXDestinationValidator.validated(destination)
        } catch let error as RemotePOSIXDestinationValidationError {
            throw AddTorrentDestinationRuleValidationError.invalidDestination(error)
        }
    }

    static func normalizedExtensions(_ extensions: [String]) throws -> [String] {
        guard extensions.count <= AddTorrentDestinationRule.maximumExtensionCount else {
            throw AddTorrentDestinationRuleValidationError.tooManyExtensions
        }

        var seen = Set<String>()
        return try extensions.compactMap { extensionValue in
            var normalized = extensionValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.hasPrefix(".") {
                normalized.removeFirst()
            }
            normalized = normalized.lowercased()

            guard !normalized.isEmpty else {
                throw AddTorrentDestinationRuleValidationError.emptyExtension
            }
            guard normalized.count <= AddTorrentDestinationRule.maximumMatcherLength,
                  normalized != ".",
                  normalized != "..",
                  !normalized.hasPrefix("."),
                  !normalized.hasSuffix("."),
                  !containsControlCharacter(normalized),
                  normalized.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  !normalized.contains("/"),
                  !normalized.contains("\\"),
                  !normalized.contains("*"),
                  !normalized.contains("?") else {
                throw AddTorrentDestinationRuleValidationError.invalidExtension(extensionValue)
            }
            return seen.insert(normalized).inserted ? normalized : nil
        }
    }

    static func normalizedNameTokens(_ nameTokens: [String]) throws -> [String] {
        guard nameTokens.count <= AddTorrentDestinationRule.maximumNameTokenCount else {
            throw AddTorrentDestinationRuleValidationError.tooManyNameTokens
        }

        return try nameTokens.map { token in
            let normalized = token
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty else {
                throw AddTorrentDestinationRuleValidationError.emptyNameToken
            }
            guard normalized.count <= AddTorrentDestinationRule.maximumMatcherLength,
                  !containsControlCharacter(normalized),
                  !normalized.contains("/"),
                  !normalized.contains("\\") else {
                throw AddTorrentDestinationRuleValidationError.invalidNameToken(token)
            }
            return normalized
        }
    }

    static func validateMatchers(
        extensions: [String],
        nameTokens: [String]
    ) throws {
        guard !extensions.isEmpty || !nameTokens.isEmpty else {
            throw AddTorrentDestinationRuleValidationError.matcherRequired
        }
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}

struct AddTorrentDestinationCandidateFile: Equatable, Sendable {
    let path: String
    let sizeBytes: Int64

    init(path: String, sizeBytes: Int64) {
        self.path = path
        self.sizeBytes = sizeBytes
    }
}

struct AddTorrentDestinationRecommendation: Equatable, Sendable {
    let destination: String
    let provenance: AddTorrentDestinationRecommendationProvenance
}

enum AddTorrentDestinationRecommendationProvenance: Equatable, Sendable {
    case matchingRule(
        id: UUID,
        label: String,
        declarationIndex: Int,
        matchedFileCount: Int,
        matchedBytes: Int64
    )
    case profileDefault
}

/// Pure recommendation engine. It never edits an add draft and never submits an
/// RPC mutation. The caller must visibly present and explicitly apply the result.
enum AddTorrentDestinationRuleResolver {
    static func recommendation(
        rules: [AddTorrentDestinationRule],
        defaultDestination: String?,
        files: [AddTorrentDestinationCandidateFile]
    ) throws -> AddTorrentDestinationRecommendation? {
        guard rules.count <= AddTorrentDestinationRulesSnapshot.maximumRuleCount else {
            throw AddTorrentDestinationRuleValidationError.tooManyRules
        }
        if let defaultDestination {
            _ = try AddTorrentDestinationRuleValidator.validatedDestination(defaultDestination)
        }

        var preparedFiles: [PreparedFile] = []
        preparedFiles.reserveCapacity(files.count)
        for (fileIndex, file) in files.enumerated() {
            if fileIndex.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            if let preparedFile = PreparedFile(candidate: file) {
                preparedFiles.append(preparedFile)
            }
        }
        let preparedFileIndex = try PreparedFileIndex(files: preparedFiles)
        var winningMatch: ScoredRule?

        for (declarationIndex, rule) in rules.enumerated() where rule.isEnabled {
            try Task.checkCancellation()
            var matchedFileCount = 0
            var matchedBytes: Int64 = 0

            let candidateIndexes = preparedFileIndex.candidateIndexes(
                for: rule.extensions
            )
            for (candidateOffset, fileIndex) in candidateIndexes.enumerated() {
                if candidateOffset.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                let file = preparedFiles[fileIndex]
                guard matchesNameTokens(file.name, rule: rule) else { continue }
                matchedFileCount += 1
                let (sum, overflow) = matchedBytes.addingReportingOverflow(file.sizeBytes)
                matchedBytes = overflow ? .max : sum
            }

            // Mirrors the useful legacy behaviour: zero-byte evidence does not
            // override a default or manual destination.
            guard matchedBytes > 0 else { continue }
            let candidate = ScoredRule(
                rule: rule,
                declarationIndex: declarationIndex,
                matchedFileCount: matchedFileCount,
                matchedBytes: matchedBytes
            )
            if candidate.matchedBytes > (winningMatch?.matchedBytes ?? 0) {
                winningMatch = candidate
            }
        }

        if let winningMatch {
            return AddTorrentDestinationRecommendation(
                destination: winningMatch.rule.destination,
                provenance: .matchingRule(
                    id: winningMatch.rule.id,
                    label: winningMatch.rule.label,
                    declarationIndex: winningMatch.declarationIndex,
                    matchedFileCount: winningMatch.matchedFileCount,
                    matchedBytes: winningMatch.matchedBytes
                )
            )
        }

        guard let defaultDestination else { return nil }
        return AddTorrentDestinationRecommendation(
            destination: defaultDestination,
            provenance: .profileDefault
        )
    }

    private static func matchesNameTokens(
        _ normalizedFileName: String,
        rule: AddTorrentDestinationRule
    ) -> Bool {
        var remaining = normalizedFileName[...]
        for token in rule.nameTokens {
            guard let range = remaining.range(of: token) else { return false }
            remaining = remaining[range.upperBound...]
        }
        return true
    }

    private struct PreparedFile {
        let name: String
        let suffixes: Set<String>
        let sizeBytes: Int64

        init?(candidate: AddTorrentDestinationCandidateFile) {
            guard candidate.sizeBytes >= 0,
                  let component = candidate.path.split(
                      omittingEmptySubsequences: false,
                      whereSeparator: { $0 == "/" || $0 == "\\" }
                  ).last,
                  !component.isEmpty else {
                return nil
            }
            let normalizedName = component.lowercased()
            name = normalizedName
            suffixes = Self.suffixes(in: normalizedName)
            sizeBytes = candidate.sizeBytes
        }

        private static func suffixes(in fileName: String) -> Set<String> {
            var result = Set<String>()
            var searchStart = fileName.startIndex
            while searchStart < fileName.endIndex,
                  let separator = fileName[searchStart...].firstIndex(of: ".") {
                let suffixStart = fileName.index(after: separator)
                if suffixStart < fileName.endIndex {
                    result.insert(String(fileName[suffixStart...]))
                }
                searchStart = suffixStart
            }
            return result
        }
    }

    private struct PreparedFileIndex {
        let allIndexes: [Int]
        let indexesBySuffix: [String: [Int]]

        init(files: [PreparedFile]) throws {
            allIndexes = Array(files.indices)
            var indexesBySuffix: [String: [Int]] = [:]
            for (fileIndex, file) in files.enumerated() {
                if fileIndex.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                for suffix in file.suffixes {
                    indexesBySuffix[suffix, default: []].append(fileIndex)
                }
            }
            self.indexesBySuffix = indexesBySuffix
        }

        func candidateIndexes(for extensions: [String]) -> [Int] {
            guard !extensions.isEmpty else { return allIndexes }
            if extensions.count == 1 {
                return indexesBySuffix[extensions[0]] ?? []
            }

            var indexes = Set<Int>()
            for extensionValue in extensions {
                indexes.formUnion(indexesBySuffix[extensionValue] ?? [])
            }
            return indexes.sorted()
        }
    }

    private struct ScoredRule {
        let rule: AddTorrentDestinationRule
        let declarationIndex: Int
        let matchedFileCount: Int
        let matchedBytes: Int64
    }
}

struct AddTorrentDestinationRecommendationOwnership: Equatable, Sendable {
    let requestID: UUID
    let presentationOwnerID: UUID
    let profileID: UUID
    let connectionToken: UUID
}

struct AddTorrentDestinationRecommendationServiceRequest: Sendable {
    let ownership: AddTorrentDestinationRecommendationOwnership
    let rules: AddTorrentDestinationRulesSnapshot
    let metainfoFiles: [TorrentMetainfoFile]
}

struct AddTorrentDestinationRecommendationServiceResponse: Equatable, Sendable {
    let ownership: AddTorrentDestinationRecommendationOwnership
    let evaluation: AddTorrentDestinationRecommendationEvaluation
}

protocol AddTorrentDestinationRecommendationServicing: Sendable {
    func evaluate(
        _ request: AddTorrentDestinationRecommendationServiceRequest
    ) async -> AddTorrentDestinationRecommendationServiceResponse?
}

/// Maps metainfo into matcher input and evaluates rules away from MainActor.
/// Cancellation is checked while mapping and by the chunked resolver.
struct AddTorrentDestinationRecommendationService: AddTorrentDestinationRecommendationServicing {
    func evaluate(
        _ request: AddTorrentDestinationRecommendationServiceRequest
    ) async -> AddTorrentDestinationRecommendationServiceResponse? {
        let worker = Task.detached(priority: .userInitiated) {
            () -> AddTorrentDestinationRecommendationServiceResponse? in
            do {
                var candidates: [AddTorrentDestinationCandidateFile] = []
                candidates.reserveCapacity(request.metainfoFiles.count)
                for (fileIndex, file) in request.metainfoFiles.enumerated() {
                    if fileIndex.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    candidates.append(
                        AddTorrentDestinationCandidateFile(
                            path: file.path,
                            sizeBytes: file.length
                        )
                    )
                }

                let recommendation = try AddTorrentDestinationRuleResolver.recommendation(
                    rules: request.rules.rules,
                    defaultDestination: request.rules.defaultDestination,
                    files: candidates
                )
                return AddTorrentDestinationRecommendationServiceResponse(
                    ownership: request.ownership,
                    evaluation: .recommendation(recommendation)
                )
            } catch is CancellationError {
                return nil
            } catch {
                return AddTorrentDestinationRecommendationServiceResponse(
                    ownership: request.ownership,
                    evaluation: .failed(error.localizedDescription)
                )
            }
        }

        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
