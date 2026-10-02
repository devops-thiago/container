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
import Foundation
import Testing
import XPC

@testable import ContainerAPIService

/// A grant request made before the running app has announced its listener waits for it, and
/// one made with no app running does not.
struct HostDirectoryGrantAnnounceWaitTests {
    /// What a wait found, carried out of the task that waited. libXPC objects are thread-safe;
    /// Swift cannot see that.
    private struct Found: @unchecked Sendable {
        let endpoint: xpc_endpoint_t?
    }

    private func endpoint() -> xpc_endpoint_t {
        let listener = xpc_connection_create(nil, nil)
        xpc_connection_set_event_handler(listener) { _ in }
        xpc_connection_activate(listener)
        return xpc_endpoint_create(listener)
    }

    private func unique() -> String { "grants-wait-\(UUID().uuidString)" }

    @Test("an announced listener is used at once, whether or not the app is running")
    func announcedListenerAtOnce() async throws {
        let label = unique()
        defer { InstanceEndpoints.remove(label: label) }
        let announced = endpoint()
        try InstanceEndpoints.attach(label: label, endpoint: announced, owner: "app")

        for running in [true, false] {
            let found = await HostDirectoryGrants.announcedEndpoint(
                label: label, appIsRunning: running, grace: .seconds(30))
            #expect(found === announced)
        }
    }

    @Test("with no app running, nobody is waited for")
    func noAppNoWait() async {
        let clock = ContinuousClock()
        let start = clock.now
        let found = await HostDirectoryGrants.announcedEndpoint(
            label: unique(), appIsRunning: false, grace: .seconds(30))
        #expect(found == nil)
        #expect(start.duration(to: clock.now) < .seconds(5))
    }

    @Test("the listener a running app announces during the wait is the one used")
    func runningAppAnnouncesLater() async throws {
        let label = unique()
        defer { InstanceEndpoints.remove(label: label) }
        let announced = endpoint()
        let waiting = Task {
            Found(
                endpoint: await HostDirectoryGrants.announcedEndpoint(
                    label: label, appIsRunning: true, grace: .seconds(30)))
        }
        // Gives the wait time to begin. Should the announce come first anyway, it is found at
        // once and the answer is the same.
        try await Task.sleep(for: .milliseconds(200))
        try InstanceEndpoints.attach(label: label, endpoint: announced, owner: "app")

        let found = await waiting.value
        #expect(found.endpoint === announced)
    }

    @Test("a running app that announces nothing within the grace leaves nobody to ask")
    func runningAppNeverAnnounces() async {
        let found = await HostDirectoryGrants.announcedEndpoint(
            label: unique(), appIsRunning: true, grace: .milliseconds(100))
        #expect(found == nil)
    }

    @Test("a cancelled wait ends without a listener")
    func cancelledWait() async {
        let label = unique()
        let waiting = Task {
            Found(
                endpoint: await HostDirectoryGrants.announcedEndpoint(
                    label: label, appIsRunning: true, grace: .seconds(30)))
        }
        waiting.cancel()
        let found = await waiting.value
        #expect(found.endpoint == nil)
    }
}
