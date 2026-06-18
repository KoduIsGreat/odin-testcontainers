package docker

// Readiness strategies. A container that is "started" is not necessarily
// "ready" — wait_until_ready polls the container's configured strategy until it
// is (or the timeout elapses).

import "core:bytes"
import "core:fmt"
import "core:net"
import "core:time"

DEFAULT_STARTUP_TIMEOUT :: 60 * time.Second
@(private)
POLL_INTERVAL :: 200 * time.Millisecond
// recv/send timeout for host-side probe connections (mapped ports).
@(private)
PROBE_TIMEOUT :: 10 * time.Second

// Bound recv/send on a host-side probe socket so a half-open port-forward
// (proxy accepted the connection but the backend isn't talking yet) can't hang
// a readiness probe past its poll interval.
@(private)
set_net_timeouts :: proc(sock: net.TCP_Socket, d: time.Duration) {
	net.set_option(sock, .Receive_Timeout, d)
	net.set_option(sock, .Send_Timeout, d)
}

Wait_Strategy :: union {
	Wait_Port, // a mapped container port accepts a TCP connection
	Wait_Log, // a substring appears in the container's logs
	Wait_Http, // an HTTP GET to a mapped port returns an expected status
	Wait_Healthcheck, // the container's Docker HEALTHCHECK reports healthy
	Wait_Func, // a user-supplied probe (custom readiness check)
}

Wait_Port :: struct {
	port: string, // e.g. "6379/tcp" (or "6379", defaults to /tcp)
}

Wait_Log :: struct {
	text: string, // substring expected in stdout/stderr
}

Wait_Http :: struct {
	port:   string, // container port to hit, e.g. "80/tcp"
	path:   string, // request path, e.g. "/health"
	status: int, // expected status; 0 means "any 2xx"
}

Wait_Healthcheck :: struct {}

// Custom readiness: `probe` is called repeatedly until it returns true (or the
// timeout elapses). It receives the live container, so it can look up mapped
// ports, env, etc. `user_data` is passed through untouched for extra state.
Wait_Func :: struct {
	probe:     proc(c: ^Container, user_data: rawptr) -> bool,
	user_data: rawptr,
}

// Poll the container's configured wait strategy until ready. Uses the
// container's startup_timeout (or DEFAULT_STARTUP_TIMEOUT). Safe to call again
// after start() to re-verify readiness.
wait_until_ready :: proc(c: Container) -> (ready: bool) {
	timeout := c.startup_timeout if c.startup_timeout > 0 else DEFAULT_STARTUP_TIMEOUT
	cc := c
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		if ready_once(&cc) {
			return true
		}
		time.sleep(POLL_INTERVAL)
	}
	return false
}

// A single readiness probe against the container's configured strategy.
@(private)
ready_once :: proc(c: ^Container) -> bool {
	switch s in c.wait {
	case Wait_Port:
		hp, ok := mapped_port(c^, s.port)
		return ok && tcp_connectable(hp)

	case Wait_Log:
		return log_contains(c^, transmute([]u8)s.text)

	case Wait_Http:
		hp, ok := mapped_port(c^, s.port)
		if !ok {
			return false
		}
		status, got := http_get_status(hp, s.path)
		if !got {
			return false
		}
		if s.status == 0 {
			return status >= 200 && status < 300
		}
		return status == s.status

	case Wait_Healthcheck:
		insp, ok := inspect_container(c^)
		if !ok {
			return false
		}
		return insp.State.Health.Status == "healthy"

	case Wait_Func:
		if s.probe == nil {
			return true
		}
		return s.probe(c, s.user_data)
	}
	return true // nil strategy: nothing to wait for
}

@(private)
tcp_connectable :: proc(host_port: int) -> bool {
	sock, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = host_port})
	if derr != nil {
		return false
	}
	net.close(sock)
	return true
}

// Fetch current logs and test for a substring. Docker multiplexes stdout/stderr
// with 8-byte frame headers when there's no TTY; a plain substring search still
// works because log text never spans a frame boundary mid-word.
@(private)
log_contains :: proc(c: Container, needle: []u8) -> bool {
	path := fmt.tprintf("/containers/%s/logs?stdout=1&stderr=1", c.id)
	resp, ok := request(c.client, "GET", path)
	if !ok {
		return false
	}
	defer response_destroy(&resp)
	return bytes.index(resp.body, needle) >= 0
}

// Host-side HTTP GET against a mapped port. Reuses the response parser by
// reading the whole reply (Connection: close) and feeding it to parse_response.
@(private)
http_get_status :: proc(host_port: int, path: string) -> (status: int, ok: bool) {
	sock, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = host_port})
	if derr != nil {
		return 0, false
	}
	defer net.close(sock)
	set_net_timeouts(sock, PROBE_TIMEOUT)

	req := fmt.tprintf("GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", path)
	if _, serr := net.send_tcp(sock, transmute([]u8)req); serr != nil {
		return 0, false
	}

	data := make([dynamic]u8, 0, 4096)
	defer delete(data)
	buf: [4096]u8
	for {
		n, rerr := net.recv_tcp(sock, buf[:])
		if n > 0 {
			append(&data, ..buf[:n])
		}
		if rerr != nil || n == 0 {
			break // peer closed (or error after any buffered data)
		}
	}
	if len(data) == 0 {
		return 0, false
	}

	resp, parsed := parse_response(data[:])
	if !parsed {
		return 0, false
	}
	defer response_destroy(&resp)
	return resp.status, true
}
