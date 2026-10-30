//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerNetworkClient
import ContainerResource
import ContainerXPC
import ContainerizationExtras
import Foundation

public actor NetworkHarness: Sendable {
    private let service: NetworkService

    public init(service: NetworkService) {
        self.service = service
    }

    @Sendable
    public func status(_ message: XPCMessage) async throws -> XPCMessage {
        let reply = message.reply()
        let status = try await service.status()
        try reply.setStatus(status)
        return reply
    }

    @Sendable
    public func allocate(_ message: XPCMessage, _ session: XPCServerSession) async throws -> XPCMessage {
        let hostname = try message.hostname()
        let macAddress =
            try message.string(key: NetworkKeys.macAddress.rawValue)
            .map { try MACAddress($0) }

        let aliases = try message.aliases()

        let (attachment:attachment, additionalData:additionalData) = try await service.allocate(
            hostname: hostname,
            macAddress: macAddress,
            aliases: aliases,
            session: session
        )

        let reply = message.reply()
        try reply.setAttachment(attachment)
        if let additionalData {
            try reply.setAdditionalData(additionalData.underlying)
        }

        return reply
    }

    @Sendable
    public func lookup(_ message: XPCMessage) async throws -> XPCMessage {
        let name = try message.name()
        let reply = message.reply()
        try Self.setMatches(try await service.lookupAll(name: name), on: reply)
        return reply
    }

    /// Put a lookup's matches in its reply: the first as the one match, as before, and, for an
    /// alias several attachments share, every one of them; a client that predates this reads
    /// the first.
    static func setMatches(_ matches: [NetworkMatch], on reply: XPCMessage) throws {
        guard let match = matches.first else {
            return
        }
        try reply.setAttachment(match.attachment)
        reply.setMatchKind(match.kind)
        if matches.count > 1 {
            reply.set(key: NetworkKeys.attachments.rawValue, value: try JSONEncoder().encode(matches.map(\.attachment)))
        }
    }

    @Sendable
    public func attachments(_ message: XPCMessage) async throws -> XPCMessage {
        let reply = message.reply()
        let attachments = try await service.attachments()
        let data = try JSONEncoder().encode(attachments)
        reply.set(key: NetworkKeys.attachments.rawValue, value: data)
        return reply
    }
}

extension XPCMessage {
    fileprivate func setAdditionalData(_ additionalData: xpc_object_t) throws {
        xpc_dictionary_set_value(self.underlying, NetworkKeys.additionalData.rawValue, additionalData)
    }

    fileprivate func setAttachment(_ attachment: Attachment) throws {
        let data = try JSONEncoder().encode(attachment)
        self.set(key: NetworkKeys.attachment.rawValue, value: data)
    }

    fileprivate func setStatus(_ status: NetworkStatus) throws {
        let data = try JSONEncoder().encode(status)
        self.set(key: NetworkKeys.status.rawValue, value: data)
    }

}
