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

import ContainerizationOS
import Darwin
import Foundation
import Testing

@testable import ContainerAPIClient

struct ProcessIORawConsoleTests {
    @Test("sandbox denial accepts raw input configured by the host launcher")
    func launcherConfiguredRaw() throws {
        try withTerminal { terminal, descriptor in
            try terminal.setraw()
            #expect(try ProcessIO.configureRawConsole(terminal) { _ in throw POSIXError(.EPERM) })
            #expect(ProcessIO.hasRawInput(descriptor: descriptor))
        }
    }

    @Test("sandbox denial cannot claim canonical input is interactive")
    func canonicalDenial() throws {
        try withTerminal { terminal, descriptor in
            var settings = termios()
            try #require(tcgetattr(descriptor, &settings) == 0)
            settings.c_lflag |= tcflag_t(ICANON | ECHO)
            try #require(tcsetattr(descriptor, TCSANOW, &settings) == 0)
            #expect(try !ProcessIO.configureRawConsole(terminal) { _ in throw POSIXError(.EPERM) })
        }
    }

    @Test("raw mode rejects input that strips Unicode bytes or buffers several keys")
    func partialRawMode() throws {
        try withTerminal { terminal, descriptor in
            try terminal.setraw()
            var raw = termios()
            try #require(tcgetattr(descriptor, &raw) == 0)
            var stripped = raw
            stripped.c_iflag |= tcflag_t(ISTRIP)
            try #require(tcsetattr(descriptor, TCSANOW, &stripped) == 0)
            #expect(!ProcessIO.hasRawInput(descriptor: descriptor))
            var buffered = raw
            withUnsafeMutableBytes(of: &buffered.c_cc) { $0[Int(VMIN)] = 4 }
            try #require(tcsetattr(descriptor, TCSANOW, &buffered) == 0)
            #expect(!ProcessIO.hasRawInput(descriptor: descriptor))
        }
    }

    @Test("successful raw setup and unrelated errors retain their behavior")
    func setupResults() throws {
        try withTerminal { terminal, _ in
            let configured = try ProcessIO.configureRawConsole(terminal)
            #expect(configured)
            #expect(throws: POSIXError(.EIO)) {
                try ProcessIO.configureRawConsole(terminal) { _ in throw POSIXError(.EIO) }
            }
        }
        #expect(!ProcessIO.hasRawInput(descriptor: -1))
    }

    private func withTerminal(_ body: (Terminal, Int32) throws -> Void) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        try #require(openpty(&master, &slave, nil, nil, nil) == 0)
        defer {
            Darwin.close(master)
            Darwin.close(slave)
        }
        try body(Terminal(descriptor: slave), slave)
    }
}
