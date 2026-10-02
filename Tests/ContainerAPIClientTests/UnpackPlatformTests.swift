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

import ContainerizationOCI
import Testing

@testable import ContainerAPIClient

struct UnpackPlatformTests {
    private let arm64 = Platform(arch: "arm64", os: "linux")
    private let amd64 = Platform(arch: "amd64", os: "linux")

    /// What an index like hello-world's lists: eight Linux platforms and an attestation
    /// manifest for each, whose platform is unknown/unknown.
    private var multiPlatform: [Platform] {
        [
            amd64, Platform(arch: "arm", os: "linux", variant: "v5"), Platform(arch: "arm", os: "linux", variant: "v6"),
            Platform(arch: "arm", os: "linux", variant: "v7"), Platform(arch: "arm64", os: "linux", variant: "v8"),
            Platform(arch: "386", os: "linux"), Platform(arch: "ppc64le", os: "linux"), Platform(arch: "s390x", os: "linux"),
            Platform(arch: "unknown", os: "unknown"),
        ]
    }

    @Test func unpacksOnlyTheHostPlatformOfAMultiPlatformImage() {
        #expect(ClientImage.unpackPlatform(host: arm64, among: multiPlatform) == arm64)
        #expect(ClientImage.unpackPlatform(host: amd64, among: multiPlatform) == amd64)
    }

    @Test func arm64MatchesWithAndWithoutItsVariant() {
        #expect(ClientImage.unpackPlatform(host: arm64, among: [Platform(arch: "arm64", os: "linux", variant: "v8")]) == arm64)
        #expect(ClientImage.unpackPlatform(host: Platform(arch: "arm64", os: "linux", variant: "v8"), among: [arm64]) != nil)
    }

    @Test func unpacksEverythingWhenTheImageLacksTheHostPlatform() {
        #expect(ClientImage.unpackPlatform(host: arm64, among: [amd64]) == nil)
        #expect(ClientImage.unpackPlatform(host: arm64, among: [Platform(arch: "unknown", os: "unknown")]) == nil)
        #expect(ClientImage.unpackPlatform(host: arm64, among: []) == nil)
    }

    @Test func aLinuxHostDoesNotTakeAnotherOSForItsOwn() {
        #expect(ClientImage.unpackPlatform(host: arm64, among: [Platform(arch: "arm64", os: "windows")]) == nil)
    }

    @Test func theHostPlatformIsLinuxOnThisMachinesArchitecture() {
        #expect(ClientImage.hostPlatform.os == "linux")
        #expect(ClientImage.hostPlatform.architecture == Arch.hostArchitecture().rawValue)
    }
}
