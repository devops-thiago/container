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

@testable import ContainerAPIClient

struct OwnedDeletionRequestTests {
    @Test("guarded deletes use a distinct route so older engines cannot ignore the condition")
    func guardedRequests() throws {
        let requirement = ["owner": "this-run"]
        let volume = try ClientVolume.deleteRequest(name: "v", requiredLabels: requirement)
        let network = try NetworkClient.deleteRequest(id: "n", requiredLabels: requirement)
        #expect(volume.string(key: XPCMessage.routeKey) == XPCRoute.volumeDeleteOwned.rawValue)
        #expect(network.string(key: XPCMessage.routeKey) == XPCRoute.networkDeleteOwned.rawValue)
        #expect(volume.string(key: .volumeName) == "v")
        #expect(network.string(key: .networkId) == "n")
        for request in [volume, network] {
            let data = try #require(request.data(key: .requiredLabels))
            #expect(try JSONDecoder().decode([String: String].self, from: data) == requirement)
        }
        #expect(try ClientVolume.deleteRequest(name: "v", requiredLabels: nil).string(key: XPCMessage.routeKey) == XPCRoute.volumeDelete.rawValue)
        #expect(try NetworkClient.deleteRequest(id: "n", requiredLabels: nil).string(key: XPCMessage.routeKey) == XPCRoute.networkDelete.rawValue)
    }
}
