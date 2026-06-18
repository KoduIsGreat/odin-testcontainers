# testcontainers for Odin

Throwaway Docker containers for integration tests, written in pure [Odin](https://odin-lang.org). Spin up a real Postgres, Redis, or anything that runs in a container, wait until it's actually ready, talk to it over its mapped port, and have it cleaned up automatically — even if your test process crashes.

Inspired by [Testcontainers](https://testcontainers.com).

```odin
import testcontainers "testcontainers:."
import postgres "testcontainers:modules/postgres"

client := testcontainers.make_client()

pg, ok := postgres.start(client, postgres.Config{password = "secret", database = "appdb"})
defer postgres.stop(pg)

url := postgres.connection_string(pg)
// postgresql://postgres:secret@127.0.0.1:32802/appdb?sslmode=disable
```

Build with the collection mapped to the repo:

```sh
odin build your_app -collection:testcontainers=/path/to/odin-test-containers
```

## Why

Integration tests want real dependencies, not mocks — but managing their lifecycle by hand (start before tests, stop after, don't leak when something panics) is tedious and error-prone. This library does it for you: a container is tied to your test process, becomes addressable once it's genuinely ready, and is reaped when the process dies.

## Design

- **Zero dependencies.** Only the Odin `core` library. No CGo, no libcurl, no Docker SDK.
- **Talks to the Docker Engine API directly** over its Unix socket via `core:sys/posix` (`core:net` is IP-only and can't reach a Unix socket). The HTTP/1.1 client and JSON handling are purpose-built and small.
- **Crash-safe cleanup** via [Ryuk](https://github.com/testcontainers/moby-ryuk) — the same resource reaper the official Testcontainers projects use.

## Requirements

- **Odin** (recent dev build).
- A **Docker-compatible daemon** exposing a Unix socket: Docker Desktop, Docker Engine, Rancher Desktop, Colima, Podman (with the Docker-compatible socket), etc.
- **macOS or Linux** (the transport uses AF_UNIX domain sockets).

The daemon socket is auto-discovered (see [Configuration](#configuration)). No manual setup required for the common cases.

## Installation

The library is consumed as an [Odin collection](https://odin-lang.org/docs/overview/#import-statement). Point a collection named `testcontainers` at the repo root, then import the root package with `"testcontainers:."` and modules with `"testcontainers:modules/<name>"`:

```sh
odin build your_app -collection:testcontainers=/path/to/odin-test-containers
```

For editor/LSP support, add the collection to your `ols.json`:

```json
{ "collections": [ { "name": "testcontainers", "path": "/path/to/odin-test-containers" } ] }
```

## Project layout

```
.                       package testcontainers   ← the library
  transport.odin          AF_UNIX bytes to the Docker daemon (core:sys/posix)
  http.odin               purpose-built HTTP/1.1: request build + response parse
  client.odin             make_client (socket resolution) + request()
  container.odin          pull / create / start / inspect / remove / run / mapped_port
  wait.odin               wait strategies
  builder.odin            Generic_Container builder
  reaper.odin             Ryuk crash-safe cleanup
modules/
  postgres/               package postgres   ← a module preset
example/
  main.odin               runnable demo
```

## Usage

### The one-liner: `run`

`run` does everything — ensures the reaper, pulls the image, creates and starts the container, and waits for readiness:

```odin
import testcontainers "testcontainers:."

client := testcontainers.make_client()

c, ok := testcontainers.run(client, testcontainers.Container_Request{
	image         = "redis:alpine",
	exposed_ports = {"6379/tcp"},
	wait          = testcontainers.Wait_Log{text = "Ready to accept connections"},
})
if !ok {
	// container failed to start or never became ready
}
defer testcontainers.remove_container(c)

port, _ := testcontainers.mapped_port(c, "6379/tcp")
// connect to 127.0.0.1:port
```

### The builder

For incremental construction, use the `Generic_Container` builder:

```odin
gc := testcontainers.new_container("nginx:alpine")
defer testcontainers.container_destroy(&gc)

testcontainers.with_exposed_port(&gc, "80/tcp")
testcontainers.with_env(&gc, "NGINX_PORT", "80")
testcontainers.with_wait(&gc, testcontainers.Wait_Http{port = "80/tcp", path = "/", status = 200})

c, ok := testcontainers.start(&gc, client)
defer testcontainers.remove_container(c)
```

Builder helpers (each returns the builder pointer, so they nest; statement style reads best):

| Helper | Purpose |
|---|---|
| `with_exposed_port(&gc, "6379/tcp")` | publish a container port to an ephemeral host port |
| `with_env(&gc, "KEY", "VALUE")` | set an environment variable |
| `with_cmd(&gc, "arg1", "arg2")` | override the container command |
| `with_name(&gc, "my-container")` | set a fixed name (Docker auto-names otherwise) |
| `with_healthcheck(&gc, "CMD-SHELL", "pg_isready")` | define a Docker HEALTHCHECK |
| `with_wait(&gc, strategy)` | set the readiness strategy |
| `with_startup_timeout(&gc, 30 * time.Second)` | cap how long to wait for readiness |

### Wait strategies

A started container is not necessarily *ready*. Pick the signal that actually means "ready":

```odin
// TCP: a mapped port accepts a connection
testcontainers.Wait_Port{port = "6379/tcp"}

// Log: a substring appears in stdout/stderr
testcontainers.Wait_Log{text = "database system is ready to accept connections"}

// HTTP: a GET to a mapped port returns the expected status (0 = any 2xx)
testcontainers.Wait_Http{port = "80/tcp", path = "/health", status = 200}

// Healthcheck: the container's Docker HEALTHCHECK reports "healthy"
testcontainers.Wait_Healthcheck{}
```

`Wait_Healthcheck` (paired with `with_healthcheck`) is the most reliable for databases — e.g. Postgres logs `"ready to accept connections"` *twice* during first-time init, which fools naive log-waiting.

### Lower-level verbs

`run` is built from composable pieces you can call directly:

```odin
testcontainers.pull_image(client, "redis:alpine")
c, _ := testcontainers.create_container(client, req)
testcontainers.start_container(c)
insp, _ := testcontainers.inspect_container(c)   // typed Inspect: State, Health, Ports
port, _ := testcontainers.mapped_port(c, "6379/tcp")
testcontainers.remove_container(c)
```

And the raw Docker API, if you need an endpoint that isn't wrapped yet:

```odin
resp, ok := testcontainers.request(client, "GET", "/version")
defer testcontainers.response_destroy(&resp)
// resp.status, resp.headers, resp.body ([]u8, ready for json.unmarshal)
```

## Modules

Module presets package a sensible image, configuration, readiness strategy, and helpers for a specific technology.

### Postgres

```odin
import postgres "testcontainers:modules/postgres"

pg, ok := postgres.start(client, postgres.Config{
	image    = "postgres:16-alpine", // optional; this is the default
	user     = "postgres",           // default
	password = "secret",             // default "postgres"
	database = "appdb",              // default = user
})
defer postgres.stop(pg)

url := postgres.connection_string(pg)
// pg.host, pg.port, pg.user, pg.password, pg.database are also available
```

Readiness is gated on a `pg_isready` healthcheck, so by the time `start` returns the server genuinely accepts connections.

## Cleanup & crash safety

Two layers:

1. **Explicit** — `remove_container(c)` / `postgres.stop(pg)`, typically via `defer`.
2. **Ryuk reaper** — for everything `defer` can't cover (panics, `os.exit`, `kill -9`).

On first container creation the library starts the `testcontainers/ryuk` sidecar and holds a TCP connection to it, registering a per-process session label. Every container the library creates is tagged with that label. When your process dies and the connection drops, Ryuk reaps every container carrying the label. This is the only cleanup that survives a hard crash — and it's why you should never rely on `defer` alone.

Disable it (e.g. in CI that handles its own cleanup) with `OTC_RYUK_DISABLED=1`.

> Note: `defer` does **not** run when you call `os.exit()`. On exit paths that bypass `defer`, Ryuk is your safety net.

## Configuration

### Socket resolution

`make_client()` (no argument) resolves the daemon socket the way the Docker CLI does:

1. `DOCKER_HOST` environment variable (`unix://` prefix is stripped)
2. context named by `DOCKER_CONTEXT`, else `currentContext` in `~/.docker/config.json`
   — looked up in `~/.docker/contexts/meta/<sha256(name)>/meta.json`
3. fallback to `/var/run/docker.sock`

Override explicitly when needed:

```odin
client := testcontainers.make_client("/Users/me/.rd/docker.sock")
```

### Environment variables

| Variable | Effect |
|---|---|
| `DOCKER_HOST` | force a specific daemon socket |
| `DOCKER_CONTEXT` | use a specific docker context |
| `OTC_RYUK_DISABLED` | `1`/`true` disables the Ryuk reaper |

## Running the example

```sh
odin run example -collection:testcontainers=.
```

Starts Postgres, prints its connection string, and proves it by performing the Postgres v3 startup handshake against the mapped port.

## Limitations & roadmap

- **Unix sockets only** — a `tcp://` `DOCKER_HOST` resolves but the transport can't dial it yet.
- **No streaming** — responses are read fully, so live log-follow / pull-progress aren't available (readiness polls instead).
- **One connection per request** — no HTTP keep-alive yet.
- **No container `exec`** — out of scope by design. Talk to services over their mapped ports with a real client library (e.g. a database package), not by shelling into the container.
- More module presets (Redis, MySQL, …) welcome.

## License

[MIT](LICENSE) © Adam Shelton
