// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

typealias RPCArguments = [String: JSONValue]

struct RPCRequest: Codable, Equatable {
    var method: String
    var arguments: RPCArguments

    init(method: String, arguments: RPCArguments = [:]) {
        self.method = method
        self.arguments = arguments
    }
}

struct RPCResponse: Decodable, Equatable {
    var containsJSONRPC: Bool
    var result: JSONValue?
    var arguments: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case result
        case arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        containsJSONRPC = container.contains(.jsonrpc)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        arguments = try container.decodeIfPresent(JSONValue.self, forKey: .arguments)
    }
}
