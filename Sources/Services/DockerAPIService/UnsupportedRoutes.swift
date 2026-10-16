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

import NIOHTTP1

/// The Docker Engine API's routes this service does not serve, answered in words the CLI
/// prints rather than with "page not found".
///
/// Swarm is answered as dockerd answers on a node that never joined one: 503 with its own
/// words. Everything else is a 501 that says what to do instead.
public enum UnsupportedRoutes {
    /// dockerd's words for a cluster request on a node in no swarm.
    public static let notASwarmManager =
        #"This node is not a swarm manager. Use "docker swarm init" or "docker swarm join" to connect this node to swarm and try again."#
    /// dockerd's words for leaving a swarm on a node in none.
    public static let notInASwarm = "This node is not part of a swarm"

    static let methods: [HTTPMethod] = [.GET, .POST, .PUT, .DELETE]

    public static func register(on router: inout DockerRouter) {
        router.add(.GET, "/containers/{id}/changes") { _, _ in
            throw DockerAPIError.notImplemented(
                "changes is not supported by SiliconShip: a container's filesystem is a disk of its own, not a layer over its image")
        }
        router.add(.GET, "/containers/{id}/export") { _, _ in
            throw DockerAPIError.notImplemented("export is not supported by SiliconShip: copy files out of the container with docker cp instead")
        }

        // Swarm: init and join cannot succeed here; everything else is dockerd's answer on a
        // node that is in no swarm.
        for action in ["init", "join"] {
            router.add(.POST, "/swarm/\(action)") { _, _ in
                throw DockerAPIError.notImplemented("swarm mode is not supported by SiliconShip")
            }
        }
        router.add(.POST, "/swarm/leave") { _, _ in throw DockerAPIError(.serviceUnavailable, notInASwarm) }
        for prefix in ["swarm", "services", "nodes", "secrets", "configs", "tasks"] {
            for method in methods {
                router.add(method, "/\(prefix)") { _, _ in throw DockerAPIError(.serviceUnavailable, notASwarmManager) }
                router.add(method, "/\(prefix)/{rest+}") { _, _ in throw DockerAPIError(.serviceUnavailable, notASwarmManager) }
            }
        }

        for method in methods {
            for pattern in ["/plugins", "/plugins/{rest+}"] {
                router.add(method, pattern) { _, _ in
                    throw DockerAPIError.notImplemented("plugins are not supported by SiliconShip")
                }
            }
        }
    }
}
