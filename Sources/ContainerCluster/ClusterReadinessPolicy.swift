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
import ContainerResource
import ContainerizationError
import Foundation

/// The requested contract, not an inference from a node's current health.
public enum ClusterReadinessPolicy: String, CaseIterable, Sendable, ExpressibleByArgument {
    case ready
    case registered

    static func forCreation(cniManifestPath: String?) -> Self {
        cniManifestPath?.uppercased() == ClusterHelper.noCNIName ? .registered : .ready
    }
}

/// Stored in the control plane's retained guest filesystem. Start keeps its all-node
/// writable-/sys adoption preflight before reading it; a policy label never selects
/// weaker readiness. No host folder permission or private host layout is used.
enum ClusterReadinessRecord {
    static let path = "/var/lib/container-cluster/readiness"

    // Compare bytes rather than command-substitution strings: shells discard NULs.
    // cmp stops at the short expected record, including any unexpected trailing byte;
    // no record contents are buffered on the host or accepted from an oversized file.
    static let readScript = #"""
        set -eu
        file=$1
        name=$2
        if [ ! -e "$file" ] && [ ! -L "$file" ]; then exit 44; fi
        [ -f "$file" ] || exit 65
        matches() {
            printf 'container-cluster-readiness-v1\n%s\n%s\n' "$name" "$1" | cmp -s - "$file"
        }
        if matches ready; then exit 0; else code=$?; fi
        [ "$code" -eq 1 ] || exit 70
        if matches registered; then exit 10; else code=$?; fi
        [ "$code" -eq 1 ] || exit 70
        exit 65
        """#

    static let writeScript = #"""
        set -eu
        file=$1
        name=$2
        policy=$3
        case "$policy" in ready|registered) ;; *) exit 64 ;; esac
        umask 077
        directory=$(dirname "$file")
        mkdir -p "$directory"
        chmod 700 "$directory"
        [ ! -d "$file" ] || exit 65
        temporary=$(mktemp "$file.XXXXXX")
        trap 'rm -f "$temporary"' EXIT
        printf 'container-cluster-readiness-v1\n%s\n%s\n' "$name" "$policy" > "$temporary"
        mv -f "$temporary" "$file"
        [ -f "$file" ] || exit 65
        """#

    static func policy(exitCode: Int32, name: String) throws -> ClusterReadinessPolicy? {
        switch exitCode {
        case 0: return .ready
        case 10: return .registered
        case 44: return nil
        case 65:
            throw ContainerizationError(
                .invalidState,
                message: "cluster \(name) has invalid readiness metadata; explicitly select --readiness ready or --readiness registered")
        default:
            throw ContainerizationError(.internalError, message: "failed to read readiness policy for cluster \(name): exit \(exitCode)")
        }
    }
}

extension ClusterHelper {
    static func readReadinessPolicy(name: String, client: ContainerClient) async throws -> ClusterReadinessPolicy? {
        let code = try await readinessRecordCommand(
            name: name, script: ClusterReadinessRecord.readScript,
            arguments: [ClusterReadinessRecord.path, name], client: client)
        return try ClusterReadinessRecord.policy(exitCode: code, name: name)
    }

    static func writeReadinessPolicy(_ policy: ClusterReadinessPolicy, name: String, client: ContainerClient) async throws {
        let code = try await readinessRecordCommand(
            name: name, script: ClusterReadinessRecord.writeScript,
            arguments: [ClusterReadinessRecord.path, name, policy.rawValue], client: client)
        guard code == 0 else {
            throw ContainerizationError(.internalError, message: "failed to store readiness policy for cluster \(name): exit \(code)")
        }
    }

    private static func readinessRecordCommand(
        name: String, script: String, arguments: [String], client: ContainerClient
    ) async throws -> Int32 {
        try Task.checkCancellation()
        let sink = FileHandle(forWritingAtPath: "/dev/null")
        defer { try? sink?.close() }
        let process = try await client.createProcess(
            containerId: name, processId: UUID().uuidString.lowercased(),
            configuration: ProcessConfiguration(
                executable: "/bin/sh", arguments: ["-c", script, "cluster-readiness"] + arguments,
                environment: [], terminal: false),
            stdio: [nil, sink, sink], deadline: .now.advanced(by: .seconds(30)))
        try await process.start()
        return try await process.wait()
    }
}
