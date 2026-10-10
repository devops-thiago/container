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
import ContainerResource
import Foundation
import Testing

@testable import ContainerAPIClient

@Suite("Health check flags")
struct HealthFlagsTests {
    private func configuration(_ arguments: [String]) throws -> HealthCheckConfiguration? {
        try Flags.Health.parse(arguments).configuration()
    }

    @Test("no flag asks for nothing, so the image's check stands")
    func nothingGiven() throws {
        #expect(try configuration([]) == nil)
        #expect(try configuration(["--health-cmd", ""]) == nil, "Docker reads an empty command as none given")
    }

    @Test("--health-cmd is a shell command, and the durations are nanoseconds")
    func commandAndTiming() throws {
        let check = try #require(
            try configuration([
                "--health-cmd", "wget -qO- localhost", "--health-interval", "2s", "--health-timeout", "1m30s", "--health-retries", "4",
                "--health-start-period", "500ms", "--health-start-interval", "1s",
            ]))
        #expect(check.test == ["CMD-SHELL", "wget -qO- localhost"])
        #expect(check.interval == 2_000_000_000)
        #expect(check.timeout == 90_000_000_000)
        #expect(check.retries == 4)
        #expect(check.startPeriod == 500_000_000)
        #expect(check.startInterval == 1_000_000_000)
    }

    @Test("timing alone keeps the image's test")
    func timingOnly() throws {
        let check = try #require(try configuration(["--health-interval", "5s"]))
        #expect(check.test.isEmpty)
        #expect(check.interval == 5_000_000_000)
    }

    @Test("--no-healthcheck turns the image's check off, and cannot be given with the others")
    func disabled() throws {
        #expect(try configuration(["--no-healthcheck"]) == .disabled)
        #expect(throws: (any Error).self) { try configuration(["--no-healthcheck", "--health-cmd", "true"]) }
        #expect(throws: (any Error).self) { try Flags.Health.parse(["--no-healthcheck", "--health-retries", "2"]) }
    }

    @Test(
        "durations are Go's, and Docker's limits apply",
        arguments: [
            ["--health-interval", "2"],
            ["--health-interval", "-1s"],
            ["--health-timeout", "1us"],
            ["--health-retries", "-1"],
            ["--health-start-period", "soon"],
        ])
    func refused(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try Flags.Health.parse(arguments) }
    }

    @Test("the memberwise form is what the app builds, and reads the same")
    func memberwise() throws {
        let given = Flags.Health(command: "true", interval: "10s", timeout: nil, retries: nil, startPeriod: nil, startInterval: nil, disabled: false)
        let check = try #require(try given.configuration())
        #expect(check == HealthCheckConfiguration(test: ["CMD-SHELL", "true"], interval: 10_000_000_000))
        #expect(try Flags.Health.none.configuration() == nil)
        #expect(try Flags.Management.parse([]).health.configuration() == nil)
    }
}

@Suite("The image's HEALTHCHECK")
struct ImageHealthCheckTests {
    @Test("read from the config blob, with Docker's names and nanoseconds")
    func readFromTheBlob() throws {
        let blob = """
            {"architecture":"arm64","os":"linux","config":{"Env":["PATH=/usr/bin"],"Cmd":["nginx"],
             "Healthcheck":{"Test":["CMD-SHELL","curl -f http://localhost/ || exit 1"],"Interval":5000000000,"Timeout":3000000000,
             "StartPeriod":10000000000,"Retries":4}},"rootfs":{"type":"layers","diff_ids":[]}}
            """
        let document = try JSONDecoder().decode(ImageHealthCheckDocument.self, from: Data(blob.utf8))
        #expect(
            document.config?.healthcheck?.configuration
                == HealthCheckConfiguration(
                    test: ["CMD-SHELL", "curl -f http://localhost/ || exit 1"], interval: 5_000_000_000, timeout: 3_000_000_000,
                    startPeriod: 10_000_000_000, retries: 4))
    }

    @Test("an image without one, or with HEALTHCHECK NONE, gives no check")
    func noneOrNONE() throws {
        let without = try JSONDecoder().decode(ImageHealthCheckDocument.self, from: Data(#"{"config":{"Cmd":["sh"]}}"#.utf8))
        #expect(without.config?.healthcheck == nil)
        let none = try JSONDecoder().decode(ImageHealthCheckDocument.self, from: Data(#"{"config":{"Healthcheck":{"Test":["NONE"]}}}"#.utf8))
        let check = try #require(none.config?.healthcheck?.configuration)
        #expect(HealthCheckConfiguration.resolve(user: nil, image: check) == nil)
        let bare = try JSONDecoder().decode(ImageHealthCheckDocument.self, from: Data(#"{"architecture":"arm64"}"#.utf8))
        #expect(bare.config == nil)
    }
}
