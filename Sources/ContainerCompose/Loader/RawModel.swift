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

/// A service as one compose file states it: only what that file says, so that a later
/// file can add to it or replace parts of it.
struct RawService {
    /// Where the service's name is written.
    var location: SourceLocation?
    /// Where each of its keys is written, for messages about one setting.
    var keyLocations: [String: SourceLocation] = [:]
    var image: String?
    var build: RawBuild?
    var command: [String]?
    var entrypoint: [String]?
    /// nil values are names without a value, to be taken from the environment.
    var environment: [String: String?]?
    var envFiles: [RawEnvFile]?
    var ports: [ComposePort]?
    var mounts: [ComposeMount]?
    var dependsOn: [ComposeDependency]?
    var healthcheck: RawHealthcheck?
    var restart: String?
    var containerName: String?
    var networks: [ComposeServiceNetwork]?
    var profiles: [String]?
    var pullPolicy: ComposePullPolicy?
    var workingDirectory: String?
    var user: String?
    var labels: [String: String]?
    var platform: String?
    var tmpfs: [String]?
    var ulimits: [ComposeUlimit]?
    var capAdd: [String]?
    var capDrop: [String]?
    var readOnly: Bool?
    var useInit: Bool?
    var tty: Bool?
    var shmSize: String?
    var dns: [String]?
    var dnsSearch: [String]?
    var dnsOptions: [String]?
    var stopSignal: String?
    var stopGracePeriod: Double?
    var cpus: Double?
    var memory: String?
    var sysctls: [String: String]?
    var hostname: String?
    var extraHosts: [String]?
}

struct RawBuild {
    var context: String?
    var dockerfile: String?
    var args: [String: String?]?
    var target: String?
    var labels: [String: String]?
    var noCache: Bool?
    var platforms: [String]?
}

struct RawEnvFile: Hashable {
    /// Absolute.
    var path: String
    var required: Bool
    var location: SourceLocation?
}

struct RawHealthcheck {
    var location: SourceLocation?
    var test: [String]?
    var disable: Bool?
    var interval: Double?
    var timeout: Double?
    var retries: Int?
    var startPeriod: Double?
    var startInterval: Double?
}

struct RawNetwork {
    var location: SourceLocation?
    var name: String?
    var external: Bool?
    var isInternal: Bool?
    var subnet: String?
    var labels: [String: String]?
}

struct RawVolume {
    var location: SourceLocation?
    var name: String?
    var external: Bool?
    var labels: [String: String]?
}

struct RawProject {
    var name: String?
    var services: [String: RawService] = [:]
    var networks: [String: RawNetwork] = [:]
    var volumes: [String: RawVolume] = [:]
}

// MARK: - Merging
//
// A later file adds to an earlier one. A single value replaces the one before it; a mapping
// is merged key by key; a list is appended to, except where its entries have an identity (a
// mount's target, a dependency's service), in which case the later entry replaces the
// earlier one with the same identity. `command`, `entrypoint` and a healthcheck's `test`
// are single values even when they are written as lists.

private func merged<Key: Hashable, Value>(_ base: [Key: Value]?, _ override: [Key: Value]?) -> [Key: Value]? {
    guard let override else { return base }
    guard let base else { return override }
    return base.merging(override) { _, later in later }
}

/// `base` followed by `override`, an entry in `override` taking the place of the one in
/// `base` with the same identity.
private func merged<Element, Identity: Hashable>(
    _ base: [Element]?, _ override: [Element]?, by identity: (Element) -> Identity
) -> [Element]? {
    guard let override else { return base }
    guard let base else { return override }
    var result = base
    for element in override {
        if let index = result.firstIndex(where: { identity($0) == identity(element) }) {
            result[index] = element
        } else {
            result.append(element)
        }
    }
    return result
}

private func merged<Element: Hashable>(_ base: [Element]?, _ override: [Element]?) -> [Element]? {
    merged(base, override, by: { $0 })
}

extension RawService {
    func merging(_ later: RawService) -> RawService {
        var result = self
        result.location = later.location ?? location
        result.keyLocations = keyLocations.merging(later.keyLocations) { _, later in later }
        result.image = later.image ?? image
        result.build = build.map { base in later.build.map(base.merging) ?? base } ?? later.build
        result.command = later.command ?? command
        result.entrypoint = later.entrypoint ?? entrypoint
        result.environment = merged(environment, later.environment)
        result.envFiles = merged(envFiles, later.envFiles, by: \.path)
        result.ports = merged(ports, later.ports)
        result.mounts = merged(mounts, later.mounts, by: \.target)
        result.dependsOn = merged(dependsOn, later.dependsOn, by: \.service)
        result.healthcheck = healthcheck.map { base in later.healthcheck.map(base.merging) ?? base } ?? later.healthcheck
        result.restart = later.restart ?? restart
        result.containerName = later.containerName ?? containerName
        result.networks = merged(networks, later.networks, by: \.key)
        result.profiles = merged(profiles, later.profiles)
        result.pullPolicy = later.pullPolicy ?? pullPolicy
        result.workingDirectory = later.workingDirectory ?? workingDirectory
        result.user = later.user ?? user
        result.labels = merged(labels, later.labels)
        result.platform = later.platform ?? platform
        result.tmpfs = merged(tmpfs, later.tmpfs)
        result.ulimits = merged(ulimits, later.ulimits, by: \.name)
        result.capAdd = merged(capAdd, later.capAdd)
        result.capDrop = merged(capDrop, later.capDrop)
        result.readOnly = later.readOnly ?? readOnly
        result.useInit = later.useInit ?? useInit
        result.tty = later.tty ?? tty
        result.shmSize = later.shmSize ?? shmSize
        result.dns = merged(dns, later.dns)
        result.dnsSearch = merged(dnsSearch, later.dnsSearch)
        result.dnsOptions = merged(dnsOptions, later.dnsOptions)
        result.stopSignal = later.stopSignal ?? stopSignal
        result.stopGracePeriod = later.stopGracePeriod ?? stopGracePeriod
        result.cpus = later.cpus ?? cpus
        result.memory = later.memory ?? memory
        result.sysctls = merged(sysctls, later.sysctls)
        result.hostname = later.hostname ?? hostname
        result.extraHosts = merged(extraHosts, later.extraHosts)
        return result
    }
}

extension RawBuild {
    func merging(_ later: RawBuild) -> RawBuild {
        var result = self
        result.context = later.context ?? context
        result.dockerfile = later.dockerfile ?? dockerfile
        result.args = merged(args, later.args)
        result.target = later.target ?? target
        result.labels = merged(labels, later.labels)
        result.noCache = later.noCache ?? noCache
        result.platforms = merged(platforms, later.platforms)
        return result
    }
}

extension RawHealthcheck {
    func merging(_ later: RawHealthcheck) -> RawHealthcheck {
        var result = self
        result.location = later.location ?? location
        result.test = later.test ?? test
        result.disable = later.disable ?? disable
        result.interval = later.interval ?? interval
        result.timeout = later.timeout ?? timeout
        result.retries = later.retries ?? retries
        result.startPeriod = later.startPeriod ?? startPeriod
        result.startInterval = later.startInterval ?? startInterval
        return result
    }
}

extension RawNetwork {
    func merging(_ later: RawNetwork) -> RawNetwork {
        var result = self
        result.location = later.location ?? location
        result.name = later.name ?? name
        result.external = later.external ?? external
        result.isInternal = later.isInternal ?? isInternal
        result.subnet = later.subnet ?? subnet
        result.labels = merged(labels, later.labels)
        return result
    }
}

extension RawVolume {
    func merging(_ later: RawVolume) -> RawVolume {
        var result = self
        result.location = later.location ?? location
        result.name = later.name ?? name
        result.external = later.external ?? external
        result.labels = merged(labels, later.labels)
        return result
    }
}

extension RawProject {
    func merging(_ later: RawProject) -> RawProject {
        var result = self
        result.name = later.name ?? name
        result.services.merge(later.services) { base, override in base.merging(override) }
        result.networks.merge(later.networks) { base, override in base.merging(override) }
        result.volumes.merge(later.volumes) { base, override in base.merging(override) }
        return result
    }
}
