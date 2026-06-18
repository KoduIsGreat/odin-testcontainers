package main

import "core:fmt"
import "core:os"

import docker "testcontainers:docker"
import postgres "testcontainers:modules/postgres"

main :: proc() {
	client := docker.make_client()
	fmt.printfln("resolved docker socket: %s", client.socket_path)

	// postgres.start brings up Postgres and waits on a custom Wait_Func (the v3
	// startup handshake) registered inside the module — no readiness code here.
	fmt.println("starting postgres ...")
	pg, ok := postgres.start(client, postgres.Config{password = "secret", database = "appdb"})
	if !ok {
		fmt.eprintln("error: postgres did not become ready")
		os.exit(1)
	}
	defer postgres.stop(&pg)

	port, _ := docker.mapped_port(pg, "5432/tcp") // subtype: Postgres -> Container
	fmt.printfln("ready on 127.0.0.1:%d", port)
	fmt.printfln("connection string: %s", postgres.connection_string(pg))

	// The container carries its own wait strategy, so readiness can be
	// re-verified on demand — here using the module's registered Wait_Func.
	if !docker.wait_until_ready(pg) {
		fmt.eprintln("error: re-check failed")
		os.exit(1)
	}
	fmt.println("re-checked ready via the container's registered Wait_Func ✅")
}
