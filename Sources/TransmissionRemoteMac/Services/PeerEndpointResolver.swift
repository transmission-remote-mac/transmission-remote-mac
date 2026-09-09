// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Darwin
import Foundation
import dnssd

struct PeerEndpointResolverConfiguration: Equatable, Sendable {
    static let standard = PeerEndpointResolverConfiguration(
        cacheCapacity: 512,
        maximumConcurrentReverseDNSLookups: 8,
        positiveTTL: 3_600,
        negativeTTL: 300,
        maximumTrackedReverseDNSLookups: 64,
        reverseDNSLookupTimeout: 5
    )

    var cacheCapacity: Int
    var maximumConcurrentReverseDNSLookups: Int
    var positiveTTL: TimeInterval
    var negativeTTL: TimeInterval
    var maximumTrackedReverseDNSLookups: Int
    var reverseDNSLookupTimeout: TimeInterval

    init(
        cacheCapacity: Int,
        maximumConcurrentReverseDNSLookups: Int,
        positiveTTL: TimeInterval,
        negativeTTL: TimeInterval,
        maximumTrackedReverseDNSLookups: Int = 64,
        reverseDNSLookupTimeout: TimeInterval = 5
    ) {
        self.cacheCapacity = max(1, cacheCapacity)
        self.maximumConcurrentReverseDNSLookups = max(1, maximumConcurrentReverseDNSLookups)
        self.positiveTTL = max(1, positiveTTL)
        self.negativeTTL = max(1, negativeTTL)
        self.maximumTrackedReverseDNSLookups = max(
            self.maximumConcurrentReverseDNSLookups,
            maximumTrackedReverseDNSLookups
        )
        self.reverseDNSLookupTimeout = max(0.1, reverseDNSLookupTimeout)
    }
}

struct BoundedLRUCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var accessOrdinal: UInt64
    }

    let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var accessOrdinal: UInt64 = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    mutating func value(forKey key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        accessOrdinal &+= 1
        entry.accessOrdinal = accessOrdinal
        entries[key] = entry
        return entry.value
    }

    mutating func insert(_ value: Value, forKey key: Key) {
        accessOrdinal &+= 1
        entries[key] = Entry(value: value, accessOrdinal: accessOrdinal)
        while entries.count > capacity {
            guard let leastRecentlyUsed = entries.min(by: {
                if $0.value.accessOrdinal != $1.value.accessOrdinal {
                    return $0.value.accessOrdinal < $1.value.accessOrdinal
                }
                return String(describing: $0.key) < String(describing: $1.key)
            })?.key else {
                break
            }
            entries.removeValue(forKey: leastRecentlyUsed)
        }
    }

    mutating func removeValue(forKey key: Key) {
        entries.removeValue(forKey: key)
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }
}

struct PeerEndpointResolverWorkload: Equatable, Sendable {
    var pendingAddressCount: Int
    var activeAddressCount: Int

    var totalAddressCount: Int {
        pendingAddressCount + activeAddressCount
    }
}

private enum ReverseDNSLookupOutcome: Sendable {
    case response(String?)
    case timedOut
    case cancelled
    case unavailable
}

private struct ReverseDNSLookupOperation: Sendable {
    let value: @Sendable () async -> ReverseDNSLookupOutcome
    let cancel: @Sendable () -> Void
}

private final class InjectedReverseDNSLookupOperation: @unchecked Sendable {
    private static let operationQueue = DispatchQueue(
        label: "net.pokwer.TransmissionRemoteMac.peer-reverse-dns.injected"
    )

    private let address: PeerIPAddress
    private let lookup: PeerEndpointResolver.ReverseDNSLookup
    private let timeout: TimeInterval
    private var queue: DispatchQueue { Self.operationQueue }
    private var continuation: CheckedContinuation<ReverseDNSLookupOutcome, Never>?
    private var completedOutcome: ReverseDNSLookupOutcome?
    private var lookupTask: Task<Void, Never>?
    private var timeoutTimer: DispatchSourceTimer?

    init(
        address: PeerIPAddress,
        timeout: TimeInterval,
        lookup: @escaping PeerEndpointResolver.ReverseDNSLookup
    ) {
        self.address = address
        self.timeout = timeout
        self.lookup = lookup
    }

    func operation() -> ReverseDNSLookupOperation {
        ReverseDNSLookupOperation(
            value: { [self] in await result() },
            cancel: { [self] in cancel() }
        )
    }

    private func result() async -> ReverseDNSLookupOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    install(continuation)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func install(
        _ continuation: CheckedContinuation<ReverseDNSLookupOutcome, Never>
    ) {
        if let completedOutcome {
            continuation.resume(returning: completedOutcome)
            return
        }
        guard self.continuation == nil else {
            continuation.resume(returning: .cancelled)
            return
        }
        self.continuation = continuation

        let lookup = lookup
        let address = address
        lookupTask = Task.detached(priority: .utility) { [weak self] in
            let hostName = await lookup(address)
            self?.queue.async { [weak self] in
                self?.finish(.response(hostName))
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.finish(.timedOut)
        }
        timeoutTimer = timer
        timer.resume()
    }

    private func cancel() {
        queue.async { [self] in
            finish(.cancelled)
        }
    }

    private func finish(_ outcome: ReverseDNSLookupOutcome) {
        guard completedOutcome == nil else { return }
        completedOutcome = outcome
        lookupTask?.cancel()
        lookupTask = nil
        timeoutTimer?.setEventHandler {}
        timeoutTimer?.cancel()
        timeoutTimer = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: outcome)
    }
}

private final class DNSServiceReverseDNSLookupOperation: @unchecked Sendable {
    private static let operationQueue = DispatchQueue(
        label: "net.pokwer.TransmissionRemoteMac.peer-reverse-dns.dnssd"
    )

    private let queryName: String
    private let timeout: TimeInterval
    private var queue: DispatchQueue { Self.operationQueue }
    private var continuation: CheckedContinuation<ReverseDNSLookupOutcome, Never>?
    private var completedOutcome: ReverseDNSLookupOutcome?
    private var serviceRef: DNSServiceRef?
    private var timeoutTimer: DispatchSourceTimer?

    init(address: PeerIPAddress, timeout: TimeInterval) {
        queryName = Self.reverseLookupName(for: address)
        self.timeout = timeout
    }

    func operation() -> ReverseDNSLookupOperation {
        ReverseDNSLookupOperation(
            value: { [self] in await result() },
            cancel: { [self] in cancel() }
        )
    }

    private func result() async -> ReverseDNSLookupOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    install(continuation)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func install(
        _ continuation: CheckedContinuation<ReverseDNSLookupOutcome, Never>
    ) {
        if let completedOutcome {
            continuation.resume(returning: completedOutcome)
            return
        }
        guard self.continuation == nil else {
            continuation.resume(returning: .cancelled)
            return
        }
        self.continuation = continuation

        var serviceRef: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let queryError = DNSServiceQueryRecord(
            &serviceRef,
            DNSServiceFlags(kDNSServiceFlagsTimeout)
                | DNSServiceFlags(kDNSServiceFlagsBackgroundTrafficClass),
            UInt32(kDNSServiceInterfaceIndexAny),
            queryName,
            UInt16(kDNSServiceType_PTR),
            UInt16(kDNSServiceClass_IN),
            { _, flags, _, errorCode, _, _, _, dataLength, data, _, context in
                guard let context else { return }
                let operation = Unmanaged<DNSServiceReverseDNSLookupOperation>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                operation.receive(
                    flags: flags,
                    errorCode: errorCode,
                    dataLength: dataLength,
                    data: data
                )
            },
            context
        )
        guard queryError == kDNSServiceErr_NoError, let serviceRef else {
            finish(.unavailable)
            return
        }
        self.serviceRef = serviceRef

        let dispatchError = DNSServiceSetDispatchQueue(serviceRef, queue)
        guard dispatchError == kDNSServiceErr_NoError else {
            finish(.unavailable)
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.finish(.timedOut)
        }
        timeoutTimer = timer
        timer.resume()
    }

    private func cancel() {
        queue.async { [self] in
            finish(.cancelled)
        }
    }

    private func receive(
        flags: DNSServiceFlags,
        errorCode: DNSServiceErrorType,
        dataLength: UInt16,
        data: UnsafeRawPointer?
    ) {
        guard errorCode == kDNSServiceErr_NoError else {
            if errorCode == kDNSServiceErr_Timeout {
                finish(.timedOut)
            } else if errorCode == kDNSServiceErr_NoSuchRecord {
                finish(.response(nil))
            } else {
                finish(.unavailable)
            }
            return
        }
        guard flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 else { return }
        finish(.response(Self.decodeDomainName(data: data, length: dataLength)))
    }

    private func finish(_ outcome: ReverseDNSLookupOutcome) {
        guard completedOutcome == nil else { return }
        completedOutcome = outcome
        timeoutTimer?.setEventHandler {}
        timeoutTimer?.cancel()
        timeoutTimer = nil
        if let serviceRef {
            DNSServiceRefDeallocate(serviceRef)
            self.serviceRef = nil
        }
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: outcome)
    }

    private static func reverseLookupName(for address: PeerIPAddress) -> String {
        switch address.family {
        case .ipv4:
            return address.bytes.reversed().map(String.init).joined(separator: ".")
                + ".in-addr.arpa."
        case .ipv6:
            let nibbles = address.bytes.flatMap { byte in
                [String(byte >> 4, radix: 16), String(byte & 0x0F, radix: 16)]
            }
            return nibbles.reversed().joined(separator: ".") + ".ip6.arpa."
        }
    }

    private static func decodeDomainName(
        data: UnsafeRawPointer?,
        length: UInt16
    ) -> String? {
        guard let data, length > 1 else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: Int(length))
        var labels: [String] = []
        var offset = 0
        while offset < Int(length) {
            let labelLength = Int(bytes[offset])
            offset += 1
            if labelLength == 0 {
                return labels.joined(separator: ".")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
            }
            guard labelLength <= 63, offset + labelLength <= Int(length) else {
                return nil
            }
            let labelBytes = UnsafeBufferPointer(
                start: bytes.advanced(by: offset),
                count: labelLength
            )
            guard let label = String(bytes: labelBytes, encoding: .utf8) else {
                return nil
            }
            labels.append(label)
            offset += labelLength
        }
        return nil
    }
}

actor PeerEndpointResolver {
    typealias ReverseDNSLookup = @Sendable (PeerIPAddress) async -> String?
    typealias DateProvider = @Sendable () -> Date

    private struct DNSCacheValue {
        var hostName: String?
        var expiresAt: Date
    }

    private struct LookupJob {
        var id: UUID
        var generation: UInt64
        var address: PeerIPAddress
        var operation: ReverseDNSLookupOperation
        var task: Task<ReverseDNSLookupOutcome, Never>
    }

    private struct ResolutionGeneration {
        var id: UInt64
        var ownerID: UUID
        var request: PeerResolutionRequest
        var pendingAddresses: [PeerIPAddress]
        var unresolvedAddresses: Set<PeerIPAddress>
        var hostNames: [PeerIPAddress: String]
        var continuation: CheckedContinuation<PeerResolutionBatch?, Never>?
    }

    private let configuration: PeerEndpointResolverConfiguration
    private let reverseDNSOperation: @Sendable (
        PeerIPAddress,
        TimeInterval
    ) -> ReverseDNSLookupOperation
    private let dateProvider: DateProvider
    private var dnsCache: BoundedLRUCache<PeerIPAddress, DNSCacheValue>
    private var generationCounter: UInt64 = 0
    private var activeGeneration: ResolutionGeneration?
    private var activeLookupJobs: [UUID: LookupJob] = [:]
    private var countryDatabase: PeerCountryDatabase?

    init(
        configuration: PeerEndpointResolverConfiguration = .standard,
        reverseDNSLookup: ReverseDNSLookup? = nil,
        dateProvider: @escaping DateProvider = { Date() }
    ) {
        self.configuration = configuration
        if let reverseDNSLookup {
            reverseDNSOperation = { address, timeout in
                InjectedReverseDNSLookupOperation(
                    address: address,
                    timeout: timeout,
                    lookup: reverseDNSLookup
                ).operation()
            }
        } else {
            reverseDNSOperation = { address, timeout in
                DNSServiceReverseDNSLookupOperation(
                    address: address,
                    timeout: timeout
                ).operation()
            }
        }
        self.dateProvider = dateProvider
        dnsCache = BoundedLRUCache(capacity: configuration.cacheCapacity)
    }

    func installCountryDatabase(_ database: PeerCountryDatabase?) {
        countryDatabase = database
    }

    func clearCaches() {
        cancelAll()
        dnsCache.removeAll()
    }

    func cancel(ownerID: UUID) {
        guard activeGeneration?.ownerID == ownerID else { return }
        invalidateActiveGeneration()
    }

    func cancelAll() {
        invalidateActiveGeneration()
    }

    func cacheEntryCount() -> Int {
        dnsCache.count
    }

    func workload() -> PeerEndpointResolverWorkload {
        PeerEndpointResolverWorkload(
            pendingAddressCount: activeGeneration?.pendingAddresses.count ?? 0,
            activeAddressCount: activeLookupJobs.count
        )
    }

    func resolve(
        _ request: PeerResolutionRequest,
        ownerID: UUID = UUID()
    ) async -> PeerResolutionBatch? {
        guard !Task.isCancelled else { return nil }
        let preferences = request.preferences.effective(
            countryDatabaseAvailable: countryDatabase != nil
        )
        let endpointsByAddress = Dictionary(
            request.endpoints.map { ($0.address, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let generationID = beginGeneration(
            ownerID: ownerID,
            request: request,
            addresses: Array(endpointsByAddress.keys).sorted(),
            resolveHostNames: preferences.resolveHostNames
        )

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                installContinuation(continuation, generationID: generationID)
            }
        } onCancel: {
            Task { await self.cancel(ownerID: ownerID) }
        }
    }

    private func beginGeneration(
        ownerID: UUID,
        request: PeerResolutionRequest,
        addresses: [PeerIPAddress],
        resolveHostNames: Bool
    ) -> UInt64 {
        invalidateActiveGeneration()
        generationCounter &+= 1
        let generationID = generationCounter
        var hostNames: [PeerIPAddress: String] = [:]
        var pendingAddresses: [PeerIPAddress] = []

        if resolveHostNames {
            let now = dateProvider()
            let availableCapacity = max(
                0,
                configuration.maximumTrackedReverseDNSLookups - activeLookupJobs.count
            )
            for address in addresses {
                if let cached = dnsCache.value(forKey: address) {
                    if cached.expiresAt > now {
                        if let hostName = cached.hostName {
                            hostNames[address] = hostName
                        }
                        continue
                    }
                    dnsCache.removeValue(forKey: address)
                }
                guard pendingAddresses.count < availableCapacity else { continue }
                pendingAddresses.append(address)
            }
        }

        activeGeneration = ResolutionGeneration(
            id: generationID,
            ownerID: ownerID,
            request: request,
            pendingAddresses: pendingAddresses,
            unresolvedAddresses: Set(pendingAddresses),
            hostNames: hostNames,
            continuation: nil
        )
        return generationID
    }

    private func installContinuation(
        _ continuation: CheckedContinuation<PeerResolutionBatch?, Never>,
        generationID: UInt64
    ) {
        guard activeGeneration?.id == generationID else {
            continuation.resume(returning: nil)
            return
        }
        guard activeGeneration?.continuation == nil else {
            continuation.resume(returning: nil)
            return
        }
        activeGeneration?.continuation = continuation
        scheduleLookupJobs()
        finishGenerationIfReady(generationID)
    }

    private func scheduleLookupJobs() {
        guard var generation = activeGeneration else { return }
        while
            activeLookupJobs.count < configuration.maximumConcurrentReverseDNSLookups,
            !generation.pendingAddresses.isEmpty
        {
            let address = generation.pendingAddresses.removeFirst()
            let jobID = UUID()
            let generationID = generation.id
            let operation = reverseDNSOperation(
                address,
                configuration.reverseDNSLookupTimeout
            )
            let task = Task.detached(priority: .utility) { [weak self] in
                let outcome = await operation.value()
                let wasCancelled = Task.isCancelled
                await self?.lookupDidFinish(
                    jobID: jobID,
                    generationID: generationID,
                    address: address,
                    outcome: outcome,
                    wasCancelled: wasCancelled
                )
                return outcome
            }
            activeLookupJobs[jobID] = LookupJob(
                id: jobID,
                generation: generationID,
                address: address,
                operation: operation,
                task: task
            )
        }
        activeGeneration = generation
    }

    private func lookupDidFinish(
        jobID: UUID,
        generationID: UInt64,
        address: PeerIPAddress,
        outcome: ReverseDNSLookupOutcome,
        wasCancelled: Bool
    ) {
        guard let job = activeLookupJobs.removeValue(forKey: jobID) else { return }
        guard
            !wasCancelled,
            !job.task.isCancelled,
            job.generation == generationID,
            job.address == address,
            activeGeneration?.id == generationID
        else {
            scheduleLookupJobs()
            return
        }

        activeGeneration?.unresolvedAddresses.remove(address)
        guard case let .response(value) = outcome else {
            scheduleLookupJobs()
            finishGenerationIfReady(generationID)
            return
        }
        let normalizedValue = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let ttl = normalizedValue == nil
            ? configuration.negativeTTL
            : configuration.positiveTTL
        dnsCache.insert(
            DNSCacheValue(
                hostName: normalizedValue,
                expiresAt: dateProvider().addingTimeInterval(ttl)
            ),
            forKey: address
        )
        if let normalizedValue {
            activeGeneration?.hostNames[address] = normalizedValue
        }
        scheduleLookupJobs()
        finishGenerationIfReady(generationID)
    }

    private func finishGenerationIfReady(_ generationID: UInt64) {
        guard
            let generation = activeGeneration,
            generation.id == generationID,
            generation.unresolvedAddresses.isEmpty,
            let continuation = generation.continuation
        else {
            return
        }
        activeGeneration = nil
        continuation.resume(returning: makeBatch(for: generation))
    }

    private func makeBatch(for generation: ResolutionGeneration) -> PeerResolutionBatch {
        let preferences = generation.request.preferences.effective(
            countryDatabaseAvailable: countryDatabase != nil
        )
        let addresses = Set(generation.request.endpoints.map(\.address))
        var metadataByAddress: [PeerIPAddress: PeerResolvedMetadata] = [:]
        metadataByAddress.reserveCapacity(addresses.count)
        for address in addresses {
            let countryCode = preferences.resolveCountries
                ? countryDatabase?.countryCode(for: address)
                : nil
            metadataByAddress[address] = PeerResolvedMetadata(
                address: address,
                hostName: generation.hostNames[address],
                countryCode: countryCode,
                countryName: countryCode.flatMap {
                    PeerCountryPresentation.localizedName(for: $0)
                },
                countryFlag: preferences.showCountryFlags
                    ? countryCode.flatMap(PeerCountryPresentation.flag(for:))
                    : nil
            )
        }
        return PeerResolutionBatch(
            context: generation.request.context,
            metadataByAddress: metadataByAddress
        )
    }

    private func invalidateActiveGeneration() {
        guard let generation = activeGeneration else { return }
        activeGeneration = nil
        let cancelledJobs = activeLookupJobs.filter { $0.value.generation == generation.id }
        for (jobID, job) in cancelledJobs {
            activeLookupJobs.removeValue(forKey: jobID)
            job.operation.cancel()
            job.task.cancel()
        }
        generation.continuation?.resume(returning: nil)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
