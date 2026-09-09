// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum PeerCountryDownloadSource {
    static func validatedCustomURL(_ text: String) throws -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !value.contains("\\"),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil,
              components.port.map({ (1 ... 65_535).contains($0) }) ?? true,
              let url = components.url else {
            throw PeerCountryDownloadError.invalidSourceURL
        }
        return url
    }

    /// Only published download links qualify; the current calendar month is
    /// deliberately not used because a provider release can arrive late.
    static func latestPublishedURL(in page: String) throws -> URL {
        let expression = try NSRegularExpression(
            pattern: #"href\s*=\s*["'](https://download\.db-ip\.com/free/dbip-country-lite-[0-9]{4}-(?:0[1-9]|1[0-2])\.csv\.gz)["']"#,
            options: .caseInsensitive
        )
        let links = expression.matches(in: page, range: NSRange(page.startIndex..., in: page)).compactMap {
            match -> String? in
            guard let range = Range(match.range(at: 1), in: page) else { return nil }
            return String(page[range])
        }
        guard let link = links.max(), let url = URL(string: link) else {
            throw PeerCountryDownloadError.publishedDownloadUnavailable
        }
        return url
    }
}

enum PeerCountryDownloadRedirectPolicy: Sendable {
    case providerPage
    case providerDownload
    case customHTTPS

    func allows(_ url: URL) -> Bool {
        guard (try? PeerCountryDownloadSource.validatedCustomURL(url.absoluteString)) != nil else { return false }
        switch self {
        case .providerPage:
            return url.host?.lowercased() == "db-ip.com" && (url.port == nil || url.port == 443)
        case .providerDownload:
            return url.host?.lowercased() == "download.db-ip.com"
                && (url.port == nil || url.port == 443)
                && url.path.hasPrefix("/free/dbip-country-lite-")
                && url.path.hasSuffix(".csv.gz")
                && url.query == nil
        case .customHTTPS:
            return true
        }
    }
}

enum PeerCountryDownloadError: LocalizedError, Equatable {
    case invalidSourceURL
    case publishedDownloadUnavailable
    case unexpectedResponse
    case httpStatus(Int)
    case unsafeRedirect
    case tooManyRedirects
    case downloadTooLarge
    case invalidGzip
    case expandedDataTooLarge
    case networkFailure

    var errorDescription: String? {
        switch self {
        case .invalidSourceURL:
            "Enter an HTTPS database URL without a username, password or fragment, or leave it blank for DB-IP."
        case .publishedDownloadUnavailable:
            "The latest DB-IP Country Lite download could not be found. Try again later or import a local CSV."
        case .unexpectedResponse:
            "The database server returned an unexpected response."
        case .httpStatus(let status):
            "The database server returned HTTP \(status). The installed database was not changed."
        case .unsafeRedirect:
            "The database download redirected to an unsupported address."
        case .tooManyRedirects:
            "The database download redirected too many times."
        case .downloadTooLarge:
            "The database download exceeds the supported size limit."
        case .invalidGzip:
            "The compressed database is corrupt, incomplete or not a supported gzip archive."
        case .expandedDataTooLarge:
            "The expanded database exceeds the supported 512 MB limit."
        case .networkFailure:
            "The country database could not be downloaded. Check the connection and try again."
        }
    }
}
