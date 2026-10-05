# Compose files

`container compose` runs the containers a compose file describes. It reads the same files
`docker compose` reads, and runs each service as a container on this engine.

## Quickstart

```yaml
# compose.yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: secret
    volumes:
      - data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
  web:
    image: my-app:latest
    ports:
      - "8080:80"
    environment:
      DATABASE_URL: postgres://postgres:secret@db:5432/postgres
    depends_on:
      db:
        condition: service_healthy
volumes:
  data:
```

```bash
# create and start everything, in dependency order
container compose up -d

# see what runs
container compose ps

# read the output
container compose logs -f web

# stop and remove the containers and the network; the volume stays
container compose down
```

## How a project runs

A project is the services of one set of compose files, under one name. The name is the
`-p` option, the `COMPOSE_PROJECT_NAME` variable, the files' top-level `name:`, or the name
of the directory the first file is in, in that order.

`up` makes, in this order:

1. The project's networks. A project with none declared gets one, `<project>_default`.
2. Its named volumes, as `<project>_<volume>`.
3. One container per service, named `<project>-<service>-1`, or the service's
   `container_name`.

Then it starts the containers, each after the services it depends on. Every container is
created before the first one starts, so each has its address, and a service resolves
every other service of the project by name whichever started first.

A service is a name on each network it attaches to. Its container's own name works too.

`up` again changes only what changed. A container whose service is as it was, and whose
image is the one it was made from, is left running. One whose service or image changed is
stopped, removed and made again.

Everything compose makes carries the labels `docker compose` uses
(`com.docker.compose.project`, `com.docker.compose.service` and the rest), so the
commands that work on a running project — `ps`, `logs`, `stop`, `start`, `restart`,
`exec`, `down` — find it by name and need no compose file: `container compose -p shop down`.

## Dependencies

`depends_on` decides the start order, and with a condition it makes a service wait:

- `service_started`, the default: the dependency has been started.
- `service_healthy`: the dependency's `healthcheck` has passed.
- `service_completed_successfully`: the dependency's container has ended with exit code 0.

A health check is run by `compose` itself, as a command in the container. While it waits,
`compose` runs the check about once a second, so the wait ends as soon as the service is
ready. The check may fail for the service's `start_period` and then for `retries`
intervals; after that `up` stops with the check's last result.

Only a `healthcheck` in the compose file counts. A health check built into an image is
not read, and a service that waits for `service_healthy` on a service without one is an
error.

A service that others wait on to finish runs again on the next `up` only when everything
that waited for it is stopped. While a service that waited is running, the job has done
its work for it and is left as it is.

## What is read from a compose file

For a service: `image`, `build`, `command`, `entrypoint`, `environment`, `env_file`,
`ports`, `volumes`, `depends_on`, `healthcheck`, `restart`, `container_name`, `hostname`,
`networks` (with `aliases` and `mac_address`), `profiles`, `pull_policy`, `working_dir`,
`user`, `labels`, `platform`, `tmpfs`, `ulimits`, `cap_add`, `cap_drop`, `read_only`,
`init`, `tty`, `shm_size`, `dns`, `dns_search`, `dns_opt`, `stop_signal`,
`stop_grace_period`, `cpus`, `mem_limit`, `deploy.resources.limits`, `sysctls` and
`extra_hosts`.

For a network: `name`, `external`, `internal`, `labels`, and one IPv4 subnet under
`ipam.config`. For a volume: `name`, `external` and `labels`.

Variables are substituted as `docker compose` does it: `$VAR`, `${VAR}`,
`${VAR:-default}`, `${VAR-default}`, `${VAR:?message}`, `${VAR:+value}`, and `$$` for a
dollar sign. They come from the environment `compose` runs in and from `.env` in the
project directory, or the files named with `--env-file`.

Several files merge in the order given with `-f`. Without `-f`, `compose.yaml` (or
`compose.yml`, `docker-compose.yaml`, `docker-compose.yml`) in the current directory is
read, with `compose.override.yaml` beside it when there is one. YAML anchors, aliases and
merge keys (`<<`) work.

`container compose config` prints the project the files come to, and
`container compose config --commands` prints the `container` commands that would make it
by hand.

`container compose version` prints the version, as `--version` does. `--short` prints the
number alone and `--format json` prints it as JSON, for a script that checks for compose
before it uses it.

## What this engine does differently

A container here is a lightweight virtual machine with its own kernel. Some of what a
compose file can ask for has no meaning for one, and some works differently.

Keys the engine cannot honour stop the command when they are in something that would run
(see [Profiles](#profiles)), and the message names the key and its line: `privileged`,
`devices`, `gpus`, `network_mode`, `pid`, `ipc`, `uts`, `cgroup`, `userns_mode`,
`secrets`, `configs`, `extends`, `volumes_from`, `runtime`, lifecycle hooks, a static
`ipv4_address`, more than one replica, a network or volume driver other than the default,
and a build from a remote context. A key `compose` does not know at all is reported as
such, so a typo is not taken for something unsupported.

Keys that change nothing a container here could notice are ignored with a warning:
`logging`, `security_opt`, `expose`, `links`, `stdin_open`, `cgroup_parent`, the CPU
scheduling and out-of-memory settings, `develop`, and the swarm parts of `deploy`.

The differences worth knowing:

- **A file cannot be mounted, only a folder.** `./nginx.conf:/etc/nginx/nginx.conf` is
  refused; mount the folder that holds the file.
- **A volume is held by one running container at a time.** Two services that mount the
  same named volume cannot run together; `compose` warns when a project has such a pair.
  Services that run together share files through a folder mounted into each. A job that
  prepares a volume and exits before the service that uses it starts is fine.
- **`restart` is stored, not supervised.** The policy is recorded with the container, and
  the SiliconShip app applies `always` and `unless-stopped` when it starts the engine. A
  container that exits is not started again.
- **CPUs are whole, and memory has a floor.** `cpus: 1.5` becomes 2, and a memory limit
  under 200 MiB becomes 200 MiB, which is the least a container boots with.
- **Networks need macOS 26.** A project's network is its own, which earlier systems
  cannot create.
- **A bind-mounted folder that does not exist is created**, as `docker compose` creates
  one for the short volume syntax.
- **A port without a host port** (`ports: ["80"]`) is published on a free host port,
  chosen when the container is made; `compose ps` shows which.

## Building

A service with `build` gets its image from `container build`. `up` builds an image that
is not there yet; `up --build` and `compose build` build regardless. The image is named
by the service's `image`, or `<project>-<service>` without one. Two services with the
same build and image are built once.

## Profiles

A service with `profiles` is left out unless one of its profiles is turned on with
`--profile` or `COMPOSE_PROFILES`, or the service is named on the command line.
`--profile "*"` turns on all of them.

`--profile` replaces `COMPOSE_PROFILES`, as it does in `docker compose`: when a profile is
named on the command line the variable is not read, whether it comes from the shell or
from the project's `.env`. With no `--profile`, the variable decides.

What is left out is not checked. A key this engine cannot honour, an env file that is not
there, or a mistake in a service whose profiles are off does not stop the project, and
nothing is said about it; the same goes for a network or a volume that only such services
use, or that no service uses. Turning the profile on, or naming the service, checks it.
`container compose --profile "*" config -q` checks every service. `config` leaves out of
what it prints a part that is not checked and has something wrong with it, and says so.
