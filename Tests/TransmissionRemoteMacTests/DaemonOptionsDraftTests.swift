// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class DaemonOptionsDraftTests: XCTestCase {
    func testDraftBuildsChangedOnlyUpdateForEditableFields() throws {
        let options = DaemonOptions(
            arguments: [
                "rpc-version": .int(14),
                "download-dir": .string("/srv/downloads"),
                "port-forwarding-enabled": .bool(true),
                "encryption": .string("preferred"),
                "speed-limit-down-enabled": .bool(true),
                "speed-limit-down": .int(900),
                "speed-limit-up-enabled": .bool(false),
                "speed-limit-up": .int(100),
                "peer-port": .int(51_413),
                "peer-port-random-on-start": .bool(false),
                "peer-limit-global": .int(200),
                "peer-limit-per-torrent": .int(50),
                "pex-enabled": .bool(true),
                "dht-enabled": .bool(true),
                "seedRatioLimited": .bool(false),
                "seedRatioLimit": .double(2),
                "blocklist-enabled": .bool(false),
                "blocklist-url": .string("https://example.invalid/blocklist"),
                "alt-speed-enabled": .bool(true),
                "alt-speed-down": .int(80),
                "alt-speed-up": .int(40),
                "alt-speed-time-enabled": .bool(false),
                "alt-speed-time-begin": .int(60),
                "alt-speed-time-end": .int(120),
                "alt-speed-time-day": .int(62),
                "incomplete-dir-enabled": .bool(false),
                "incomplete-dir": .string("/srv/incomplete"),
                "rename-partial-files": .bool(true),
                "lpd-enabled": .bool(true),
                "cache-size-mb": .int(4),
                "idle-seeding-limit-enabled": .bool(false),
                "idle-seeding-limit": .int(30),
                "utp-enabled": .bool(true),
                "download-queue-enabled": .bool(true),
                "download-queue-size": .int(3),
                "seed-queue-enabled": .bool(true),
                "seed-queue-size": .int(4),
                "queue-stalled-enabled": .bool(true),
                "queue-stalled-minutes": .int(30)
            ],
            rpcVersion: 14
        )
        let capabilities = SessionCapabilities(rpcVersion: 14)
        var draft = DaemonOptionsDraft(options: options)

        draft.downloadSpeedLimitEnabled = false
        draft.alternateSpeedUpKBps = "45"
        draft.seedQueueSize = "6"

        let update = try XCTUnwrap(draft.update(comparedTo: options, capabilities: capabilities))
        let arguments = update.arguments(rpcVersion: 14)

        XCTAssertEqual(arguments["speed-limit-down-enabled"], .bool(false))
        XCTAssertEqual(arguments["speed-limit-down"], nil)
        XCTAssertEqual(arguments["alt-speed-up"], .int(45))
        XCTAssertEqual(arguments["seed-queue-size"], .int(6))
        XCTAssertEqual(arguments["alt-speed-down"], nil)
        XCTAssertEqual(arguments["download-queue-size"], nil)
        XCTAssertEqual(arguments["queue-stalled-minutes"], nil)
    }

    func testDraftValidationRejectsInvalidVisibleNumbers() {
        let options = DaemonOptions(
            arguments: [
                "download-dir": .string("/srv/downloads"),
                "port": .int(51_413),
                "peer-limit": .int(200),
                "pex-allowed": .bool(true),
                "speed-limit-down-enabled": .bool(true),
                "speed-limit-down": .int(900),
                "speed-limit-up-enabled": .bool(false),
                "speed-limit-up": .int(100),
                "peer-port": .int(51_413),
                "peer-limit-global": .int(200),
                "peer-limit-per-torrent": .int(50),
                "alt-speed-enabled": .bool(false),
                "alt-speed-down": .int(80),
                "alt-speed-up": .int(40)
            ],
            rpcVersion: 5
        )
        var draft = DaemonOptionsDraft(options: options)
        draft.downloadSpeedLimitKBps = "fast"
        draft.alternateSpeedDownKBps = "-1"

        XCTAssertEqual(
            draft.validationIssues(capabilities: SessionCapabilities(rpcVersion: 5)),
            [
                "Download speed limit must be a whole number.",
                "Alternate download speed must be a whole number."
            ]
        )
    }

    func testDraftBuildsExpandedChangedOnlyUpdateForDaemonSettings() throws {
        let options = DaemonOptions(
            arguments: [
                "rpc-version": .int(14),
                "download-dir": .string("/srv/downloads"),
                "port-forwarding-enabled": .bool(false),
                "encryption": .string("tolerated"),
                "speed-limit-down-enabled": .bool(false),
                "speed-limit-down": .int(900),
                "speed-limit-up-enabled": .bool(false),
                "speed-limit-up": .int(100),
                "peer-port": .int(51_413),
                "peer-port-random-on-start": .bool(false),
                "peer-limit-global": .int(200),
                "peer-limit-per-torrent": .int(50),
                "pex-enabled": .bool(true),
                "dht-enabled": .bool(true),
                "seedRatioLimited": .bool(false),
                "seedRatioLimit": .double(2),
                "blocklist-enabled": .bool(false),
                "blocklist-url": .string("https://example.invalid/blocklist"),
                "alt-speed-enabled": .bool(false),
                "alt-speed-down": .int(80),
                "alt-speed-up": .int(40),
                "alt-speed-time-enabled": .bool(false),
                "alt-speed-time-begin": .int(60),
                "alt-speed-time-end": .int(120),
                "alt-speed-time-day": .int(62),
                "incomplete-dir-enabled": .bool(false),
                "incomplete-dir": .string("/srv/incomplete"),
                "rename-partial-files": .bool(false),
                "lpd-enabled": .bool(false),
                "cache-size-mb": .int(4),
                "idle-seeding-limit-enabled": .bool(false),
                "idle-seeding-limit": .int(30),
                "utp-enabled": .bool(false),
                "download-queue-enabled": .bool(false),
                "download-queue-size": .int(3),
                "seed-queue-enabled": .bool(false),
                "seed-queue-size": .int(4),
                "queue-stalled-enabled": .bool(false),
                "queue-stalled-minutes": .int(30)
            ],
            rpcVersion: 14
        )
        let capabilities = SessionCapabilities(rpcVersion: 14)
        var draft = DaemonOptionsDraft(options: options)

        draft.encryption = .required
        draft.peerLimitGlobal = "250"
        draft.peerLimitPerTorrent = "60"
        draft.incompleteDirectoryEnabled = true
        draft.incompleteDirectory = "/srv/downloading"
        draft.blocklistEnabled = true
        draft.blocklistURL = "https://example.invalid/new-blocklist"
        draft.alternateSpeedTimeEnabled = true
        draft.alternateSpeedTimeBegin = "01:30"
        draft.alternateSpeedTimeEnd = "03:00"
        draft.alternateSpeedSunday = true
        draft.alternateSpeedMonday = false
        draft.alternateSpeedTuesday = true
        draft.alternateSpeedWednesday = false
        draft.alternateSpeedThursday = true
        draft.alternateSpeedFriday = false
        draft.alternateSpeedSaturday = true
        draft.cacheSizeMB = "8"
        draft.idleSeedingLimitEnabled = true
        draft.idleSeedingLimitMinutes = "45"
        draft.utpEnabled = true

        let update = try XCTUnwrap(draft.update(comparedTo: options, capabilities: capabilities))
        let arguments = update.arguments(rpcVersion: 14)

        XCTAssertEqual(arguments["encryption"], .string("required"))
        XCTAssertEqual(arguments["peer-limit-global"], .int(250))
        XCTAssertEqual(arguments["peer-limit-per-torrent"], .int(60))
        XCTAssertEqual(arguments["incomplete-dir-enabled"], .bool(true))
        XCTAssertEqual(arguments["incomplete-dir"], .string("/srv/downloading"))
        XCTAssertEqual(arguments["blocklist-enabled"], .bool(true))
        XCTAssertEqual(arguments["blocklist-url"], .string("https://example.invalid/new-blocklist"))
        XCTAssertEqual(arguments["alt-speed-time-enabled"], .bool(true))
        XCTAssertEqual(arguments["alt-speed-time-begin"], .int(90))
        XCTAssertEqual(arguments["alt-speed-time-end"], .int(180))
        XCTAssertEqual(arguments["alt-speed-time-day"], .int(85))
        XCTAssertEqual(arguments["cache-size-mb"], .int(8))
        XCTAssertEqual(arguments["idle-seeding-limit-enabled"], .bool(true))
        XCTAssertEqual(arguments["idle-seeding-limit"], .int(45))
        XCTAssertEqual(arguments["utp-enabled"], .bool(true))
        XCTAssertEqual(arguments["peer-port"], nil)
        XCTAssertEqual(arguments["download-queue-size"], nil)
    }

    func testDraftValidationCoversEnabledExpandedFields() {
        let options = DaemonOptions(
            arguments: [
                "download-dir": .string("/srv/downloads"),
                "speed-limit-down-enabled": .bool(false),
                "speed-limit-down": .int(900),
                "speed-limit-up-enabled": .bool(false),
                "speed-limit-up": .int(100),
                "peer-port": .int(51_413),
                "peer-limit-global": .int(200),
                "peer-limit-per-torrent": .int(50),
                "seedRatioLimited": .bool(false),
                "seedRatioLimit": .double(2),
                "blocklist-enabled": .bool(false),
                "alt-speed-down": .int(80),
                "alt-speed-up": .int(40),
                "alt-speed-time-enabled": .bool(false),
                "alt-speed-time-begin": .int(60),
                "alt-speed-time-end": .int(120),
                "alt-speed-time-day": .int(62),
                "incomplete-dir-enabled": .bool(false),
                "incomplete-dir": .string("/srv/incomplete"),
                "cache-size-mb": .int(4),
                "idle-seeding-limit-enabled": .bool(false),
                "idle-seeding-limit": .int(30),
                "download-queue-enabled": .bool(false),
                "download-queue-size": .int(3),
                "seed-queue-enabled": .bool(false),
                "seed-queue-size": .int(4),
                "queue-stalled-enabled": .bool(false),
                "queue-stalled-minutes": .int(30)
            ],
            rpcVersion: 14
        )
        var draft = DaemonOptionsDraft(options: options)

        draft.seedRatioLimited = true
        draft.seedRatioLimit = "ratio"
        draft.blocklistEnabled = true
        draft.blocklistURL = " "
        draft.alternateSpeedTimeEnabled = true
        draft.alternateSpeedTimeBegin = "25:00"
        draft.alternateSpeedTimeEnd = ""
        draft.alternateSpeedSunday = false
        draft.alternateSpeedMonday = false
        draft.alternateSpeedTuesday = false
        draft.alternateSpeedWednesday = false
        draft.alternateSpeedThursday = false
        draft.alternateSpeedFriday = false
        draft.alternateSpeedSaturday = false
        draft.incompleteDirectoryEnabled = true
        draft.incompleteDirectory = ""
        draft.cacheSizeMB = "-1"
        draft.idleSeedingLimitEnabled = true
        draft.idleSeedingLimitMinutes = "idle"

        XCTAssertEqual(
            draft.validationIssues(capabilities: SessionCapabilities(rpcVersion: 14)),
            [
                "Seed ratio limit must be a number.",
                "Blocklist URL is required.",
                "Alternate speed start time must use HH:MM.",
                "Alternate speed end time is required.",
                "Alternate speed schedule must include at least one day.",
                "Incomplete folder is required.",
                "Cache size must be a whole number.",
                "Idle seeding limit must be a whole number."
            ]
        )
    }

    func testPeerPortValidationRejectsZeroAndValuesAboveTCPRangeAcrossRPCGenerations() {
        for rpcVersion in [4, 14] {
            let options = DaemonOptions(
                arguments: [
                    "download-dir": .string("/srv/downloads"),
                    "speed-limit-down-enabled": .bool(false),
                    "speed-limit-down": .int(0),
                    "speed-limit-up-enabled": .bool(false),
                    "speed-limit-up": .int(0),
                    rpcVersion >= 5 ? "peer-port" : "port": .int(51_413),
                    rpcVersion >= 5 ? "peer-limit-global" : "peer-limit": .int(50),
                    "peer-limit-per-torrent": .int(25),
                    "alt-speed-down": .int(0),
                    "alt-speed-up": .int(0),
                ],
                rpcVersion: rpcVersion
            )
            for invalidPort in ["0", "65536"] {
                var draft = DaemonOptionsDraft(options: options)
                draft.peerPort = invalidPort

                XCTAssertTrue(
                    draft.validationIssues(
                        capabilities: SessionCapabilities(rpcVersion: rpcVersion)
                    ).contains("Peer port must be a whole number from 1 to 65535.")
                )
            }
        }
    }

    func testExpandedUpdateArgumentsRemainVersionGated() {
        let update = DaemonOptionsUpdate(
            downloadDirectory: "/srv/downloads",
            portForwardingEnabled: true,
            encryption: .preferred,
            peerPort: 51_413,
            peerPortRandomOnStart: true,
            peerLimitGlobal: 200,
            peerLimitPerTorrent: 50,
            legacyPeerLimit: 80,
            pexEnabled: true,
            dhtEnabled: true,
            seedRatioLimited: true,
            seedRatioLimit: 2.5,
            blocklistEnabled: true,
            blocklistURL: "https://example.invalid/blocklist",
            alternateSpeedTimeEnabled: true,
            alternateSpeedTimeBeginMinutes: 60,
            alternateSpeedTimeEndMinutes: 120,
            alternateSpeedTimeDayMask: 62,
            incompleteDirectoryEnabled: true,
            incompleteDirectory: "/srv/incomplete",
            renamePartialFiles: true,
            lpdEnabled: true,
            cacheSizeMB: 8,
            idleSeedingLimitEnabled: true,
            idleSeedingLimitMinutes: 45,
            utpEnabled: true,
            downloadQueueEnabled: true,
            downloadQueueSize: 3,
            seedQueueEnabled: true,
            seedQueueSize: 4,
            queueStalledEnabled: true,
            queueStalledMinutes: 30
        )

        let legacyArguments = update.arguments(rpcVersion: 4)
        XCTAssertEqual(legacyArguments["port"], .int(51_413))
        XCTAssertEqual(legacyArguments["peer-limit"], .int(80))
        XCTAssertEqual(legacyArguments["pex-allowed"], .bool(true))
        XCTAssertEqual(legacyArguments["peer-limit-global"], nil)
        XCTAssertEqual(legacyArguments["blocklist-url"], nil)
        XCTAssertEqual(legacyArguments["utp-enabled"], nil)

        let rpc10Arguments = update.arguments(rpcVersion: 10)
        XCTAssertEqual(rpc10Arguments["peer-limit-global"], .int(200))
        XCTAssertEqual(rpc10Arguments["seedRatioLimit"], .double(2.5))
        XCTAssertEqual(rpc10Arguments["blocklist-enabled"], .bool(true))
        XCTAssertEqual(rpc10Arguments["blocklist-url"], nil)
        XCTAssertEqual(rpc10Arguments["incomplete-dir"], .string("/srv/incomplete"))
        XCTAssertEqual(rpc10Arguments["rename-partial-files"], .bool(true))
        XCTAssertEqual(rpc10Arguments["lpd-enabled"], .bool(true))
        XCTAssertEqual(rpc10Arguments["cache-size-mb"], .int(8))
        XCTAssertEqual(rpc10Arguments["idle-seeding-limit"], .int(45))
        XCTAssertEqual(rpc10Arguments["utp-enabled"], nil)
        XCTAssertEqual(rpc10Arguments["download-queue-enabled"], nil)

        let rpc11Arguments = update.arguments(rpcVersion: 11)
        XCTAssertEqual(rpc11Arguments["blocklist-enabled"], .bool(true))
        XCTAssertEqual(
            rpc11Arguments["blocklist-url"],
            .string("https://example.invalid/blocklist")
        )

        let rpc14Arguments = update.arguments(rpcVersion: 14)
        XCTAssertEqual(rpc14Arguments["utp-enabled"], .bool(true))
        XCTAssertEqual(rpc14Arguments["download-queue-enabled"], .bool(true))
        XCTAssertEqual(rpc14Arguments["download-queue-size"], .int(3))
    }

    func testDisabledSeedChildrenAreIgnoredAndNeverEmitted() {
        let options = DaemonOptions(
            arguments: [
                "rpc-version": .int(14),
                "download-dir": .string("/srv/downloads"),
                "speed-limit-down-enabled": .bool(false),
                "speed-limit-down": .int(100),
                "speed-limit-up-enabled": .bool(false),
                "speed-limit-up": .int(100),
                "peer-port": .int(51_413),
                "peer-limit-global": .int(200),
                "peer-limit-per-torrent": .int(50),
                "seedRatioLimited": .bool(false),
                "seedRatioLimit": .double(2),
                "alt-speed-down": .int(50),
                "alt-speed-up": .int(25),
                "idle-seeding-limit-enabled": .bool(false),
                "idle-seeding-limit": .int(30),
                "cache-size-mb": .int(4),
                "download-queue-size": .int(3),
                "seed-queue-size": .int(4),
                "queue-stalled-minutes": .int(30)
            ],
            rpcVersion: 14
        )
        let capabilities = SessionCapabilities(rpcVersion: 14)
        var draft = DaemonOptionsDraft(options: options)
        draft.seedRatioLimit = "9"
        draft.idleSeedingLimitMinutes = "90"

        XCTAssertFalse(draft.hasChanges(comparedTo: options, capabilities: capabilities))
        XCTAssertNil(draft.update(comparedTo: options, capabilities: capabilities))

        let directUpdate = DaemonOptionsUpdate(
            seedRatioLimited: false,
            seedRatioLimit: 9,
            idleSeedingLimitEnabled: false,
            idleSeedingLimitMinutes: 90
        )
        let arguments = directUpdate.arguments(rpcVersion: 14)
        XCTAssertEqual(arguments["seedRatioLimited"], .bool(false))
        XCTAssertEqual(arguments["seedRatioLimit"], nil)
        XCTAssertEqual(arguments["idle-seeding-limit-enabled"], .bool(false))
        XCTAssertEqual(arguments["idle-seeding-limit"], nil)
    }
}
