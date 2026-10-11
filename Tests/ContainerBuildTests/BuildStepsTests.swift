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
import ContainerBuild
import ContainerizationError
import ContainerizationOCI
import Foundation
import Testing

struct BuildStepsTests {
    // MARK: - Platforms

    @Test func explicitPlatformsWin() throws {
        let platforms = try Builder.resolvePlatforms(
            platforms: ["linux/amd64", "linux/arm64"],
            os: ["linux"],
            arch: ["arm64"],
            environment: [DefaultPlatform.environmentVariable: "linux/riscv64"]
        )
        #expect(platforms == [try Platform(from: "linux/amd64"), try Platform(from: "linux/arm64")])
    }

    @Test func theEnvironmentDefaultComesNext() throws {
        let platforms = try Builder.resolvePlatforms(
            platforms: [],
            os: ["linux"],
            arch: ["arm64"],
            environment: [DefaultPlatform.environmentVariable: "linux/amd64"]
        )
        #expect(platforms == [try Platform(from: "linux/amd64")])
    }

    @Test func otherwiseEveryOSAndArchPair() throws {
        let platforms = try Builder.resolvePlatforms(platforms: [], os: ["linux"], arch: ["arm64", "amd64"], environment: [:])
        #expect(platforms == [try Platform(from: "linux/arm64"), try Platform(from: "linux/amd64")])
    }

    @Test func anInvalidPlatformIsNamed() {
        #expect(throws: BuildInputError("invalid platform specified not-a-platform")) {
            try Builder.resolvePlatforms(platforms: ["not-a-platform"], os: ["linux"], arch: ["arm64"], environment: [:])
        }
        #expect(throws: BuildInputError("invalid os/architecture combination linux/")) {
            try Builder.resolvePlatforms(platforms: [], os: ["linux"], arch: [""], environment: [:])
        }
    }

    // MARK: - Tags and exports

    @Test func tagsAreNormalized() throws {
        let short = try Builder.normalizedTags(["web"])
        #expect(short == ["web:latest"])
        let full = try Builder.normalizedTags(["example.com/team/web:1.2"])
        #expect(full == ["example.com/team/web:1.2"])
        #expect(throws: (any Error).self) { try Builder.normalizedTags(["Not A Reference"]) }
    }

    @Test func anExportWithoutDestinationWritesIntoTheExportDirectory() throws {
        let directory = URL(fileURLWithPath: "/tmp/builder/abc")
        let exports = try Builder.exports(from: ["type=oci"], exportDirectory: directory)
        #expect(exports.count == 1)
        #expect(exports[0].type == "oci")
        #expect(exports[0].destination == directory.appendingPathComponent("out.tar"))
    }

    @Test func anExportWithDestinationKeepsIt() throws {
        let exports = try Builder.exports(from: ["type=tar,dest=/tmp/image.tar"], exportDirectory: URL(fileURLWithPath: "/tmp/builder/abc"))
        #expect(exports[0].type == "tar")
        #expect(exports[0].destination?.path == "/tmp/image.tar")
    }

    @Test func outcomeSummaryIsWhatTheCLIPrints() {
        #expect(Builder.BuildOutcome(tags: ["a:1", "b:2"], destination: nil).summary == "a:1\nb:2")
        #expect(
            Builder.BuildOutcome(tags: ["a:1"], destination: URL(fileURLWithPath: "/tmp/out/image.tar")).summary
                == "/tmp/out/image.tar")
    }

    // MARK: - Dockerfile and secrets

    @Test func aDockerfileUnderTheLimitPasses() throws {
        try Builder.checkBuildFileSize(Data(count: Builder.maxBuildFileSize - 1))
    }

    @Test func aDockerfileAtTheLimitIsRejected() {
        #expect(throws: ContainerizationError.self) {
            try Builder.checkBuildFileSize(Data(count: Builder.maxBuildFileSize))
        }
    }

    @Test func readBuildFileTakesTheIgnoreFileBesideIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BuildStepsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dockerfile = directory.appendingPathComponent("Dockerfile")
        try Data("FROM scratch\n".utf8).write(to: dockerfile)

        var read = try Builder.readBuildFile(at: dockerfile.path)
        #expect(read.dockerfile == Data("FROM scratch\n".utf8))
        #expect(read.dockerignore == nil)

        try Data("*.log\n".utf8).write(to: directory.appendingPathComponent("Dockerfile.dockerignore"))
        read = try Builder.readBuildFile(at: dockerfile.path)
        #expect(read.dockerignore == Data("*.log\n".utf8))
    }

    @Test func secretsAreReadFromTheirFiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("BuildStepsTests-\(UUID().uuidString)")
        try Data("from-file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let secrets: [String: Builder.Secret] = ["a": .data(Data("inline".utf8)), "b": .file(file.path)]
        #expect(Builder.secretFiles(secrets) == [file.path])
        #expect(try Builder.readSecrets(secrets) == ["a": Data("inline".utf8), "b": Data("from-file".utf8)])
    }

    // MARK: - Context

    @Test func standardInputNeedsNoContext() async throws {
        let path = try await Builder.resolveBuildFile(contextDir: "/nonexistent-\(UUID().uuidString)", file: "-", log: .init(label: "test"))
        #expect(path == "-")
    }

    @Test func aMissingContextIsNamed() async throws {
        let context = "/nonexistent-\(UUID().uuidString)"
        await #expect(throws: BuildInputError("context dir does not exist \(context)")) {
            try await Builder.resolveBuildFile(contextDir: context, file: nil, log: .init(label: "test"))
        }
    }

    @Test func theDockerfileIsFoundInTheContext() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BuildStepsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: BuildInputError("dockerfile not found in context dir")) {
            try await Builder.resolveBuildFile(contextDir: directory.path, file: nil, log: .init(label: "test"))
        }
        try Data("FROM scratch\n".utf8).write(to: directory.appendingPathComponent("Dockerfile"))
        let found = try await Builder.resolveBuildFile(contextDir: directory.path, file: nil, log: .init(label: "test"))
        #expect(URL(fileURLWithPath: found).lastPathComponent == "Dockerfile")

        await #expect(throws: BuildInputError("dockerfile does not exist \(directory.path)/Missing")) {
            try await Builder.resolveBuildFile(contextDir: directory.path, file: "\(directory.path)/Missing", log: .init(label: "test"))
        }
    }
}
