package testcontainers

// Generic_Container: the ergonomic, Testcontainers-style builder. Construct
// incrementally with with_* helpers, then start(). Each helper returns the
// builder pointer so calls can be nested, though statement style reads best:
//
//   gc := docker.new_container("nginx:alpine")
//   defer docker.container_destroy(&gc)
//   docker.with_exposed_port(&gc, "80/tcp")
//   docker.with_wait(&gc, docker.Wait_Http{port = "80/tcp", path = "/", status = 200})
//   c, ok := docker.start(&gc, client)

import "core:fmt"
import "core:time"

Generic_Container :: struct {
	image:           string,
	ports:           [dynamic]string,
	env:             [dynamic]string,
	cmd:             [dynamic]string,
	name:            string,
	wait:            Wait_Strategy,
	startup_timeout: time.Duration,
	healthcheck:     [dynamic]string,
}

new_container :: proc(image: string, allocator := context.allocator) -> Generic_Container {
	return Generic_Container {
		image = image,
		ports       = make([dynamic]string, allocator),
		env         = make([dynamic]string, allocator),
		cmd         = make([dynamic]string, allocator),
		healthcheck = make([dynamic]string, allocator),
	}
}

container_destroy :: proc(gc: ^Generic_Container) {
	for e in gc.env {
		delete(e, gc.env.allocator) // with_env aprintf-allocated these
	}
	delete(gc.ports)
	delete(gc.env)
	delete(gc.cmd)
	delete(gc.healthcheck)
}

with_exposed_port :: proc(gc: ^Generic_Container, port: string) -> ^Generic_Container {
	append(&gc.ports, port)
	return gc
}

with_env :: proc(gc: ^Generic_Container, key, value: string) -> ^Generic_Container {
	append(&gc.env, fmt.aprintf("%s=%s", key, value, allocator = gc.env.allocator))
	return gc
}

with_cmd :: proc(gc: ^Generic_Container, args: ..string) -> ^Generic_Container {
	for a in args {
		append(&gc.cmd, a)
	}
	return gc
}

with_name :: proc(gc: ^Generic_Container, name: string) -> ^Generic_Container {
	gc.name = name
	return gc
}

// Set a container HEALTHCHECK (Docker Test form), e.g.
// with_healthcheck(&gc, "CMD-SHELL", "redis-cli ping | grep PONG"). Pairs with
// Wait_Healthcheck.
with_healthcheck :: proc(gc: ^Generic_Container, test: ..string) -> ^Generic_Container {
	for t in test {
		append(&gc.healthcheck, t)
	}
	return gc
}

with_wait :: proc(gc: ^Generic_Container, strategy: Wait_Strategy) -> ^Generic_Container {
	gc.wait = strategy
	return gc
}

with_startup_timeout :: proc(gc: ^Generic_Container, d: time.Duration) -> ^Generic_Container {
	gc.startup_timeout = d
	return gc
}

// Materialize the builder into a Container_Request and run it (ensure reaper,
// create, start, wait). The builder must outlive this call (slices alias it).
start :: proc(gc: ^Generic_Container, client: Client, allocator := context.allocator) -> (c: Container, ok: bool) {
	req := Container_Request {
		image           = gc.image,
		exposed_ports   = gc.ports[:],
		env             = gc.env[:],
		cmd             = gc.cmd[:],
		name            = gc.name,
		wait            = gc.wait,
		startup_timeout = gc.startup_timeout,
		healthcheck     = gc.healthcheck[:],
	}
	return run(client, req, allocator)
}
