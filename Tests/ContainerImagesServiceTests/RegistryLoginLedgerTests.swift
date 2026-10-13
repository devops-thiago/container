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

import ContainerizationError
import Foundation
import Testing

@testable import ContainerImagesService

/// A login keeps its credential only while it is the newest sign-in or sign-out for its host
/// and within its deadline; the registry check itself ends at the deadline.
struct RegistryLoginLedgerTests {
    let start = ContinuousClock.now

    @Test("a login with nothing after it keeps its credential")
    func soleLoginKeeps() {
        var ledger = RegistryLoginLedger()
        let ticket = ledger.begin("ghcr.io", at: start)
        #expect(ledger.mayKeep(ticket, at: start + .seconds(5)))
    }

    @Test("a sign-out that began during the check leaves the login nothing to keep")
    func signOutSupersedes() {
        var ledger = RegistryLoginLedger()
        let login = ledger.begin("ghcr.io", at: start)
        _ = ledger.begin("ghcr.io", at: start + .seconds(1))
        #expect(!ledger.mayKeep(login, at: start + .seconds(2)))
    }

    @Test("of two sign-ins for one host, only the newer keeps")
    func newerSignInWins() {
        var ledger = RegistryLoginLedger()
        let first = ledger.begin("ghcr.io", at: start)
        let second = ledger.begin("ghcr.io", at: start + .seconds(1))
        #expect(!ledger.mayKeep(first, at: start + .seconds(3)))
        #expect(ledger.mayKeep(second, at: start + .seconds(3)))
    }

    @Test("other hosts do not supersede a login")
    func otherHostsAreIndependent() {
        var ledger = RegistryLoginLedger()
        let login = ledger.begin("ghcr.io", at: start)
        _ = ledger.begin("docker.io", at: start)
        #expect(ledger.mayKeep(login, at: start))
    }

    @Test("an answer that comes after the deadline keeps nothing")
    func lateAnswerKeepsNothing() {
        var ledger = RegistryLoginLedger()
        let login = ledger.begin("ghcr.io", at: start)
        #expect(ledger.mayKeep(login, at: start + .seconds(60), deadline: .seconds(60)))
        #expect(!ledger.mayKeep(login, at: start + .seconds(61), deadline: .seconds(60)))
    }

    @Test("the engine's deadline ends before the client stops waiting")
    func deadlineIsShorterThanTheClientWait() {
        // ClientImage.login waits 90 seconds for the answer.
        #expect(RegistryLoginLedger.deadline < .seconds(90))
    }

    @Test("a check that outlasts its deadline is cancelled and reported as a timeout")
    func stalledCheckTimesOut() async throws {
        let cancelled = Flag()
        let clock = ContinuousClock()
        let began = clock.now
        do {
            _ = try await RegistryLoginLedger.checking("stalled.example", within: .milliseconds(100)) {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await cancelled.set()
                    throw error
                }
                return true
            }
            Issue.record("a stalled check returned")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.timeout))
            #expect(error.message.contains("stalled.example"))
        }
        #expect(await cancelled.value, "the stalled check was left running")
        #expect(clock.now - began < .seconds(10))
    }

    @Test("a check that answers in time returns its answer")
    func promptCheckReturns() async throws {
        let answer = try await RegistryLoginLedger.checking("ghcr.io", within: .seconds(5)) { 7 }
        #expect(answer == 7)
    }

    @Test("a check's own error is passed on unchanged")
    func checkErrorsPassThrough() async {
        do {
            _ = try await RegistryLoginLedger.checking("ghcr.io", within: .seconds(5)) { () async throws -> Int in
                throw ContainerizationError(.invalidArgument, message: "401")
            }
            Issue.record("a failed check returned")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.invalidArgument))
            #expect(error.message == "401")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}

private actor Flag {
    private(set) var value = false
    func set() { value = true }
}
