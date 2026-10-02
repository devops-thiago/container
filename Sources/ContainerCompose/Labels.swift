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

/// The labels compose puts on what it creates. They are how a project's containers are
/// found again, by this tool or another, and they carry what is needed to start a stopped
/// project in order without its compose file.
public enum ComposeLabels {
    public static let project = "com.docker.compose.project"
    public static let service = "com.docker.compose.service"
    public static let containerNumber = "com.docker.compose.container-number"
    public static let oneoff = "com.docker.compose.oneoff"
    public static let workingDirectory = "com.docker.compose.project.working_dir"
    public static let configFiles = "com.docker.compose.project.config_files"
    /// A digest of everything the container was created from. A service whose digest
    /// differs from its container's is created again by `up`.
    public static let configHash = "com.docker.compose.config-hash"
    /// `service:condition:restart` for each dependency, joined by commas.
    public static let dependsOn = "com.docker.compose.depends_on"
    public static let network = "com.docker.compose.network"
    public static let volume = "com.docker.compose.volume"
    /// The service's health check, as JSON. The engine does not run health checks, so the
    /// check travels with the container for whoever waits on it.
    public static let healthcheck = "com.apple.container.compose.healthcheck"
    /// Seconds a stop waits before it kills, when the service sets `stop_grace_period`.
    public static let stopGracePeriod = "com.apple.container.compose.stop-grace-period"

    public static func encode(_ dependencies: [ComposeDependency]) -> String {
        dependencies.map { "\($0.service):\($0.condition.rawValue):\($0.restart)" }.joined(separator: ",")
    }

    public static func dependencies(from label: String) -> [ComposeDependency] {
        label.split(separator: ",").compactMap { entry in
            let fields = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard let service = fields.first, !service.isEmpty else { return nil }
            let condition = fields.count > 1 ? ComposeDependency.Condition(rawValue: fields[1]) ?? .started : .started
            return ComposeDependency(service: service, condition: condition, restart: fields.count > 2 && fields[2] == "true")
        }
    }

    public static func encode(_ healthcheck: ComposeHealthcheck) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(healthcheck)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func healthcheck(from label: String) -> ComposeHealthcheck? {
        try? JSONDecoder().decode(ComposeHealthcheck.self, from: Data(label.utf8))
    }
}
