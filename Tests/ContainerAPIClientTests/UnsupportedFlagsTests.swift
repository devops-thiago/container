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
import Testing

@testable import ContainerAPIClient

@Suite("Unsupported run flags")
struct UnsupportedFlagsTests {
    @Test("flags of other tools parse, and the ones given are named in order")
    func givenFlagsAreNamed() throws {
        let parsed = try Flags.Unsupported.parse([
            "--device", "/dev/kvm", "--privileged", "--device", "/dev/fuse",
            "--pid", "host", "--log-opt", "max-size=10m", "--security-opt", "seccomp=unconfined",
        ])
        #expect(parsed.given == ["--privileged", "--pid", "--device", "--security-opt", "--log-opt"])
        #expect(parsed.device == ["/dev/kvm", "/dev/fuse"])
    }

    @Test("nothing given, nothing to warn about")
    func nothingGiven() throws {
        #expect(try Flags.Unsupported.parse([]).given.isEmpty)
    }

    @Test("-P is --publish-all")
    func publishAllShort() throws {
        #expect(try Flags.Unsupported.parse(["-P"]).given == ["--publish-all"])
    }

    @Test("a flag no tool has is still an error")
    func unknownFlagStillFails() {
        #expect(throws: (any Error).self) { try Flags.Unsupported.parse(["--bogus"]) }
    }

    @Test("the flags all parse together with the run command's own groups")
    func noNameCollisions() throws {
        // Every flag at once: ArgumentParser reports a duplicated name the first time a
        // group is parsed, so this is the collision check against the existing groups.
        var arguments: [String] = []
        for flag in ["--privileged", "--oom-kill-disable", "--no-healthcheck", "--publish-all"] { arguments.append(flag) }
        let valued = [
            "pid", "ipc", "uts", "userns", "cgroupns", "cgroup-parent", "oom-score-adj", "log-driver", "gpus", "isolation",
            "stop-signal", "stop-timeout", "health-cmd", "health-interval", "health-retries", "health-start-period",
            "health-start-interval", "health-timeout", "ip", "ip6", "mac-address", "domainname", "memory-swap",
            "memory-swappiness", "memory-reservation", "kernel-memory", "cpu-shares", "cpu-period", "cpu-quota",
            "cpuset-cpus", "cpuset-mems", "blkio-weight", "pids-limit", "detach-keys", "volume-driver", "device",
            "device-cgroup-rule", "security-opt", "log-opt", "storage-opt", "link", "expose", "group-add",
            "blkio-weight-device", "device-read-bps", "device-read-iops", "device-write-bps",
            "device-write-iops", "attach", "annotation", "label-file", "volumes-from",
        ]
        for flag in valued { arguments += ["--\(flag)", "x"] }
        let parsed = try Flags.Unsupported.parse(arguments)
        #expect(parsed.given.count == 4 + valued.count)
        let management = try Flags.Management.parse(["--name", "n", "--hostname", "h"])
        #expect(management.name == "n")
    }
}
