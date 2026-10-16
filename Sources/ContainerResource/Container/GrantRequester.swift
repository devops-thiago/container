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

import Foundation

#if os(macOS)
import Darwin
#endif

/// Who asked for a host folder, as the permission panel names it: `docker (pid 4242)`.
///
/// Display only. It never decides anything: a same-user process can claim any name it likes,
/// and the panel is still the user's choice of folder, not a trust decision about the asker.
/// What it does is let the user tell `docker run -v`, a test suite and an IDE apart when one
/// of them asks for a folder they did not expect.
///
/// Every value is sanitized wherever it crosses a boundary, because it is shown to the user
/// in a system panel: control and bidirectional formatting characters are removed, so a name
/// cannot break a line or reorder the text around it, and the length is bounded.
public enum GrantRequester {
    /// The longest description kept, in characters.
    public static let maxLength = 64

    /// `raw` as it may be shown, or nil when nothing showable is left.
    ///
    /// Idempotent: a sanitized value comes back unchanged.
    public static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: raw.unicodeScalars.filter { !isStripped($0) })
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let bounded = String(trimmed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        return bounded.isEmpty ? nil : bounded
    }

    /// The description of process `pid`: its executable's name and its pid, or the pid alone
    /// when the name cannot be read. nil for no process.
    ///
    /// - Parameter name: how a process's name is found; the system's by default.
    public static func describe(
        pid: pid_t,
        name: (pid_t) -> String? = GrantRequester.processName(of:)
    ) -> String? {
        guard pid > 0 else { return nil }
        let suffix = "pid \(pid)"
        guard let name = sanitized(name(pid)) else { return suffix }
        // A long name is shortened rather than the pid, which is the part that tells two
        // instances of one tool apart.
        let room = maxLength - suffix.count - 3
        guard room > 0 else { return suffix }
        let shown = String(name.prefix(room)).trimmingCharacters(in: .whitespaces)
        return sanitized("\(shown) (\(suffix))")
    }

    /// The name of process `pid`'s executable: the last component of its path, which is not
    /// truncated the way the kernel's short command name is, or that short name when the path
    /// cannot be read. nil for a process that has exited or cannot be inspected.
    public static func processName(of pid: pid_t) -> String? {
        #if os(macOS)
        guard pid > 0 else { return nil }
        var path = [UInt8](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &path, UInt32(path.count))
        if pathLength > 0 {
            let full = String(decoding: path[..<Int(pathLength)], as: UTF8.self)
            let last = (full as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        var name = [UInt8](repeating: 0, count: 256)
        let nameLength = proc_name(pid, &name, UInt32(name.count))
        guard nameLength > 0 else { return nil }
        let short = String(decoding: name[..<Int(nameLength)], as: UTF8.self)
        return short.isEmpty ? nil : short
        #else
        return nil
        #endif
    }

    /// Control characters (C0, DEL, C1) and the bidirectional formatting characters, which
    /// Unicode also counts as controls and which can make a panel read differently than it is
    /// written.
    static func isStripped(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control { return true }
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }
}
