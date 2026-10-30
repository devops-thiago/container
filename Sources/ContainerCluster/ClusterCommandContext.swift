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

/// The CLI invocation belongs to one parse/run task. Embedded callers keep their own
/// default, and concurrent parsers do not change a process-wide setting.
public enum ClusterCommandContext {
    @TaskLocal public static var invokedAs: String = "cluster"

    public static var defaultName: String {
        invokedAs == "k8s" ? "k8s-dev" : ClusterHelper.defaultName
    }
}
