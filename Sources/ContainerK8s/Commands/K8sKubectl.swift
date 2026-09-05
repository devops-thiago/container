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
import ContainerAPIClient
import ContainerizationError
import Foundation

/// `container k8s kubectl …`: the kubectl that ships beside this plugin, run against the
/// kubeconfig the plugin maintains, so a cluster made here can be driven without installing
/// kubectl or writing a config by hand.
///
/// The process is replaced rather than spawned: kubectl gets the terminal, the signals and
/// the exit status directly, which is what `kubectl exec -it` and `kubectl logs -f` need.
public struct K8sKubectl: AsyncParsableCommand {
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

    /// The host files a kubectl command line reads or writes: manifests after `-f`, `--filename`,
    /// `-k` and `--kustomize`, a `--kubeconfig`, and the local side of `cp`. Standard input and
    /// URLs are not files. The remote side of `cp` is `[namespace/]pod:path`, told apart from a
    /// local path by the colon before any slash.
    static func fileReferences(in arguments: [String]) -> [String] {
        var files: [String] = []
        let fileFlags: Set<String> = ["-f", "--filename", "-k", "--kustomize", "--kubeconfig"]
        // Flags whose value is not a file and not a positional either, so `-n kube-system` does
        // not read as a path to copy. The common ones; an unknown flag's value is taken as a
        // positional, which for `cp` only matters once two real ones are missing.
        let valueFlags: Set<String> = [
            "-n", "--namespace", "-c", "--container", "--context", "--cluster", "--user", "--retries",
            "-s", "--server", "--request-timeout", "--token", "--as", "--as-group", "-o", "--output",
            "-l", "--selector", "--field-selector", "--timeout", "--cache-dir",
        ]
        var index = 0
        var subcommand: String?
        var positionals: [String] = []
        while index < arguments.count {
            let argument = arguments[index]
            if fileFlags.contains(argument), index + 1 < arguments.count {
                files.append(arguments[index + 1])
                index += 2
                continue
            }
            if valueFlags.contains(argument), index + 1 < arguments.count {
                index += 2
                continue
            }
            if let equals = argument.firstIndex(of: "="), fileFlags.contains(String(argument[..<equals])) {
                files.append(String(argument[argument.index(after: equals)...]))
                index += 1
                continue
            }
            if argument == "--" { break }
            if !argument.hasPrefix("-") {
                if subcommand == nil {
                    subcommand = argument
                } else {
                    positionals.append(argument)
                }
            }
            index += 1
        }
        if subcommand == "cp" {
            // kubectl cp takes exactly a source and a destination.
            files += positionals.prefix(2).filter { !isRemoteCopyPath($0) }
        }
        return files.filter { $0 != "-" && !$0.contains("://") }
    }

    /// `pod:/path` or `namespace/pod:/path`: a colon that comes before any slash.
    static func isRemoteCopyPath(_ argument: String) -> Bool {
        guard let colon = argument.firstIndex(of: ":") else { return false }
        let head = argument[..<colon]
        return head.filter { $0 == "/" }.count <= 1 && !head.hasPrefix("/") && !head.hasPrefix(".")
    }

    /// Borrow the folders kubectl will touch, and start it where the user is.
    ///
    /// kubectl is exec'd into this process, which is sandboxed alongside the CLI: it reads a
    /// manifest or copies a file with this process's access and from this process's working
    /// directory, and sandboxed that directory is a container of its own. The shell's `PWD` is
    /// where the user ran the command; a relative path means that folder, so it is borrowed and
    /// made the working directory before the exec. Nothing is borrowed for a command line that
    /// names no file.
    static func prepareHostAccess(arguments: [String], environment: [String: String]) async throws {
        let files = fileReferences(in: arguments)
        guard !files.isEmpty, ClientHostDirectory.isSandboxed else { return }
        let relative = files.filter { !$0.hasPrefix("/") }
        if !relative.isEmpty, let pwd = environment["PWD"], pwd.hasPrefix("/") {
            try await ClientHostDirectory.borrow([pwd], verb: "read")
            guard FileManager.default.changeCurrentDirectoryPath(pwd) else {
                throw ContainerizationError(.invalidArgument, message: "cannot enter \(pwd) for kubectl")
            }
        }
        try await ClientHostDirectory.borrow(files.filter { $0.hasPrefix("/") }, verb: "read")
    }

    public func run() async throws {
        try await Self.prepareHostAccess(arguments: arguments, environment: ProcessInfo.processInfo.environment)
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
