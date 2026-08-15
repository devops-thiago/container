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

import ArgumentParser
import ContainerAPIClient
import ContainerAPIService
import ContainerLog
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerVersion
import ContainerXPC
import ContainerizationExtras
import DNSServer
import Foundation
import Logging
import SystemPackage

extension APIServer {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start helper for the API server"
        )

        static let listenAddress = "127.0.0.1"
        static let localhostDNSPort = 1053
        static let dnsPort = 2053

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        @Option(name: .customLong("lifecycle-generation"), help: "Lifecycle generation for generation-aware shutdown")
        var lifecycleGenerationOption: String?

        private var lifecycleGeneration: String? {
            lifecycleGenerationOption ?? ProcessInfo.processInfo.environment[PluginLoader.lifecycleGenerationEnvironmentName]
        }

        var appRoot = ApplicationRoot.path

        var installRoot = InstallRoot.path

        var logRoot = LogRoot.path

        func validate() throws {
            if let lifecycleGeneration,
                !PluginLoader.isValidLifecycleGeneration(lifecycleGeneration)
            {
                throw ValidationError("Lifecycle generation must contain only ASCII letters, digits, and hyphens")
            }
        }

        func run() async throws {
            let containerSystemConfig: ContainerSystemConfig = try await ConfigurationLoader.load()
            let commandName = APIServer._commandName
            let logPath = logRoot.map { $0.appending(FilePath.Component("\(commandName).log") ?? "unknown") }
            let log = ServiceLogger.bootstrap(category: "APIServer", debug: debug, logPath: logPath)
            log.info("starting helper", metadata: ["name": "\(commandName)"])
            defer {
                log.info("stopping helper", metadata: ["name": "\(commandName)"])
            }

            do {
                // launchd delivers SIGTERM when the host app unregisters the
                // agents (quit). Spawned runtime instances are our children and
                // would be orphaned; reap them before exiting. Graceful
                // container stops have already happened through the API by the
                // time a well-behaved host quits — this is the backstop.
                signal(SIGTERM, SIG_IGN)
                let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
                sigterm.setEventHandler {
                    PluginLoader.terminateAllInstances()
                    Darwin.exit(0)
                }
                sigterm.activate()

                // A previous apiserver may have died without reaping its
                // helpers; they would otherwise hold vmnet networks and VMs
                // forever.
                let root = URL(fileURLWithPath: installRoot.string)
                let asked = PluginLoader.reapOrphanedInstances(installRoot: root, log: log)
                // The SIGTERM above is on the startup path because a helper still holding a
                // network has to be asked to go before new ones spawn. Finding out whether it
                // obeyed is not: that waits, and waiting here delayed the listen call below by
                // up to five seconds whenever an orphan was stubborn.
                if !asked.isEmpty {
                    Task { await PluginLoader.killSurvivingOrphans(asked, installRoot: root, log: log) }
                }

                log.info("configuring XPC server")
                var routes = [XPCRoute: XPCServer.RouteHandler]()
                let processNonce = UUID().uuidString
                let ownerWatchdog = OwnerWatchdog(log: log)
                let pluginLoader = try initializePluginLoader(log: log)

                let pluginsService = try await initializePlugins(pluginLoader: pluginLoader, log: log, routes: &routes, debug: debug)

                // Sandboxed embedding: spawned plugin instances announce their
                // anonymous endpoints here (InstanceAttach), since they can own
                // no launchd mach name.
                if ServiceIdentity.appGroup != nil {
                    let attachHarness = InstanceAttachHarness(log: log)
                    routes[XPCRoute.runtimeAttach] = XPCServer.route(attachHarness.attach)
                    routes[XPCRoute.runtimeResolve] = XPCServer.route(attachHarness.resolve)

                    // The embedder pushing folders its user granted. Same table as the attach
                    // routes above, because the embedder's grant listener is announced through
                    // them: it can own no mach name either (S7a).
                    await HostDirectoryGrants.shared.configure(log: log)
                    routes[XPCRoute.hostDirectoryGrantsPublish] = XPCServer.route {
                        (message: XPCMessage) async throws -> XPCMessage in
                        guard
                            let data = message.dataNoCopy(key: .hostDirectoryBookmarks),
                            let bookmarks = try? JSONDecoder().decode([Data].self, from: data)
                        else { return message.reply() }
                        let kept = await HostDirectoryGrants.shared.publish(bookmarks: bookmarks)
                        log.info(
                            "embedder published host directory grants",
                            metadata: ["sent": "\(bookmarks.count)", "kept": "\(kept)"])
                        return message.reply()
                    }
                }

                let containersService = try initializeContainersService(
                    pluginLoader: pluginLoader,
                    containerSystemConfig: containerSystemConfig,
                    log: log,
                    routes: &routes
                )
                let networkService = try await initializeNetworksService(
                    pluginLoader: pluginLoader,
                    containersService: containersService,
                    containerSystemConfig: containerSystemConfig,
                    log: log,
                    routes: &routes
                )
                await containersService.setNetworksService(networkService)
                initializeHealthCheckService(processNonce: processNonce, log: log, routes: &routes)
                try initializeKernelService(log: log, routes: &routes)
                let volumesService = try await initializeVolumeService(containersService: containersService, log: log, routes: &routes)
                try initializeDiskUsageService(
                    containersService: containersService,
                    volumesService: volumesService,
                    log: log,
                    routes: &routes
                )

                if let lifecycleGeneration {
                    let shutdownGate = SystemShutdownGate()
                    let mutatingRoutes: Set<XPCRoute> = [
                        .containerCreate,
                        .containerDelete,
                        .containerBootstrap,
                        .containerCreateProcess,
                        .containerStartProcess,
                        .containerKill,
                        .containerStop,
                        .containerResize,
                        .containerCopyIn,
                        .pluginLoad,
                        .pluginRestart,
                        .pluginUnload,
                        .networkCreate,
                        .networkDelete,
                        .volumeCreate,
                        .volumeDelete,
                        .installKernel,
                    ]
                    for route in mutatingRoutes {
                        if let handler = routes[route] {
                            routes[route] = shutdownGate.wrap(handler)
                        }
                    }

                    let shutdownService = SystemShutdownService(
                        lifecycleGeneration: lifecycleGeneration,
                        processNonce: processNonce,
                        ownershipToken: ProcessInfo.processInfo.environment["CONTAINER_SILICONSHIP_OWNERSHIP_TOKEN"],
                        containersService: containersService,
                        pluginsService: pluginsService,
                        shutdownGate: shutdownGate,
                        log: log
                    )
                    routes[XPCRoute.systemShutdown] = shutdownService.shutdown
                }

                // Work is gated on the engine having a running app; the engine's own plumbing
                // is not. The ping is how a client asks whether the engine is there at all,
                // which it must be able to do precisely when the answer is no. The attach and
                // resolve routes are helpers we spawned posting and dialing their endpoints,
                // and the grant publish is the app handing us its folder bookmarks — none of
                // those are a user running a workload, and refusing them only stops the engine
                // assembling itself. Nothing escapes through them either: the routes that start
                // containers are all gated.
                let ungated: Set<XPCRoute> = [.ping, .runtimeAttach, .runtimeResolve, .hostDirectoryGrantsPublish]
                for (route, handler) in routes where !ungated.contains(route) {
                    routes[route] = ownerWatchdog.wrap(handler)
                }

                let server = XPCServer(
                    identifier: ServiceIdentity.apiServerService,
                    routes: routes.reduce(
                        into: [String: XPCServer.RouteHandler](),
                        {
                            $0[$1.key.rawValue] = $1.value
                        }), log: log)

                await withTaskGroup(of: Result<Void, Error>.self) { group in
                    group.addTask {
                        log.info("starting XPC server")
                        do {
                            try await server.listen()
                            return .success(())
                        } catch {
                            return .failure(error)
                        }
                    }

                    group.addTask {
                        // Networks spawn helpers that announce back to us, so
                        // they can only start once the listener above is up.
                        //
                        // And only on behalf of an app. launchd demand-starts this engine for
                        // any dial, including a CLI one with no app running, and that engine
                        // is about to exit — a vmnet interface claimed on the way through
                        // outlives it as an orphan holding the network.
                        guard await ownerWatchdog.waitUntilOwnedOrExpired() else {
                            log.info("no owning app; not provisioning persisted networks")
                            return .success(())
                        }
                        await networkService.startPersistedNetworks()
                        return .success(())
                    }

                    group.addTask {
                        // The host app is not this process's parent — launchd is — so a force
                        // quit of the app kills only the app and cascades nowhere. Waiting on
                        // the owner here is what actually makes the engine's lifetime the
                        // app's. It doubles as the exit for an engine that launchd
                        // demand-started for a CLI with no app running, which nobody ever
                        // claims.
                        await ownerWatchdog.waitForOwnerLoss()
                        log.info("engine has no owning app; stopping")
                        await Self.stopContainersOnOwnerLoss(containersService: containersService, log: log)
                        // Same backstop as the SIGTERM path: spawned runtime and network
                        // helpers are our children and would otherwise be orphaned holding
                        // VMs and vmnet interfaces.
                        PluginLoader.terminateAllInstances(log: log)
                        Darwin.exit(0)
                    }

                    // start up host table DNS
                    group.addTask {
                        let hostsResolver = ContainerDNSHandler(networkService: networkService)
                        let nxDomainResolver = NxDomainResolver()
                        let compositeResolver = CompositeResolver(handlers: [hostsResolver, nxDomainResolver])
                        let hostsQueryValidator = StandardQueryValidator(handler: compositeResolver)
                        let dnsServer: DNSServer = DNSServer(handler: hostsQueryValidator, log: log)
                        log.info(
                            "starting DNS resolver for container hostnames",
                            metadata: [
                                "host": "\(Self.listenAddress)",
                                "port": "\(Self.dnsPort)",
                            ]
                        )
                        do {
                            try await dnsServer.run(host: Self.listenAddress, port: Self.dnsPort)
                            return .success(())
                        } catch {
                            return .failure(error)
                        }

                    }

                    // start up realhost DNS
                    group.addTask {
                        do {
                            let localhostResolver = LocalhostDNSHandler(log: log)
                            try await localhostResolver.monitorResolvers()

                            let nxDomainResolver = NxDomainResolver()
                            let compositeResolver = CompositeResolver(handlers: [localhostResolver, nxDomainResolver])
                            let hostsQueryValidator = StandardQueryValidator(handler: compositeResolver)
                            let dnsServer: DNSServer = DNSServer(handler: hostsQueryValidator, log: log)
                            log.info(
                                "starting DNS resolver for localhost",
                                metadata: [
                                    "host": "\(Self.listenAddress)",
                                    "port": "\(Self.localhostDNSPort)",
                                ]
                            )
                            try await dnsServer.run(host: Self.listenAddress, port: Self.localhostDNSPort)
                            return .success(())
                        } catch {
                            return .failure(error)
                        }
                    }

                    for await result in group {
                        switch result {
                        case .success():
                            continue
                        case .failure(let error):
                            log.error("API server task failed: \(error)")
                        }
                    }
                }
            } catch {
                log.error(
                    "helper failed",
                    metadata: [
                        "name": "\(commandName)",
                        "error": "\(error)",
                    ])
                APIServer.exit(withError: error)
            }
        }

        /// Stop running containers before the engine exits for want of an owner.
        ///
        /// Best-effort and bounded: the app normally stops containers itself on Quit, and this
        /// runs on the path where it never got the chance. A container that will not stop in
        /// time is left to `terminateAllInstances`, which is not graceful but does not leak.
        private static func stopContainersOnOwnerLoss(containersService: ContainersService, log: Logger) async {
            guard let snapshots = try? await containersService.list(), !snapshots.isEmpty else { return }
            log.info("stopping containers before engine exit", metadata: ["count": "\(snapshots.count)"])
            let options = ContainerStopOptions(timeoutInSeconds: 5, signal: nil)
            await withTaskGroup(of: Void.self) { group in
                for snapshot in snapshots {
                    group.addTask {
                        do {
                            try await containersService.stop(
                                id: snapshot.id, options: options, responseTimeout: .seconds(20))
                        } catch {
                            log.error(
                                "failed to stop container before engine exit",
                                metadata: ["id": "\(snapshot.id)", "error": "\(error)"]
                            )
                        }
                    }
                }
            }
        }

        private func initializePluginLoader(log: Logger) throws -> PluginLoader {
            log.info(
                "initializing plugin loader",
                metadata: [
                    "installRoot": "\(installRoot.string)"
                ])

            // TODO: Remove when we convert PluginLoader to FilePath
            let installRootURL = URL(fileURLWithPath: installRoot.string)
            let pluginsURL = PluginLoader.userPluginsDir(installRoot: installRootURL)
            log.info("detecting user plugins directory", metadata: ["path": "\(pluginsURL.path(percentEncoded: false))"])
            var directoryExists: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: pluginsURL.path, isDirectory: &directoryExists)
            let userPluginsURL = directoryExists.boolValue ? pluginsURL : nil

            // plugins built into the application installed as a Unix-like application
            let installRootPluginsPath =
                installRoot
                .appending(FilePath.Component("libexec"))
                .appending(FilePath.Component("container"))
                .appending(FilePath.Component("plugins"))
            let installRootPluginsURL = URL(fileURLWithPath: installRootPluginsPath.string)

            let pluginDirectories = [
                userPluginsURL,
                installRootPluginsURL,
            ].compactMap { $0 }

            let pluginFactories: [PluginFactory] = [
                DefaultPluginFactory(logger: log),
                AppBundlePluginFactory(logger: log),
            ]

            for pluginDirectory in pluginDirectories {
                log.info("discovered plugin directory", metadata: ["path": "\(pluginDirectory.path(percentEncoded: false))"])
            }

            let appRootURL = URL(fileURLWithPath: appRoot.string)
            return try PluginLoader(
                appRoot: appRootURL,
                installRoot: installRootURL,
                logRoot: logRoot,
                pluginDirectories: pluginDirectories,
                pluginFactories: pluginFactories,
                lifecycleGeneration: lifecycleGeneration,
                log: log
            )
        }

        // First load all of the plugins we can find. Then just expose
        // the handlers for clients to do whatever they want.
        private func initializePlugins(
            pluginLoader: PluginLoader,
            log: Logger,
            routes: inout [XPCRoute: XPCServer.RouteHandler],
            debug: Bool = false
        ) async throws -> PluginsService {
            log.info("initializing plugins")

            let bootPlugins = pluginLoader.findPlugins().filter { $0.shouldBoot }

            let service = PluginsService(pluginLoader: pluginLoader, log: log)
            try await service.loadAll(bootPlugins, debug: debug)

            let harness = PluginsHarness(service: service, log: log)
            routes[XPCRoute.pluginGet] = XPCServer.route(harness.get)
            routes[XPCRoute.pluginList] = XPCServer.route(harness.list)
            routes[XPCRoute.pluginLoad] = XPCServer.route(harness.load)
            routes[XPCRoute.pluginUnload] = XPCServer.route(harness.unload)
            routes[XPCRoute.pluginRestart] = XPCServer.route(harness.restart)
            return service
        }

        private func initializeHealthCheckService(
            processNonce: String,
            log: Logger,
            routes: inout [XPCRoute: XPCServer.RouteHandler]
        ) {
            log.info("initializing health check service")

            // TODO: Remove when we convert HealthCheckHarness to FilePath
            let installRootURL = URL(fileURLWithPath: installRoot.string)
            let appRootURL = URL(fileURLWithPath: appRoot.string)
            let svc = HealthCheckHarness(
                appRoot: appRootURL,
                installRoot: installRootURL,
                logRoot: logRoot,
                lifecycleGeneration: lifecycleGeneration,
                processNonce: lifecycleGeneration == nil ? nil : processNonce,
                log: log
            )
            routes[XPCRoute.ping] = XPCServer.route(svc.ping)
        }

        private func initializeKernelService(log: Logger, routes: inout [XPCRoute: XPCServer.RouteHandler]) throws {
            log.info("initializing kernel service")

            // TODO: Remove when we convert KernelService to FilePath
            let appRootURL = URL(fileURLWithPath: appRoot.string)
            let svc = try KernelService(log: log, appRoot: appRootURL)
            let harness = KernelHarness(service: svc, log: log)
            routes[XPCRoute.installKernel] = XPCServer.route(harness.install)
            routes[XPCRoute.getDefaultKernel] = XPCServer.route(harness.getDefaultKernel)
        }

        private func initializeContainersService(
            pluginLoader: PluginLoader,
            containerSystemConfig: ContainerSystemConfig,
            log: Logger,
            routes: inout [XPCRoute: XPCServer.RouteHandler]
        ) throws -> ContainersService {
            log.info("initializing containers service")

            // TODO: Remove when we convert ContainersService to FilePath
            let appRootURL = URL(fileURLWithPath: appRoot.string)
            let service = try ContainersService(
                appRoot: appRootURL,
                pluginLoader: pluginLoader,
                containerSystemConfig: containerSystemConfig,
                log: log,
                debugHelpers: debug
            )
            let harness = ContainersHarness(service: service, log: log)

            routes[XPCRoute.containerList] = XPCServer.route(harness.list)
            routes[XPCRoute.containerCreate] = XPCServer.route(harness.create)
            routes[XPCRoute.containerDelete] = XPCServer.route(harness.delete)
            routes[XPCRoute.containerLogs] = XPCServer.route(harness.logs)
            routes[XPCRoute.containerBootstrap] = XPCServer.route(harness.bootstrap)
            routes[XPCRoute.containerDial] = XPCServer.route(harness.dial)
            routes[XPCRoute.containerStop] = XPCServer.route(harness.stop)
            routes[XPCRoute.containerStartProcess] = XPCServer.route(harness.startProcess)
            routes[XPCRoute.containerCreateProcess] = XPCServer.route(harness.createProcess)
            routes[XPCRoute.containerResize] = XPCServer.route(harness.resize)
            routes[XPCRoute.containerWait] = XPCServer.route(harness.wait)
            routes[XPCRoute.containerKill] = XPCServer.route(harness.kill)
            routes[XPCRoute.containerStats] = XPCServer.route(harness.stats)
            routes[XPCRoute.containerDiskUsage] = XPCServer.route(harness.diskUsage)
            routes[XPCRoute.containerCopyIn] = XPCServer.route(harness.copyIn)
            routes[XPCRoute.containerCopyOut] = XPCServer.route(harness.copyOut)
            routes[XPCRoute.containerExport] = XPCServer.route(harness.export)

            return service
        }

        private func initializeNetworksService(
            pluginLoader: PluginLoader,
            containersService: ContainersService,
            containerSystemConfig: ContainerSystemConfig,
            log: Logger,
            routes: inout [XPCRoute: XPCServer.RouteHandler]
        ) async throws -> NetworksService {
            log.info("initializing networks service")

            let resourceRoot = appRoot.appending(FilePath.Component("networks"))
            let defaultNetworkConfig = try Self.defaultNetworkConfiguration(
                containerSystemConfig: containerSystemConfig)
            let service = try await NetworksService(
                pluginLoader: pluginLoader,
                resourceRoot: resourceRoot,
                containersService: containersService,
                defaultNetworkConfiguration: defaultNetworkConfig,
                log: log,
                debugHelpers: debug
            )

            // The default network is created after the XPC listener is up (see
            // ensureDefaultNetwork). Creating it here would deadlock: creating
            // a network spawns a helper that must announce its endpoint back to
            // this process, which cannot answer until it is listening.

            let harness = NetworksHarness(service: service, log: log)

            if #available(macOS 26, *) {
                routes[XPCRoute.networkCreate] = XPCServer.route(harness.create)
            }
            routes[XPCRoute.networkList] = XPCServer.route(harness.list)
            routes[XPCRoute.networkDelete] = XPCServer.route(harness.delete)

            return service
        }

        /// The built-in network every container joins unless told otherwise.
        static func defaultNetworkConfiguration(
            containerSystemConfig: ContainerSystemConfig
        ) throws -> NetworkConfiguration {
            // FIXME: default network should be configurable elsewhere
            try NetworkConfiguration(
                name: NetworkClient.defaultNetworkName,
                mode: .nat,
                ipv4Subnet: containerSystemConfig.network.subnet,
                ipv6Subnet: containerSystemConfig.network.subnetv6,
                labels: try .init([ResourceLabelKeys.role: ResourceRoleValues.builtin]),
                plugin: "container-network-vmnet"
            )
        }

        private func initializeVolumeService(
            containersService: ContainersService,
            log: Logger,
            routes: inout [XPCRoute: XPCServer.RouteHandler]
        ) async throws -> VolumesService {
            log.info("initializing volume service")

            let resourceRoot = appRoot.appending(FilePath.Component("volumes"))
            let service = try await VolumesService(resourceRoot: resourceRoot, containersService: containersService, log: log)
            let harness = VolumesHarness(service: service, log: log)

            routes[XPCRoute.volumeCreate] = XPCServer.route(harness.create)
            routes[XPCRoute.volumeDelete] = XPCServer.route(harness.delete)
            routes[XPCRoute.volumeList] = XPCServer.route(harness.list)
            routes[XPCRoute.volumeInspect] = XPCServer.route(harness.inspect)
            routes[XPCRoute.volumeDiskUsage] = XPCServer.route(harness.diskUsage)

            return service
        }

        private func initializeDiskUsageService(
            containersService: ContainersService,
            volumesService: VolumesService,
            log: Logger,
            routes: inout [XPCRoute: XPCServer.RouteHandler]
        ) throws {
            log.info("initializing disk usage service")

            let service = DiskUsageService(
                containersService: containersService,
                volumesService: volumesService,
                log: log
            )
            let harness = DiskUsageHarness(service: service, log: log)

            routes[XPCRoute.systemDiskUsage] = XPCServer.route(harness.get)
        }
    }
}
