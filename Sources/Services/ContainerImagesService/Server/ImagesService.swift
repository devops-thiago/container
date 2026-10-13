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

import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerResource
import Containerization
import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import RegistryTransport
import Security
import TerminalProgress

public actor ImagesService {
    private let log: Logger
    private var logins = RegistryLoginLedger()
    private let registry: RegistryAccess
    private let contentStore: ContentStore
    private let imageStore: ImageStore
    private let snapshotStore: SnapshotStore

    public init(
        contentStore: ContentStore,
        imageStore: ImageStore,
        snapshotStore: SnapshotStore,
        log: Logger
    ) throws {
        try self.init(contentStore: contentStore, imageStore: imageStore, snapshotStore: snapshotStore, log: log, registry: .live)
    }

    /// With `registry` in place of the live registry and keychain, for tests.
    init(
        contentStore: ContentStore,
        imageStore: ImageStore,
        snapshotStore: SnapshotStore,
        log: Logger,
        registry: RegistryAccess
    ) throws {
        self.contentStore = contentStore
        self.imageStore = imageStore
        self.snapshotStore = snapshotStore
        self.log = log
        self.registry = registry
    }

    private func _list() async throws -> [Containerization.Image] {
        try await imageStore.list()
    }

    private func _get(_ reference: String) async throws -> Containerization.Image {
        try await imageStore.get(reference: reference)
    }

    private func _get(_ description: ImageDescription) async throws -> Containerization.Image {
        let exists = try await self._get(description.reference)
        guard exists.descriptor == description.descriptor else {
            throw ContainerizationError(.invalidState, message: "descriptor mismatch: expected \(description.descriptor), got \(exists.descriptor)")
        }
        return exists
    }

    public func list() async throws -> [ImageDescription] {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)"
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)"
                ]
            )
        }

        return try await imageStore.list().map { $0.description.fromCZ }
    }

    public func pull(reference: String, platform: Platform?, insecure: Bool, progressUpdate: ProgressUpdateHandler?, maxConcurrentDownloads: Int = 3) async throws
        -> ImageDescription
    {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "ref": "\(reference)",
                "platform": "\(String(describing: platform))",
                "insecure": "\(insecure)",
                "maxConcurrentDownloads": "\(maxConcurrentDownloads)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "ref": "\(reference)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let img = try await Self.withAuthentication(ref: reference) { auth in
            let progress = ContainerizationProgressAdapter.handler(from: progressUpdate)
            if insecure, let auth {
                return try await self.pullOverExplicitHTTP(
                    reference: reference,
                    platform: platform,
                    authentication: auth,
                    progress: progress,
                    maxConcurrentDownloads: maxConcurrentDownloads)
            }
            return try await self.imageStore.pull(
                reference: reference, platform: platform, insecure: insecure, auth: auth, progress: progress,
                maxConcurrentDownloads: maxConcurrentDownloads)
        }
        guard let img else {
            throw ContainerizationError(.internalError, message: "failed to pull image \(reference)")
        }
        return img.description.fromCZ
    }

    // MARK: Registry logins

    /// Where a login to `server` goes: its host and port, over `scheme` exactly as given.
    /// There is no probing and no fallback between the two; a caller that names http has
    /// chosen a registry it reaches without TLS.
    static func loginTarget(server: String, scheme: String) throws -> (host: String, port: Int?, scheme: String) {
        guard scheme == "http" || scheme == "https" else {
            throw ContainerizationError(.invalidArgument, message: "unsupported registry scheme \(scheme); use http or https")
        }
        let server = Reference.resolveDomain(domain: server)
        guard let url = URL(string: "\(scheme)://\(server)"), let host = url.host, !host.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "invalid registry \(server)")
        }
        return (host, url.port, scheme)
    }

    /// Check a login against the registry and keep it in the keychain, as
    /// `container registry login` does.
    ///
    /// Done here, in the process that reads the keychain for every pull, so the login is kept
    /// by the process that uses it. An app cannot run the bundled command line for this:
    /// macOS stops a sandboxed tool started by a sandboxed app before it runs.
    ///
    /// The check has a deadline shorter than the caller's wait, and the credential is kept
    /// only if no sign-in or sign-out for the same host began since: an answer that comes too
    /// late, or for a request that was replaced, keeps nothing.
    public func login(server: String, username: String, password: String, scheme: String) async throws {
        let target = try Self.loginTarget(server: server, scheme: scheme)
        let host = Reference.resolveDomain(domain: server)
        let ticket = logins.begin(host, at: .now)
        let authentication = BasicAuthentication(username: username, password: password)
        let registry = self.registry
        try await RegistryLoginLedger.checking(server, within: registry.deadline) {
            try await registry.check(target, authentication)
        }
        // No suspension from here to the save: the actor runs no other sign-in or sign-out
        // for this host in between.
        guard logins.mayKeep(ticket, at: .now, deadline: registry.deadline) else {
            log.info("registry login dropped: replaced or past its deadline", metadata: ["server": "\(server)"])
            throw ContainerizationError(
                .cancelled,
                message: "the login to \(server) was replaced by a later sign-in or sign-out, or ran past its deadline")
        }
        try registry.keep(host, username, password)
        log.info("registry login kept", metadata: ["server": "\(server)"])
    }

    /// Forget the login kept for `server`, as `container registry logout` does.
    public func logout(server: String) throws {
        let host = Reference.resolveDomain(domain: server)
        // A login for this host still checking the registry keeps nothing after this.
        _ = logins.begin(host, at: .now)
        do {
            try registry.forget(host)
        } catch {
            throw Self.logoutError(error, host: host)
        }
    }

    /// The keychain lets only the program that made a login remove it, so a login made with
    /// `container registry login` cannot be removed here, and says so in words.
    static func logoutError(_ error: any Error, host: String) -> any Error {
        if case KeychainQuery.Error.unhandledError(let status) = error, status == errSecInvalidOwnerEdit {
            return ContainerizationError(
                .invalidState,
                message: "the login for \(host) was made by another program, and only it can remove it",
                cause: error)
        }
        return error
    }

    /// Pull through the credential transport only when the caller explicitly selected HTTP
    /// and a credential exists. The ordinary HTTPS/anonymous path remains on ImageStore's
    /// upstream client, so there is no protocol probing or public-host downgrade here.
    private func pullOverExplicitHTTP(
        reference: String,
        platform: Platform?,
        authentication: any Authentication,
        progress: ProgressHandler?,
        maxConcurrentDownloads: Int
    ) async throws -> Containerization.Image {
        let parsed = try Reference.parse(reference)
        let name = parsed.path
        guard let tag = parsed.tag ?? parsed.digest else {
            throw ContainerizationError(.invalidArgument, message: "invalid tag/digest for image reference \(reference)")
        }
        let client = try ExplicitHTTPRegistryClient(
            reference: reference,
            authentication: authentication)
        let root = try await client.resolve(name: name, tag: tag)
        let (session, directory) = try await contentStore.newIngestSession()
        do {
            let operation = ImageStore.ImportOperation(
                name: name,
                contentStore: contentStore,
                client: client,
                ingestDir: directory,
                progress: progress,
                maxConcurrentDownloads: maxConcurrentDownloads)
            let descriptor = try await operation.import(
                root: root,
                matcher: createPlatformMatcher(for: platform))
            try await contentStore.completeIngestSession(session)
            return try await imageStore.create(
                description: Containerization.Image.Description(
                    reference: reference,
                    descriptor: descriptor))
        } catch {
            try? await contentStore.cancelIngestSession(session)
            throw error
        }
    }

    public func push(reference: String, platform: Platform?, insecure: Bool, progressUpdate: ProgressUpdateHandler?) async throws {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "ref": "\(reference)",
                "platform": "\(String(describing: platform))",
                "insecure": "\(insecure)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "ref": "\(reference)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        try await Self.withAuthentication(ref: reference) { auth in
            try await self.imageStore.push(
                reference: reference, platform: platform, insecure: insecure, auth: auth, progress: ContainerizationProgressAdapter.handler(from: progressUpdate))
        }
    }

    public func tag(old: String, new: String) async throws -> ImageDescription {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "old": "\(old)",
                "new": "\(new)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "old": "\(old)",
                    "new": "\(new)",
                ]
            )
        }

        let img = try await self.imageStore.tag(existing: old, new: new)
        return img.description.fromCZ
    }

    public func delete(reference: String, garbageCollect: Bool) async throws {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "ref": "\(reference)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "ref": "\(reference)",
                ]
            )
        }

        try await self.imageStore.delete(reference: reference, performCleanup: garbageCollect)
    }

    public func save(references: [String], out: URL, platform: Platform?) async throws {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "references": "\(references)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "references": "\(references)",
                ]
            )
        }

        let tempDir = FileManager.default.uniqueTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await self.imageStore.save(references: references, out: tempDir, platform: platform)
        try DockerImageArchive(log: self.log).writeCompatibilityFiles(in: tempDir, platform: platform ?? .current)
        let writer = try ArchiveWriter(format: .pax, filter: .none, file: out)
        try writer.archiveDirectory(tempDir)
        try writer.finishEncoding()
    }

    public func load(from tarFile: URL, force: Bool) async throws -> ([ImageDescription], [String]) {
        let archivePathname = tarFile.absolutePath()
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "archivePath": "\(archivePathname)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "archivePath": "\(archivePathname)",
                ]
            )
        }

        let reader = try ArchiveReader(file: tarFile)
        let tempDir = FileManager.default.uniqueTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        var rejectedMembers = try reader.extractContents(to: tempDir)
        guard rejectedMembers.isEmpty || force else {
            throw ContainerizationError(.invalidArgument, message: "cannot load tar image with rejected paths: \(rejectedMembers)")
        }

        if DockerImageArchive.needsConversion(at: tempDir) {
            let converted = try DockerImageArchive(log: self.log).convertToOCILayout(at: tempDir)
            rejectedMembers += converted.rejectedMembers
            // ImageStore rejects an empty index. Untagged Docker entries are
            // reported rejections, including when none of the entries has a tag.
            guard converted.hasImages else {
                return ([], rejectedMembers)
            }
        } else if !DockerImageArchive.isOCILayout(at: tempDir) {
            throw ContainerizationError(
                .invalidArgument,
                message: "not an image archive: expected an OCI layout (oci-layout + index.json) or a `docker save` archive (manifest.json)")
        }

        let loaded = try await self.imageStore.load(from: tempDir)
        var images: [ImageDescription] = []
        for image in loaded {
            images.append(image.description.fromCZ)
        }
        return (images, rejectedMembers)
    }

    public func cleanUpOrphanedBlobs() async throws -> ([String], UInt64) {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)"
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)"
                ]
            )
        }

        let images = try await self._list()
        let freedSnapshotBytes = try await self.snapshotStore.clean(keepingSnapshotsFor: images)
        let (deleted, freedContentBytes) = try await self.imageStore.cleanUpOrphanedBlobs()
        return (deleted, freedContentBytes + freedSnapshotBytes)
    }

    /// Calculate disk usage for images
    /// - Parameter activeReferences: Set of image references currently in use by containers
    public func calculateDiskUsage(activeReferences: Set<String>) async throws -> (totalCount: Int, activeCount: Int, totalSize: UInt64, reclaimableSize: UInt64) {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "references": "\(activeReferences)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "references": "\(activeReferences)",
                ]
            )
        }

        let images = try await self._list()
        var activeCount = 0
        var activeContentSizes: [String: UInt64] = [:]
        var activeSnapshotSizes: [String: UInt64] = [:]
        var processedDigests = Set<String>()

        for image in images {
            guard activeReferences.contains(image.reference) else { continue }
            activeCount += 1
            let imageDigest = try image.digest.validatedDigestEncoding()
            guard processedDigests.insert(imageDigest).inserted else { continue }

            for digest in try await image.referencedDigests() where activeContentSizes[digest] == nil {
                guard let content: Content = try await self.contentStore.get(digest: digest) else { continue }
                activeContentSizes[digest] = try self.contentDiskSize(content)
            }
            for (digest, size) in try await self.snapshotStore.getSnapshotSizes(for: image) {
                activeSnapshotSizes[digest] = size
            }
        }

        let snapshotDiskSize = await self.snapshotStore.totalAllocatedSize()
        let contentDiskTotal = try await self.contentStore.totalAllocatedSize()
        let totalOnDisk = contentDiskTotal + snapshotDiskSize
        let activeSize = activeContentSizes.values.reduce(0, +) + activeSnapshotSizes.values.reduce(0, +)
        let reclaimable = totalOnDisk > activeSize ? totalOnDisk - activeSize : 0

        return (images.count, activeCount, totalOnDisk, reclaimable)
    }

    private func contentDiskSize(_ content: Content) throws -> UInt64 {
        let values = try? content.path.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        if let allocatedSize = values?.totalFileAllocatedSize {
            return UInt64(allocatedSize)
        }
        return try content.size()
    }
}

// MARK: Image Snapshot Methods

extension ImagesService {
    public func unpack(description: ImageDescription, platform: Platform?, progressUpdate: ProgressUpdateHandler?) async throws {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "description": "\(description)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "description": "\(description)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let img = try await self._get(description)
        try await self.snapshotStore.unpack(image: img, platform: platform, progressUpdate: progressUpdate)
    }

    public func deleteImageSnapshot(description: ImageDescription, platform: Platform?) async throws {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "description": "\(description)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "description": "\(description)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let img = try await self._get(description)
        try await self.snapshotStore.delete(for: img, platform: platform)
    }

    public func getImageSnapshot(description: ImageDescription, platform: Platform) async throws -> Filesystem {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "description": "\(description)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "description": "\(description)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let img = try await self._get(description)
        return try await self.snapshotStore.get(for: img, platform: platform)
    }
}

// MARK: Static Methods

extension ImagesService {
    private static func withAuthentication<T>(
        ref: String, _ body: @Sendable @escaping (_ auth: Authentication?) async throws -> T?
    ) async throws -> T? {
        var authentication: Authentication?
        let ref = try Reference.parse(ref)
        guard let host = ref.resolvedDomain else {
            throw ContainerizationError(.invalidArgument, message: "no host specified in image reference: \(ref)")
        }
        authentication = Self.authenticationFromEnv(host: host)
        if let authentication {
            return try await body(authentication)
        }
        let keychain = KeychainHelper(securityDomain: Constants.keychainID)
        do {
            authentication = try keychain.lookup(hostname: host)
        } catch let err as KeychainHelper.Error {
            guard case .keyNotFound = err else {
                throw ContainerizationError(.internalError, message: "error querying keychain for \(host)", cause: err)
            }
        }
        do {
            return try await body(authentication)
        } catch let err as RegistryClient.Error {
            // The token server answered the saved login with its own challenge and the client
            // will not go further — the credential is what is wrong, and only the caller can
            // fix that. Name the host so an embedder can ask for that registry's login again;
            // the raw text talks about an insecure exchange and reads like a network fault.
            if case .insecureCredentialExchange = err, authentication != nil {
                throw ContainerizationError(
                    .invalidState,
                    message: "registry \(host) rejected the saved login",
                    cause: err)
            }
            guard case .invalidStatus(_, let status, _) = err else {
                throw err
            }
            guard status == .unauthorized || status == .forbidden else {
                throw err
            }
            guard authentication != nil else {
                throw ContainerizationError(.internalError, message: "\(String(describing: err)), no credentials found for host \(host)")
            }
            // A registry that answers the saved login with 401 or 403 outright — basic auth,
            // no token server — has rejected it just as surely as one whose token server
            // did. Same message, so the embedder's sign-in offer covers both.
            throw ContainerizationError(
                .invalidState,
                message: "registry \(host) rejected the saved login",
                cause: err)
        }
    }

    private static func authenticationFromEnv(host: String) -> Authentication? {
        let env = ProcessInfo.processInfo.environment
        guard env["CONTAINER_REGISTRY_HOST"] == host else {
            return nil
        }
        guard let user = env["CONTAINER_REGISTRY_USER"], let password = env["CONTAINER_REGISTRY_TOKEN"] else {
            return nil
        }
        return BasicAuthentication(username: user, password: password)
    }
}

extension ImageDescription {
    public var toCZ: Containerization.Image.Description {
        .init(reference: self.reference, descriptor: self.descriptor)
    }
}

extension Containerization.Image.Description {
    public var fromCZ: ImageDescription {
        .init(
            reference: self.reference,
            descriptor: self.descriptor
        )
    }
}
