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

/// The image verbs spelled at the root: `container pull alpine` beside `container image pull
/// alpine`. Each is the existing command behind another name: its flags, its help text and
/// its run, through an option group. They stay out of the root's help, which lists `image`.
extension Application {
    static let imageRootSpellings: [any ParsableCommand.Type] = [
        Images.self, Pull.self, Push.self, Tag.self, RemoveImage.self, Save.self, Load.self,
    ]

    public struct Images: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "images", abstract: "List images (the same as image list)", shouldDisplay: false)
        @OptionGroup var command: ImageList
        public var logOptions: Flags.Logging { command.logOptions }
        public mutating func run() async throws { try await command.run() }
    }

    public struct Pull: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "pull", abstract: "Pull an image (the same as image pull)", shouldDisplay: false)
        @OptionGroup var command: ImagePull
        public var logOptions: Flags.Logging { command.logOptions }
        public func run() async throws { try await command.run() }
    }

    public struct Push: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "push", abstract: "Push an image (the same as image push)", shouldDisplay: false)
        @OptionGroup var command: ImagePush
        public var logOptions: Flags.Logging { command.logOptions }
        public func run() async throws { try await command.run() }
    }

    public struct Tag: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "tag", abstract: "Tag an image (the same as image tag)", shouldDisplay: false)
        @OptionGroup var command: ImageTag
        public var logOptions: Flags.Logging { command.logOptions }
        public func run() async throws { try await command.run() }
    }

    public struct RemoveImage: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "rmi", abstract: "Delete images (the same as image delete)", shouldDisplay: false)
        @OptionGroup var command: ImageDelete
        public var logOptions: Flags.Logging { command.logOptions }
        public mutating func run() async throws { try await command.run() }
    }

    public struct Save: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "save", abstract: "Save images to an archive (the same as image save)", shouldDisplay: false)
        @OptionGroup var command: ImageSave
        public var logOptions: Flags.Logging { command.logOptions }
        public func run() async throws { try await command.run() }
    }

    public struct Load: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "load", abstract: "Load images from an archive (the same as image load)", shouldDisplay: false)
        @OptionGroup var command: ImageLoad
        public var logOptions: Flags.Logging { command.logOptions }
        public func run() async throws { try await command.run() }
    }
}
