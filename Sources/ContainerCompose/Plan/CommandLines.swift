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
            // The health check goes to the engine beside the options, as `--health-*` flags
            // cannot give a test without a shell; by hand, the flags are what there is.
            let healthFlags = service.healthcheck?.commandLineFlags ?? []
            lines.append("container run " + ShellWords.join(service.options + healthFlags + [service.image] + service.command))
        }
        return lines
    }
}

extension ComposeHealthcheck {
    /// The check as the flags of `container run`. A test given as a command to run without
    /// a shell is written for the shell, which is the one way `--health-cmd` takes it.
    var commandLineFlags: [String] {
        guard !isDisabled else { return ["--no-healthcheck"] }
        var arguments = ArgumentList()
        if test.count == 3, Array(test.prefix(2)) == HealthCheckConfiguration.shell {
            arguments.option("--health-cmd", test[2])
        } else if !test.isEmpty {
            arguments.option("--health-cmd", ShellWords.join(test))
        }
        func duration(_ seconds: Double) -> String {
            HealthCheckConfiguration.format(.nanoseconds(Int64((seconds * 1_000_000_000).rounded())))
        }
        if let interval { arguments.option("--health-interval", duration(interval)) }
        if let timeout { arguments.option("--health-timeout", duration(timeout)) }
        if let retries { arguments.option("--health-retries", "\(retries)") }
        if let startPeriod { arguments.option("--health-start-period", duration(startPeriod)) }
        if let startInterval { arguments.option("--health-start-interval", duration(startInterval)) }
        return arguments.words
    }
}
