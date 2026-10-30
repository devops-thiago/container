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

import ContainerResource
import ContainerizationOCI
import Darwin
import Foundation
import MachineAPIClient
import Testing

/// Runs the production guest script with a private /etc and simulated NSS/chown.
/// Real guest execution and ownership are covered by the live machine check.
private final class UserSetupFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("machine-hook-\(UUID())")
    var home: String { root.appendingPathComponent("home/developer").path }
    var marker: String { get throws { try read("etc/.machine.initialized") } }

    init() throws {
        for directory in ["etc/machine", "etc/default", "etc/skel", "bin"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try write("etc/os-release", "ID=ubuntu\n")
        try write("etc/adduser.conf", "DSHELL=/bin/bash\n")
        try write("etc/passwd", "root:x:0:0::/root:/bin/sh\n")
        try write("etc/group", "root:x:0:\n")
        try write("etc/shadow", "root:*:0:0:99999:7:::\n")
        try write("etc/.machine.initialized", "")
        try write("etc/skel/profile", "retained skeleton\n")
        try executable(
            "bin/getent",
            #"""
            #!/bin/sh
            case "$1" in passwd|group) ;; *) exit 2 ;; esac
            awk -F: -v key="$2" '$1 == key || $3 == key { print; found=1 } END { exit !found }' "$FIXTURE_ROOT/etc/$1"
            """#)
        try executable(
            "bin/id",
            #"""
            #!/bin/sh
            [ "$1" != "-u" ] || shift
            entry=$(getent passwd "$1") || exit 1
            printf '%s\n' "$entry" | cut -d: -f3
            """#)
        try executable(
            "bin/chown",
            #"""
            #!/bin/sh
            printf '%s\n' "$*" >> "$FIXTURE_ROOT/chown.calls"
            """#)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    func executable(_ name: String, _ text: String) throws {
        try write(name, text + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(name).path)
    }

    func customHook(failOnce: Bool = false) throws {
        if failOnce { try write("fail-once", "1") }
        try executable(
            "etc/machine/create-user.sh",
            #"""
            #!/bin/sh
            set -e
            printf '%s\n' "$CONTAINER_USER" "$CONTAINER_UID" "$CONTAINER_GID" "$CONTAINER_HOME" "$CONTAINER_MACHINE_ID" "$CONTAINER_SHELL" > "$FIXTURE_ROOT/hook.env"
            printf 'run\n' >> "$FIXTURE_ROOT/hook.runs"
            if ! getent passwd "$CONTAINER_USER" >/dev/null; then
                printf '%s:x:%s:%s::%s:%s\n' "$CONTAINER_USER" "$CONTAINER_UID" "$CONTAINER_GID" "$CONTAINER_HOME" "$CONTAINER_SHELL" >> "$FIXTURE_ROOT/etc/passwd"
            fi
            if [ -e "$FIXTURE_ROOT/fail-once" ]; then
                rm "$FIXTURE_ROOT/fail-once"
                echo 'deliberate partial setup failure' >&2
                exit 17
            fi
            """#)
    }

    func run() throws -> (status: Int32, output: String) {
        // Only the fixed guest /etc paths are relocated. The setup code itself is
        // MachineUserSetup.script, not a second implementation of its decisions.
        let script = MachineUserSetup.script.replacingOccurrences(of: "/etc/", with: root.path + "/etc/")
        try write("setup.sh", script)
        let configuration = try MachineConfiguration(
            id: "hook-fixture",
            image: ImageDescription(
                reference: "fixture:latest",
                descriptor: Descriptor(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "a", count: 64), size: 0)),
            platform: .current, userSetup: UserSetup(username: "developer", uid: 1500, gid: 1600, home: home))
        var environment = Dictionary(
            uniqueKeysWithValues: configuration.processEnvironment.map { value in
                let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(parts[0]), String(parts[1]))
            })
        environment["PATH"] = root.appendingPathComponent("bin").path + ":/usr/bin:/bin"
        environment["FIXTURE_ROOT"] = root.path
        try write("output", "")
        let output = try FileHandle(forWritingTo: root.appendingPathComponent("output"))
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [root.appendingPathComponent("setup.sh").path]
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw NSError(domain: "MachineUserSetupTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "guest-script fixture timed out"])
        }
        process.waitUntilExit()
        return (process.terminationStatus, try read("output"))
    }
}

struct MachineUserSetupTests {
    @Test func customHookGetsDocumentedEnvironmentAndRunsOnce() throws {
        let f = try UserSetupFixture()
        try f.customHook()
        let first = try f.run()
        #expect(first.status == 0, "\(first.output)")
        #expect(try f.read("hook.env") == "developer\n1500\n1600\n\(f.home)\nhook-fixture\n/bin/bash\n")
        #expect(try f.marker == "1\n")
        let passwd = try f.read("etc/passwd")
        #expect(try f.run().status == 0)
        #expect(try f.read("hook.runs") == "run\n")
        #expect(try f.read("etc/passwd") == passwd)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("chown.calls").path))
    }

    @Test func partiallyFailedHookIsRetriedEvenAfterCreatingTheUser() throws {
        let f = try UserSetupFixture()
        try f.customHook(failOnce: true)
        let first = try f.run()
        #expect(first.status == 17)
        #expect(first.output.contains("deliberate partial setup failure"))
        #expect(try f.marker == "setup-pending\n")
        #expect(try f.read("etc/passwd").contains("developer:x:1500:1600:"))
        #expect(try f.run().status == 0)
        #expect(try f.marker == "1\n")
        #expect(try f.read("hook.runs") == "run\nrun\n")
        #expect(try f.run().status == 0)
        #expect(try f.read("hook.runs") == "run\nrun\n")
    }

    @Test func retainedInitializationMarkerPreventsHookRerun() throws {
        let f = try UserSetupFixture()
        try f.customHook()
        try f.write("etc/.machine.initialized", "1\n")
        try f.write("etc/passwd", "developer:x:1500:1600::\(f.home):/bin/bash\n")
        let passwd = try f.read("etc/passwd")
        #expect(try f.run().status == 0)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("hook.runs").path))
        #expect(try f.read("etc/passwd") == passwd)
    }

    @Test func missingAccountStillRunsTheLegacyHookDespiteAnOldMarker() throws {
        let f = try UserSetupFixture()
        try f.customHook()
        try f.write("etc/.machine.initialized", "1\n")
        #expect(try f.run().status == 0)
        #expect(try f.read("hook.runs") == "run\n")
        #expect(try f.read("etc/passwd").contains("developer:x:1500:1600:"))
    }

    @Test func legacyImageWithPreseededUserDoesNotUnexpectedlyRunItsHook() throws {
        let f = try UserSetupFixture()
        try f.customHook()
        let passwd = "developer:x:1500:1600::\(f.home):/bin/bash\n"
        try f.write("etc/passwd", passwd)
        #expect(try f.run().status == 0)
        #expect(try f.marker == "1\n")
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("hook.runs").path))
        #expect(try f.read("etc/passwd") == passwd)
    }

    @Test func defaultSetupStillChecksAndRepairsOnEachActualBoot() throws {
        let f = try UserSetupFixture()
        let first = try f.run()
        #expect(first.status == 0, "\(first.output)")
        #expect(try f.marker == "1\n")
        #expect(try f.read("etc/group").contains("developer:x:1600:"))
        #expect(try f.read("home/developer/profile") == "retained skeleton\n")
        let passwd = try f.read("etc/passwd")
        let ownership = try f.read("chown.calls")
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("etc/sudoers.d/developer"))
        #expect(try f.run().status == 0)
        #expect(try f.read("etc/passwd") == passwd)
        #expect(try f.read("chown.calls") == ownership)
        #expect(try f.read("etc/sudoers.d/developer").contains("NOPASSWD:ALL"))
        try f.write("etc/passwd", passwd.replacingOccurrences(of: "developer:x:1500:", with: "developer:x:1700:"))
        let conflict = try f.run()
        #expect(conflict.status != 0)
        #expect(conflict.output.contains("refusing to provision"))
    }

    @Test func defaultSetupDoesNotTakeOverAnExistingHome() throws {
        let f = try UserSetupFixture()
        try FileManager.default.createDirectory(atPath: f.home, withIntermediateDirectories: true)
        try f.write("home/developer/keep", "user data")
        let passwd = try f.read("etc/passwd")
        let result = try f.run()
        #expect(result.status != 0)
        #expect(try f.read("home/developer/keep") == "user data")
        #expect(try f.read("etc/passwd") == passwd)
        #expect(try f.marker.isEmpty)
    }

    @Test(arguments: ["non-executable", "directory", "broken-symlink"])
    func invalidCustomHookDoesNotFallBackToDefaultSetup(kind: String) throws {
        let f = try UserSetupFixture()
        let hook = f.root.appendingPathComponent("etc/machine/create-user.sh")
        switch kind {
        case "directory": try FileManager.default.createDirectory(at: hook, withIntermediateDirectories: false)
        case "broken-symlink": try FileManager.default.createSymbolicLink(at: hook, withDestinationURL: f.root.appendingPathComponent("missing"))
        default: try f.write("etc/machine/create-user.sh", "#!/bin/sh\nexit 0\n")
        }
        let passwd = try f.read("etc/passwd")
        let result = try f.run()
        #expect(result.status != 0)
        #expect(result.output.contains("must be an executable file"))
        #expect(try f.read("etc/passwd") == passwd)
        #expect(try f.marker.isEmpty)
    }
    @Test(arguments: ["future-format:pending\n", "1-future-state\n"])
    func unknownInitializationStateIsPreserved(marker: String) throws {
        let f = try UserSetupFixture()
        try f.customHook()
        try f.write("etc/.machine.initialized", marker)
        let passwd = try f.read("etc/passwd")
        let result = try f.run()
        #expect(result.status != 0)
        #expect(result.output.contains("unrecognized account setup state"))
        #expect(try f.marker == marker)
        #expect(try f.read("etc/passwd") == passwd)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("hook.runs").path))
    }

    @Test func customHookGetsTheImagesConfiguredShell() throws {
        let f = try UserSetupFixture()
        try f.customHook()
        try f.write("etc/os-release", "ID=alpine\n")
        try f.write("etc/default/useradd", "SHELL=/bin/ash\n")
        #expect(try f.run().status == 0)
        #expect(try f.read("hook.env").hasSuffix("/bin/ash\n"))
    }

}
