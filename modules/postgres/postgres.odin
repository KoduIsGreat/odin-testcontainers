package postgres

// Postgres module preset. A Postgres IS a docker.Container (embedded),
// configured with the right env and a custom readiness probe that performs the
// Postgres v3 startup handshake — a real connection test, registered as a
// Wait_Func. connection_string and friends read back the config from the
// container, so there's no duplicated state.

import "core:fmt"
import "core:net"
import "core:time"

import "testcontainers:docker"

DEFAULT_IMAGE :: "postgres:16-alpine"

Config :: struct {
	image:    string, // default DEFAULT_IMAGE
	user:     string, // default "postgres"
	password: string, // default "postgres"
	database: string, // default = user
}

Postgres :: struct {
	using container: docker.Container,
}

start :: proc(
	client: docker.Client,
	config := Config{},
	allocator := context.allocator,
) -> (
	pg: Postgres,
	ok: bool,
) {
	image := config.image if config.image != "" else DEFAULT_IMAGE
	user := config.user if config.user != "" else "postgres"
	password := config.password if config.password != "" else "postgres"
	database := config.database if config.database != "" else user

	c := docker.new_container(image, allocator)
	docker.with_exposed_port(&c, "5432/tcp")
	docker.with_env(&c, "POSTGRES_USER", user)
	docker.with_env(&c, "POSTGRES_PASSWORD", password)
	docker.with_env(&c, "POSTGRES_DB", database)
	// Readiness = the server completes the Postgres v3 startup handshake. This
	// is a stronger signal than a port check and is fully self-contained.
	docker.with_wait(&c, docker.Wait_Func{probe = pg_ready})

	if !docker.start(&c, client) {
		docker.container_destroy(&c)
		return {}, false
	}
	return Postgres{container = c}, true
}

stop :: proc(pg: ^Postgres) {
	docker.remove_container(pg^) // value subtype: Postgres -> Container
	docker.container_destroy(pg) // pointer subtype: ^Postgres -> ^Container
}

// postgresql://user:password@host:port/database?sslmode=disable
connection_string :: proc(pg: Postgres, allocator := context.allocator) -> string {
	user, _ := docker.container_env(pg, "POSTGRES_USER")
	password, _ := docker.container_env(pg, "POSTGRES_PASSWORD")
	database, _ := docker.container_env(pg, "POSTGRES_DB")
	port, _ := docker.mapped_port(pg, "5432/tcp")
	return fmt.aprintf(
		"postgresql://%s:%s@%s:%d/%s?sslmode=disable",
		user,
		password,
		docker.host(pg),
		port,
		database,
		allocator = allocator,
	)
}

// --- Custom readiness probe (registered as a Wait_Func) ------------------

// Ready when the mapped port speaks the Postgres protocol: we send a v3
// StartupMessage and the server replies with an Authentication ('R') message.
@(private)
pg_ready :: proc(c: ^docker.Container, user_data: rawptr) -> bool {
	user, _ := docker.container_env(c^, "POSTGRES_USER")
	database, _ := docker.container_env(c^, "POSTGRES_DB")
	port, ok := docker.mapped_port(c^, "5432/tcp")
	if !ok {
		return false
	}
	return pg_handshake_ok(port, user, database)
}

@(private)
pg_handshake_ok :: proc(port: int, user, database: string) -> bool {
	sock, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
	if derr != nil {
		return false
	}
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 2 * time.Second)

	// StartupMessage: Int32 length | Int32 protocol(196608) | params | \0
	params := fmt.tprintf("user\x00%s\x00database\x00%s\x00\x00", user, database)
	msg_len := u32(4 + 4 + len(params))
	msg := make([]u8, msg_len, context.temp_allocator)
	be32(msg[0:4], msg_len)
	be32(msg[4:8], 196608)
	copy(msg[8:], params)
	if _, serr := net.send_tcp(sock, msg); serr != nil {
		return false
	}

	resp: [16]u8
	n, rerr := net.recv_tcp(sock, resp[:])
	return rerr == nil && n >= 1 && resp[0] == 'R'
}

@(private)
be32 :: proc(b: []u8, v: u32) {
	b[0] = u8(v >> 24)
	b[1] = u8(v >> 16)
	b[2] = u8(v >> 8)
	b[3] = u8(v)
}
