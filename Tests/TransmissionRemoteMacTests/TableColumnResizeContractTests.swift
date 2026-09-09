// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import Combine
import Foundation
import SwiftUI
import XCTest
@testable import TransmissionRemoteMac

final class TableColumnResizeContractTests: XCTestCase {
    func testEveryCustomizedProductionTableColumnDeclaresARangedWidth() throws {
        let expectations: [(fileName: String, expectedIDs: Set<String>)] = [
            (
                fileName: "TorrentTableView.swift",
                expectedIDs: [
                    "TorrentTableColumnID.name.rawValue",
                    "TorrentTableColumnID.size.rawValue",
                    "TorrentTableColumnID.done.rawValue",
                    "TorrentTableColumnID.status.rawValue",
                    "TorrentTableColumnID.seeds.rawValue",
                    "TorrentTableColumnID.peers.rawValue",
                    "TorrentTableColumnID.downloadSpeed.rawValue",
                    "TorrentTableColumnID.uploadSpeed.rawValue",
                    "TorrentTableColumnID.eta.rawValue",
                    "TorrentTableColumnID.ratio.rawValue",
                    "TorrentTableColumnID.downloaded.rawValue",
                    "TorrentTableColumnID.uploaded.rawValue",
                    "TorrentTableColumnID.tracker.rawValue",
                    "TorrentTableColumnID.trackerStatus.rawValue",
                    "TorrentTableColumnID.addedOn.rawValue",
                    "TorrentTableColumnID.completedOn.rawValue",
                    "TorrentTableColumnID.lastActive.rawValue",
                    "TorrentTableColumnID.path.rawValue",
                    "TorrentTableColumnID.priority.rawValue",
                    "TorrentTableColumnID.sizeToDownload.rawValue",
                    "TorrentTableColumnID.torrentID.rawValue",
                    "TorrentTableColumnID.queuePosition.rawValue",
                    "TorrentTableColumnID.seedingTime.rawValue",
                    "TorrentTableColumnID.sizeLeft.rawValue",
                    "TorrentTableColumnID.privateTorrent.rawValue",
                    "TorrentTableColumnID.labels.rawValue",
                ]
            ),
            (
                fileName: "TorrentFilesView.swift",
                expectedIDs: [
                    "SecondaryTableColumnID.Files.name",
                    "SecondaryTableColumnID.Files.size",
                    "SecondaryTableColumnID.Files.completed",
                    "SecondaryTableColumnID.Files.progress",
                    "SecondaryTableColumnID.Files.wanted",
                    "SecondaryTableColumnID.Files.priority",
                ]
            ),
            (
                fileName: "TorrentPeersView.swift",
                expectedIDs: [
                    "SecondaryTableColumnID.Peers.host",
                    "SecondaryTableColumnID.Peers.port",
                    "SecondaryTableColumnID.Peers.country",
                    "SecondaryTableColumnID.Peers.client",
                    "SecondaryTableColumnID.Peers.flags",
                    "SecondaryTableColumnID.Peers.progress",
                    "SecondaryTableColumnID.Peers.upload",
                    "SecondaryTableColumnID.Peers.download",
                ]
            ),
            (
                fileName: "TorrentTrackersView.swift",
                expectedIDs: [
                    "SecondaryTableColumnID.Trackers.tracker",
                    "SecondaryTableColumnID.Trackers.status",
                    "SecondaryTableColumnID.Trackers.update",
                    "SecondaryTableColumnID.Trackers.seeds",
                    "SecondaryTableColumnID.Trackers.leechers",
                    "SecondaryTableColumnID.Trackers.downloads",
                ]
            ),
        ]

        for expectation in expectations {
            let sourceURL = repositoryRoot
                .appendingPathComponent("Sources/TransmissionRemoteMac/Views")
                .appendingPathComponent(expectation.fileName)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let declarations = try customizedColumnDeclarations(
                in: source,
                fileName: expectation.fileName
            )
            let tableColumnCount = source.components(separatedBy: "TableColumn(").count - 1

            let declaredIDs = declarations.map(\.customizationID)
            let declaredIDSet = Set(declaredIDs)
            let duplicateIDs = Dictionary(grouping: declaredIDs, by: { $0 })
                .filter { $0.value.count > 1 }
                .keys
                .sorted()
            XCTAssertEqual(
                tableColumnCount,
                expectation.expectedIDs.count,
                "\(expectation.fileName) contains a TableColumn without a matching contract entry"
            )
            XCTAssertEqual(
                declarations.count,
                expectation.expectedIDs.count,
                "\(expectation.fileName) customized column census changed: "
                    + declaredIDs.joined(separator: ", ")
            )
            XCTAssertEqual(
                declaredIDSet.count,
                declaredIDs.count,
                "\(expectation.fileName) contains duplicate customization IDs: "
                    + duplicateIDs.joined(separator: ", ")
            )
            XCTAssertEqual(
                declaredIDSet,
                expectation.expectedIDs,
                "\(expectation.fileName) customization ID set changed; missing: "
                    + expectation.expectedIDs.subtracting(declaredIDSet).sorted().joined(separator: ", ")
                    + "; unexpected: "
                    + declaredIDSet.subtracting(expectation.expectedIDs).sorted().joined(separator: ", ")
            )

            for declaration in declarations {
                XCTAssertEqual(
                    declaration.widthModifiers.count,
                    1,
                    "\(expectation.fileName):\(declaration.tableLine) "
                        + "\(declaration.customizationID) must declare exactly one width modifier "
                        + "before customizationID at line \(declaration.customizationLine)"
                )
                guard let width = declaration.widthModifiers.first else { continue }
                XCTAssertTrue(
                    width.source.contains("min:") && width.source.contains("ideal:"),
                    "\(expectation.fileName):\(width.line) "
                        + "\(declaration.customizationID) uses fixed \(width.source.trimmingCharacters(in: .whitespaces)); "
                        + "user-customizable columns require .width(min:ideal:)"
                )
                guard let range = numericRangedWidth(in: width.source) else {
                    XCTFail(
                        "\(expectation.fileName):\(width.line) "
                            + "\(declaration.customizationID) has an unparseable width modifier: "
                            + width.source.trimmingCharacters(in: .whitespaces)
                            + "; use numeric .width(min:ideal:) or .width(min:ideal:max:) literals"
                    )
                    continue
                }
                XCTAssertLessThan(
                    range.minimum,
                    range.ideal,
                    "\(expectation.fileName):\(width.line) "
                        + "\(declaration.customizationID) must have min < ideal"
                )
                if let maximum = range.maximum {
                    XCTAssertLessThan(
                        range.ideal,
                        maximum,
                        "\(expectation.fileName):\(width.line) "
                            + "\(declaration.customizationID) must have ideal < max"
                    )
                }
            }
        }
    }

    @MainActor
    func testRangedNativeColumnAllowsUserResizeAndPersistsPublishedWidth() async throws {
        let suiteName = "TableColumnResizeContractTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let storageKey = "tableColumnResizeContract.customization"
        let controller = TableColumnCustomizationPersistenceController<NativeResizeRow>(
            storageKey: storageKey,
            userDefaults: userDefaults
        )
        let hostingView = NSHostingView(rootView: resizeFixture(controller: controller))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            window.contentView = nil
            window.close()
        }

        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)

        let mountedTable = await nativeTable(in: hostingView, timeout: .seconds(2))
        let table = try XCTUnwrap(
            mountedTable,
            "The offscreen SwiftUI Table did not mount an NSTableView"
        )
        let sizeColumn = try XCTUnwrap(
            table.tableColumns.first { $0.headerCell.stringValue == "Size" },
            "The offscreen table did not expose the Size column"
        )

        XCTAssertTrue(table.allowsColumnResizing)
        XCTAssertEqual(table.columnAutoresizingStyle, .noColumnAutoresizing)
        XCTAssertTrue(sizeColumn.resizingMask.contains(.userResizingMask))
        XCTAssertLessThan(sizeColumn.minWidth, sizeColumn.maxWidth)

        let oldWidth = sizeColumn.width
        let targetWidth: CGFloat = abs(oldWidth - 137) > 1 ? 137 : 173
        let expectedWidth = Double(targetWidth)
        XCTAssertGreaterThan(targetWidth, sizeColumn.minWidth)
        XCTAssertLessThan(targetWidth, sizeColumn.maxWidth)
        XCTAssertNotEqual(oldWidth, targetWidth, accuracy: 0.01)
        let published = expectation(description: "native resize published through customization binding")
        var publishedWidth: Double?
        var didFulfill = false
        let subscription = controller.$customization
            .dropFirst()
            .sink { customization in
                guard !didFulfill,
                      let data = try? JSONEncoder().encode(customization),
                      let width = try? self.requiredWidth(for: "size", in: data),
                      abs(width - expectedWidth) < 0.01 else {
                    return
                }
                didFulfill = true
                publishedWidth = width
                published.fulfill()
            }

        sizeColumn.width = targetWidth
        NotificationCenter.default.post(
            name: NSTableView.columnDidResizeNotification,
            object: table,
            userInfo: [
                "NSTableColumn": sizeColumn,
                "NSOldWidth": oldWidth,
            ]
        )

        await fulfillment(of: [published], timeout: 2)
        withExtendedLifetime(subscription) {}

        XCTAssertEqual(try XCTUnwrap(publishedWidth), expectedWidth, accuracy: 0.01)
        let storedData = try XCTUnwrap(userDefaults.data(forKey: storageKey))
        XCTAssertEqual(
            try requiredWidth(for: "size", in: storedData),
            expectedWidth,
            accuracy: 0.01
        )
        let recreated = TableColumnCustomizationPersistenceController<NativeResizeRow>(
            storageKey: storageKey,
            userDefaults: userDefaults
        )
        XCTAssertEqual(
            try requiredWidth(
                for: "size",
                in: JSONEncoder().encode(recreated.customization)
            ),
            expectedWidth,
            accuracy: 0.01
        )

        table.setFrameSize(NSSize(width: table.frame.width + 200, height: table.frame.height))
        XCTAssertEqual(sizeColumn.width, targetWidth, accuracy: 0.01, "Layout changes must not redistribute user widths")

        let replacementHost = NSHostingView(rootView: resizeFixture(controller: recreated))
        window.contentView = replacementHost
        let remountedTable = await nativeTable(in: replacementHost, timeout: .seconds(2))
        let restoredTable = try XCTUnwrap(remountedTable)
        let restoredSizeColumn = try XCTUnwrap(restoredTable.tableColumns.first { $0.headerCell.stringValue == "Size" })
        XCTAssertEqual(restoredTable.columnAutoresizingStyle, .noColumnAutoresizing)
        XCTAssertEqual(restoredSizeColumn.width, targetWidth, accuracy: 0.01, "Restored bytes must reach the remounted native column")
        let secondWidth = targetWidth + 30
        restoredSizeColumn.width = secondWidth
        NotificationCenter.default.post(
            name: NSTableView.columnDidResizeNotification,
            object: restoredTable,
            userInfo: ["NSTableColumn": restoredSizeColumn, "NSOldWidth": targetWidth]
        )
        replacementHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(restoredSizeColumn.width, secondWidth, accuracy: 0.01, "A later user drag must not snap back to the restored width")

        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)
    }

    func testMainColumnDefaultsGiveNameSpaceAndShrinkDoneByAtLeastThirtyPercent() throws {
        let url = repositoryRoot.appendingPathComponent("Sources/TransmissionRemoteMac/Views/TorrentTableView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let columns = try customizedColumnDeclarations(in: source, fileName: "TorrentTableView.swift")
        let name = try XCTUnwrap(columns.first { $0.customizationID == "TorrentTableColumnID.name.rawValue" })
        let done = try XCTUnwrap(columns.first { $0.customizationID == "TorrentTableColumnID.done.rawValue" })
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(numericRangedWidth(in: name.widthModifiers[0].source)).ideal, 500)
        XCTAssertLessThanOrEqual(try XCTUnwrap(numericRangedWidth(in: done.widthModifiers[0].source)).ideal, 125 * 0.7)
    }

    @MainActor
    private func resizeFixture(controller: TableColumnCustomizationPersistenceController<NativeResizeRow>) -> some View {
        Table(
            [NativeResizeRow(id: 1, size: "88 MB", name: "Fixture")],
            sortOrder: Binding<[KeyPathComparator<NativeResizeRow>]>.constant([]),
            columnCustomization: controller.binding
        ) {
            TableColumn("Size", value: \NativeResizeRow.size) { row in
                Text(row.size)
            }
            .width(min: 44, ideal: 88)
            .customizationID("size")

            TableColumn("Name", value: \NativeResizeRow.name) { row in
                Text(row.name)
            }
            .width(min: 100, ideal: 240)
            .customizationID("name")
        }
        .background(TableColumnResizePolicyBridge(widthsByTitle: Dictionary(uniqueKeysWithValues:
            controller.columnWidths.map { ($0.key == "size" ? "Size" : "Name", $0.value) }
        )))
        .frame(width: 520, height: 180)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func customizedColumnDeclarations(
        in source: String,
        fileName: String
    ) throws -> [CustomizedColumnDeclaration] {
        let lines = source.components(separatedBy: .newlines)
        return try lines.indices.compactMap { customizationIndex in
            guard lines[customizationIndex].contains(".customizationID(") else {
                return nil
            }
            guard let tableIndex = (0...customizationIndex).reversed().first(where: {
                lines[$0].contains("TableColumn(")
            }) else {
                throw ColumnContractInspectionError.missingOwningTableColumn(
                    file: fileName,
                    line: customizationIndex + 1
                )
            }
            let widthModifiers = (tableIndex...customizationIndex).compactMap { lineIndex in
                lines[lineIndex].contains(".width(")
                    ? WidthModifier(line: lineIndex + 1, source: lines[lineIndex])
                    : nil
            }
            let customizationID = lines[customizationIndex]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ".customizationID(", with: "")
                .replacingOccurrences(of: ")", with: "")
            return CustomizedColumnDeclaration(
                customizationID: customizationID,
                tableLine: tableIndex + 1,
                customizationLine: customizationIndex + 1,
                widthModifiers: widthModifiers
            )
        }
    }

    @MainActor
    private func nativeTable(
        in rootView: NSView,
        timeout: Duration
    ) async -> NSTableView? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            rootView.layoutSubtreeIfNeeded()
            if let table = firstSubview(of: NSTableView.self, in: rootView) {
                return table
            }
            try? await Task.sleep(for: .milliseconds(10))
        } while clock.now < deadline
        return nil
    }

    @MainActor
    private func firstSubview<ViewType: NSView>(
        of type: ViewType.Type,
        in rootView: NSView
    ) -> ViewType? {
        if let matchingView = rootView as? ViewType {
            return matchingView
        }
        for subview in rootView.subviews {
            if let matchingView = firstSubview(of: type, in: subview) {
                return matchingView
            }
        }
        return nil
    }

    private func requiredWidth(for columnID: String, in data: Data) throws -> Double {
        let inspection = try NativeTableColumnCustomizationFixtureInspector.inspect(data)
        guard let index = inspection.orderedColumnIDs.firstIndex(of: columnID),
              let width = inspection.widths[index] else {
            throw ColumnContractInspectionError.missingPersistedWidth(columnID)
        }
        return width
    }

    private func numericRangedWidth(in source: String) -> NumericRangedWidth? {
        let pattern = #"^\s*\.width\(\s*min:\s*([0-9]+(?:\.[0-9]+)?)\s*,\s*ideal:\s*([0-9]+(?:\.[0-9]+)?)(?:\s*,\s*max:\s*([0-9]+(?:\.[0-9]+)?))?\s*\)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: source,
                  range: NSRange(source.startIndex..., in: source)
              ),
              match.range.location != NSNotFound,
              let minimum = capturedDouble(at: 1, from: match, in: source),
              let ideal = capturedDouble(at: 2, from: match, in: source) else {
            return nil
        }
        return NumericRangedWidth(
            minimum: minimum,
            ideal: ideal,
            maximum: capturedDouble(at: 3, from: match, in: source)
        )
    }

    private func capturedDouble(
        at index: Int,
        from match: NSTextCheckingResult,
        in source: String
    ) -> Double? {
        let range = match.range(at: index)
        guard range.location != NSNotFound,
              let sourceRange = Range(range, in: source) else {
            return nil
        }
        return Double(source[sourceRange])
    }
}

private struct NativeResizeRow: Identifiable {
    var id: Int
    var size: String
    var name: String
}

private struct CustomizedColumnDeclaration {
    var customizationID: String
    var tableLine: Int
    var customizationLine: Int
    var widthModifiers: [WidthModifier]
}

private struct WidthModifier {
    var line: Int
    var source: String
}

private struct NumericRangedWidth {
    var minimum: Double
    var ideal: Double
    var maximum: Double?
}

private enum ColumnContractInspectionError: Error {
    case missingOwningTableColumn(file: String, line: Int)
    case missingPersistedWidth(String)
}
