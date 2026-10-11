# Docker → container migration

Complete command mapping. Verified against `container --help` and each group's `--help`.
When a flag matters, confirm with `container <command> --help` rather than assuming Docker's
spelling.

The SiliconShip 1.4.0 engine also takes the Docker spelling wherever the tables below show
an equivalent: `ps`, `container <verb>`, `restart`, `logs --tail`, `images`, `pull`, `push`,
`tag`, `rmi`, `save`, `load`, `image ls NAME`, `version`, `info`, `-f` on every prune and
`system prune`. With `alias docker=container`, those command lines run as typed; the
`container` column stays the primary spelling in `--help`.

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
| `docker ps` | `container list` / `ls` / `ps` | add `-a` for stopped containers |
| `docker container prune` | `container prune` | `-f` is accepted and changes nothing: it never asks |
| `docker container <verb>` | `container <verb>` | the noun is accepted too: `container container ls` |
| `docker restart` | `container restart` | stop, then start; `-t` and `-s` as on `stop` |
| `docker logs --tail N` | `container logs -n N` / `--tail N` | |
| `docker attach` | — | use `container exec -it <id> sh` |
| `docker top` | — | `container exec <id> ps aux` |
| `docker port` | — | `container inspect <id>` |
| `docker commit` | — | build an image from a Dockerfile instead |
| `docker rename`, `pause`, `unpause`, `wait`, `diff`, `update` | — | no equivalent |

`--restart no|always|unless-stopped|on-failure[:N]` behaves as Docker's: the engine starts an
exited container again, with Docker's growing delay, and starts `always` and `unless-stopped`
containers when it starts. `container ls` shows a container waiting to be restarted as
`restarting`, with a `RESTARTS` column; `inspect` has `restartCount`.

Health checks behave as Docker's: the image's `HEALTHCHECK` runs without any flag,
`--health-cmd`, `--health-interval`, `--health-timeout`, `--health-retries`,
`--health-start-period` and `--health-start-interval` adjust it, and `--no-healthcheck` turns it
off. `container ls` has a `HEALTH` column (`starting`, `healthy`, `unhealthy`, or `none`), and
`inspect` has `status.health` with `failingStreak` and the last results, where `docker inspect`
has `State.Health`.

The 1.3.0 fork also accepts `--hostname`, `--sysctl key=value`, `--add-host name:address`
(including `host-gateway`), and `--pull always|missing|never`. A host service reached through
`host-gateway` must listen on an address accessible from the guest, not only host loopback.

Flags this engine has no equivalent for, such as `--privileged`, `--device`, `--pid`, `--ipc`,
`--security-opt`, `--gpus` and the `--log-*` family, are accepted by `container run`
and `container create`, reported on stderr as `Warning! --privileged is not supported by this
engine and was ignored`, and ignored: a command copied from elsewhere still runs, without them.

## Images

| Docker | container |
|---|---|
| `docker build` | `container build` |
| `docker images` | `container image list` / `ls`, or `container images` |
| `docker image ls NAME` | `container image ls NAME`: a repository, or repository:tag |
| `docker pull` | `container image pull`, or `container pull` |
| `docker push` | `container image push`, or `container push` |
| `docker rmi` | `container image delete` / `rm`, or `container rmi` |
| `docker tag` | `container image tag`, or `container tag` |
| `docker save` | `container image save`, or `container save` |
| `docker load` | `container image load`, or `container load` |
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
| `docker info` | `container system status`, or `container info` |
| `docker version` | `container system version`, or `container version` |
| `docker system df` | `container system df` |
| daemon logs | `container system logs` |
| `docker events` | — no equivalent |

`container system prune` runs the prunes in a row: stopped containers, unused networks,
then dangling images (`-a` for every unused image). Volumes hold data and are pruned only
with `--volumes`, and then only the anonymous ones. Each prune also runs on its own:

```bash
container prune                 # stopped containers
container image prune
container volume prune          # anonymous volumes; --all for named ones too, as in Docker
container network prune
```

## Running a compose file

`container compose` reads the compose files `docker compose` reads and runs each service as a
container on a network of the project's own: `up`, `down`, `ps`, `logs`, `exec`, `start`,
`stop`, `restart`, `pull`, `build` and `config`, with `-f`, `-p`, `--profile` and `--env-file`
in front of the subcommand. `docs/compose.md` describes all of it.

```bash
container compose up -d      # networks, volumes, containers, started in dependency order
container compose ps
container compose logs -f web
container compose exec db psql -U postgres
container compose down       # containers and networks; volumes stay unless -v
```

What carries over as written: `image`, `build`, `command`, `entrypoint`, `environment`,
`env_file`, `${VAR:-default}` substitution with `.env`, `ports`, `volumes` for folders and
named volumes, `depends_on` with its three conditions, `healthcheck` (over the image's `HEALTHCHECK`, which the engine runs) as what
`service_healthy` waits for, `networks` with aliases, `profiles`, override files and `-f`
merges, YAML anchors, and the resource, capability, DNS and `extra_hosts` settings.

What to change in a file written for another engine:

- A file mounted into a container (`./nginx.conf:/etc/nginx/nginx.conf`) is refused: mount
  the folder that holds it. Single-file mounts are planned for 1.5.0.
- Two services that mount the same named volume cannot run at the same time: a volume is a
  disk that one running container holds. `compose` warns about such a pair. Services that
  run together share files through a folder mounted into each.
- `privileged`, `devices`, `network_mode`, `pid`, `ipc`, `secrets`, `configs`, `extends` and
  `volumes_from` stop the command, which names the key and its line. `logging`,
  `security_opt`, `expose`, `links` and the CPU-scheduling keys are ignored with a warning.
- `restart` is applied by the engine as Docker applies it, on exits and when the engine
  starts.

`container compose config --commands` prints the `container` commands a project comes to.
For this file:

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

in a directory named `shop`, it prints (labels left out here):

```bash
container network create shop_default
container run --detach --name shop-db-1 --network shop_default,alias=db \
  --env POSTGRES_PASSWORD=secret postgres:16
container run --detach --name shop-web-1 --network shop_default,alias=web --publish 8080:80 \
  --env DATABASE_URL=postgres://postgres:secret@db:5432/postgres my-app:latest
```

`web` reaches the database as `db`: a service is a name on each of its networks. A
container's hosts file is written when it starts, with the name and address of every
container that exists on its networks, started or not, and a container holds its address
from create to delete. `compose up` creates every container before it starts the first, so
each service resolves every other one whatever the start order. A container created after
another started is unknown to that one until it restarts: existing guests do not receive
live updates, which is tracked in
[SiliconShip#188](https://github.com/devops-thiago/SiliconShip/issues/188). Because a stopped
container keeps its address, a network runs out when every address of its subnet belongs to
a container that exists; `container create` then fails and says so.

The [migration roadmap](https://github.com/devops-thiago/SiliconShip/issues/235) has what
comes next:

| Release | Capability |
|---|---|
| 1.3.0 | Migration report, image archives, and the flags described above |
| 1.4.0 | `container compose`, and compose files in the app, with dependency health gates |
| 1.5.0 | Planned: engine restart supervision, live health, dynamic guest name resolution, single-file bind mounts |
| 1.6.0 | Planned: Engine API compatibility for the user's Docker CLI, Docker Compose, Testcontainers and IDE integrations |

The user migration guide is at [siliconship.app/docker](https://siliconship.app/docker).

## Features with no Docker counterpart

- `container machine` — a full Linux environment with your home directory mapped in. See
  `container-machines.md`.
- `container run --publish-socket <host_path:container_path>` — publish a Unix socket to the
  host rather than a TCP port.
- `container run --ssh` — forward your SSH agent socket into the container.
- `container run --virtualization` — expose virtualization to the container for nested use.
- `container run --rosetta` — run x86-64 binaries on Apple silicon.
- `container system kernel` — manage the kernel containers boot with.
