package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:time"

import testcontainers "testcontainers:."
import postgres "testcontainers:modules/postgres"

main :: proc() {
	client := testcontainers.make_client()
	fmt.printfln("resolved docker socket: %s", client.socket_path)

	fmt.println("starting postgres (waiting for pg_isready healthcheck) ...")
	pg, ok := postgres.start(client, postgres.Config{password = "secret", database = "appdb"})
	if !ok {
		fmt.eprintln("error: postgres did not become ready")
		os.exit(1)
	}
	defer postgres.stop(pg)

	fmt.printfln("ready: %s", postgres.connection_string(pg))

	// Prove the mapped port is a real Postgres by performing the protocol
	// startup handshake and confirming the server sends an Authentication ('R')
	// message back. Retry: Rancher's host-side port-forward can lag a beat even
	// after the in-container healthcheck passes.
	for attempt in 1 ..= 15 {
		if code, got := pg_startup_probe(pg); got {
			fmt.printfln("server speaks Postgres: Authentication message (code %d) ✅", code)
			return
		}
		time.sleep(200 * time.Millisecond)
		if attempt == 15 {
			fmt.eprintln("error: startup handshake failed")
			os.exit(1)
		}
	}
}

// Connect to the mapped port and send a Postgres v3 StartupMessage; a real
// server replies with a 'R' (Authentication) message. Returns the auth code.
pg_startup_probe :: proc(pg: postgres.Postgres) -> (auth_code: u32, ok: bool) {
	sock, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = pg.port})
	if derr != nil {
		return 0, false
	}
	defer net.close(sock)

	// StartupMessage = Int32 length | Int32 protocol(196608=3.0) | params | \0
	params := fmt.tprintf("user\x00%s\x00database\x00%s\x00\x00", pg.user, pg.database)
	msg_len := u32(4 + 4 + len(params))
	msg := make([]u8, msg_len, context.temp_allocator)
	be32(msg[0:4], msg_len)
	be32(msg[4:8], 196608)
	copy(msg[8:], params)
	if _, serr := net.send_tcp(sock, msg); serr != nil {
		return 0, false
	}

	// Response framing: Byte1 type | Int32 length | (if 'R') Int32 auth code
	resp: [16]u8
	n, rerr := net.recv_tcp(sock, resp[:])
	if rerr != nil || n < 9 || resp[0] != 'R' {
		return 0, false
	}
	return read_be32(resp[5:9]), true
}

be32 :: proc(b: []u8, v: u32) {
	b[0] = u8(v >> 24)
	b[1] = u8(v >> 16)
	b[2] = u8(v >> 8)
	b[3] = u8(v)
}

read_be32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}
