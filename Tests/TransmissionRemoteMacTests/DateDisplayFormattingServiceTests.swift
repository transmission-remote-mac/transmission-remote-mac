// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class DateDisplayFormattingServiceTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_704_110_400)

    func testInvalidDatesAreUnavailableInBothModesWithoutCreatingFoundationFormatters() {
        let factory = CountingDateDisplayFormatterFactory()
        let service = DateDisplayFormattingService(formatterFactory: factory)
        let invalidDates = [
            Date(timeIntervalSince1970: .infinity),
            Date(timeIntervalSince1970: -.infinity),
            Date(timeIntervalSince1970: .nan),
            Date(timeIntervalSince1970: 1e300),
            Date(timeIntervalSince1970: -1e300),
            Date.distantFuture.addingTimeInterval(1),
            Date.distantPast.addingTimeInterval(-1),
        ]

        for date in invalidDates {
            XCTAssertNil(service.relativeBucket(from: date, relativeTo: referenceDate))
            XCTAssertEqual(service.absoluteString(from: date, context: .detail), "Unknown")
            XCTAssertEqual(service.relativeString(from: date, relativeTo: referenceDate), "Unknown")
            for mode in DateDisplayMode.allCases {
                for context in [DateDisplayContext.table, .detail] {
                    XCTAssertEqual(
                        service.presentation(
                            for: date,
                            relativeTo: referenceDate,
                            preferences: DateDisplayPreferences(mode: mode),
                            context: context
                        ),
                        DateDisplayPresentation(primary: "Unknown", alternate: "Unknown")
                    )
                }
            }
        }

        XCTAssertEqual(factory.totalCreations, 0)
    }

    func testInvalidReferenceDateLeavesAbsolutePresentationAvailable() {
        let service = makeService()
        for reference in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: 1e300)] {
            XCTAssertNil(service.relativeBucket(from: referenceDate, relativeTo: reference))
            let absolute = service.presentation(
                for: referenceDate,
                relativeTo: reference,
                preferences: DateDisplayPreferences(mode: .absolute),
                context: .detail
            )
            let relative = service.presentation(
                for: referenceDate,
                relativeTo: reference,
                preferences: DateDisplayPreferences(mode: .relative),
                context: .detail
            )

            XCTAssertEqual(absolute.alternate, "Unknown")
            XCTAssertNotEqual(absolute.primary, "Unknown")
            XCTAssertEqual(relative.primary, "Unknown")
            XCTAssertEqual(relative.alternate, absolute.primary)
        }
    }

    func testSupportedDateSentinelsRemainWithinSafeRelativeBuckets() throws {
        let service = makeService()
        for date in [Date.distantPast, .distantFuture] {
            let bucket = try XCTUnwrap(service.relativeBucket(from: date, relativeTo: referenceDate))
            XCTAssertEqual(bucket.unit, .year)
            XCTAssertNotEqual(service.absoluteString(from: date, context: .detail), "Unknown")
        }
    }

    func testAbsoluteAndRelativeModesSwapPrimaryAndAlternateRepresentations() {
        let service = makeService()
        let date = referenceDate.addingTimeInterval(-125)
        let absolute = service.presentation(
            for: date,
            relativeTo: referenceDate,
            preferences: DateDisplayPreferences(mode: .absolute),
            context: .detail
        )
        let relative = service.presentation(
            for: date,
            relativeTo: referenceDate,
            preferences: DateDisplayPreferences(mode: .relative),
            context: .detail
        )

        XCTAssertEqual(absolute.primary, relative.alternate)
        XCTAssertEqual(absolute.alternate, relative.primary)
        XCTAssertFalse(absolute.primary.isEmpty)
        XCTAssertFalse(relative.primary.isEmpty)
    }

    func testAbsoluteFormattingUsesInjectedLocaleTimeZoneAndExistingViewContexts() throws {
        let utc = makeService(timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        let brisbane = makeService(timeZone: try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane")))
        let date = Date(timeIntervalSince1970: 1_704_110_400)

        XCTAssertNotEqual(
            utc.absoluteString(from: date, context: .detail),
            brisbane.absoluteString(from: date, context: .detail)
        )
        XCTAssertNotEqual(
            utc.absoluteString(from: date, context: .table),
            utc.absoluteString(from: date, context: .detail)
        )
    }

    func testRelativeThresholdsAreDeterministicAtEveryBoundary() {
        let service = makeService()
        let cases: [(TimeInterval, RelativeDateBucket)] = [
            (4.999, RelativeDateBucket(unit: .now, value: 0)),
            (-5, RelativeDateBucket(unit: .second, value: -5)),
            (59.999, RelativeDateBucket(unit: .second, value: 59)),
            (60, RelativeDateBucket(unit: .minute, value: 1)),
            (3_599.999, RelativeDateBucket(unit: .minute, value: 59)),
            (3_600, RelativeDateBucket(unit: .hour, value: 1)),
            (86_400, RelativeDateBucket(unit: .day, value: 1)),
            (604_800, RelativeDateBucket(unit: .week, value: 1)),
            (2_592_000, RelativeDateBucket(unit: .month, value: 1)),
            (31_536_000, RelativeDateBucket(unit: .year, value: 1))
        ]

        for (interval, expected) in cases {
            XCTAssertEqual(
                service.relativeBucket(
                    from: referenceDate.addingTimeInterval(interval),
                    relativeTo: referenceDate
                ),
                expected,
                "Unexpected bucket at \(interval) seconds"
            )
        }
    }

    func testRepeatedRowFormattingUsesOneBoundedFormatterPerContextAndRelativeStyle() {
        let factory = CountingDateDisplayFormatterFactory()
        let service = DateDisplayFormattingService(
            locale: Locale(identifier: "en_AU"),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            calendarIdentifier: .gregorian,
            formatterFactory: factory
        )

        for row in 0..<1_000 {
            let date = referenceDate.addingTimeInterval(TimeInterval(-60 - row))
            _ = service.absoluteString(from: date, context: .table)
            _ = service.absoluteString(from: date, context: .detail)
            _ = service.relativeString(from: date, relativeTo: referenceDate)
            _ = service.relativeString(from: referenceDate, relativeTo: referenceDate)
        }

        XCTAssertEqual(factory.absoluteCreations[.table], 1)
        XCTAssertEqual(factory.absoluteCreations[.detail], 1)
        XCTAssertEqual(factory.relativeCreations[.numeric], 1)
        XCTAssertEqual(factory.relativeCreations[.named], 1)
        XCTAssertEqual(factory.totalCreations, 4)
    }

    private func makeService(
        timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!
    ) -> DateDisplayFormattingService {
        DateDisplayFormattingService(
            locale: Locale(identifier: "en_AU"),
            timeZone: timeZone,
            calendarIdentifier: .gregorian
        )
    }
}

private final class CountingDateDisplayFormatterFactory: DateDisplayFoundationFormatterFactory {
    private let foundationFactory = FoundationDateDisplayFormatterFactory()
    private(set) var absoluteCreations: [DateDisplayContext: Int] = [:]
    private(set) var relativeCreations: [DateDisplayRelativeFormatterStyle: Int] = [:]

    var totalCreations: Int {
        absoluteCreations.values.reduce(0, +) + relativeCreations.values.reduce(0, +)
    }

    func makeAbsoluteFormatter(
        locale: Locale,
        timeZone: TimeZone,
        calendarIdentifier: Calendar.Identifier,
        context: DateDisplayContext
    ) -> DateFormatter {
        absoluteCreations[context, default: 0] += 1
        return foundationFactory.makeAbsoluteFormatter(
            locale: locale,
            timeZone: timeZone,
            calendarIdentifier: calendarIdentifier,
            context: context
        )
    }

    func makeRelativeFormatter(
        locale: Locale,
        style: DateDisplayRelativeFormatterStyle
    ) -> RelativeDateTimeFormatter {
        relativeCreations[style, default: 0] += 1
        return foundationFactory.makeRelativeFormatter(locale: locale, style: style)
    }
}
