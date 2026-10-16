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
import NIOCore

/// `GET /containers/{id}/export`, which `docker export` saves.
extension ContainerToolRoutes.Routes {
    /// What is read from the staged archive and written at a time.
    static var exportChunkSize: Int { 1 << 20 }

    /// The container's filesystem as a tar, in any state dockerd exports one.
    ///
    /// The engine writes the archive into a directory of its own in the scratch directory,
    /// which is streamed to the client and removed however the response ends, as the archive
    /// GET's copy is. Nothing is sent before the engine has finished, so a failed export is
    /// an error status, not a truncated tar.
    func export(_ reference: String) async throws -> DockerResponse {
        let container = try await find(reference)
        let scratch = try makeScratch()
        let handle: FileHandle
        do {
            let archive = scratch.appending(path: "export.tar")
            do {
                try await engine.export(container.snapshot, to: archive)
            } catch let error as DockerAPIError {
                throw error
            } catch {
                throw DockerAPIError.internalError("could not export container \(reference): \(DockerContainerProcesses.message(error))")
            }
            handle = try FileHandle(forReadingFrom: archive)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
        return .stream(status: .ok, contentType: "application/x-tar") { output in
            defer {
                try? handle.close()
                try? FileManager.default.removeItem(at: scratch)
            }
            while let chunk = try handle.read(upToCount: Self.exportChunkSize), !chunk.isEmpty {
                try await output.write(ByteBuffer(bytes: chunk))
            }
        }
    }
}
