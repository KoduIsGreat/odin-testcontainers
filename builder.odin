package testcontainers

// Construction helpers for a Container. Configure incrementally, then start():
//
//   c := testcontainers.new_container("nginx:alpine")
//   defer testcontainers.container_destroy(&c)
//   testcontainers.with_exposed_port(&c, "80/tcp")
//   testcontainers.with_wait(&c, testcontainers.Wait_Http{port = "80/tcp", path = "/", status = 200})
//   testcontainers.start(&c, client)
//
// Each with_* returns the container pointer so calls can nest; statement style
// reads best.

import "core:fmt"
import "core:time"

new_container :: proc(image: string, allocator := context.allocator) -> Container {
	return Container {
		image         = image,
		allocator     = allocator,
		exposed_ports = make([dynamic]string, allocator),
		env           = make([dynamic]string, allocator),
		cmd           = make([dynamic]string, allocator),
		healthcheck   = make([dynamic]string, allocator),
	}
}

// Free a container's configuration (and its id). Does NOT remove the running
// container — call remove_container for that (or rely on the reaper).
container_destroy :: proc(c: ^Container) {
	for e in c.env {
		delete(e, c.allocator) // with_env aprintf-allocated these
	}
	delete(c.exposed_ports)
	delete(c.env)
	delete(c.cmd)
	delete(c.healthcheck)
	if c.id != "" {
		delete(c.id, c.allocator)
	}
}

with_exposed_port :: proc(c: ^Container, port: string) -> ^Container {
	append(&c.exposed_ports, port)
	return c
}

with_env :: proc(c: ^Container, key, value: string) -> ^Container {
	append(&c.env, fmt.aprintf("%s=%s", key, value, allocator = c.allocator))
	return c
}

with_cmd :: proc(c: ^Container, args: ..string) -> ^Container {
	for a in args {
		append(&c.cmd, a)
	}
	return c
}

with_name :: proc(c: ^Container, name: string) -> ^Container {
	c.name = name
	return c
}

// Set a container HEALTHCHECK (Docker Test form), e.g.
// with_healthcheck(&c, "CMD-SHELL", "pg_isready -U postgres"). Pairs with
// Wait_Healthcheck.
with_healthcheck :: proc(c: ^Container, test: ..string) -> ^Container {
	for t in test {
		append(&c.healthcheck, t)
	}
	return c
}

with_wait :: proc(c: ^Container, strategy: Wait_Strategy) -> ^Container {
	c.wait = strategy
	return c
}

with_startup_timeout :: proc(c: ^Container, d: time.Duration) -> ^Container {
	c.startup_timeout = d
	return c
}
