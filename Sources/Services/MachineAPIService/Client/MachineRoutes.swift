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

public enum MachineRoutes: String {
    /// Create a container machine.
    case createMachine
    /// Delete a container machine.
    case deleteMachine
    /// List container machines.
    case listMachine
    /// Get the default container machine.
    case getDefault
    /// Set the default container machine.
    case setDefault
    /// Boot a container machine.
    case bootMachine
    /// Boot once and identify the request responsible for account setup.
    case bootMachineForSetup
    /// Publish successful account setup for the same VM and owning request.
    case completeMachineSetup
    /// Roll back only the VM still owned by a failed setup request.
    case stopMachineSetup
    /// Stop a container machine.
    case stopMachine
    /// Inspect a container machine.
    case inspectMachine
    /// Set boot-time config for a container machine.
    case setConfig
    /// Fetch logs of a container machine.
    case logsMachine
}
