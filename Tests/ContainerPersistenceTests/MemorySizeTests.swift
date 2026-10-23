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
import Testing

@testable import ContainerPersistence

struct MemorySizeTests {
    @Test("a size is counted in the unit asked for")
    func counts() throws {
        #expect(try MemorySize("2g").toUInt64(unit: .bytes) == 2 << 30)
        #expect(try MemorySize("1536m").toUInt64(unit: .gibibytes) == 2)
    }

    @Test("a size no count can hold saturates, so the check that refuses it is reached", arguments: ["20000000000000g", "99999999999999999999999999p"])
    func saturates(size: String) throws {
        #expect(try MemorySize(size).toUInt64(unit: .bytes) == UInt64.max)
    }
}
