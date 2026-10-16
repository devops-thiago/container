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
import Foundation

/// Docker's stats JSON, the fields the CLI and Compose read.
public struct DockerStats: Encodable, Sendable, Equatable {
    public struct CPUUsage: Encodable, Sendable, Equatable {
        public var total_usage: UInt64 = 0
        public var usage_in_kernelmode: UInt64 = 0
        public var usage_in_usermode: UInt64 = 0
    }

    public struct Throttling: Encodable, Sendable, Equatable {
        public var periods: UInt64 = 0
        public var throttled_periods: UInt64 = 0
        public var throttled_time: UInt64 = 0
    }

    public struct CPU: Encodable, Sendable, Equatable {
        public var cpu_usage = CPUUsage()
        /// The host's CPU time, in nanoseconds across every CPU: the CLI divides the container's
        /// CPU time by its change. Absent in an empty sample, as dockerd omits a zero.
        public var system_cpu_usage: UInt64?
        public var online_cpus: UInt32?
        public var throttling_data = Throttling()
    }

    public struct Memory: Encodable, Sendable, Equatable {
        public var usage: UInt64?
        public var limit: UInt64?
    }

    public struct Network: Encodable, Sendable, Equatable {
        public var rx_bytes: UInt64 = 0
        public var rx_packets: UInt64 = 0
        public var rx_errors: UInt64 = 0
        public var rx_dropped: UInt64 = 0
        public var tx_bytes: UInt64 = 0
        public var tx_packets: UInt64 = 0
        public var tx_errors: UInt64 = 0
        public var tx_dropped: UInt64 = 0
    }

    public struct Pids: Encodable, Sendable, Equatable {
        public var current: UInt64?
    }

    public struct BlkioEntry: Encodable, Sendable, Equatable {
        public var major: UInt64 = 0
        public var minor: UInt64 = 0
        public var op: String
        public var value: UInt64
    }

    public struct Blkio: Encodable, Sendable, Equatable {
        public var io_service_bytes_recursive: [BlkioEntry]?
    }

    public var id: String
    public var name: String
    public var os_type: String?
    public var read: String
    public var preread: String
    public var cpu_stats = CPU()
    public var precpu_stats = CPU()
    public var memory_stats = Memory()
    public var networks: [String: Network]?
    public var pids_stats = Pids()
    public var blkio_stats = Blkio()
    public var num_procs: UInt32 = 0
}

/// One reading of a container's use, with the host CPU time it was read at.
public struct DockerStatsSample: Sendable {
    public let stats: ContainerStats
    public let read: Date
    /// The host's CPU time when it was read, in nanoseconds across `cpus` CPUs.
    public let systemNanoseconds: UInt64
    public let cpus: Int

    public init(stats: ContainerStats, read: Date, systemNanoseconds: UInt64, cpus: Int) {
        self.stats = stats
        self.read = read
        self.systemNanoseconds = systemNanoseconds
        self.cpus = cpus
    }
}

/// The engine's stats as Docker's stats JSON.
///
/// The engine reports the container's CPU time, memory, network and block I/O totals and its
/// process count. The CLI's CPU percentage is `Δcontainer / Δsystem × online_cpus × 100`, where
/// dockerd's system time is the host's CPU time over every CPU. A container here is a VM with
/// its own CPUs, so the system time is the time elapsed multiplied by the VM's CPU count, and
/// the percentage comes out as dockerd's does: 100% for one CPU kept busy, up to 100% × CPUs.
public enum DockerStatsMapper {
    public static func map(_ sample: DockerStatsSample?, previous: DockerStatsSample?, container: DockerContainer) -> DockerStats {
        var result = DockerStats(
            id: container.dockerID, name: "/" + container.name, read: ContainerViewMapper.timestamp(sample?.read),
            preread: ContainerViewMapper.timestamp(previous?.read))
        if let previous {
            result.precpu_stats = cpu(previous)
        }
        guard let sample else {
            // dockerd's answer for a container that is not running: names, and zeros.
            result.os_type = "linux"
            return result
        }
        result.cpu_stats = cpu(sample)
        let stats = sample.stats
        result.memory_stats = .init(usage: stats.memoryUsageBytes, limit: stats.memoryLimitBytes ?? container.snapshot.configuration.resources.memoryInBytes)
        if stats.networkRxBytes != nil || stats.networkTxBytes != nil {
            // The engine sums every interface; Docker lists them by name.
            result.networks = ["eth0": .init(rx_bytes: stats.networkRxBytes ?? 0, tx_bytes: stats.networkTxBytes ?? 0)]
        }
        result.pids_stats = .init(current: stats.numProcesses)
        if stats.blockReadBytes != nil || stats.blockWriteBytes != nil {
            result.blkio_stats = .init(io_service_bytes_recursive: [
                .init(op: "read", value: stats.blockReadBytes ?? 0), .init(op: "write", value: stats.blockWriteBytes ?? 0),
            ])
        }
        return result
    }

    static func cpu(_ sample: DockerStatsSample) -> DockerStats.CPU {
        DockerStats.CPU(
            cpu_usage: .init(total_usage: (sample.stats.cpuUsageUsec ?? 0) &* 1000), system_cpu_usage: sample.systemNanoseconds,
            online_cpus: UInt32(clamping: sample.cpus))
    }

    /// The CPU percentage the Docker CLI shows for two consecutive samples, by its formula.
    public static func cpuPercent(_ stats: DockerStats) -> Double {
        let container = Double(stats.cpu_stats.cpu_usage.total_usage) - Double(stats.precpu_stats.cpu_usage.total_usage)
        let system = Double(stats.cpu_stats.system_cpu_usage ?? 0) - Double(stats.precpu_stats.system_cpu_usage ?? 0)
        guard container > 0, system > 0 else { return 0 }
        return container / system * Double(stats.cpu_stats.online_cpus ?? 0) * 100
    }
}

/// `GET /containers/{id}/stats`.
extension ContainerToolRoutes.Routes {
    /// `?stream=&one-shot=`. A stream sends a sample a second until the container stops or the
    /// client leaves, each with the one before as its `precpu_stats`. Without a stream, one
    /// sample with a second one taken a sample interval earlier as its `precpu_stats`, as
    /// dockerd takes two; with `one-shot`, the one sample alone.
    func stats(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
        let stream = try request.bool("stream", default: true)
        let oneShot = try request.bool("one-shot")
        let container = try await find(reference)
        let engine = self.engine
        let options = self.options
        let take = { @Sendable () async throws -> DockerStatsSample in
            let stats = try await engine.stats(container.snapshot)
            let cpus = max(container.snapshot.configuration.resources.cpus, 1)
            return DockerStatsSample(
                stats: stats, read: options.now(), systemNanoseconds: options.monotonicNanoseconds() &* UInt64(cpus), cpus: cpus)
        }
        guard ContainerViewMapper.isRunning(container.snapshot) else {
            return try .json(DockerStatsMapper.map(nil, previous: nil, container: container))
        }
        guard stream else {
            var previous: DockerStatsSample?
            if !oneShot {
                previous = try await take()
                try await Task.sleep(for: options.statsInterval)
            }
            return try .json(DockerStatsMapper.map(try await take(), previous: previous, container: container))
        }
        return .stream(status: .ok, contentType: "application/json") { writer in
            var previous: DockerStatsSample?
            while true {
                // A failed sample is a container that stopped or went: the stream ends then, as
                // dockerd's does.
                guard let sample = try? await take() else { return }
                try await writer.writeJSON(DockerStatsMapper.map(sample, previous: previous, container: container))
                previous = sample
                try await Task.sleep(for: options.statsInterval)
            }
        }
    }
}
