# Docker → container migration

Complete command mapping. Verified against `container --help` and each group's `--help`.
When a flag matters, confirm with `container <command> --help` rather than assuming Docker's
spelling.

## Containers

| Docker | container | Notes |
|---|---|---|
| `docker run` | `container run` | |
| `docker create` | `container create` | |
| `docker start` | `container start` | |
| `docker stop` | `container stop` | |
| `docker kill` | `container kill` | |
| `docker rm` | `container delete` / `rm` | |
| `docker exec` | `container exec` | |
| `docker logs` | `container logs` | |
| `docker cp` | `container copy` / `cp` | `container:path` on either side |
| `docker export` | `container export` | |
| `docker inspect` | `container inspect` | also the way to find a container's IP |
| `docker stats` | `container stats` | |
| `docker ps` | `container list` / `ls` | add `-a` for stopped containers |
| `docker container prune` | `container prune` | |
| `docker restart` | — | `container stop <id> && container start <id>` |
| `docker attach` | — | use `container exec -it <id> sh` |
| `docker top` | — | `container exec <id> ps aux` |
| `docker port` | — | `container inspect <id>` |
| `docker commit` | — | build an image from a Dockerfile instead |
| `docker rename`, `pause`, `unpause`, `wait`, `diff`, `update` | — | no equivalent |

The SiliconShip 1.3.0 engine accepts `--restart no|always|unless-stopped|on-failure[:N]`
and stores the policy for `inspect`. The app applies `always` and `unless-stopped` when it
starts the engine; the standalone engine does not yet supervise policies. Process-exit
restarts arrive with the engine supervisor planned for 1.5.0. See the roadmap below.

The 1.3.0 fork also accepts `--hostname`, `--sysctl key=value`, `--add-host name:address`
(including `host-gateway`), and `--pull always|missing|never`. A host service reached through
`host-gateway` must listen on an address accessible from the guest, not only host loopback.

## Images

| Docker | container |
|---|---|
| `docker build` | `container build` |
| `docker images` | `container image list` / `ls` |
| `docker pull` | `container image pull` |
| `docker push` | `container image push` |
| `docker rmi` | `container image delete` / `rm` |
| `docker tag` | `container image tag` |
| `docker save` | `container image save` |
| `docker load` | `container image load` |
| `docker image inspect` | `container image inspect` |
| `docker image prune` | `container image prune` |
| `docker history` | — no equivalent |

`container image` has the alias `i`.

### Build notes

`container build` covers the BuildKit features people reach for most: `--platform`,
`--target`, `--build-arg`, `--secret`, `--no-cache`, `-f`, and `-o/--output` with
`type=oci|tar|local`.

Two differences worth knowing:

- `-t` is effectively required. The default tag is a freshly generated UUID, so a build
  without `-t` produces an image you then have to hunt for in `container image ls`.
- Builds execute in a builder container managed by `container builder`. It starts on demand,
  but when a build fails for no clear reason, check `container builder status`. Give it more
  room with `container builder start --cpus 8 --memory 16g`.

## Registries, volumes, networks

| Docker | container |
|---|---|
| `docker login` / `logout` | `container registry login` / `logout` |
| — | `container registry list` — shows current logins |
| `docker volume create` / `ls` / `rm` / `inspect` / `prune` | `container volume create` / `list` / `delete` / `inspect` / `prune` |
| `docker network create` / `ls` / `rm` / `inspect` / `prune` | `container network create` / `list` / `delete` / `inspect` / `prune` |
| `docker network connect` / `disconnect` | — set `--network` when you run the container |

## System

| Docker | container |
|---|---|
| `docker info` | `container system status` |
| `docker version` | `container system version` |
| `docker system df` | `container system df` |
| daemon logs | `container system logs` |
| `docker events` | — no equivalent |

`docker system prune` has no single equivalent. Run the four prunes:

```bash
container prune                 # stopped containers
container image prune
container volume prune
container network prune
```

## Replacing a compose file

There is no `container compose` in SiliconShip 1.3.0. A small stack can be translated into
explicit `container run` commands, but that script does not implement Compose semantics.
The [migration roadmap](https://github.com/devops-thiago/SiliconShip/issues/235) separates
what ships now from planned work:

| Release | Planned capability |
|---|---|
| 1.3.0 | Migration report, run-command paste, image archives, and the flags described above |
| 1.4.0 | Native `container compose` commands and in-app Compose startup with dependency health gates |
| 1.5.0 | Engine restart supervision, live health, dynamic guest name resolution, and single-file bind mounts |
| 1.6.0 | Engine API compatibility for the user's Docker CLI, Docker Compose, Testcontainers and IDE integrations |

Those later capabilities are plans, not commands available in the 1.3.0 binary. The user
migration guide is at [siliconship.app/docker](https://siliconship.app/docker).

On the `default` network, peer names are captured when the consuming container starts.
Start dependencies first and wait for readiness before starting their consumers. If a peer
restarts with a different address, recreate or restart its consumers after that peer is ready;
existing guests do not receive a live name-to-address update. This limitation is tracked in
[SiliconShip#188](https://github.com/devops-thiago/SiliconShip/issues/188).

**Do not reach for `container network create` here.** Name lookup between containers works on
the `default` network with a domain-qualified name. It does *not* work for containers on a
custom network — that gap is tracked as
[apple/container#1809](https://github.com/apple/container/issues/1809). A custom network is
for *isolating* containers; if you use one, wire the containers together by IP from
`container inspect <name>`, not by name.

Set up name resolution once (all three steps — see SKILL.md):

```bash
# [dns] domain = "test" in ~/.config/container/config.toml
container system stop && container system start
sudo container system dns create test
```

Then translate the file. This compose file:

```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: secret
  web:
    image: my-app:latest
    ports: ["8080:80"]
    environment:
      DATABASE_URL: postgres://postgres:secret@db:5432/postgres
    depends_on: [db]
```

becomes:

```bash
#!/bin/bash
set -euo pipefail

# no --network flag: both containers land on `default`, where name lookup works
container run -d --name db \
  -e POSTGRES_PASSWORD=secret \
  postgres:16

# depends_on becomes an explicit readiness check
until container exec db pg_isready -q; do sleep 1; done

# db.test, not db — the name must be domain-qualified
container run -d --name web -p 8080:80 \
  -e DATABASE_URL=postgres://postgres:secret@db.test:5432/postgres \
  my-app:latest
```

Teardown:

```bash
container stop web db
container delete web db
```

Mapping notes:

- `depends_on` has no declarative form here. Compose can wait for health with
  `condition: service_healthy`; a hand-written script needs its own readiness checks and
  teardown/error handling to approximate that behavior.
- The example references the dependency as `<name>.<domain>` (`db.test`). The fork also
  installs bare peer hostnames for peers already running on the network at consumer startup.
  Neither spelling makes those entries dynamic; dependency order and restart handling still matter.
- `ports:` → `-p`. Often unnecessary between containers, since each container has its own IP
  and is reachable without publishing. You need `-p` to reach a service from a host browser or
  a macOS-native tool.
- `volumes:` → `-v` for bind mounts, or `container volume create` plus `-v <name>:<path>`.
- `build:` → a `container build -t <name> .` line before the `run`.
- `restart:` can be carried as `--restart`, but 1.3.0 only persists it and applies the app's
  engine-start pass. It is not Compose's exit-driven supervision. Keep recovery explicit in
  scripts until the planned 1.5.0 engine supervisor is available.

## Features with no Docker counterpart

- `container machine` — a full Linux environment with your home directory mapped in. See
  `container-machines.md`.
- `container run --publish-socket <host_path:container_path>` — publish a Unix socket to the
  host rather than a TCP port.
- `container run --ssh` — forward your SSH agent socket into the container.
- `container run --virtualization` — expose virtualization to the container for nested use.
- `container run --rosetta` — run x86-64 binaries on Apple silicon.
- `container system kernel` — manage the kernel containers boot with.
