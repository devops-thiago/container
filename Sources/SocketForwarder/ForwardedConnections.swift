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

import NIOCore
import Synchronization

/// Owns both ends of a group of TCP relays, including connections whose listener has gone.
/// Closing a listener permits those sessions to drain; closing this group ends them all.
public final class ForwardedConnections: Sendable {
    private struct State {
        var closed = false
        var channels: [ObjectIdentifier: any Channel] = [:]
    }
    private let state = Mutex(State())

    public init() {}

    var count: Int { state.withLock { $0.channels.count } }

    /// Called by each channel initializer, before it can forward or dial anything.
    func insert(_ channel: any Channel) -> Bool {
        let id = ObjectIdentifier(channel)
        let accepted = state.withLock { state in
            guard !state.closed else { return false }
            state.channels[id] = channel
            return true
        }
        if accepted {
            channel.closeFuture.whenComplete { [self] _ in
                state.withLock { _ = $0.channels.removeValue(forKey: id) }
            }
        }
        return accepted
    }

    /// Refuses late initializers and closes existing channels, including pending backend dials.
    public func closeAll() async {
        let channels = state.withLock { state in
            state.closed = true
            return Array(state.channels.values)
        }
        for channel in channels { channel.close(promise: nil) }
        for channel in channels { try? await channel.closeFuture.get() }
    }
}
