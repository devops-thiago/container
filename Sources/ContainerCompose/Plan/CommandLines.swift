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

import Foundation

extension ProjectPlan {
    /// The project as the commands that would make it by hand, in the order `up` works:
    /// networks, volumes, then each service's build and run. Lines that start with `#`
    /// say what a command cannot.
    public var commandLines: [String] {
        var lines: [String] = []
        for network in networks {
            guard !network.external else {
                lines.append("# the network \(network.name) is external: it has to exist already")
                continue
            }
            var arguments = ArgumentList()
            if network.isInternal { arguments.flag("--internal") }
            if let subnet = network.subnet { arguments.option("--subnet", subnet) }
            for key in network.labels.keys.sorted() {
                arguments.option("--label", "\(key)=\(network.labels[key] ?? "")")
            }
            lines.append("container network create " + ShellWords.join(arguments.words + [network.name]))
        }
        for volume in volumes {
            guard !volume.external else {
                lines.append("# the volume \(volume.name) is external: it has to exist already")
                continue
            }
            var arguments = ArgumentList()
            for key in volume.labels.keys.sorted() {
                arguments.option("--label", "\(key)=\(volume.labels[key] ?? "")")
            }
            lines.append("container volume create " + ShellWords.join(arguments.words + [volume.name]))
        }
        var built: [BuildPlan] = []
        for service in services {
            // Services that share an image and its build have it built once.
            if let build = service.build, !built.contains(build) {
                built.append(build)
                lines.append("container build " + ShellWords.join(build.arguments))
            }
            for port in service.ephemeralPorts {
                lines.append("# \(service.service): port \(port.target) is published on a free host port, chosen when the container is created")
            }
            for dependency in service.dependencies where dependency.condition != .started {
                let wait = dependency.condition == .healthy ? "is healthy" : "has finished without an error"
                lines.append("# \(service.service): waits until \(dependency.service) \(wait)")
            }
            lines.append("container run " + ShellWords.join(service.arguments))
        }
        return lines
    }
}
