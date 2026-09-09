// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class PathMappingServiceTests: XCTestCase {
    func testResolvedPathsPreserveSignificantWhitespaceInBothMappingDirections() throws {
        let mapping = try PathMapping.validated(
            remotePathPrefix: " /srv/downloads/ ",
            localPathPrefix: " /Users/tester/Media/ "
        )
        let service = PathMappingService(mappings: [mapping], host: "transmission.example")

        for suffix in ["Movie.mkv ", "Episode.mkv\n", "Folder \t/File "] {
            let daemonPath = "/srv/downloads/\(suffix)"
            let localPath = "/Users/tester/Media/\(suffix)"
            XCTAssertEqual(service.localPath(forDaemonPath: daemonPath), localPath)
            XCTAssertEqual(try service.resolvedLocalPath(forDaemonPath: daemonPath), localPath)
            XCTAssertEqual(try service.daemonPath(forLocalPath: localPath), daemonPath)
        }

        XCTAssertNil(service.localPath(forDaemonPath: " /srv/downloads/Movie.mkv"))
    }

    func testLoopbackFallbackPreservesSignificantFilenameWhitespace() throws {
        let service = PathMappingService(profile: .localDefault)
        for path in ["/Users/tester/Media/Movie.mkv ", "/Users/tester/Media/Episode.mkv\n"] {
            XCTAssertEqual(try service.resolvedLocalPath(forDaemonPath: path), path)
        }
    }

    func testHostMappingInitializerPreservesProfilePathPolicy() throws {
        let mapping = PathMapping(remotePathPrefix: "/remote", localPathPrefix: "/Users/tester/Media")
        for host in ["localhost", "LOCALHOST", "127.0.0.1", "::1", "[::1]", "transmission.example"] {
            for mappings in [[], [mapping]] {
                let profile = ConnectionProfile(name: "Test", host: host, pathMappings: mappings)
                let allowsUnmappedPaths = host != "transmission.example"
                for service in [
                    PathMappingService(profile: profile),
                    PathMappingService(mappings: mappings, host: host)
                ] {
                    for path in ["/remote/file.bin", "/Users/tester/Unmapped/file.bin", "relative/file.bin"] {
                        if !mappings.isEmpty, path == "/remote/file.bin" {
                            XCTAssertEqual(try service.resolvedLocalPath(forDaemonPath: path), "/Users/tester/Media/file.bin", host)
                        } else if allowsUnmappedPaths, path.hasPrefix("/") {
                            XCTAssertEqual(try service.resolvedLocalPath(forDaemonPath: path), path, host)
                        } else {
                            XCTAssertThrowsError(try service.resolvedLocalPath(forDaemonPath: path)) {
                                XCTAssertEqual($0 as? PathMappingResolutionError, .noMappingForNonLocalPath(path), host)
                            }
                        }
                    }
                }
            }
        }
    }

    func testMapsExactRemotePathToLocalPrefix() throws {
        let mapping = try PathMapping.validated(
            remotePathPrefix: "/downloads",
            localPathPrefix: "/Volumes/Downloads"
        )
        let service = PathMappingService(mappings: [mapping])

        XCTAssertEqual(service.localPath(forDaemonPath: "/downloads"), "/Volumes/Downloads")
    }

    func testResolvesMappedDaemonPathToLocalPath() throws {
        let mapping = try PathMapping.validated(
            remotePathPrefix: "/srv/downloads",
            localPathPrefix: "/Volumes/Downloads"
        )
        let service = PathMappingService(mappings: [mapping])

        XCTAssertEqual(
            try service.resolvedLocalPath(forDaemonPath: "/srv/downloads/tv/show.mkv"),
            "/Volumes/Downloads/tv/show.mkv"
        )
    }

    func testFallsBackToAbsoluteDaemonPathWhenNoMappingMatches() throws {
        let service = PathMappingService(mappings: [])

        XCTAssertEqual(
            try service.resolvedLocalPath(forDaemonPath: "/Users/tester/Downloads/file.iso"),
            "/Users/tester/Downloads/file.iso"
        )
    }

    func testRejectsRelativeDaemonPathWithoutMapping() {
        let service = PathMappingService(mappings: [])

        XCTAssertThrowsError(try service.resolvedLocalPath(forDaemonPath: "Downloads/file.iso")) { error in
            XCTAssertEqual(error as? PathMappingResolutionError, .noMappingForNonLocalPath("Downloads/file.iso"))
        }
    }

    func testRemoteProfileRejectsUnmappedAbsoluteDaemonPath() throws {
        let profile = try ConnectionProfile.validated(
            name: "Remote",
            host: "transmission.example"
        )
        let service = PathMappingService(profile: profile)

        XCTAssertThrowsError(try service.resolvedLocalPath(forDaemonPath: "/Applications/Example.app")) { error in
            XCTAssertEqual(
                error as? PathMappingResolutionError,
                .noMappingForNonLocalPath("/Applications/Example.app")
            )
        }
    }

    func testLocalProfileAllowsStandardizedAbsoluteDaemonPath() throws {
        let service = PathMappingService(profile: .localDefault)

        XCTAssertEqual(
            try service.resolvedLocalPath(forDaemonPath: "/Users/tester/Downloads/../Media/file.iso"),
            "/Users/tester/Media/file.iso"
        )
    }

    func testMappedPathCannotEscapeLocalPrefix() throws {
        let mapping = try PathMapping.validated(
            remotePathPrefix: "/srv/downloads",
            localPathPrefix: "/Users/tester/Media"
        )
        let service = PathMappingService(mappings: [mapping])

        XCTAssertNil(
            service.localPath(forDaemonPath: "/srv/downloads/../../Applications/Example.app")
        )
        XCTAssertThrowsError(
            try service.resolvedLocalPath(forDaemonPath: "/srv/downloads/../../Applications/Example.app")
        )
    }

    func testMapsRemotePathSuffixOntoLocalPrefix() throws {
        let mapping = try PathMapping.validated(
            remotePathPrefix: "/downloads",
            localPathPrefix: "/Volumes/Downloads"
        )
        let service = PathMappingService(mappings: [mapping])

        XCTAssertEqual(
            service.localPath(forDaemonPath: "/downloads/music/album.flac"),
            "/Volumes/Downloads/music/album.flac"
        )
    }

    func testUsesLongestMatchingRemotePrefix() throws {
        let broad = try PathMapping.validated(
            remotePathPrefix: "/downloads",
            localPathPrefix: "/Volumes/Downloads"
        )
        let specific = try PathMapping.validated(
            remotePathPrefix: "/downloads/music",
            localPathPrefix: "/Volumes/Music"
        )
        let service = PathMappingService(mappings: [broad, specific])

        XCTAssertEqual(
            service.localPath(forDaemonPath: "/downloads/music/album.flac"),
            "/Volumes/Music/album.flac"
        )
    }

    func testDoesNotMatchPartialPathSegment() throws {
        let mapping = try PathMapping.validated(
            remotePathPrefix: "/downloads",
            localPathPrefix: "/Volumes/Downloads"
        )
        let service = PathMappingService(mappings: [mapping])

        XCTAssertNil(service.localPath(forDaemonPath: "/downloads-old/file.mkv"))
    }

    func testRootMappingPreservesFullDaemonSuffix() throws {
        let mapping = try PathMapping.validated(
            remotePathPrefix: "/",
            localPathPrefix: "/Volumes/Remote"
        )
        let service = PathMappingService(mappings: [mapping])

        XCTAssertEqual(service.localPath(forDaemonPath: "/tv/show.mkv"), "/Volumes/Remote/tv/show.mkv")
    }

    func testReverseMappingMapsExactLocalRootToDaemonPrefix() throws {
        let mapping = try PathMapping.validated(
            remotePathPrefix: "/srv/downloads",
            localPathPrefix: "/Volumes/Downloads"
        )
        let service = PathMappingService(mappings: [mapping])

        XCTAssertEqual(
            try service.daemonPath(forLocalPath: "/Volumes/Downloads"),
            "/srv/downloads"
        )
    }

    func testReverseMappingPreservesNestedSuffixAndSpaces() throws {
        let mapping = try PathMapping.validated(
            remotePathPrefix: "/srv/media files",
            localPathPrefix: "/Volumes/Media Files"
        )
        let service = PathMappingService(mappings: [mapping])

        XCTAssertEqual(
            try service.daemonPath(forLocalPath: "/Volumes/Media Files/TV Shows/Series One"),
            "/srv/media files/TV Shows/Series One"
        )
    }

    func testReverseMappingUsesLongestMatchingLocalPrefix() throws {
        let broad = try PathMapping.validated(
            remotePathPrefix: "/srv/downloads",
            localPathPrefix: "/Volumes/Downloads"
        )
        let specific = try PathMapping.validated(
            remotePathPrefix: "/srv/music",
            localPathPrefix: "/Volumes/Downloads/Music"
        )
        let service = PathMappingService(mappings: [broad, specific])

        XCTAssertEqual(
            try service.daemonPath(forLocalPath: "/Volumes/Downloads/Music/Album"),
            "/srv/music/Album"
        )
    }

    func testReverseMappingRejectsSiblingPrefixEscape() throws {
        let mapping = try PathMapping.validated(
            remotePathPrefix: "/srv/downloads",
            localPathPrefix: "/Volumes/Downloads"
        )
        let service = PathMappingService(mappings: [mapping])
        let selectedPath = "/Volumes/Downloads-Archive/Movie"

        XCTAssertThrowsError(try service.daemonPath(forLocalPath: selectedPath)) { error in
            XCTAssertEqual(
                error as? PathMappingResolutionError,
                .noMappingForLocalPath(selectedPath)
            )
        }
    }

    func testReverseMappingRejectsTraversalAndSymlinkEscapes() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let mappedRoot = temporaryRoot.appendingPathComponent("Mapped", isDirectory: true)
        let outsideRoot = temporaryRoot.appendingPathComponent("Outside", isDirectory: true)
        let symlink = mappedRoot.appendingPathComponent("Outside Link")
        try FileManager.default.createDirectory(at: mappedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideRoot)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let mapping = try PathMapping.validated(
            remotePathPrefix: "/srv/downloads",
            localPathPrefix: mappedRoot.path
        )
        let service = PathMappingService(mappings: [mapping])

        for selectedPath in [
            mappedRoot.appendingPathComponent("../Outside").path,
            symlink.appendingPathComponent("Movie").path
        ] {
            XCTAssertThrowsError(try service.daemonPath(forLocalPath: selectedPath)) { error in
                XCTAssertEqual(
                    error as? PathMappingResolutionError,
                    .noMappingForLocalPath(selectedPath)
                )
            }
        }
    }

    func testReverseMappingRejectsEquallySpecificAmbiguousMappings() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let realRoot = temporaryRoot.appendingPathComponent("Real Root", isDirectory: true)
        let aliasRoot = temporaryRoot.appendingPathComponent("Alias Root", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: realRoot)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let service = PathMappingService(mappings: [
            try PathMapping.validated(
                remotePathPrefix: "/srv/one",
                localPathPrefix: realRoot.path
            ),
            try PathMapping.validated(
                remotePathPrefix: "/srv/two",
                localPathPrefix: aliasRoot.path
            )
        ])
        let selectedPath = realRoot.appendingPathComponent("Movies").path

        XCTAssertThrowsError(try service.daemonPath(forLocalPath: selectedPath)) { error in
            XCTAssertEqual(
                error as? PathMappingResolutionError,
                .ambiguousLocalPath(
                    selectedPath,
                    daemonPaths: ["/srv/one/Movies", "/srv/two/Movies"]
                )
            )
        }
    }

    func testPathMappingValidationTrimsTrailingSeparatorsAndRejectsBlanks() throws {
        let mapping = try PathMapping.validated(
            remotePathPrefix: " /downloads/ ",
            localPathPrefix: " /Volumes/Downloads/ "
        )

        XCTAssertEqual(mapping.remotePathPrefix, "/downloads")
        XCTAssertEqual(mapping.localPathPrefix, "/Volumes/Downloads")

        XCTAssertThrowsError(try PathMapping.validated(remotePathPrefix: " ", localPathPrefix: "/tmp")) { error in
            XCTAssertEqual(error as? ConnectionProfileValidationError, .pathMappingRemotePathRequired)
        }
        XCTAssertThrowsError(try PathMapping.validated(remotePathPrefix: "/tmp", localPathPrefix: " ")) { error in
            XCTAssertEqual(error as? ConnectionProfileValidationError, .pathMappingLocalPathRequired)
        }
    }

    func testProfileValidationSortsMappingsAndRejectsDuplicateRemotePrefixes() throws {
        let profile = try ConnectionProfile.validated(
            name: "Remote",
            host: "transmission.example",
            pathMappings: [
                PathMapping(remotePathPrefix: "/z", localPathPrefix: "/Volumes/Z"),
                PathMapping(remotePathPrefix: "/a", localPathPrefix: "/Volumes/A")
            ]
        )

        XCTAssertEqual(profile.pathMappings.map(\.remotePathPrefix), ["/a", "/z"])

        XCTAssertThrowsError(
            try ConnectionProfile.validated(
                name: "Remote",
                host: "transmission.example",
                pathMappings: [
                    PathMapping(remotePathPrefix: "/downloads", localPathPrefix: "/Volumes/One"),
                    PathMapping(remotePathPrefix: "/downloads/", localPathPrefix: "/Volumes/Two")
                ]
            )
        ) { error in
            XCTAssertEqual(error as? ConnectionProfileValidationError, .duplicatePathMappingRemotePath("/downloads"))
        }
    }
}
