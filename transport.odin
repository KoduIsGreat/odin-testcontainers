package testcontainers

// Raw AF_UNIX byte transport to the Docker daemon. No core:net (IP-only),
// just core:sys/posix. This is the only OS-touching layer in the package.

import "core:c"
import "core:sys/posix"

@(private)
Connection :: struct {
	fd: posix.FD,
}

// Open a stream connection to a unix socket path (the Docker daemon socket).
@(private)
dial :: proc(socket_path: string) -> (conn: Connection, ok: bool) {
	fd := posix.socket(.UNIX, .STREAM)
	if fd == -1 {
		return {}, false
	}

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	if len(socket_path) >= len(addr.sun_path) {
		posix.close(fd)
		return {}, false
	}
	copy(addr.sun_path[:], socket_path)

	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		posix.close(fd)
		return {}, false
	}
	return Connection{fd = fd}, true
}

@(private)
conn_close :: proc(conn: Connection) {
	posix.close(conn.fd)
}

// Write the whole buffer, looping until every byte is sent.
@(private)
send_all :: proc(conn: Connection, data: []u8) -> (ok: bool) {
	sent := 0
	for sent < len(data) {
		rem := len(data) - sent
		n := posix.send(conn.fd, raw_data(data[sent:]), c.size_t(rem), {})
		if n <= 0 {
			return false
		}
		sent += int(n)
	}
	return true
}

// Read until the peer closes the connection (we send `Connection: close`,
// so the daemon EOFs once the full response is written).
@(private)
read_all :: proc(conn: Connection, allocator := context.allocator) -> (data: [dynamic]u8, ok: bool) {
	data = make([dynamic]u8, 0, 4096, allocator)
	buf: [4096]u8
	for {
		n := posix.recv(conn.fd, raw_data(buf[:]), c.size_t(len(buf)), {})
		if n < 0 {
			delete(data)
			return nil, false
		}
		if n == 0 {
			break // peer closed
		}
		append(&data, ..buf[:n])
	}
	return data, true
}
