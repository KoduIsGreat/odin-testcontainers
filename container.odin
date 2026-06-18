package testcontainers

// The Container type and its lifecycle. A Container is configured (via the
// with_* builders in builder.odin), then start()ed, after which it carries its
// runtime identity AND its configuration — so readiness, port lookup, and
// inspection all work off the same value. Modules embed it via
// `using container: Container`.

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

import "base:runtime"

Container :: struct {
	// Runtime identity — populated by start().
	client: Client,
	id:     string,

	// Configuration — set with the with_* builders, retained after start().
	image:           string,
	exposed_ports:   [dynamic]string,
	env:             [dynamic]string,
	cmd:             [dynamic]string,
	healthcheck:     [dynamic]string, // Docker Test form, e.g. {"CMD-SHELL", "..."}
	name:            string,          // optional; Docker auto-names if empty
	wait:            Wait_Strategy,   // nil = don't wait for readiness
	startup_timeout: time.Duration,   // 0 = DEFAULT_STARTUP_TIMEOUT

	allocator: runtime.Allocator,
}

// --- Wire structs (Docker API JSON shapes) -------------------------------

@(private)
Wire_Port_Binding :: struct {
	HostIp:   string `json:"HostIp,omitempty"`,
	HostPort: string `json:"HostPort"`,
}

@(private)
Wire_Host_Config :: struct {
	PortBindings: map[string][]Wire_Port_Binding `json:"PortBindings,omitempty"`,
	Binds:        []string                       `json:"Binds,omitempty"`,
	Privileged:   bool                           `json:"Privileged,omitempty"`,
	AutoRemove:   bool                           `json:"AutoRemove,omitempty"`,
}

@(private)
Wire_Healthcheck :: struct {
	Test:     []string `json:"Test"`,               // e.g. {"CMD-SHELL", "..."}
	Interval: i64      `json:"Interval,omitempty"`,  // nanoseconds
	Timeout:  i64      `json:"Timeout,omitempty"`,   // nanoseconds
	Retries:  int      `json:"Retries,omitempty"`,
}

@(private)
Wire_Create :: struct {
	Image:        string                          `json:"Image"`,
	Cmd:          []string                        `json:"Cmd,omitempty"`,
	Env:          []string                        `json:"Env,omitempty"`,
	Labels:       map[string]string               `json:"Labels,omitempty"`,
	ExposedPorts: map[string]struct {}            `json:"ExposedPorts,omitempty"`,
	Healthcheck:  Maybe(Wire_Healthcheck)         `json:"Healthcheck,omitempty"`,
	HostConfig:   Wire_Host_Config                `json:"HostConfig"`,
}

// Subset of `GET /containers/{id}/json` we care about.
Port_Map_Entry :: struct {
	HostIp:   string `json:"HostIp"`,
	HostPort: string `json:"HostPort"`,
}

Container_Health :: struct {
	Status: string `json:"Status"`, // "starting" | "healthy" | "unhealthy" ("" if no healthcheck)
}

Container_State :: struct {
	Status:   string           `json:"Status"`,
	Running:  bool             `json:"Running"`,
	ExitCode: int              `json:"ExitCode"`,
	Health:   Container_Health `json:"Health"`,
}

Network_Settings :: struct {
	Ports: map[string][]Port_Map_Entry `json:"Ports"`,
}

Inspect :: struct {
	Id:              string           `json:"Id"`,
	State:           Container_State  `json:"State"`,
	NetworkSettings: Network_Settings `json:"NetworkSettings"`,
}

// --- Lifecycle -----------------------------------------------------------

// The single entrypoint: ensure the reaper, pull the image, create + start the
// container, and wait for readiness (if a wait strategy is set). Fills in
// c.client and c.id. Returns ok=false if it never started or never became
// ready — the caller still has the handle for inspection / removal.
start :: proc(c: ^Container, client: Client) -> (ok: bool) {
	c.client = client
	ensure_reaper(client) // best-effort crash-safety; failure is non-fatal

	// Auto-pull so callers don't pre-stage images (fast no-op when local).
	if !pull_image(client, c.image) {
		return false
	}
	if !container_create(c) {
		return false
	}
	if !container_start(c^) {
		return false
	}
	if c.wait != nil {
		if !wait_until_ready(c^) {
			return false
		}
	}
	return true
}

// Pull an image. Streams progress JSON which we drain to EOF; success is a 200.
pull_image :: proc(client: Client, image: string, allocator := context.allocator) -> (ok: bool) {
	name, tag := split_image_tag(image)
	path := fmt.tprintf("/images/create?fromImage=%s&tag=%s", name, tag)
	resp := request(client, "POST", path, allocator = allocator) or_return
	defer response_destroy(&resp, allocator)
	return resp.status == 200
}

inspect_container :: proc(c: Container, allocator := context.allocator) -> (insp: Inspect, ok: bool) {
	path := fmt.tprintf("/containers/%s/json", c.id)
	resp := request(c.client, "GET", path, allocator = allocator) or_return
	defer response_destroy(&resp, allocator)
	if resp.status != 200 {
		return {}, false
	}
	if json.unmarshal(resp.body, &insp, allocator = allocator) != nil {
		return {}, false
	}
	return insp, true
}

// Force-remove the container and its anonymous volumes.
remove_container :: proc(c: Container, allocator := context.allocator) -> (ok: bool) {
	path := fmt.tprintf("/containers/%s?force=true&v=true", c.id)
	resp := request(c.client, "DELETE", path, allocator = allocator) or_return
	defer response_destroy(&resp, allocator)
	return resp.status == 204
}

// Resolve the ephemeral host port bound to a container port (e.g. "6379/tcp").
mapped_port :: proc(c: Container, container_port: string) -> (host_port: int, ok: bool) {
	insp := inspect_container(c, context.temp_allocator) or_return
	key := normalize_port(container_port, context.temp_allocator)
	bindings, has := insp.NetworkSettings.Ports[key]
	if !has {
		return 0, false
	}
	for b in bindings {
		if b.HostPort != "" {
			return strconv.parse_int(b.HostPort)
		}
	}
	return 0, false
}

// The host address mapped ports are reachable on. (Currently always loopback;
// would derive from a remote DOCKER_HOST once TCP transport is supported.)
host :: proc(c: Container) -> string {
	return "127.0.0.1"
}

// Look up a configured environment variable (e.g. "POSTGRES_USER"). Lets a
// custom Wait_Func or a module helper read back what was configured without
// threading extra state.
container_env :: proc(c: Container, key: string) -> (value: string, ok: bool) {
	for e in c.env {
		if len(e) > len(key) && e[:len(key)] == key && e[len(key)] == '=' {
			return e[len(key) + 1:], true
		}
	}
	return "", false
}

// --- Internal create/start ----------------------------------------------

@(private)
container_create :: proc(c: ^Container) -> (ok: bool) {
	wire: Wire_Create
	wire.Image = c.image
	wire.Cmd = c.cmd[:]
	wire.Env = c.env[:]

	// Label every managed container so the reaper can find it.
	wire.Labels = make(map[string]string, context.temp_allocator)
	wire.Labels[MANAGED_LABEL] = "true"
	wire.Labels[SESSION_LABEL] = session_id()

	if len(c.healthcheck) > 0 {
		// Fast defaults so test readiness doesn't wait Docker's 30s interval.
		wire.Healthcheck = Wire_Healthcheck {
			Test     = c.healthcheck[:],
			Interval = i64(1 * time.Second),
			Timeout  = i64(3 * time.Second),
			Retries  = 3,
		}
	}

	wire.ExposedPorts = make(map[string]struct {}, context.temp_allocator)
	wire.HostConfig.PortBindings = make(map[string][]Wire_Port_Binding, context.temp_allocator)
	for p in c.exposed_ports {
		key := normalize_port(p, context.temp_allocator)
		wire.ExposedPorts[key] = {}
		// Empty HostPort => Docker auto-assigns an ephemeral host port.
		bindings := make([]Wire_Port_Binding, 1, context.temp_allocator)
		bindings[0] = Wire_Port_Binding{HostPort = ""}
		wire.HostConfig.PortBindings[key] = bindings
	}

	id := create_from_wire(c.client, wire, c.name, c.allocator) or_return
	c.id = id
	return true
}

@(private)
container_start :: proc(c: Container, allocator := context.allocator) -> (ok: bool) {
	path := fmt.tprintf("/containers/%s/start", c.id)
	resp := request(c.client, "POST", path, allocator = allocator) or_return
	defer response_destroy(&resp, allocator)
	return resp.status == 204 || resp.status == 304 // 304 = already started
}

// Marshal a wire config, POST /containers/create, return the new id. Shared by
// container_create and the reaper (which needs raw Binds/Privileged).
@(private)
create_from_wire :: proc(
	client: Client,
	wire: Wire_Create,
	name := "",
	allocator := context.allocator,
) -> (
	id: string,
	ok: bool,
) {
	body, merr := json.marshal(wire, allocator = context.temp_allocator)
	if merr != nil {
		return "", false
	}

	path := "/containers/create"
	if name != "" {
		path = fmt.tprintf("/containers/create?name=%s", name)
	}
	resp := request(client, "POST", path, body, "application/json", allocator) or_return
	defer response_destroy(&resp, allocator)
	if resp.status != 201 {
		return "", false
	}

	Created :: struct {
		Id: string `json:"Id"`,
	}
	created: Created
	if json.unmarshal(resp.body, &created, allocator = context.temp_allocator) != nil {
		return "", false
	}
	return strings.clone(created.Id, allocator), true
}

// --- Helpers -------------------------------------------------------------

@(private)
split_image_tag :: proc(image: string) -> (name: string, tag: string) {
	slash := strings.last_index_byte(image, '/')
	colon := strings.last_index_byte(image, ':')
	if colon > slash {
		return image[:colon], image[colon + 1:]
	}
	return image, "latest"
}

@(private)
normalize_port :: proc(p: string, allocator := context.allocator) -> string {
	if strings.contains(p, "/") {
		return strings.clone(p, allocator)
	}
	return strings.concatenate({p, "/tcp"}, allocator)
}
