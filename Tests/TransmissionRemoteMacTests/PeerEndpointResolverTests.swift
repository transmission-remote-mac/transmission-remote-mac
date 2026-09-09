// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class PeerEndpointResolverTests: XCTestCase {
    func testResolutionReuseIgnoresStatsRevisionPortsAndCanonicalAddressSpelling() throws {
        let request = try makeRequest(address: "192.0.2.1")
        var next = request
        next.context.detailGeneration += 1
        next.context.peersSnapshotRevision = UUID()
        next.endpoints = [
            try XCTUnwrap(PeerEndpoint(rawAddress: "::ffff:192.0.2.1", port: 1)),
            try XCTUnwrap(PeerEndpoint(rawAddress: "192.0.2.1", port: 2))
        ]
        XCTAssertTrue(request.canReuseResolution(for: next))
    }

    func testResolutionReuseRejectsOwnershipPreferencesAndAddressChanges() throws {
        let request = try makeRequest(address: "192.0.2.1")
        var next = request
        next.context.profileID = UUID()
        XCTAssertFalse(request.canReuseResolution(for: next))
        next = request
        next.context.connectionToken = UUID()
        XCTAssertFalse(request.canReuseResolution(for: next))
        next = request
        next.context.selectionGeneration += 1
        XCTAssertFalse(request.canReuseResolution(for: next))
        next = request
        next.context.torrentID += 1
        XCTAssertFalse(request.canReuseResolution(for: next))
        next = request
        next.preferences.resolveHostNames = false
        XCTAssertFalse(request.canReuseResolution(for: next))
        next = request
        next.endpoints = [try XCTUnwrap(PeerEndpoint(rawAddress: "192.0.2.2", port: 51_413))]
        XCTAssertFalse(request.canReuseResolution(for: next))
    }

    func testReverseDNSConcurrencyIsStrictlyBounded() async throws {
        let probe = ReverseDNSProbe(delay: .milliseconds(20))
        let resolver = makeResolver(probe: probe)
        var request = try makeRequest(address: "192.0.2.1")
        request.endpoints = try (1 ... 12).map {
            try XCTUnwrap(PeerEndpoint(rawAddress: "192.0.2.\($0)", port: 51_413))
        }

        _ = await resolver.resolve(request)

        let maximumActiveCount = await probe.maximumActiveCount
        XCTAssertEqual(maximumActiveCount, 2)
    }

    func testPendingAndActiveAddressesRemainBoundedAcrossGenerationReplacement() async throws {
        let probe = ReverseDNSProbe(delay: .milliseconds(80))
        let resolver = PeerEndpointResolver(
            configuration: PeerEndpointResolverConfiguration(
                cacheCapacity: 8,
                maximumConcurrentReverseDNSLookups: 2,
                positiveTTL: 60,
                negativeTTL: 10,
                maximumTrackedReverseDNSLookups: 4
            ),
            reverseDNSLookup: { await probe.lookup($0) },
            dateProvider: { Date(timeIntervalSince1970: 1_000) }
        )
        var firstRequest = try makeRequest(address: "192.0.2.1")
        firstRequest.endpoints = try (1 ... 12).map {
            try XCTUnwrap(PeerEndpoint(rawAddress: "192.0.2.\($0)", port: 51_413))
        }
        var secondRequest = firstRequest
        secondRequest.context.selectionGeneration += 1
        secondRequest.endpoints = try (20 ... 31).map {
            try XCTUnwrap(PeerEndpoint(rawAddress: "192.0.2.\($0)", port: 51_413))
        }
        let firstOwner = UUID()
        let secondOwner = UUID()
        let firstTask = Task {
            await resolver.resolve(firstRequest, ownerID: firstOwner)
        }

        let firstGenerationStarted = await waitUntil { await probe.totalCallCount == 2 }
        let firstWorkload = await resolver.workload()
        XCTAssertTrue(firstGenerationStarted)
        XCTAssertEqual(
            firstWorkload,
            PeerEndpointResolverWorkload(pendingAddressCount: 2, activeAddressCount: 2)
        )

        let secondTask = Task {
            await resolver.resolve(secondRequest, ownerID: secondOwner)
        }
        let secondGenerationQueued = await waitUntil {
            let workload = await resolver.workload()
            return workload.pendingAddressCount == 2 && workload.activeAddressCount == 2
        }
        let replacementWorkload = await resolver.workload()
        XCTAssertTrue(secondGenerationQueued)
        XCTAssertLessThanOrEqual(replacementWorkload.totalAddressCount, 4)

        let firstResult = await firstTask.value
        let secondResult = await secondTask.value
        let finalWorkload = await resolver.workload()
        XCTAssertNil(firstResult)
        XCTAssertNotNil(secondResult)
        XCTAssertLessThanOrEqual(finalWorkload.totalAddressCount, 4)
    }

    func testCancelledBatchNeverReturnsPublishableResult() async throws {
        let probe = ReverseDNSProbe(delay: .milliseconds(100))
        let resolver = makeResolver(probe: probe)
        let request = try makeRequest(address: "192.0.2.40")
        let task = Task { await resolver.resolve(request) }

        await Task.yield()
        task.cancel()

        let result = await task.value
        XCTAssertNil(result)
        let lookupStopped = await waitUntil { await probe.activeLookupCount == 0 }
        let cacheEntryCount = await resolver.cacheEntryCount()
        XCTAssertTrue(lookupStopped)
        XCTAssertEqual(cacheEntryCount, 0)
    }

    func testExplicitOwnerCancellationRejectsResultAndCacheInsertion() async throws {
        let probe = ReverseDNSProbe(delay: .milliseconds(80))
        let resolver = makeResolver(probe: probe)
        let request = try makeRequest(address: "192.0.2.41")
        let ownerID = UUID()
        let task = Task {
            await resolver.resolve(request, ownerID: ownerID)
        }

        let lookupStarted = await waitUntil { await probe.totalCallCount == 1 }
        XCTAssertTrue(lookupStarted)
        await resolver.cancel(ownerID: ownerID)

        let result = await task.value
        let lookupStopped = await waitUntil { await probe.activeLookupCount == 0 }
        let cacheEntryCount = await resolver.cacheEntryCount()
        XCTAssertNil(result)
        XCTAssertTrue(lookupStopped)
        XCTAssertEqual(cacheEntryCount, 0)
    }

    func testClearingCachesCancelsGenerationAndRejectsLateInsertion() async throws {
        let probe = ReverseDNSProbe(delay: .milliseconds(80))
        let resolver = makeResolver(probe: probe)
        let request = try makeRequest(address: "192.0.2.42")
        let task = Task {
            await resolver.resolve(request, ownerID: UUID())
        }

        let lookupStarted = await waitUntil { await probe.totalCallCount == 1 }
        XCTAssertTrue(lookupStarted)
        await resolver.clearCaches()

        let result = await task.value
        let lookupStopped = await waitUntil { await probe.activeLookupCount == 0 }
        let cacheEntryCount = await resolver.cacheEntryCount()
        XCTAssertNil(result)
        XCTAssertTrue(lookupStopped)
        XCTAssertEqual(cacheEntryCount, 0)
    }

    func testSupersededGenerationCannotInsertCacheOrReturnStaleBatch() async throws {
        let probe = ReverseDNSProbe(delay: .milliseconds(80))
        let resolver = makeResolver(probe: probe)
        let staleRequest = try makeRequest(address: "192.0.2.50")
        var currentRequest = try makeRequest(address: "192.0.2.51")
        currentRequest.context.selectionGeneration += 1
        let staleTask = Task {
            await resolver.resolve(staleRequest, ownerID: UUID())
        }

        let staleLookupStarted = await waitUntil { await probe.totalCallCount == 1 }
        XCTAssertTrue(staleLookupStarted)
        let currentTask = Task {
            await resolver.resolve(currentRequest, ownerID: UUID())
        }

        let staleResult = await staleTask.value
        let currentResult = await currentTask.value
        XCTAssertNil(staleResult)
        let currentBatch = try XCTUnwrap(currentResult)
        XCTAssertEqual(
            currentBatch.metadataByAddress.values.first?.hostName,
            "host-192-0-2-51.test"
        )
        let cacheEntryCount = await resolver.cacheEntryCount()
        XCTAssertEqual(cacheEntryCount, 1)

        _ = await resolver.resolve(staleRequest, ownerID: UUID())
        let staleAddressCallCount = await probe.callCount(for: "192.0.2.50")
        XCTAssertEqual(
            staleAddressCallCount,
            2,
            "a stale generation must not populate the DNS cache"
        )
    }

    func testCancelledStalledGenerationPromptlyYieldsSlotToReplacement() async throws {
        let staleAddress = "192.0.2.60"
        let currentAddress = "192.0.2.61"
        let probe = StallingReverseDNSProbe(stalledAddress: staleAddress)
        let resolver = PeerEndpointResolver(
            configuration: PeerEndpointResolverConfiguration(
                cacheCapacity: 8,
                maximumConcurrentReverseDNSLookups: 1,
                positiveTTL: 60,
                negativeTTL: 10,
                maximumTrackedReverseDNSLookups: 2,
                reverseDNSLookupTimeout: 30
            ),
            reverseDNSLookup: { await probe.lookup($0) },
            dateProvider: { Date(timeIntervalSince1970: 1_000) }
        )
        let staleRequest = try makeRequest(address: staleAddress)
        let currentRequest = try makeRequest(address: currentAddress)
        let staleTask = Task {
            await resolver.resolve(staleRequest, ownerID: UUID())
        }
        let staleLookupStarted = await waitUntil {
            await probe.callCount(for: staleAddress) == 1
        }
        XCTAssertTrue(staleLookupStarted)

        let currentTask = Task {
            await resolver.resolve(currentRequest, ownerID: UUID())
        }
        let replacementStarted = await waitUntil {
            await probe.callCount(for: currentAddress) == 1
        }
        XCTAssertTrue(
            replacementStarted,
            "a cancelled lookup must not retain the only resolver slot"
        )
        let staleResult = await staleTask.value
        let currentBatch = await currentTask.value
        let currentResult = try XCTUnwrap(currentBatch)
        XCTAssertNil(staleResult)
        XCTAssertEqual(
            currentResult.metadataByAddress.values.first?.hostName,
            "host-192-0-2-61.test"
        )
        let completedWorkload = await resolver.workload()
        let completedCacheEntryCount = await resolver.cacheEntryCount()
        XCTAssertEqual(
            completedWorkload,
            PeerEndpointResolverWorkload(pendingAddressCount: 0, activeAddressCount: 0)
        )
        XCTAssertEqual(completedCacheEntryCount, 1)

        await probe.releaseStalledLookup()
        let staleLookupStopped = await waitUntil { await probe.activeLookupCount == 0 }
        XCTAssertTrue(staleLookupStopped)
        _ = await resolver.resolve(staleRequest, ownerID: UUID())
        let staleAddressCallCount = await probe.callCount(for: staleAddress)
        XCTAssertEqual(
            staleAddressCallCount,
            2,
            "the abandoned generation must not populate the cache when it eventually returns"
        )
    }

    func testLookupDeadlineRetiresWorkWithoutCachingTimeout() async throws {
        let address = "192.0.2.62"
        let probe = StallingReverseDNSProbe(stalledAddress: address)
        let resolver = PeerEndpointResolver(
            configuration: PeerEndpointResolverConfiguration(
                cacheCapacity: 8,
                maximumConcurrentReverseDNSLookups: 1,
                positiveTTL: 60,
                negativeTTL: 10,
                maximumTrackedReverseDNSLookups: 1,
                reverseDNSLookupTimeout: 0.1
            ),
            reverseDNSLookup: { await probe.lookup($0) },
            dateProvider: { Date(timeIntervalSince1970: 1_000) }
        )
        let request = try makeRequest(address: address)

        let timedOutResult = await resolver.resolve(request, ownerID: UUID())
        let timedOutBatch = try XCTUnwrap(timedOutResult)
        XCTAssertNil(timedOutBatch.metadataByAddress.values.first?.hostName)
        let timedOutCacheEntryCount = await resolver.cacheEntryCount()
        let timedOutWorkload = await resolver.workload()
        XCTAssertEqual(timedOutCacheEntryCount, 0)
        XCTAssertEqual(
            timedOutWorkload,
            PeerEndpointResolverWorkload(pendingAddressCount: 0, activeAddressCount: 0)
        )

        let retryResult = await resolver.resolve(request, ownerID: UUID())
        let retryBatch = try XCTUnwrap(retryResult)
        XCTAssertEqual(
            retryBatch.metadataByAddress.values.first?.hostName,
            "host-192-0-2-62.test"
        )
        let retryCallCount = await probe.callCount(for: address)
        let retryCacheEntryCount = await resolver.cacheEntryCount()
        XCTAssertEqual(retryCallCount, 2)
        XCTAssertEqual(retryCacheEntryCount, 1)

        await probe.releaseStalledLookup()
        let staleLookupStopped = await waitUntil { await probe.activeLookupCount == 0 }
        XCTAssertTrue(staleLookupStopped)
        _ = await resolver.resolve(request, ownerID: UUID())
        let finalCallCount = await probe.callCount(for: address)
        XCTAssertEqual(
            finalCallCount,
            2,
            "a late timeout result must neither evict nor replace the fresh cached value"
        )
    }

    func testTrackedAndActiveCapsHoldForIndefinitelySuspendedLookups() async throws {
        let probe = SuspendingReverseDNSProbe()
        let resolver = PeerEndpointResolver(
            configuration: PeerEndpointResolverConfiguration(
                cacheCapacity: 8,
                maximumConcurrentReverseDNSLookups: 2,
                positiveTTL: 60,
                negativeTTL: 10,
                maximumTrackedReverseDNSLookups: 4,
                reverseDNSLookupTimeout: 30
            ),
            reverseDNSLookup: { await probe.lookup($0) },
            dateProvider: { Date(timeIntervalSince1970: 1_000) }
        )
        var request = try makeRequest(address: "192.0.2.70")
        request.endpoints = try (70 ... 81).map {
            try XCTUnwrap(PeerEndpoint(rawAddress: "192.0.2.\($0)", port: 51_413))
        }
        let ownerID = UUID()
        let task = Task { await resolver.resolve(request, ownerID: ownerID) }
        let initialLookupsStarted = await waitUntil { await probe.totalCallCount == 2 }
        let initialWorkload = await resolver.workload()
        let maximumActiveCount = await probe.maximumActiveCount
        XCTAssertTrue(initialLookupsStarted)
        XCTAssertEqual(
            initialWorkload,
            PeerEndpointResolverWorkload(pendingAddressCount: 2, activeAddressCount: 2)
        )
        XCTAssertEqual(maximumActiveCount, 2)

        await resolver.cancel(ownerID: ownerID)
        let cancelledResult = await task.value
        let cancelledWorkload = await resolver.workload()
        XCTAssertNil(cancelledResult)
        XCTAssertEqual(
            cancelledWorkload,
            PeerEndpointResolverWorkload(pendingAddressCount: 0, activeAddressCount: 0)
        )
        await probe.releaseAll()
        let lookupsStopped = await waitUntil { await probe.activeLookupCount == 0 }
        let cacheEntryCount = await resolver.cacheEntryCount()
        XCTAssertTrue(lookupsStopped)
        XCTAssertEqual(cacheEntryCount, 0)
    }

    func testPositiveNegativeTTLAndStrictLRUEviction() async throws {
        let clock = ResolverTestClock(now: Date(timeIntervalSince1970: 1_000))
        let probe = ReverseDNSProbe(negativeAddresses: ["192.0.2.2"])
        let resolver = PeerEndpointResolver(
            configuration: PeerEndpointResolverConfiguration(
                cacheCapacity: 2,
                maximumConcurrentReverseDNSLookups: 2,
                positiveTTL: 60,
                negativeTTL: 10
            ),
            reverseDNSLookup: { await probe.lookup($0) },
            dateProvider: { clock.now }
        )

        _ = await resolver.resolve(try makeRequest(address: "192.0.2.1"))
        _ = await resolver.resolve(try makeRequest(address: "192.0.2.2"))
        _ = await resolver.resolve(try makeRequest(address: "192.0.2.2"))
        var negativeCallCount = await probe.callCount(for: "192.0.2.2")
        XCTAssertEqual(negativeCallCount, 1, "negative result must be cached")

        _ = await resolver.resolve(try makeRequest(address: "192.0.2.1"))
        _ = await resolver.resolve(try makeRequest(address: "192.0.2.3"))
        var cacheEntryCount = await resolver.cacheEntryCount()
        XCTAssertEqual(cacheEntryCount, 2)
        _ = await resolver.resolve(try makeRequest(address: "192.0.2.2"))
        negativeCallCount = await probe.callCount(for: "192.0.2.2")
        XCTAssertEqual(negativeCallCount, 2, "least-recently-used entry must be evicted")
        cacheEntryCount = await resolver.cacheEntryCount()
        XCTAssertEqual(cacheEntryCount, 2)

        clock.advance(by: 11)
        _ = await resolver.resolve(try makeRequest(address: "192.0.2.2"))
        negativeCallCount = await probe.callCount(for: "192.0.2.2")
        XCTAssertEqual(negativeCallCount, 3, "negative TTL must expire")

        clock.advance(by: 60)
        _ = await resolver.resolve(try makeRequest(address: "192.0.2.3"))
        let positiveCallCount = await probe.callCount(for: "192.0.2.3")
        XCTAssertEqual(positiveCallCount, 2, "positive TTL must expire")
    }

    func testCountryResolutionIsLocalAndFlagFormattingIsOptional() async throws {
        let probe = ReverseDNSProbe()
        let resolver = makeResolver(probe: probe)
        let database = try PeerCountryCSVImporter.parse(
            data: Data(#""203.0.113.0","203.0.113.255","AU""#.utf8),
            sourceFileName: "dbip-country-lite-2026-09.csv"
        )
        await resolver.installCountryDatabase(database)
        let request = try makeRequest(
            address: "203.0.113.9",
            preferences: PeerResolutionPreferences(
                resolveHostNames: false,
                resolveCountries: true,
                showCountryFlags: true
            )
        )

        let batch = await resolver.resolve(request)
        let metadata = try XCTUnwrap(batch?.metadataByAddress.values.first)

        XCTAssertEqual(metadata.countryCode, "AU")
        XCTAssertEqual(metadata.countryName, Locale.current.localizedString(forRegionCode: "AU"))
        XCTAssertEqual(metadata.countryFlag, "🇦🇺")
        let totalCallCount = await probe.totalCallCount
        XCTAssertEqual(totalCallCount, 0, "country lookup must not use DNS or a web service")
    }

    func testStaleGenerationPublicationIsRejected() {
        let context = PeerResolutionContext(
            profileID: UUID(),
            connectionToken: UUID(),
            selectionGeneration: 4,
            torrentID: 12,
            detailGeneration: 8,
            peersSnapshotRevision: UUID()
        )

        XCTAssertTrue(PeerResolutionPublicationGuard.canPublish(
            expected: context,
            profileID: context.profileID,
            connectionToken: context.connectionToken,
            selectionGeneration: context.selectionGeneration,
            torrentID: context.torrentID,
            detailGeneration: context.detailGeneration,
            peersSnapshotRevision: context.peersSnapshotRevision
        ))
        XCTAssertFalse(PeerResolutionPublicationGuard.canPublish(
            expected: context,
            profileID: UUID(),
            connectionToken: context.connectionToken,
            selectionGeneration: context.selectionGeneration,
            torrentID: context.torrentID,
            detailGeneration: context.detailGeneration,
            peersSnapshotRevision: context.peersSnapshotRevision
        ))
        XCTAssertFalse(PeerResolutionPublicationGuard.canPublish(
            expected: context,
            profileID: context.profileID,
            connectionToken: UUID(),
            selectionGeneration: context.selectionGeneration,
            torrentID: context.torrentID,
            detailGeneration: context.detailGeneration,
            peersSnapshotRevision: context.peersSnapshotRevision
        ))
        XCTAssertFalse(PeerResolutionPublicationGuard.canPublish(
            expected: context,
            profileID: context.profileID,
            connectionToken: context.connectionToken,
            selectionGeneration: context.selectionGeneration + 1,
            torrentID: context.torrentID,
            detailGeneration: context.detailGeneration,
            peersSnapshotRevision: context.peersSnapshotRevision
        ))
        XCTAssertFalse(PeerResolutionPublicationGuard.canPublish(
            expected: context,
            profileID: context.profileID,
            connectionToken: context.connectionToken,
            selectionGeneration: context.selectionGeneration,
            torrentID: context.torrentID,
            detailGeneration: context.detailGeneration + 1,
            peersSnapshotRevision: context.peersSnapshotRevision
        ))
        XCTAssertFalse(PeerResolutionPublicationGuard.canPublish(
            expected: context,
            profileID: context.profileID,
            connectionToken: context.connectionToken,
            selectionGeneration: context.selectionGeneration,
            torrentID: context.torrentID + 1,
            detailGeneration: context.detailGeneration,
            peersSnapshotRevision: context.peersSnapshotRevision
        ))
        XCTAssertFalse(PeerResolutionPublicationGuard.canPublish(
            expected: context,
            profileID: context.profileID,
            connectionToken: context.connectionToken,
            selectionGeneration: context.selectionGeneration,
            torrentID: context.torrentID,
            detailGeneration: context.detailGeneration,
            peersSnapshotRevision: UUID()
        ))
    }

    func testRegionalIndicatorFlagFormattingRejectsInvalidCodes() {
        XCTAssertEqual(PeerCountryPresentation.flag(for: "au"), "🇦🇺")
        XCTAssertEqual(PeerCountryPresentation.flag(for: "US"), "🇺🇸")
        XCTAssertNil(PeerCountryPresentation.flag(for: "A"))
        XCTAssertNil(PeerCountryPresentation.flag(for: "A1"))
        XCTAssertNil(PeerCountryPresentation.flag(for: "USA"))
    }

    func testPeerEnrichmentPreservesRawEndpointAndStableIdentity() throws {
        let peer = TorrentPeer(index: 0, json: [
            "address": .string("203.0.113.8"),
            "port": .int(51_413),
            "clientName": .string("Transmission")
        ])
        let enriched = peer.applying(PeerResolvedMetadata(
            address: try XCTUnwrap(PeerIPAddress(parsing: peer.host)),
            hostName: "peer.example",
            countryCode: "AU",
            countryName: "Australia",
            countryFlag: "🇦🇺"
        ))

        XCTAssertEqual(enriched.id, peer.id)
        XCTAssertEqual(enriched.host, "203.0.113.8")
        XCTAssertEqual(enriched.port, 51_413)
        XCTAssertEqual(enriched.displayHost, "peer.example")
        XCTAssertEqual(enriched.countryDisplay, "🇦🇺 Australia")
    }

    func testHostOnlyEnrichmentPreservesDaemonCountry() throws {
        let peer = TorrentPeer(index: 0, json: [
            "address": .string("203.0.113.8"),
            "country": .string("Legacy country")
        ])
        let enriched = peer.applying(PeerResolvedMetadata(
            address: try XCTUnwrap(PeerIPAddress(parsing: peer.host)),
            hostName: "peer.example",
            countryCode: nil,
            countryName: nil,
            countryFlag: nil
        ))

        XCTAssertEqual(enriched.displayHost, "peer.example")
        XCTAssertEqual(enriched.countryDisplay, "Legacy country")
    }

    private func makeResolver(probe: ReverseDNSProbe) -> PeerEndpointResolver {
        PeerEndpointResolver(
            configuration: PeerEndpointResolverConfiguration(
                cacheCapacity: 8,
                maximumConcurrentReverseDNSLookups: 2,
                positiveTTL: 60,
                negativeTTL: 10
            ),
            reverseDNSLookup: { await probe.lookup($0) },
            dateProvider: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private func makeRequest(
        address: String,
        preferences: PeerResolutionPreferences = PeerResolutionPreferences(
            resolveHostNames: true,
            resolveCountries: false,
            showCountryFlags: false
        )
    ) throws -> PeerResolutionRequest {
        PeerResolutionRequest(
            context: PeerResolutionContext(
                profileID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                connectionToken: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
                selectionGeneration: 3,
                torrentID: 7,
                detailGeneration: 4,
                peersSnapshotRevision: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
            ),
            endpoints: [try XCTUnwrap(PeerEndpoint(rawAddress: address, port: 51_413))],
            preferences: preferences
        )
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private actor ReverseDNSProbe {
    private var callsByAddress: [String: Int] = [:]
    private var activeCount = 0
    private(set) var maximumActiveCount = 0
    private let negativeAddresses: Set<String>
    private let delay: Duration

    init(negativeAddresses: Set<String> = [], delay: Duration = .zero) {
        self.negativeAddresses = negativeAddresses
        self.delay = delay
    }

    var totalCallCount: Int { callsByAddress.values.reduce(0, +) }
    var activeLookupCount: Int { activeCount }

    func lookup(_ address: PeerIPAddress) async -> String? {
        callsByAddress[address.canonicalString, default: 0] += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer { activeCount -= 1 }
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard !negativeAddresses.contains(address.canonicalString) else { return nil }
        return "host-\(address.canonicalString.replacingOccurrences(of: ".", with: "-")).test"
    }

    func callCount(for address: String) -> Int {
        callsByAddress[address, default: 0]
    }
}

private actor StallingReverseDNSProbe {
    private let stalledAddress: String
    private var callsByAddress: [String: Int] = [:]
    private var stalledContinuation: CheckedContinuation<Void, Never>?
    private(set) var activeLookupCount = 0

    init(stalledAddress: String) {
        self.stalledAddress = stalledAddress
    }

    func lookup(_ address: PeerIPAddress) async -> String? {
        let canonicalAddress = address.canonicalString
        callsByAddress[canonicalAddress, default: 0] += 1
        let callCount = callsByAddress[canonicalAddress, default: 0]
        activeLookupCount += 1
        defer { activeLookupCount -= 1 }
        if canonicalAddress == stalledAddress, callCount == 1 {
            await withCheckedContinuation { continuation in
                stalledContinuation = continuation
            }
        }
        return "host-\(canonicalAddress.replacingOccurrences(of: ".", with: "-")).test"
    }

    func callCount(for address: String) -> Int {
        callsByAddress[address, default: 0]
    }

    func releaseStalledLookup() {
        let continuation = stalledContinuation
        stalledContinuation = nil
        continuation?.resume()
    }
}

private actor SuspendingReverseDNSProbe {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var totalCallCount = 0
    private(set) var activeLookupCount = 0
    private(set) var maximumActiveCount = 0

    func lookup(_ address: PeerIPAddress) async -> String? {
        totalCallCount += 1
        activeLookupCount += 1
        maximumActiveCount = max(maximumActiveCount, activeLookupCount)
        defer { activeLookupCount -= 1 }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        return "host-\(address.canonicalString.replacingOccurrences(of: ".", with: "-")).test"
    }

    func releaseAll() {
        let continuations = continuations
        self.continuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private final class ResolverTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) { value = now }

    var now: Date { lock.withLock { value } }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}
