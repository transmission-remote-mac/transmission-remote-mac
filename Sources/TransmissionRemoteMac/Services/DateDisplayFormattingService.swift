// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum DateDisplayContext: Equatable, Hashable, Sendable {
    case table
    case detail
}

enum RelativeDateUnit: String, Equatable, Sendable {
    case now
    case second
    case minute
    case hour
    case day
    case week
    case month
    case year
}

struct RelativeDateBucket: Equatable, Sendable {
    let unit: RelativeDateUnit
    let value: Int
}

struct DateDisplayPresentation: Equatable, Sendable {
    let primary: String
    let alternate: String
}

struct DateDisplayFormattingService {
    private static let unavailableDateText = "Unknown"

    let locale: Locale
    let timeZone: TimeZone
    let calendarIdentifier: Calendar.Identifier
    private let formatterCache: SynchronizedDateDisplayFormatterCache

    init(
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        calendarIdentifier: Calendar.Identifier = .gregorian,
        formatterFactory: DateDisplayFoundationFormatterFactory = FoundationDateDisplayFormatterFactory()
    ) {
        self.locale = locale
        self.timeZone = timeZone
        self.calendarIdentifier = calendarIdentifier
        formatterCache = SynchronizedDateDisplayFormatterCache(
            locale: locale,
            timeZone: timeZone,
            calendarIdentifier: calendarIdentifier,
            factory: formatterFactory
        )
    }

    func presentation(
        for date: Date,
        relativeTo referenceDate: Date,
        preferences: DateDisplayPreferences,
        context: DateDisplayContext
    ) -> DateDisplayPresentation {
        let absolute = absoluteString(from: date, context: context)
        let relative = relativeString(from: date, relativeTo: referenceDate)
        switch preferences.mode {
        case .absolute:
            return DateDisplayPresentation(primary: absolute, alternate: relative)
        case .relative:
            return DateDisplayPresentation(primary: relative, alternate: absolute)
        }
    }

    func absoluteString(from date: Date, context: DateDisplayContext) -> String {
        guard Self.isSupportedDate(date) else { return Self.unavailableDateText }
        return formatterCache.absoluteString(from: date, context: context)
    }

    func relativeString(from date: Date, relativeTo referenceDate: Date) -> String {
        guard let bucket = relativeBucket(from: date, relativeTo: referenceDate) else {
            return Self.unavailableDateText
        }
        if bucket.unit == .now {
            return formatterCache.relativeString(from: DateComponents(second: 0), style: .named)
        }

        var components = DateComponents()
        switch bucket.unit {
        case .now:
            components.second = 0
        case .second:
            components.second = bucket.value
        case .minute:
            components.minute = bucket.value
        case .hour:
            components.hour = bucket.value
        case .day:
            components.day = bucket.value
        case .week:
            components.weekOfYear = bucket.value
        case .month:
            components.month = bucket.value
        case .year:
            components.year = bucket.value
        }
        return formatterCache.relativeString(from: components, style: .numeric)
    }

    /// Returns nil when either date is outside the app's supported display range.
    func relativeBucket(from date: Date, relativeTo referenceDate: Date) -> RelativeDateBucket? {
        guard Self.isSupportedDate(date), Self.isSupportedDate(referenceDate) else { return nil }
        let interval = date.timeIntervalSince(referenceDate)
        let magnitude = abs(interval)
        let sign = interval < 0 ? -1 : 1

        if magnitude < 5 {
            return RelativeDateBucket(unit: .now, value: 0)
        }
        if magnitude < 60 {
            return RelativeDateBucket(unit: .second, value: sign * max(1, Int(magnitude)))
        }
        if magnitude < 60 * 60 {
            return RelativeDateBucket(unit: .minute, value: sign * max(1, Int(magnitude / 60)))
        }
        if magnitude < 24 * 60 * 60 {
            return RelativeDateBucket(unit: .hour, value: sign * max(1, Int(magnitude / (60 * 60))))
        }
        if magnitude < 7 * 24 * 60 * 60 {
            return RelativeDateBucket(unit: .day, value: sign * max(1, Int(magnitude / (24 * 60 * 60))))
        }
        if magnitude < 30 * 24 * 60 * 60 {
            return RelativeDateBucket(unit: .week, value: sign * max(1, Int(magnitude / (7 * 24 * 60 * 60))))
        }
        if magnitude < 365 * 24 * 60 * 60 {
            return RelativeDateBucket(unit: .month, value: sign * max(1, Int(magnitude / (30 * 24 * 60 * 60))))
        }
        return RelativeDateBucket(
            unit: .year,
            value: sign * max(1, Int(magnitude / (365 * 24 * 60 * 60)))
        )
    }

    private static func isSupportedDate(_ date: Date) -> Bool {
        // Keep invalid programmatic dates out of Foundation formatters as well
        // as the relative bucket's bounded Double-to-Int conversions.
        date.timeIntervalSinceReferenceDate.isFinite
            && date >= .distantPast
            && date <= .distantFuture
    }
}

protocol DateDisplayFoundationFormatterFactory: AnyObject {
    func makeAbsoluteFormatter(
        locale: Locale,
        timeZone: TimeZone,
        calendarIdentifier: Calendar.Identifier,
        context: DateDisplayContext
    ) -> DateFormatter

    func makeRelativeFormatter(
        locale: Locale,
        style: DateDisplayRelativeFormatterStyle
    ) -> RelativeDateTimeFormatter
}

final class FoundationDateDisplayFormatterFactory: DateDisplayFoundationFormatterFactory {
    func makeAbsoluteFormatter(
        locale: Locale,
        timeZone: TimeZone,
        calendarIdentifier: Calendar.Identifier,
        context: DateDisplayContext
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        var calendar = Calendar(identifier: calendarIdentifier)
        calendar.locale = locale
        calendar.timeZone = timeZone
        formatter.calendar = calendar
        formatter.dateStyle = context == .table ? .short : .medium
        formatter.timeStyle = .short
        return formatter
    }

    func makeRelativeFormatter(
        locale: Locale,
        style: DateDisplayRelativeFormatterStyle
    ) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = style == .named ? .named : .numeric
        return formatter
    }
}

enum DateDisplayRelativeFormatterStyle: Hashable {
    case named
    case numeric
}

// The lock covers factory calls, cache mutation and every formatter use.
// Cached mutable Foundation formatters never escape this owner.
private final class SynchronizedDateDisplayFormatterCache: @unchecked Sendable {
    private let locale: Locale
    private let timeZone: TimeZone
    private let calendarIdentifier: Calendar.Identifier
    private let factory: DateDisplayFoundationFormatterFactory
    private let lock = NSLock()
    private var absoluteFormatters: [DateDisplayContext: DateFormatter] = [:]
    private var relativeFormatters: [DateDisplayRelativeFormatterStyle: RelativeDateTimeFormatter] = [:]

    init(
        locale: Locale,
        timeZone: TimeZone,
        calendarIdentifier: Calendar.Identifier,
        factory: DateDisplayFoundationFormatterFactory
    ) {
        self.locale = locale
        self.timeZone = timeZone
        self.calendarIdentifier = calendarIdentifier
        self.factory = factory
    }

    func absoluteString(from date: Date, context: DateDisplayContext) -> String {
        lock.lock()
        defer { lock.unlock() }
        let formatter: DateFormatter
        if let cachedFormatter = absoluteFormatters[context] {
            formatter = cachedFormatter
        } else {
            formatter = factory.makeAbsoluteFormatter(
                locale: locale,
                timeZone: timeZone,
                calendarIdentifier: calendarIdentifier,
                context: context
            )
            absoluteFormatters[context] = formatter
        }
        return formatter.string(from: date)
    }

    func relativeString(
        from components: DateComponents,
        style: DateDisplayRelativeFormatterStyle
    ) -> String {
        lock.lock()
        defer { lock.unlock() }
        let formatter: RelativeDateTimeFormatter
        if let cachedFormatter = relativeFormatters[style] {
            formatter = cachedFormatter
        } else {
            formatter = factory.makeRelativeFormatter(locale: locale, style: style)
            relativeFormatters[style] = formatter
        }
        return formatter.localizedString(from: components)
    }
}
