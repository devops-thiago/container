# Updating the guest agent for safe file copies

New containers use the guest agent shipped with this engine. Existing containers retain their guest filesystem, including any customizations. A copy that requires the new owned-file or checked-archive operation fails before writing when the installed guest does not support it. The engine does not retry the unsafe archive operation.

Docker uploads with `noOverwriteDirNonDir` pass that policy to the guest for running containers, queued prestart copies, and uploads that race with Start. The guest checks each archive entry as it writes; a host-side preflight alone cannot protect nested entries or prevent a destination changing between the check and the copy.

Native file copies refuse a same-named directory and follow a confined final file symlink. Explicit archive uploads keep their existing archive semantics: when no type-protection policy was requested, archive entries may replace a directory or a symlink. The engine carries that distinction through both running and queued uploads instead of silently changing the Docker archive API's behavior.

To update an existing container, stop it and run:

```sh
container stop my-container
container system upgrade-guest my-container
container start my-container
```

The command replaces the container's guest-agent filesystem with the engine's pinned image. It preserves the workload filesystem, container configuration and container identity. Guest filesystem customizations will no longer be used; do not run the command if those customizations are needed. Other containers are unaffected.

The engine rejects a running or bootstrapped container, and rechecks its identity and stopped state after downloading the image. A failed download or staging operation leaves the installed guest unchanged. No upgrade happens automatically on Start or after a failed copy.

The host library is pinned to containerization commit `cd99535bdfa1f59b2f8ffcca07c87546c3691c20`, branch `siliconship/1.6.1` of the fork: upstream 0.53.0 plus the owned-file and checked-archive copy patch. The guest image was built from that same commit. The guest image is `ghcr.io/devops-thiago/containerization/vminit@sha256:e16716fa750a1eff25079bdf8537a173bf915841ab123bf45fa3f62a74708e48`, also tagged `sha-cd99535bdfa1f59b2f8ffcca07c87546c3691c20`. The image was built by the fork's `SiliconShip guest backport` workflow, run `40993565027`. An anonymous pull of the manifest by tag and by digest returned that digest, and the manifest's own SHA-256 matches it.
