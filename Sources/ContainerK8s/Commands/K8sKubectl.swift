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
import ContainerizationError
import Foundation

/// `container k8s kubectl …`: the kubectl that ships beside this plugin, run against the
/// kubeconfig the plugin maintains, so a cluster made here can be driven without installing
/// kubectl or writing a config by hand.
///
/// The process is replaced rather than spawned: kubectl gets the terminal, the signals and
/// the exit status directly, which is what `kubectl exec -it` and `kubectl logs -f` need.
public struct K8sKubectl: ParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "kubectl",
        abstract: "Run the bundled kubectl against a cluster made here",
        discussion: """
            Everything after `kubectl` goes to kubectl unchanged. The bundled kubectl matches
            the Kubernetes version of the node image, and reads the kubeconfig this plugin
            keeps unless KUBECONFIG is set.

            EXAMPLES:
              $ container k8s kubectl get nodes
              $ container k8s kubectl --name my-cluster get pods -A
              $ container k8s kubectl version --client
            """
    )

    @Option(name: .long, help: "Use this cluster's context instead of the current one")
    var name: String?

    @Argument(parsing: .captureForPassthrough, help: "Arguments for kubectl")
    var arguments: [String] = []

    /// What gets exec'd, apart from the exec itself.
    struct Invocation: Equatable {
        let executable: String
        let argv: [String]
        /// Environment entries added or replaced; the rest of the environment is inherited.
        let environment: [String: String]
    }

    /// Where the bundled kubectl lives: beside this plugin's own executable.
    static func bundledKubectl(besides executable: String) -> String {
        URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("kubectl").path
    }

    static func invocation(
        kubectl: String,
        kubeconfig: String,
        inheritedKubeconfig: String?,
        context: String?,
        arguments: [String]
    ) -> Invocation {
        var argv = [kubectl]
        if let context { argv += ["--context", context] }
        argv += arguments
        // The user's own KUBECONFIG wins, as it would for any kubectl; the plugin's file is
        // the default only.
        let environment = (inheritedKubeconfig?.isEmpty == false) ? [:] : ["KUBECONFIG": kubeconfig]
        return Invocation(executable: kubectl, argv: argv, environment: environment)
    }

    public func run() throws {
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let resolved = Self.resolvedExecutable(Self.bundledKubectl(besides: executable))
        guard FileManager.default.isExecutableFile(atPath: resolved) else {
            throw ContainerizationError(.notFound, message: "no bundled kubectl at \(resolved)")
        }
        let invocation = Self.invocation(
            kubectl: resolved,
            kubeconfig: K8sHelper.resolveKubeconfigMergePath().string,
            inheritedKubeconfig: ProcessInfo.processInfo.environment["KUBECONFIG"],
            context: name,
            arguments: arguments)
        for (key, value) in invocation.environment {
            setenv(key, value, 1)
        }
        try Self.exec(invocation)
    }

    /// The plugin is exec'd by the CLI with its real path, but `/proc`-less macOS gives no
    /// better answer than argv[0]; resolve symlinks so a wrapper still finds the sibling.
    private static func resolvedExecutable(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func exec(_ invocation: Invocation) throws {
        let argv: [UnsafeMutablePointer<CChar>?] = invocation.argv.map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        execv(invocation.executable, argv)
        // Only reached when the exec failed.
        throw ContainerizationError(
            .internalError,
            message: "could not run \(invocation.executable): \(String(cString: strerror(errno)))")
    }
}
