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
import ContainerXPC
import Containerization
import ContainerizationError
import Foundation
import Logging

public struct KernelHarness: Sendable {
    private let log: Logging.Logger
    private let service: KernelService

    public init(service: KernelService, log: Logging.Logger) {
        self.log = log
        self.service = service
    }

    @Sendable
    public func install(_ message: XPCMessage) async throws -> XPCMessage {
        let kernelFilePath = try message.kernelFilePath()
        let platform = try message.platform()
        let force = try message.kernelForce()
        let expectedDigest = message.kernelDigest()

        let installation: KernelInstallation
        if let kernelTarURL = try message.kernelTarURL() {
            let progressUpdateService = ProgressUpdateService(message: message)
            installation = try await self.service.installKernelFrom(
                tar: kernelTarURL,
                kernelFilePath: kernelFilePath,
                platform: platform,
                progressUpdate: progressUpdateService?.handler,
                expectedDigest: expectedDigest,
                force: force)
        } else {
            // We have been given a path to a kernel binary on disk
            guard let kernelFile = URL(string: kernelFilePath) else {
                throw ContainerizationError(.invalidArgument, message: "invalid kernel file path: \(kernelFilePath)")
            }
            installation = try await self.service.installKernel(
                kernelFile: kernelFile,
                platform: platform,
                force: force)
        }

        let reply = message.reply()
        reply.set(key: .kernelInstallation, value: try JSONEncoder().encode(installation))
        return reply
    }

    @Sendable
    public func getDefaultKernel(_ message: XPCMessage) async throws -> XPCMessage {
        guard let platformData = message.dataNoCopy(key: .systemPlatform) else {
            throw ContainerizationError(.invalidArgument, message: "missing SystemPlatform")
        }
        let platform = try JSONDecoder().decode(SystemPlatform.self, from: platformData)
        let kernel = try await self.service.getDefaultKernel(platform: platform)
        let reply = message.reply()
        let data = try JSONEncoder().encode(kernel)
        reply.set(key: .kernel, value: data)
        return reply
    }
}

extension XPCMessage {
    fileprivate func platform() throws -> SystemPlatform {
        guard let platformData = self.dataNoCopy(key: .systemPlatform) else {
            throw ContainerizationError(.invalidArgument, message: "missing SystemPlatform in XPC Message")
        }
        let platform = try JSONDecoder().decode(SystemPlatform.self, from: platformData)
        return platform
    }

    fileprivate func kernelFilePath() throws -> String {
        guard let kernelFilePath = self.string(key: .kernelFilePath) else {
            throw ContainerizationError(.invalidArgument, message: "missing kernel file path in XPC Message")
        }
        return kernelFilePath
    }

    fileprivate func kernelTarURL() throws -> URL? {
        guard let kernelTarURLString = self.string(key: .kernelTarURL) else {
            return nil
        }
        if let k = URL(string: kernelTarURLString), k.scheme != nil {
            return k
        }
        return URL(fileURLWithPath: kernelTarURLString)
    }

    fileprivate func kernelForce() throws -> Bool {
        self.bool(key: .kernelForce)
    }

    fileprivate func kernelDigest() -> String? {
        self.string(key: .kernelDigest)
    }
}
