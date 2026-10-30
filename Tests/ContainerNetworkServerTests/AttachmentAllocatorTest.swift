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

import DNSServer
import Testing

@testable import ContainerNetworkServer

struct AttachmentAllocatorTest {
    @Test("An exact alias cannot steal a foreign namespace", arguments: [false, true])
    func foreignSubtreeRejectedWithoutAllocating(existingIsAlias: Bool) async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 2)
        let owner = existingIsAlias ? "peer.test" : "gateway.test"
        let address = try await allocator.allocate(hostname: owner, aliases: existingIsAlias ? rules("Gateway.Test.") : [])
        await #expect(throws: (any Error).self) {
            try await allocator.allocate(hostname: "attacker.test", aliases: rules("gateway.test", ".gateway.test"))
        }
        #expect(try await allocator.lookup(hostname: "attacker.test") == nil)
        #expect(try await allocator.match(name: "child.gateway.test") == nil)
        #expect(try await allocator.match(name: "gateway.test")?.index == address)
        // A rejected claim must not consume the second address or leave an alias behind.
        _ = try await allocator.allocate(hostname: "innocent.test")
    }

    @Test("Private subtree ownership cannot be invalidated by a later exact claim", arguments: [false, true])
    func privateSubtreeRootRemainsExclusive(asHostname: Bool) async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 2)
        let address = try await allocator.allocate(hostname: "owner.test", aliases: rules("apps.test", ".apps.test"))
        await #expect(throws: (any Error).self) {
            try await allocator.allocate(hostname: asHostname ? "apps.test" : "peer.test", aliases: asHostname ? [] : rules("apps.test"))
        }
        #expect(try await allocator.match(name: "child.apps.test")?.index == address)
        _ = try await allocator.allocate(hostname: "innocent.test")
    }

    @Test func testAllocateSingleHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address = try await allocator.allocate(hostname: "test-host")

        #expect(address >= 100)
        #expect(address < 110)
    }

    @Test func testAllocateSameHostnameTwice() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address1 = try await allocator.allocate(hostname: "test-host")
        let address2 = try await allocator.allocate(hostname: "test-host")

        #expect(address1 == address2)
    }

    @Test func testAllocateMultipleHostnames() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address1 = try await allocator.allocate(hostname: "host1")
        let address2 = try await allocator.allocate(hostname: "host2")
        let address3 = try await allocator.allocate(hostname: "host3")

        #expect(address1 != address2)
        #expect(address2 != address3)
        #expect(address1 != address3)
    }

    @Test func testLookupAllocatedHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "test-host")
        let lookedUpAddress = try await allocator.lookup(hostname: "test-host")

        #expect(lookedUpAddress == allocatedAddress)
    }

    @Test func testLookupNonExistentHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address = try await allocator.lookup(hostname: "non-existent")

        #expect(address == nil)
    }

    @Test func testDeallocateAllocatedHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "test-host")
        let deallocatedAddress = try await allocator.deallocate(hostname: "test-host")

        #expect(deallocatedAddress == allocatedAddress)

        // After deallocation, lookup should return nil
        let lookedUpAddress = try await allocator.lookup(hostname: "test-host")
        #expect(lookedUpAddress == nil)
    }

    @Test func testDeallocateNonExistentHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let deallocatedAddress = try await allocator.deallocate(hostname: "non-existent")

        #expect(deallocatedAddress == nil)
    }

    @Test func testReallocateAfterDeallocation() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address1 = try await allocator.allocate(hostname: "test-host")
        let released1 = try await allocator.deallocate(hostname: "test-host")
        #expect(address1 == released1)
        let address2 = try await allocator.allocate(hostname: "test-host")

        // After deallocation, allocating the same hostname should give a new address
        #expect(address2 >= 100)
        #expect(address2 < 110)
    }

    @Test func testAllocateUntilFull() async throws {
        let size = 5
        let allocator = try AttachmentAllocator(lower: 100, size: size)

        // Allocate up to the limit
        for i in 0..<size {
            _ = try await allocator.allocate(hostname: "host\(i)")
        }

        // Attempting to allocate one more should throw
        await #expect(throws: Error.self) {
            try await allocator.allocate(hostname: "extra-host")
        }
    }

    @Test func testDeallocateAndReallocateDifferentHostname() async throws {
        let size = 3
        let allocator = try AttachmentAllocator(lower: 100, size: size)

        // Fill up the allocator
        let address1 = try await allocator.allocate(hostname: "host1")
        let address2 = try await allocator.allocate(hostname: "host2")
        let address3 = try await allocator.allocate(hostname: "host3")

        // Deallocate one
        let released2 = try await allocator.deallocate(hostname: "host2")
        #expect(address2 == released2)

        // Should be able to allocate a new hostname now
        let newAddress = try await allocator.allocate(hostname: "host4")
        #expect(newAddress >= 100)
        #expect(newAddress < 103)

        // The three remaining allocations should all be different
        let finalAddress1 = try await allocator.lookup(hostname: "host1")
        let finalAddress3 = try await allocator.lookup(hostname: "host3")
        let finalAddress4 = try await allocator.lookup(hostname: "host4")

        #expect(finalAddress1 == address1)
        #expect(finalAddress3 == address3)
        #expect(finalAddress4 == newAddress)
    }

    @Test func testMultipleDeallocationsOfSameHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address = try await allocator.allocate(hostname: "test-host")

        let firstDeallocate = try await allocator.deallocate(hostname: "test-host")
        #expect(firstDeallocate == address)

        // Second deallocation should return nil since it's already deallocated
        let secondDeallocate = try await allocator.deallocate(hostname: "test-host")
        #expect(secondDeallocate == nil)
    }

    @Test func testLookupIgnoresCase() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "Foo.Test.")

        #expect(try await allocator.lookup(hostname: "foo.test.") == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "FOO.TEST.") == allocatedAddress)
    }

    @Test func testLookupIgnoresTrailingDot() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "foo.test")

        #expect(try await allocator.lookup(hostname: "foo.test.") == allocatedAddress)
    }

    @Test func testAllocateSameHostnameDifferentCaseReusesAddress() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address1 = try await allocator.allocate(hostname: "foo.test.")
        let address2 = try await allocator.allocate(hostname: "FOO.test.")

        #expect(address1 == address2)
    }

    @Test func testDeallocateIgnoresCase() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "Foo.Test.")
        let deallocatedAddress = try await allocator.deallocate(hostname: "foo.test.")

        #expect(deallocatedAddress == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "foo.test.") == nil)
    }

    // MARK: - Aliases

    private func rules(_ strings: String...) throws -> [DNSMatchRule] {
        try strings.map { try DNSMatchRule($0) }
    }

    @Test func testMatchResolvesHostnameAndAliasesToTheSameAddress() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let index = try await allocator.allocate(hostname: "gw.test.", aliases: rules("api.test", ".gw.test"))

        #expect(try await allocator.match(name: "gw.test.") == AttachmentAllocator.Match(index: index, hostname: "gw.test", kind: .hostname))
        #expect(try await allocator.match(name: "api.test.") == AttachmentAllocator.Match(index: index, hostname: "gw.test", kind: .alias))
        #expect(try await allocator.match(name: "web.gw.test.") == AttachmentAllocator.Match(index: index, hostname: "gw.test", kind: .subtree(baseLabelCount: 2)))
        #expect(try await allocator.match(name: "a.b.gw.test.") == AttachmentAllocator.Match(index: index, hostname: "gw.test", kind: .subtree(baseLabelCount: 2)))
    }

    @Test func testMatchIgnoresCaseAndTrailingDot() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let index = try await allocator.allocate(hostname: "gw.test.", aliases: rules("API.test", ".GW.test"))

        #expect(try await allocator.match(name: "Api.Test")?.index == index)
        #expect(try await allocator.match(name: "WEB.gw.test.")?.index == index)
    }

    @Test func testSubtreeDoesNotMatchItsBaseOrUnrelatedNames() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        try await allocator.allocate(hostname: "host.test.", aliases: rules(".example.test"))

        #expect(try await allocator.match(name: "example.test.") == nil)
        #expect(try await allocator.match(name: "evilexample.test.") == nil)
        #expect(try await allocator.match(name: "web.example.com.") == nil)
        #expect(try await allocator.match(name: "test.") == nil)
        #expect(try await allocator.match(name: "") == nil)
    }

    @Test func testHostnameBeatsAliasAndAliasBeatsSubtree() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let gateway = try await allocator.allocate(hostname: "gw.test.", aliases: rules(".gw.test"))
        let other = try await allocator.allocate(hostname: "other.test.", aliases: rules("web.gw.test"))
        let api = try await allocator.allocate(hostname: "api.gw.test.")

        #expect(try await allocator.match(name: "api.gw.test.")?.index == api)
        #expect(try await allocator.match(name: "api.gw.test.")?.kind == .hostname)
        #expect(try await allocator.match(name: "web.gw.test.")?.index == other)
        #expect(try await allocator.match(name: "web.gw.test.")?.kind == .alias)
        #expect(try await allocator.match(name: "x.gw.test.")?.index == gateway)
        #expect(try await allocator.match(name: "x.gw.test.")?.kind == .subtree(baseLabelCount: 2))
    }

    @Test func testLongestSubtreeWins() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let outer = try await allocator.allocate(hostname: "example.test.", aliases: rules(".example.test"))
        let inner = try await allocator.allocate(hostname: "sub.example.test.", aliases: rules(".sub.example.test"))

        #expect(try await allocator.match(name: "a.sub.example.test.") == AttachmentAllocator.Match(index: inner, hostname: "sub.example.test", kind: .subtree(baseLabelCount: 3)))
        #expect(try await allocator.match(name: "a.b.sub.example.test.")?.index == inner)
        #expect(try await allocator.match(name: "a.example.test.") == AttachmentAllocator.Match(index: outer, hostname: "example.test", kind: .subtree(baseLabelCount: 2)))
        // The inner base is a hostname, so it resolves as one and not as part of the outer subtree.
        #expect(try await allocator.match(name: "sub.example.test.")?.kind == .hostname)
    }

    @Test func testLookupDoesNotConsiderAliases() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        try await allocator.allocate(hostname: "gw.test.", aliases: rules("api.test", ".gw.test"))

        #expect(try await allocator.lookup(hostname: "api.test.") == nil)
        #expect(try await allocator.lookup(hostname: "web.gw.test.") == nil)
    }

    @Test func testAnExactAliasIsSharedAndResolvesToEveryHolder() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        let web1 = try await allocator.allocate(hostname: "web-1", aliases: rules("web"))
        let web2 = try await allocator.allocate(hostname: "web-2", aliases: rules("web"))
        #expect(web1 != web2)

        // As Docker's DNS answers a shared alias: every holder, first registered first.
        #expect(try await allocator.matches(name: "web.").map(\.index) == [web1, web2])
        #expect(try await allocator.match(name: "web")?.hostname == "web-1")

        // A holder that goes leaves the others answering.
        try await allocator.deallocate(hostname: "web-1")
        #expect(try await allocator.matches(name: "web").map(\.hostname) == ["web-2"])
        try await allocator.deallocate(hostname: "web-2")
        #expect(try await allocator.matches(name: "web").isEmpty)
    }

    @Test func testSubtreeAlreadyUsedByAnotherHostIsRejected() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        try await allocator.allocate(hostname: "one.test.", aliases: rules(".gw.test"))

        await #expect(throws: (any Error).self) {
            try await allocator.allocate(hostname: "two.test.", aliases: rules(".gw.test"))
        }
        #expect(try await allocator.lookup(hostname: "two.test.") == nil)
    }

    @Test func testAnAliasMayBeAnotherHostsHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        let one = try await allocator.allocate(hostname: "one.test.")
        let two = try await allocator.allocate(hostname: "two.test.", aliases: rules("one.test"))

        // The hostname answers first, then the host holding it as an alias.
        #expect(try await allocator.matches(name: "one.test.").map(\.index) == [one, two])
        // An alias repeating the host's own hostname adds nothing.
        let three = try await allocator.allocate(hostname: "three.test.", aliases: rules("three.test"))
        #expect(try await allocator.matches(name: "three.test.").map(\.index) == [three])
    }

    @Test func testAHostnameMayBeAnotherHostsAlias() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        let one = try await allocator.allocate(hostname: "one.test.", aliases: rules("api.test"))
        let api = try await allocator.allocate(hostname: "api.test.")

        #expect(try await allocator.match(name: "api.test.")?.hostname == "api.test")
        #expect(try await allocator.matches(name: "api.test.").map(\.index) == [api, one])
    }

    @Test func testAllocatingAgainWithTheSameAliasesIsIdempotent() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let index1 = try await allocator.allocate(hostname: "gw.test.", aliases: rules("api.test", ".gw.test"))
        let index2 = try await allocator.allocate(hostname: "gw.test.", aliases: rules("api.test", ".gw.test"))
        #expect(index1 == index2)

        // Each allocation is a holder, and the names stay until the last one lets go.
        try await allocator.deallocate(hostname: "gw.test.")
        #expect(try await allocator.match(name: "api.test.")?.index == index1)
        try await allocator.deallocate(hostname: "gw.test.")
        #expect(try await allocator.match(name: "api.test.") == nil)
        #expect(try await allocator.match(name: "web.gw.test.") == nil)
    }

    @Test func testAllocatingAgainAddsNewAliases() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let index = try await allocator.allocate(hostname: "gw.test.", aliases: rules("one.test"))
        _ = try await allocator.allocate(hostname: "gw.test.", aliases: rules("one.test", "two.test"))

        #expect(try await allocator.match(name: "one.test.")?.index == index)
        #expect(try await allocator.match(name: "two.test.")?.index == index)
    }

    @Test func testDeallocateRemovesAliasesAndFreesThemForReuse() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        try await allocator.allocate(hostname: "one.test.", aliases: rules("api.test", ".one.test"))

        try await allocator.deallocate(hostname: "one.test.")

        #expect(try await allocator.match(name: "api.test.") == nil)
        #expect(try await allocator.match(name: "web.one.test.") == nil)

        let index = try await allocator.allocate(hostname: "two.test.", aliases: rules("api.test", ".one.test"))
        #expect(try await allocator.match(name: "api.test.")?.index == index)
        #expect(try await allocator.match(name: "web.one.test.")?.index == index)
    }

    @Test func testFailedAllocationDoesNotRegisterAliases() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 1)
        let first = try await allocator.allocate(hostname: "one.test.", aliases: rules("one-alias.test"))

        await #expect(throws: (any Error).self) {
            try await allocator.allocate(hostname: "two.test.", aliases: rules("two-alias.test"))
        }

        #expect(try await allocator.match(name: "two-alias.test.") == nil)
        #expect(try await allocator.match(name: "one-alias.test.")?.index == first)
    }

    @Test func testAddressIsKeptUntilItsLastHolderLetsGo() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        // The engine holds the address from create; the runtime holds it while it runs.
        let reserved = try await allocator.allocate(hostname: "web")
        let running = try await allocator.allocate(hostname: "web")
        #expect(reserved == running)

        // The container stops: its runtime lets go, the address stays where it was.
        #expect(try await allocator.deallocate(hostname: "web") == nil)
        #expect(try await allocator.lookup(hostname: "web") == reserved)
        #expect(await allocator.allocations() == ["web": reserved])

        // It starts again and gets the same address, then is deleted while stopped.
        #expect(try await allocator.allocate(hostname: "web") == reserved)
        #expect(try await allocator.deallocate(hostname: "web") == nil)
        #expect(try await allocator.deallocate(hostname: "web") == reserved)
        #expect(try await allocator.lookup(hostname: "web") == nil)
        #expect(try await allocator.deallocate(hostname: "web") == nil)
    }

    @Test func testAFreedAddressIsNotHandedOutWhileAnotherHostnameHoldsIts() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 2)
        let first = try await allocator.allocate(hostname: "a")
        let second = try await allocator.allocate(hostname: "b")
        #expect(first != second)
        // The pool is spent: a third container is refused instead of sharing an address.
        await #expect(throws: (any Error).self) { try await allocator.allocate(hostname: "c") }
        // Deleting one frees exactly its address for the next.
        #expect(try await allocator.deallocate(hostname: "a") == first)
        #expect(try await allocator.allocate(hostname: "c") == first)
        #expect(try await allocator.lookup(hostname: "b") == second)
    }
}
