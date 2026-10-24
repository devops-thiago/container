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

The host library is pinned to containerization commit `965d42ea5951cb9b7d219736b375291cad5fbac7`; the guest image is `ghcr.io/devops-thiago/containerization/vminit@sha256:8e68048d28032fab40263002759fba4f854a69de88d7b44c5a3c3da04c7c163a`. The image was built by the fork's `SiliconShip guest backport` workflow, run `40012308726`. Anonymous pull and the manifest digest were verified with the engine before validation.
