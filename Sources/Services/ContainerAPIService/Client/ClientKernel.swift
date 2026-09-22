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

import ContainerVersion
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import TerminalProgress

public struct ClientKernel {
    static let serviceIdentifier = ServiceIdentity.apiServerService
}

extension ClientKernel {
    private static func newClient() -> XPCClient {
        XPCClient(service: serviceIdentifier)
    }

    private static func kernelInstallation(from reply: XPCMessage) throws -> KernelInstallation {
        guard let data = reply.dataNoCopy(key: .kernelInstallation) else {
            throw ContainerizationError(
                .internalError,
                message: "missing kernel installation data from XPC response")
        }
        do {
            return try JSONDecoder().decode(KernelInstallation.self, from: data)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "malformed kernel installation data in XPC response: \(error)")
        }
    }

    @discardableResult
    public static func installKernel(
        kernelFilePath: String,
        platform: SystemPlatform,
        force: Bool
    ) async throws -> KernelInstallation {
        let client = newClient()
        let message = XPCMessage(route: .installKernel)

        message.set(key: .kernelFilePath, value: kernelFilePath)
        message.set(key: .kernelForce, value: force)

        let platformData = try JSONEncoder().encode(platform)
        message.set(key: .systemPlatform, value: platformData)
        let reply = try await client.send(message)
        return try kernelInstallation(from: reply)
    }

    @discardableResult
    public static func installKernelFromTar(
        tarFile: String,
        kernelFilePath: String,
        platform: SystemPlatform,
        progressUpdate: ProgressUpdateHandler? = nil,
        expectedDigest: String? = nil,
        force: Bool
    ) async throws -> KernelInstallation {
        try await installKernelFromTar(
            tarFile: tarFile,
            kernelFilePath: kernelFilePath,
            platform: platform,
            progressUpdate: progressUpdate,
            expectedDigest: expectedDigest,
            force: force,
            client: newClient())
    }

    /// The transport is a parameter so that a test can stand in for the daemon.
    @discardableResult
    static func installKernelFromTar(
        tarFile: String,
        kernelFilePath: String,
        platform: SystemPlatform,
        progressUpdate: ProgressUpdateHandler? = nil,
        expectedDigest: String? = nil,
        force: Bool,
        client: XPCClient
    ) async throws -> KernelInstallation {
        let message = XPCMessage(route: .installKernel)

        message.set(key: .kernelTarURL, value: tarFile)
        message.set(key: .kernelFilePath, value: kernelFilePath)
        message.set(key: .kernelForce, value: force)
        if let expectedDigest {
            message.set(key: .kernelDigest, value: expectedDigest)
        }

        let platformData = try JSONEncoder().encode(platform)
        message.set(key: .systemPlatform, value: platformData)

        var progressUpdateClient: ProgressUpdateClient?
        if let progressUpdate {
            progressUpdateClient = await ProgressUpdateClient(for: progressUpdate, request: message)
        }

        let reply: XPCMessage
        do {
            // An install from a URL is a download of hundreds of megabytes, and the one
            // request here that a person may reasonably give up on.
            reply = try await client.send(message, cancelOnTaskCancellation: true)
        } catch {
            // Closing the connection is what tells the daemon. It cancels a request's work
            // when the peer goes away and learns of a caller that stopped waiting in no other
            // way, so without this the download carries on to its end for nobody. The pending
            // reply keeps this client alive, so leaving it to `deinit` would never close it.
            client.close()
            // And stop listening for progress: a caller that gave up must hear no more of it.
            await progressUpdateClient?.finish()
            throw error
        }
        await progressUpdateClient?.finish()
        return try kernelInstallation(from: reply)
    }

    @discardableResult
    public static func getDefaultKernel(for platform: SystemPlatform) async throws -> Kernel {
        let client = newClient()
        let message = XPCMessage(route: .getDefaultKernel)

        let platformData = try JSONEncoder().encode(platform)
        message.set(key: .systemPlatform, value: platformData)
        do {
            let reply = try await client.send(message)
            guard let kData = reply.dataNoCopy(key: .kernel) else {
                throw ContainerizationError(.internalError, message: "missing kernel data from XPC response")
            }

            let kernel = try JSONDecoder().decode(Kernel.self, from: kData)
            return kernel
        } catch let err as ContainerizationError {
            guard err.isCode(.notFound) else {
                throw err
            }
            throw ContainerizationError(
                .notFound, message: "default kernel not configured for architecture \(platform.architecture), please use the `container system kernel set` command to configure it")
        }
    }
}

extension SystemPlatform {
    public static var current: SystemPlatform {
        switch Platform.current.architecture {
        case "arm64":
            return .linuxArm
        case "amd64":
            return .linuxAmd
        default:
            fatalError("unknown architecture")
        }
    }
}
