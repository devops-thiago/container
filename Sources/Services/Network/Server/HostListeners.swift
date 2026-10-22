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

#if os(macOS)
import Darwin
#endif

/// A TCP socket listening on the Mac: the address it is bound to and its port.
public struct HostListener: Sendable, Hashable {
    public enum Address: Sendable, Hashable {
        /// `127.0.0.1` (or anything else in 127/8).
        case loopbackV4
        /// `::1`.
        case loopbackV6
        /// Every IPv4 address: `0.0.0.0`, or a dual-stack `::`. The gateway reaches it already.
        case anyV4
        /// Anything else: one interface's address, or an IPv6-only wildcard.
        case other
    }

    public let address: Address
    public let port: UInt16

    public init(address: Address, port: UInt16) {
        self.address = address
        self.port = port
    }
}

public enum HostListeners {
    /// Every TCP socket listening on this Mac now, read from the kernel's own table: the
    /// `net.inet.tcp.pcblist64` sysctl `netstat` reads. It needs no privilege and the App
    /// Sandbox allows it, so the network helper can see a service the moment it listens,
    /// whoever started it.
    public static func current() throws -> [HostListener] {
        #if os(macOS)
        let name = "net.inet.tcp.pcblist64"
        var length = 0
        // The table can grow between the size query and the read; ask with room to spare.
        for _ in 0..<3 {
            guard sysctlbyname(name, nil, &length, nil, 0) == 0 else { throw HostListenersError.sysctl(errno) }
            length += length / 4 + 4096
            var buffer = [UInt8](repeating: 0, count: length)
            let status = buffer.withUnsafeMutableBytes { sysctlbyname(name, $0.baseAddress, &length, nil, 0) }
            if status == 0 { return parse(Array(buffer.prefix(length))) }
            guard errno == ENOMEM else { throw HostListenersError.sysctl(errno) }
        }
        throw HostListenersError.sysctl(ENOMEM)
        #else
        return []
        #endif
    }

    #if os(macOS)
    /// The listeners in a `pcblist64` buffer: an `xinpgen` header, one `xtcpcb64` per socket,
    /// and an `xinpgen` trailer, each record carrying its own length.
    static func parse(_ buffer: [UInt8]) -> [HostListener] {
        buffer.withUnsafeBytes { raw -> [HostListener] in
            var listeners: [HostListener] = []
            let headerSize = MemoryLayout<xinpgen>.size
            guard raw.count >= headerSize else { return [] }
            var offset = Int(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            while offset + headerSize <= raw.count {
                let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                guard length > headerSize, offset + MemoryLayout<xtcpcb64>.size <= raw.count else { break }
                let record = raw.loadUnaligned(fromByteOffset: offset, as: xtcpcb64.self)
                if record.t_state == TCPS_LISTEN {
                    listeners.append(listener(record.xt_inpcb))
                }
                offset += length
            }
            return listeners
        }
    }

    private static func listener(_ pcb: xinpcb64) -> HostListener {
        let port = UInt16(bigEndian: pcb.inp_lport)
        if pcb.inp_vflag & UInt8(INP_IPV4) != 0 {
            let address = UInt32(bigEndian: pcb.inp_dependladdr.inp46_local.ia46_addr4.s_addr)
            if address == 0 { return HostListener(address: .anyV4, port: port) }
            if address >> 24 == 127 { return HostListener(address: .loopbackV4, port: port) }
            return HostListener(address: .other, port: port)
        }
        var local = pcb.inp_dependladdr.inp6_local
        let bytes = withUnsafeBytes(of: &local) { Array($0) }
        if bytes == [UInt8](repeating: 0, count: 15) + [1] { return HostListener(address: .loopbackV6, port: port) }
        return HostListener(address: .other, port: port)
    }
    #endif
}

public enum HostListenersError: Error, CustomStringConvertible {
    case sysctl(Int32)

    public var description: String {
        switch self {
        case .sysctl(let code): "cannot read the host's TCP listeners: \(String(cString: strerror(code)))"
        }
    }
}
