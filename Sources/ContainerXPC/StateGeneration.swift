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

import Synchronization

/// How many observable changes a service has made since it started.
///
/// A client that keeps a listing compares this with the value its last successful listing was
/// taken at, and lists again only when it moved. The count starts over when the service
/// does, so it is only meaningful next to the service's process nonce: the same number from
/// another process says nothing. It moves on every change a listing could show, and moving
/// when nothing visible changed only costs the client one listing.
public final class StateGeneration: Sendable {
    /// The one count a service process reports.
    public static let shared = StateGeneration()

    private let value = Mutex<UInt64>(0)

    public init() {}

    public var current: UInt64 { value.withLock { $0 } }

    /// Record a change; returns the new count.
    @discardableResult
    public func advance() -> UInt64 {
        value.withLock {
            $0 &+= 1
            return $0
        }
    }
}
