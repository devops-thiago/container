//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ContainerVersion
import ContainerXPC
import ContainerizationOS
import Darwin
import Foundation
import Logging
import Synchronization
import SystemPackage

public struct PluginLoader: Sendable {
    public static let lifecycleGenerationEnvironmentName = "CONTAINER_LIFECYCLE_GENERATION"

    private static let launchdLabelPrefix = ServiceIdentity.machPrefix

    private let appRoot: URL

    private let installRoot: URL

    private let logRoot: FilePath?

    private let pluginDirectories: [URL]

    private let pluginFactories: [PluginFactory]

    private let log: Logger?

    public let lifecycleGeneration: String?

    public typealias PluginQualifier = ((Plugin) -> Bool)

    // A path on disk managed by the PluginLoader, where it stores
    // runtime data for loaded plugins. This includes the launchd plists
    // and logs files.
    private let pluginResourceRoot: URL

    public init(
        appRoot: URL,
        installRoot: URL,
        logRoot: FilePath?,
        pluginDirectories: [URL],
        pluginFactories: [PluginFactory],
        lifecycleGeneration: String? = nil,
        log: Logger? = nil
    ) throws {
        let pluginResourceRoot = appRoot.appendingPathComponent("plugin-state")
        try FileManager.default.createDirectory(at: pluginResourceRoot, withIntermediateDirectories: true)
        self.pluginResourceRoot = pluginResourceRoot
        self.appRoot = appRoot
        self.installRoot = installRoot
        self.logRoot = logRoot
        self.pluginDirectories = pluginDirectories
        self.pluginFactories = pluginFactories
        self.lifecycleGeneration = lifecycleGeneration
        self.log = log
    }

    public static func isValidLifecycleGeneration(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.allSatisfy {
                (97...122).contains($0)
                    || (65...90).contains($0)
                    || (48...57).contains($0)
                    || $0 == 45
            }
    }

    public static func generationQualifiedLabel(_ label: String, lifecycleGeneration: String?) -> String {
        guard let lifecycleGeneration else {
            return label
        }
        return "\(label).\(lifecycleGeneration)"
    }

    private static func launchctlDeadline(
        timeout: TimeInterval?
    ) -> ContinuousClock.Instant? {
        timeout.map {
            ContinuousClock().now.advanced(by: .seconds(max(0, $0)))
        }
    }

    private static func remainingLaunchctlTimeout(
        until deadline: ContinuousClock.Instant?
    ) -> TimeInterval? {
        guard let deadline else { return nil }
        let remaining = ContinuousClock().now.duration(to: deadline)
        guard remaining > .zero else { return 0 }
        let components = remaining.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    public func launchdLabel(pluginName: String, instanceId: String? = nil) -> String {
        var label = "\(Self.launchdLabelPrefix)\(pluginName)"
        if let instanceId {
            label += ".\(instanceId)"
        }
        return Self.generationQualifiedLabel(label, lifecycleGeneration: lifecycleGeneration)
    }

    public func launchdLabel(plugin: Plugin, instanceId: String? = nil) -> String {
        Self.generationQualifiedLabel(
            plugin.getLaunchdLabel(instanceId: instanceId),
            lifecycleGeneration: lifecycleGeneration
        )
    }

    public func fullLaunchdLabel(pluginName: String, instanceId: String? = nil) throws -> String {
        let domain = try ServiceManager.getDomainString()
        return "\(domain)/\(launchdLabel(pluginName: pluginName, instanceId: instanceId))"
    }

    public func fullLaunchdLabel(plugin: Plugin, instanceId: String? = nil) throws -> String {
        let domain = try ServiceManager.getDomainString()
        return "\(domain)/\(launchdLabel(plugin: plugin, instanceId: instanceId))"
    }

    static public func userPluginsDir(installRoot: URL) -> URL {
        installRoot
            .appending(path: "libexec")
            .appending(path: "container-plugins")
            .resolvingSymlinksInPath()
    }
}

extension PluginLoader {
    public func alterCLIHelpText(original: String) -> String {
        var plugins = findPlugins()
        plugins = plugins.filter { $0.config.isCLI }
        guard !plugins.isEmpty else {
            return original
        }

        var lines = original.split(separator: "\n").map { String($0) }

        let sectionHeader = "PLUGINS:"
        lines.append(sectionHeader)

        for plugin in plugins {
            let helpText = plugin.helpText(padding: 24)
            lines.append(helpText)
        }

        return lines.joined(separator: "\n")
    }

    /// Scan all plugin directories and detect plugins.
    public func findPlugins() -> [Plugin] {
        let fm = FileManager.default

        // Maintain a set for tracking shadowed plugins
        var pluginNames = Set<String>()
        var plugins: [Plugin] = []

        for pluginDir in pluginDirectories {
            // Skip nonexistent plugin parent directories
            if !fm.fileExists(atPath: pluginDir.path) {
                continue
            }

            // Get all entries under the parent directory
            let resolvedPluginDir = pluginDir.resolvingSymlinksInPath()
            guard
                let urls = try? fm.contentsOfDirectory(
                    at: resolvedPluginDir,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: .skipsHiddenFiles
                )
            else {
                continue
            }

            // Filter out all but plugin installation directories
            let installURLs = urls.filter { url in
                if url.isDirectory {
                    return true
                }

                if url.isSymlink {
                    var isDirectory: ObjCBool = false
                    _ = fm.fileExists(atPath: url.resolvingSymlinksInPath().path(percentEncoded: false), isDirectory: &isDirectory)
                    return isDirectory.boolValue
                }

                return false
            }

            for installURL in installURLs {
                do {
                    // Create a plugin with the first factory that can grok the layout under the install URL
                    guard
                        let plugin = try
                            (pluginFactories.compactMap {
                                try $0.create(installURL: installURL)
                            }.first)
                    else {
                        log?.warning(
                            "not installing plugin with missing configuration",
                            metadata: [
                                "path": "\(installURL.path)"
                            ]
                        )
                        continue
                    }

                    // Warn and skip if this plugin name has been encountered already
                    guard !pluginNames.contains(plugin.name) else {
                        log?.warning(
                            "not installing shadowed plugin",
                            metadata: [
                                "path": "\(installURL.path)",
                                "name": "\(plugin.name)",
                            ])
                        continue
                    }

                    // Add the plugin to the list
                    plugins.append(plugin)
                    pluginNames.insert(plugin.name)
                } catch {
                    log?.warning(
                        "not installing plugin with invalid configuration",
                        metadata: [
                            "path": "\(installURL.path)",
                            "error": "\(error)",
                        ]
                    )
                }
            }
        }

        return plugins
    }

    /// Locate a plugin with a specific name.
    public func findPlugin(name: String, log: Logger? = nil) -> Plugin? {
        do {
            for pluginDirectory in pluginDirectories {
                for PluginFactory in pluginFactories {
                    // throw means that the factory is correct but the plugin is broken
                    if let plugin = try PluginFactory.create(parentURL: pluginDirectory, name: name) {
                        return plugin
                    }
                }
            }
        } catch {
            log?.warning(
                "not installing plugin with invalid configuration",
                metadata: [
                    "name": "\(name)",
                    "error": "\(error)",
                ]
            )
        }

        return nil
    }

    /// Locate the plugin whose executable resolves to `path`, e.g. to let a
    /// running plugin process identify its own `Plugin` (and thus its
    /// `resourceURL`) from `CommandLine.executablePath`.
    public func findPlugin(forExecutable path: FilePath) -> Plugin? {
        guard let resolvedPath = Self.resolveSymlinks(path.string) else {
            return nil
        }
        for plugin in findPlugins() {
            guard let binaryPath = Self.resolveSymlinks(plugin.binaryURL.path(percentEncoded: false)) else {
                continue
            }
            if binaryPath == resolvedPath {
                return plugin
            }
        }
        return nil
    }

    private static func resolveSymlinks(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else {
            return nil
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

extension PluginLoader {
    public static let proxyKeys: Set<String> = {
        var keys: Set<String> = [
            "http_proxy", "HTTP_PROXY",
            "https_proxy", "HTTPS_PROXY",
            "no_proxy", "NO_PROXY",
        ]
        #if CONTAINER_COVERAGE
        // Allows LLVM coverage profiling data to be written by launchd-managed
        // helper processes. Compiled in only for coverage enabled builds.
        keys.insert("LLVM_PROFILE_FILE")
        #endif
        return keys
    }()

    public func registerWithLaunchd(
        plugin: Plugin,
        pluginStateRoot: URL? = nil,
        args: [String]? = nil,
        instanceId: String? = nil,
        debug: Bool = false,
    ) throws {
        // We only care about loading plugins that have a service
        // to expose; otherwise, they may just be CLI commands.
        guard let serviceConfig = plugin.config.servicesConfig else {
            return
        }

        let id = launchdLabel(plugin: plugin, instanceId: instanceId)
        log?.info("Registering plugin", metadata: ["id": "\(id)"])
        let rootURL = pluginStateRoot ?? self.pluginResourceRoot.appending(path: plugin.name)
        let resourceURL = plugin.resourceURL

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var env = Self.filterEnvironment()
        env[ApplicationRoot.environmentName] = appRoot.path(percentEncoded: false)
        env[InstallRoot.environmentName] = installRoot.path(percentEncoded: false)
        if let lifecycleGeneration {
            env[Self.lifecycleGenerationEnvironmentName] = lifecycleGeneration
        }
        if let logRoot {
            env[LogRoot.environmentName] =
                logRoot.isAbsolute
                ? logRoot.string
                : FilePath(FileManager.default.currentDirectoryPath).appending(logRoot.components).string
        }

        let processedArgs = (args ?? ["start"]) + (resourceURL.map { ["--resources", $0.path] } ?? []) + (debug ? ["--debug"] : [])

        // Sandboxed embedding: launchd is off limits (no launchctl, and a
        // sandboxed process cannot bootstrap jobs). Static plugins are
        // SMAppService agents pre-registered by the host app, so launchd
        // already owns their mach names and demand-starts them — nothing to
        // do here. Instanced plugins (one per container) are posix_spawned as
        // inherit-sandbox children that dial the apiserver back and post
        // their anonymous endpoint (see RuntimeInstanceRegistry).
        if ServiceIdentity.appGroup != nil {
            guard let instanceId else {
                log?.debug(
                    "static plugin is an SMAppService agent; skipping launchd registration",
                    metadata: ["id": "\(id)"])
                return
            }
            env["CONTAINER_ATTACH_SERVICE"] = ServiceIdentity.apiServerService
            let argv = [plugin.binaryURL.path] + processedArgs + serviceConfig.defaultArguments
            // Evict any endpoint a previous instance (possibly an orphan of a
            // crashed apiserver) left under this label: the wait below must be
            // satisfied only by the child spawned here, or clients get handed
            // a dead endpoint and fail with 'Connection invalid'.
            let machServices = plugin.getMachServices(instanceId: instanceId)
            for service in machServices {
                InstanceEndpoints.remove(label: service)
            }
            try Self.spawnInstance(label: id, instanceId: instanceId, argv: argv, env: env, log: log)
            // Clients dial the instance as soon as this returns, so the child
            // must have announced its endpoint by then.
            let waitStart = ContinuousClock.now
            for service in machServices {
                let attached = InstanceEndpoints.waitForAttach(label: service, timeout: 30)
                log?.info(
                    "instance announce wait",
                    metadata: [
                        "service": "\(service)",
                        "attached": "\(attached)",
                        "elapsed": "\(waitStart.duration(to: ContinuousClock.now))",
                    ])
                if !attached {
                    log?.error(
                        "runtime instance did not announce its endpoint",
                        metadata: ["service": "\(service)"])
                }
            }
            return
        }

        let plist = LaunchPlist(
            label: id,
            arguments: [plugin.binaryURL.path] + processedArgs + serviceConfig.defaultArguments,
            environment: env,
            limitLoadToSessionType: [.Aqua, .Background, .System],
            runAtLoad: serviceConfig.runAtLoad,
            machServices: plugin.getMachServices(instanceId: instanceId)
        )

        let plistUrl = rootURL.appendingPathComponent("service.plist")
        let data = try plist.encode()
        try data.write(to: plistUrl)
        try ServiceManager.register(plistPath: plistUrl.path)
    }

    public func deregisterWithLaunchd(
        plugin: Plugin,
        instanceId: String? = nil,
        timeout: TimeInterval? = nil
    ) throws {
        // We only care about loading plugins that have a service
        // to expose; otherwise, they may just be CLI commands.
        guard plugin.config.servicesConfig != nil else {
            return
        }

        if ServiceIdentity.appGroup != nil {
            guard instanceId != nil else { return }
            let id = launchdLabel(plugin: plugin, instanceId: instanceId)
            Self.terminateInstance(label: id, log: log)
            return
        }
        let deadline = Self.launchctlDeadline(timeout: timeout)
        let domain = try ServiceManager.getDomainString(
            timeout: Self.remainingLaunchctlTimeout(until: deadline)
        )
        let label = "\(domain)/\(launchdLabel(plugin: plugin, instanceId: instanceId))"
        log?.info("Deregistering plugin", metadata: ["id": "\(launchdLabel(plugin: plugin, instanceId: instanceId))"])
        try ServiceManager.deregister(
            fullServiceLabel: label,
            timeout: Self.remainingLaunchctlTimeout(until: deadline)
        )
    }

    public static func filterEnvironment(
        env: [String: String] = ProcessInfo.processInfo.environment,
        additionalAllowKeys: Set<String> = Self.proxyKeys
    ) -> [String: String] {
        env.filter { key, _ in
            key.hasPrefix("CONTAINER_") || additionalAllowKeys.contains(key)
        }
    }
}

// MARK: - Spawned instances (sandboxed embedding)

extension PluginLoader {
    /// Live instance processes, keyed by launchd-style label. Holding the
    /// Process keeps its terminationHandler (the reaper) alive.
    private static let instances = Mutex<[String: Foundation.Process]>([:])

    static func spawnInstance(
        label: String,
        instanceId: String,
        argv: [String],
        env: [String: String],
        log: Logger?
    ) throws {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        // The helper logs to its own file under logRoot; don't tie its stdio
        // to ours.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { proc in
            Self.instances.withLock { _ = $0.removeValue(forKey: label) }
            log?.info(
                "runtime instance exited",
                metadata: [
                    "label": "\(label)",
                    "status": "\(proc.terminationStatus)",
                ])
        }
        try process.run()
        Self.instances.withLock { $0[label] = process }
        log?.info(
            "spawned runtime instance",
            metadata: [
                "label": "\(label)",
                "pid": "\(process.processIdentifier)",
            ])
    }

    static func terminateInstance(label: String, log: Logger?) {
        guard let process = Self.instances.withLock({ $0[label] }) else {
            log?.debug("no spawned instance to terminate", metadata: ["label": "\(label)"])
            return
        }
        log?.info(
            "terminating runtime instance",
            metadata: ["label": "\(label)", "pid": "\(process.processIdentifier)"])
        process.terminate()
    }

    /// Kill helper processes left behind by a previous apiserver.
    ///
    /// Spawned instances are ordinary children, so they outlive an apiserver
    /// that crashed or was killed rather than asked to stop. Their endpoints are
    /// already evicted on respawn, but the processes themselves would linger —
    /// holding vmnet networks and VMs — until the machine reboots. Only
    /// processes running out of `installRoot` are touched, so a separately
    /// installed container engine is never disturbed.
    /// - Returns: the pids sent SIGTERM, for `killSurvivingOrphans` to follow up on. Sending
    ///   the signal is immediate and stays on the startup path, because a stale helper still
    ///   holding a network has to be asked to go before anything new is spawned. Waiting to see
    ///   whether it obeyed does not, and used to cost every start five seconds.
    @discardableResult
    public static func reapOrphanedInstances(installRoot: URL, log: Logger? = nil) -> [pid_t] {
        let root = installRoot.resolvingSymlinksInPath().path(percentEncoded: false)
        let selfPid = getpid()

        var pids = [pid_t](repeating: 0, count: 4096)
        let byteCount = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard byteCount > 0 else { return [] }
        let count = Int(byteCount) / MemoryLayout<pid_t>.size

        var victims: [pid_t] = []
        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0, pid != selfPid else { continue }
            // Helpers only: never the app itself or the CLI the user may be running.
            guard let path = helperPath(of: pid, under: root) else { continue }
            log?.info(
                "reaping orphaned instance",
                metadata: ["pid": "\(pid)", "path": "\(path)"])
            kill(pid, SIGTERM)
            victims.append(pid)
        }

        return victims
    }

    /// Follow up on `reapOrphanedInstances`: SIGKILL whatever ignored the SIGTERM.
    ///
    /// SIGTERM alone is a request, and the vmnet helper was measured ignoring it — a single
    /// orphan survived two days of restarts, holding its network the whole time. This waits a
    /// short grace and then insists.
    ///
    /// Off the startup path deliberately. It sleeps, and running it inline delayed the
    /// apiserver reaching its listen call by up to five seconds every time an orphan was
    /// stubborn — before any client could connect at all.
    public static func killSurvivingOrphans(
        _ asked: [pid_t], installRoot: URL, log: Logger? = nil
    ) async {
        guard !asked.isEmpty else { return }
        let root = installRoot.resolvingSymlinksInPath().path(percentEncoded: false)
        var victims = asked
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(500))
            victims.removeAll { kill($0, 0) != 0 }
            if victims.isEmpty { return }
        }
        for pid in victims {
            // Checked again, not trusted from five seconds ago. The path is what authorises
            // killing this number at all, and in the grace above a victim can exit and the
            // kernel hand its number to something else — which the liveness probe cannot tell
            // apart from the victim still running. Re-reading the path is what keeps SIGKILL
            // pointed at our own helper.
            guard let path = helperPath(of: pid, under: root) else {
                log?.info("orphan exited during grace; not killing", metadata: ["pid": "\(pid)"])
                continue
            }
            log?.info(
                "orphan ignored SIGTERM; sending SIGKILL",
                metadata: ["pid": "\(pid)", "path": "\(path)"])
            kill(pid, SIGKILL)
        }
    }

    /// The executable path of `pid`, but only when it is one of our own plugin helpers living
    /// under `root`. nil for everything else, including a pid that has since exited.
    private static func helperPath(of pid: pid_t, under root: String) -> String? {
        // `proc_pidpath` returns the length it wrote, so the string is built from that rather
        // than by scanning for a terminator — which is also what the array form of
        // `String(cString:)` was deprecated for asking callers to assume.
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer[..<Int(length)], as: UTF8.self)
        guard path.hasPrefix(root), path.contains("/libexec/container/plugins/") else {
            return nil
        }
        return path
    }

    /// Labels of currently live spawned instances.
    public static func spawnedInstanceLabels() -> [String] {
        Self.instances.withLock { Array($0.keys) }
    }

    /// Quit path: SIGTERM every spawned instance (graceful container stop
    /// happens first through the runtime API; this is the backstop).
    ///
    /// Waits for them, briefly. Asking and exiting in the same breath is what leaves a helper
    /// orphaned holding a vmnet network: SIGTERM is delivered but the parent is gone before the
    /// child finishes unwinding, and reparenting to launchd means nothing collects it until the
    /// next engine start sweeps for orphans. The wait is bounded well inside the few seconds
    /// launchd allows a job after its own SIGTERM, and a helper that will not go in that time is
    /// killed outright — this is the last moment anything can be done about it.
    public static func terminateAllInstances(log: Logger? = nil, waitFor: Duration = .seconds(2)) {
        let all = Self.instances.withLock { Array($0.values) }
        var asked: [Process] = []
        for process in all where process.isRunning {
            log?.info("terminating instance", metadata: ["pid": "\(process.processIdentifier)"])
            process.terminate()
            asked.append(process)
        }
        guard !asked.isEmpty else { return }

        let deadline = ContinuousClock.now.advanced(by: waitFor)
        while ContinuousClock.now < deadline {
            asked.removeAll { !$0.isRunning }
            if asked.isEmpty { return }
            usleep(50_000)
        }
        for process in asked where process.isRunning {
            log?.info("instance ignored SIGTERM; killing", metadata: ["pid": "\(process.processIdentifier)"])
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
