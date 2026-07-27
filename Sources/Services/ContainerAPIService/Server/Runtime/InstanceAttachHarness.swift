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

import ContainerXPC
import ContainerizationError
import Foundation
import Logging

/// Records the endpoints that spawned plugin instances announce.
///
/// Under sandboxed embedding a posix_spawned helper cannot own a launchd mach
/// name (SMAppService plists are static, and a sandboxed parent can only spawn
/// inherit children — spike S2c). Each instance instead publishes the endpoint
/// of its anonymous listener here, keyed by the mach name it would otherwise
/// have owned, and `InstanceEndpoints` hands that endpoint to whichever client
/// dials the name.
public struct InstanceAttachHarness: Sendable {
    private let log: Logger

    public init(log: Logger) {
        self.log = log
    }

    public func attach(_ message: XPCMessage) async throws -> XPCMessage {
        guard let id = message.string(key: "id") else {
            throw ContainerizationError(.invalidArgument, message: "instance attach: missing id")
        }
        guard let endpoint = message.endpoint(key: "endpoint") else {
            throw ContainerizationError(
                .invalidArgument, message: "instance attach: missing endpoint")
        }
        let pid = pid_t(message.int64(key: "pid"))
        log.info("instance attached", metadata: ["id": "\(id)", "pid": "\(pid)"])
        InstanceEndpoints.attach(label: id, endpoint: endpoint)
        return message.reply()
    }
}
