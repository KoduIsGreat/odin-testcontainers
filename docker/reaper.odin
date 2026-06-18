package docker

// Ryuk-based crash-safe cleanup. We start the testcontainers/ryuk sidecar,
// hold a TCP connection to it, and register a label filter. When our process
// dies (clean exit, panic, or kill -9) the OS closes the connection and Ryuk
// reaps every container carrying our session label. This is the only cleanup
// that survives a hard crash — defer/remove cannot.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

@(private)
SESSION_LABEL :: "com.odin-test-containers.session"
@(private)
MANAGED_LABEL :: "com.odin-test-containers.managed"

@(private)
REAPER_IMAGE :: "testcontainers/ryuk:0.11.0"
@(private)
REAPER_PORT :: "8080/tcp"
// Daemon-side path to the Docker socket (resolved inside the daemon/VM, not the
// host), bind-mounted into Ryuk so it can talk to Docker.
@(private)
DAEMON_SOCKET :: "/var/run/docker.sock"

@(private)
g_session_id: string
@(private)
g_reaper_active: bool
@(private)
g_reaper_sock: net.TCP_Socket

// Per-process session id, generated once. Stamped onto every managed container.
@(private)
session_id :: proc() -> string {
	if g_session_id == "" {
		g_session_id = fmt.aprintf("otc-%x", time.to_unix_nanoseconds(time.now()))
	}
	return g_session_id
}

@(private)
reaper_disabled :: proc() -> bool {
	v := os.get_env("OTC_RYUK_DISABLED", context.temp_allocator)
	return v == "true" || v == "1"
}

// Ensure Ryuk is running and our filter is registered. Idempotent and
// best-effort: a false return means no crash-safety net (callers still work,
// relying on explicit remove_container).
@(private)
ensure_reaper :: proc(client: Client) -> (ok: bool) {
	if g_reaper_active {
		return true
	}
	if reaper_disabled() {
		return false
	}

	sid := session_id()

	if !pull_image(client, REAPER_IMAGE) {
		return false
	}

	// Ryuk needs the daemon socket + privileged access. It is deliberately NOT
	// given the session label, so it never schedules itself for reaping.
	wire: Wire_Create
	wire.Image = REAPER_IMAGE
	wire.ExposedPorts = make(map[string]struct {}, context.temp_allocator)
	wire.ExposedPorts[REAPER_PORT] = {}
	wire.HostConfig.PortBindings = make(map[string][]Wire_Port_Binding, context.temp_allocator)
	pb := make([]Wire_Port_Binding, 1, context.temp_allocator)
	pb[0] = Wire_Port_Binding {
		HostPort = "",
	}
	wire.HostConfig.PortBindings[REAPER_PORT] = pb
	wire.HostConfig.Binds = []string {
		strings.concatenate({DAEMON_SOCKET, ":", DAEMON_SOCKET}, context.temp_allocator),
	}
	wire.HostConfig.Privileged = true
	// Auto-remove the Ryuk container the moment it exits (post-reap) so its
	// own containers don't accumulate across runs.
	wire.HostConfig.AutoRemove = true

	rid, created := create_from_wire(client, wire)
	if !created {
		return false
	}
	reaper := Container {
		client = client,
		id     = rid,
	}
	if !container_start(reaper) {
		return false
	}

	host_port, pok := mapped_port(reaper, REAPER_PORT)
	if !pok {
		return false
	}

	filter := fmt.tprintf("label=%s=%s\n", SESSION_LABEL, sid)
	sock, hok := reaper_handshake(host_port, filter, 20 * time.Second)
	if !hok {
		return false
	}

	g_reaper_sock = sock // intentionally never closed; drop => reap
	g_reaper_active = true
	return true
}

// Connect to Ryuk, send the filter, and read the "ACK" — retried until the
// deadline. Each attempt bounds the ACK read with a receive timeout: Rancher's
// port-forwarder accepts the TCP connection before Ryuk is actually listening
// inside the container, so a plain blocking recv would hang forever.
@(private)
reaper_handshake :: proc(
	host_port: int,
	filter: string,
	timeout: time.Duration,
) -> (
	sock: net.TCP_Socket,
	ok: bool,
) {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		s, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = host_port})
		if derr != nil {
			time.sleep(200 * time.Millisecond)
			continue
		}
		// Bound the ACK wait so a half-open forward can't block us.
		net.set_option(s, .Receive_Timeout, 2 * time.Second)
		if _, serr := net.send_tcp(s, transmute([]u8)filter); serr != nil {
			net.close(s)
			time.sleep(200 * time.Millisecond)
			continue
		}
		ack: [8]u8
		n, rerr := net.recv_tcp(s, ack[:])
		if rerr == nil && n >= 3 && string(ack[:3]) == "ACK" {
			// Clear the timeout: this socket is held open for the process
			// lifetime and must not error out later.
			net.set_option(s, .Receive_Timeout, time.Duration(0))
			return s, true
		}
		net.close(s)
		time.sleep(200 * time.Millisecond)
	}
	return {}, false
}
