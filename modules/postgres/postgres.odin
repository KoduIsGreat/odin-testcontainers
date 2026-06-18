package postgres

// Postgres module preset for odin-test-containers. Brings up a throwaway
// Postgres, waits until it genuinely accepts connections (via a pg_isready
// HEALTHCHECK — more reliable than log-waiting, since Postgres logs
// "ready to accept connections" twice during first-time init), and hands back
// a typed handle with a connection string.

import "core:fmt"
import "core:strings"

import testcontainers "testcontainers:."

DEFAULT_IMAGE :: "postgres:16-alpine"

Config :: struct {
	image:    string, // default DEFAULT_IMAGE
	user:     string, // default "postgres"
	password: string, // default "postgres"
	database: string, // default = user
}

Postgres :: struct {
	container: testcontainers.Container,
	host:      string,
	port:      int,
	user:      string,
	password:  string,
	database:  string,
}

start :: proc(client: testcontainers.Client, config := Config{}, allocator := context.allocator) -> (pg: Postgres, ok: bool) {
	image := config.image if config.image != "" else DEFAULT_IMAGE
	user := config.user if config.user != "" else "postgres"
	password := config.password if config.password != "" else "postgres"
	database := config.database if config.database != "" else user

	gc := testcontainers.new_container(image, allocator)
	defer testcontainers.container_destroy(&gc)
	testcontainers.with_exposed_port(&gc, "5432/tcp")
	testcontainers.with_env(&gc, "POSTGRES_USER", user)
	testcontainers.with_env(&gc, "POSTGRES_PASSWORD", password)
	testcontainers.with_env(&gc, "POSTGRES_DB", database)
	// pg_isready returns 0 only once Postgres is truly accepting connections.
	testcontainers.with_healthcheck(&gc, "CMD-SHELL", fmt.tprintf("pg_isready -U %s -d %s", user, database))
	testcontainers.with_wait(&gc, testcontainers.Wait_Healthcheck{})

	c := testcontainers.start(&gc, client, allocator) or_return
	port := testcontainers.mapped_port(c, "5432/tcp") or_return

	return Postgres {
			container = c,
			host = "127.0.0.1",
			port = port,
			user = strings.clone(user, allocator),
			password = strings.clone(password, allocator),
			database = strings.clone(database, allocator),
		},
		true
}

stop :: proc(pg: Postgres) {
	testcontainers.remove_container(pg.container)
}

// postgresql://user:password@host:port/database?sslmode=disable
connection_string :: proc(pg: Postgres, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"postgresql://%s:%s@%s:%d/%s?sslmode=disable",
		pg.user,
		pg.password,
		pg.host,
		pg.port,
		pg.database,
		allocator = allocator,
	)
}
