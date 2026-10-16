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

import ContainerResource
import ContainerXPC
import Darwin
import Foundation
import Testing

@testable import ContainerAPIClient
@testable import ContainerAPIService

/// Who the app's folder panel names: what a client says on a create, start or copy, or the
/// XPC peer when it says nothing, carried sanitized onto the grant request.
struct HostDirectoryGrantRequesterTests {
    private func grantRequest(requester: String?) -> XPCMessage {
        HostDirectoryGrants.requestMessage(
            path: "/Users/me/project", requestID: "request-229", patience: .seconds(42), ownerToken: "owner", requester: requester)
    }

    @Test("the grant request carries the requester when there is one, sanitized, and no key when there is not")
    func requestMessage() {
        #expect(grantRequest(requester: "docker (pid 4242)").string(key: .hostDirectoryRequester) == "docker (pid 4242)")
        #expect(grantRequest(requester: "dock\u{1B}er\n (pid 1)").string(key: .hostDirectoryRequester) == "docker (pid 1)")
        let long = grantRequest(requester: String(repeating: "x", count: 100)).string(key: .hostDirectoryRequester)
        #expect(long?.count == GrantRequester.maxLength)
        #expect(grantRequest(requester: nil).string(key: .hostDirectoryRequester) == nil)
        #expect(grantRequest(requester: "\u{202E}\u{7}").string(key: .hostDirectoryRequester) == nil)
        // Control: the rest of the request is what it always was.
        let message = grantRequest(requester: "docker (pid 4242)")
        #expect(message.string(key: .hostDirectoryPath) == "/Users/me/project")
        #expect(message.string(key: .hostDirectoryRequestID) == "request-229")
        #expect(message.int64(key: .hostDirectoryDeadlineSeconds) == 42)
    }

    private func clientRequest(requester: String?) -> XPCMessage {
        let message = XPCMessage(route: .containerCreate)
        ContainerClient.setRequester(requester, on: message)
        return message
    }

    @Test("a client puts a requester on its request only when there is something to show")
    func clientSetsRequester() {
        #expect(clientRequest(requester: "docker (pid 4242)").string(key: .hostDirectoryRequester) == "docker (pid 4242)")
        #expect(clientRequest(requester: "java\r\n (pid 9)").string(key: .hostDirectoryRequester) == "java (pid 9)")
        #expect(clientRequest(requester: nil).string(key: .hostDirectoryRequester) == nil)
        #expect(clientRequest(requester: " \n").string(key: .hostDirectoryRequester) == nil)
    }

    @Test("what the client says wins over the peer, sanitized")
    func statedWins() {
        let message = clientRequest(requester: "docker (pid 4242)")
        #expect(ContainersHarness.requester(of: message, peerPID: 77) { _ in "container-docker-api" } == "docker (pid 4242)")
        let raw = XPCMessage(route: .containerCreate)
        // Not NUL: an XPC string ends at the first one, so it never reaches the sanitizer.
        raw.set(key: .hostDirectoryRequester, value: "doc\u{202E}ker\u{7} (pid 1)")
        #expect(ContainersHarness.requester(of: raw, peerPID: 77) { _ in "container" } == "docker (pid 1)")
    }

    @Test("with nothing said, the peer is named; with nothing showable said, too; with no peer, nobody")
    func peerFallback() {
        let silent = XPCMessage(route: .containerCreate)
        #expect(ContainersHarness.requester(of: silent, peerPID: 77) { _ in "container" } == "container (pid 77)")
        #expect(ContainersHarness.requester(of: silent, peerPID: 77) { _ in nil } == "pid 77")
        let blank = XPCMessage(route: .containerCreate)
        blank.set(key: .hostDirectoryRequester, value: "\u{7}\n")
        #expect(ContainersHarness.requester(of: blank, peerPID: 77) { _ in "container" } == "container (pid 77)")
        #expect(ContainersHarness.requester(of: silent, peerPID: 0) { _ in "container" } == nil)
    }

    @Test("the peer's name is read from the system")
    func realPeer() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["5"]
        try sleeper.run()
        defer {
            sleeper.terminate()
            sleeper.waitUntilExit()
        }
        let pid = sleeper.processIdentifier
        #expect(ContainersHarness.requester(of: XPCMessage(route: .containerCreate), peerPID: pid) == "sleep (pid \(pid))")
    }
}
