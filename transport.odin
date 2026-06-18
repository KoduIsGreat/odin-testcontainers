package testcontainers

// Raw AF_UNIX byte transport to the Docker daemon. No core:net (IP-only),
// just core:sys/posix. This is the only OS-touching layer in the package.

import "core:c"
import "core:sys/posix"
import "core:time"

// Inactivity timeout for daemon socket I/O: recv/send return an error after this
// long with NO progress. It is NOT a total-operation deadline — it resets on
// every byte, so a slow-but-progressing image pull won't trip it; only a wedged
// daemon (or a proxy that accepted the connection but never responds) will.
@(private)
SOCKET_TIMEOUT :: 60 * time.Second

// Bounded wait for the connect handshake (the daemon socket is local, so this
// is generous; it only matters if a proxy accepts but never completes).
@(private)
CONNECT_TIMEOUT :: 10 * time.Second

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

	if !connect_with_timeout(fd, &addr, CONNECT_TIMEOUT) {
		posix.close(fd)
		return {}, false
	}
	set_socket_timeouts(fd, SOCKET_TIMEOUT)
	return Connection{fd = fd}, true
}

// Connect with a bounded wait: set the socket non-blocking so connect() returns
// immediately, poll() for the socket to become writable (= connected or
// failed) up to the timeout, then check SO_ERROR to see if it actually
// connected. Restores blocking mode for the normal send/recv path. Without this
// a proxy that accepts the connection but never completes the handshake would
// hang connect() forever.
@(private)
connect_with_timeout :: proc(fd: posix.FD, addr: ^posix.sockaddr_un, d: time.Duration) -> (ok: bool) {
	flags := posix.fcntl(fd, .GETFL)
	if flags == -1 {
		return false
	}
	if posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK) == -1 {
		return false
	}
	defer posix.fcntl(fd, .SETFL, flags) // restore blocking mode

	if posix.connect(fd, (^posix.sockaddr)(addr), size_of(posix.sockaddr_un)) == .OK {
		return true // local sockets commonly connect immediately
	}
	if posix.errno() != .EINPROGRESS {
		return false // immediate, real failure (e.g. ECONNREFUSED)
	}

	// In progress — wait for writability up to the timeout.
	pfds: [1]posix.pollfd
	pfds[0] = posix.pollfd {
		fd     = fd,
		events = {.OUT},
	}
	if posix.poll(raw_data(pfds[:]), 1, c.int(d / time.Millisecond)) <= 0 {
		return false // 0 = timed out, -1 = poll error
	}

	// Writable: SO_ERROR tells us whether the connect succeeded or failed.
	soerr: c.int
	length := posix.socklen_t(size_of(soerr))
	if posix.getsockopt(fd, c.int(posix.SOL_SOCKET), .ERROR, &soerr, &length) != .OK {
		return false
	}
	return soerr == 0
}

// Bound recv/send with SO_RCVTIMEO/SO_SNDTIMEO so a wedged daemon can't hang us
// forever. On timeout the syscall returns -1, which dial's callers treat as a
// failed request (not a hang).
@(private)
set_socket_timeouts :: proc(fd: posix.FD, d: time.Duration) {
	tv := posix.timeval {
		tv_sec  = posix.time_t(d / time.Second),
		tv_usec = posix.suseconds_t((d % time.Second) / time.Microsecond),
	}
	posix.setsockopt(fd, c.int(posix.SOL_SOCKET), .RCVTIMEO, &tv, size_of(tv))
	posix.setsockopt(fd, c.int(posix.SOL_SOCKET), .SNDTIMEO, &tv, size_of(tv))
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
